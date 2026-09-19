import SwiftUI
import AVKit
import AVFoundation
import Combine
import AppKit

// MARK: - Payload
struct PlayPayload: Codable, Hashable, Identifiable {
    var id: String { episodeKey }
    var seriesTitle: String
    var episodeName: String
    var episodeKey: String
    var sourceURL: String?
    var cover: String?
    var channelName: String?
    var episodes: [EpisodeItem]
    var playSource: String?
}

enum SpeedStore {
    private static let key = "GW_PlaybackRate"
    static var rate: Float {
        get { let v = UserDefaults.standard.float(forKey: key); return (v > 0 && v <= 3) ? v : 1 }
        set { UserDefaults.standard.set(min(max(newValue, 0.5), 3), forKey: key) }
    }
}

enum VolumeStore {
    private static let key = "GW_PlayerVolume"
    static var value: Float {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return 1 }
            return min(max(UserDefaults.standard.float(forKey: key), 0), 1)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: key) }
    }
}

enum PositionStore {
    private static func k(_ s: String) -> String { "GW_Pos_" + s }
    static func save(_ sec: Double, _ key: String) {
        guard sec > 5, !key.isEmpty else { return }
        UserDefaults.standard.set(sec, forKey: k(key))
    }
    static func load(_ key: String) -> Double { UserDefaults.standard.double(forKey: k(key)) }
    static func clear(_ key: String) { UserDefaults.standard.removeObject(forKey: k(key)) }
}

/// 秒 → 0:00 / 1:02:03
func gwTimeString(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "--:--" }
    let total = Int(t.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - 视频渲染层（消除 AVPictureInPicturePlayerLayerView 层级冲突警告）
final class PlayerSurfaceView: NSView {
    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let onReady: (PlayerSurfaceView) -> Void

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let v = PlayerSurfaceView()
        v.playerLayer.player = player
        let cb = onReady
        DispatchQueue.main.async { cb(v) }
        return v
    }
    func updateNSView(_ v: PlayerSurfaceView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// 拿到承载视图所在的 NSWindow（用于全屏切换）
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        let cb = onWindow
        DispatchQueue.main.async { cb(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        let cb = onWindow
        DispatchQueue.main.async { cb(v.window) }
    }
}

// MARK: - 播放模型
@MainActor
final class PlayerModel: ObservableObject {

    /// ⭐ 播放状态机：把「意图」和「实际状态」彻底分开
    enum Phase: Equatable {
        case idle       // 空
        case loading    // 首次解析 / 起播中
        case playing    // 真正在出画面
        case buffering  // 想播但卡住了（网络/解码/seek）
        case paused     // 用户主动暂停或播完
        case failed     // 出错
    }

    let player = AVPlayer()

    // MARK: 对外状态
    @Published var phase: Phase = .idle
    @Published var loading = true
    @Published var error: String?
    @Published var current: EpisodeItem?
    @Published var isLocal = false

    /// 真正在出画面（用于：控制栏自动隐藏、防休眠判断）
    @Published var isPlaying = false
    /// ⭐ 用户「想播」的意图（用于：播放/暂停按钮图标）—— 卡顿时依然为 true
    @Published var intendsToPlay = false
    /// ⭐ 正在卡顿 / 缓冲
    @Published var isBuffering = false
    /// ⭐ 去抖后真正显示的转圈（避免 seek 时闪一下）
    @Published var showBusySpinner = false
    /// ⭐ 卡了较久 → 提示网络可能有问题
    @Published var slowNetwork = false
    /// ⭐ 卡太久 → 给用户手动"重新加载"按钮
    @Published var offerManualRetry = false

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var isScrubbing = false
    @Published var scrubTime: Double = 0

    @Published var rate: Float = SpeedStore.rate
    @Published var volume: Float = VolumeStore.value
    @Published var isMuted = false
    @Published var isPiPActive = false
    @Published var pipReady = false

    var payload: PlayPayload?
    var onEnded: (() -> Void)?

    // MARK: 私有
    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var stallObs: NSObjectProtocol?
    private var failEndObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var waitReasonObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var keepUpObs: NSKeyValueObservation?
    private var pip: AVPictureInPictureController?
    private var sleepToken: NSObjectProtocol?
    private var episodeKey = ""
    private var lastSavedAt: Double = -100

    /// 用户意图（唯一真源）
    private var wantsPlayback = false
    /// 起播/恢复时要跳到的位置
    private var pendingStart: Double?

    // 卡顿看门狗
    private var watchdog: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var lastRecoveryAt = Date.distantPast
    private var isRecovering = false

    // 时间线
    private let spinnerDelay: UInt64        = 350_000_000      // 0.35s 后才转圈
    private let slowHintDelay: UInt64       = 5_650_000_000    // 累计 ~6s 提示网络慢
    private let autoRecoverDelay: UInt64    = 9_000_000_000    // 累计 ~15s 自动自愈
    private let manualRetryDelay: UInt64    = 10_000_000_000   // 累计 ~25s 给手动按钮

    /// UI 用的"当前时间"（拖动时显示拖动位置）
    var displayTime: Double { isScrubbing ? scrubTime : currentTime }

    init() {
        player.volume = VolumeStore.value
        player.actionAtItemEnd = .pause
        observeTimeControlStatus()
    }

    // MARK: - 载入
    func load(payload p: PlayPayload,
              episode: EpisodeItem,
              startAt: Double? = nil,
              resetRecovery: Bool = true) async {

        payload = p; current = episode
        teardownItemObservers()
        stopWatchdog()

        wantsPlayback = false          // 起播前意图归零，readyToPlay 后再置 true
        loading = true; error = nil
        currentTime = 0; duration = 0; bufferedTime = 0
        isScrubbing = false; lastSavedAt = -100
        episodeKey = episode.url
        pendingStart = startAt
        if resetRecovery { recoveryAttempts = 0 }
        recomputePhase()

        var target: URL?
        if let local = HLSDownloadManager.shared.localURL(forEpisodeKey: episode.url) {
            target = local; isLocal = true
        } else {
            isLocal = false
            do {
                let real = try await VideoAPI.resolveRealURL(episodeURL: episode.url)
                target = URL(string: real)
            } catch {
                fail(with: error.localizedDescription)
                return
            }
        }
        guard let url = target else {
            fail(with: T("无法播放", "Unable to play"))
            return
        }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if !isLocal { item.preferredForwardBufferDuration = 10 }
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = !isLocal

        let key = episode.url

        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            guard let self else { return }
            let status = observed.status
            let errText = observed.error?.localizedDescription
            Task { @MainActor in self.handleStatus(status, errorText: errText, episodeKey: key) }
        }

        // ⭐ 缓冲相关 KVO：在进入 Task 之前解除 weak 绑定，避免 Swift 6 报错
        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
        keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }

        // ⭐ 0.2s 一次：驱动进度条 / 缓冲 / 断点续播存档
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
                guard let self else { return }
                let sec = t.seconds
                Task { @MainActor in self.tick(sec) }
            }

        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                PositionStore.clear(key)
                self.wantsPlayback = false
                self.recomputePhase()
                self.onEnded?()
            }
        }

        // ⭐ 卡顿通知
        stallObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                                         object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }

        // ⭐ 播放中断通知
        failEndObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                           object: item, queue: .main) { [weak self] note in
            guard let self else { return }
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                if self.recoveryAttempts < 2 {
                    await self.recoverNow(hard: true)
                } else {
                    self.fail(with: msg ?? T("播放中断", "Playback interrupted"))
                }
            }
        }

        recordPlayback(p, episode)
    }

    private func handleStatus(_ status: AVPlayerItem.Status, errorText: String?, episodeKey: String) {
        switch status {
        case .readyToPlay:
            loading = false
            if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }

            let saved = PositionStore.load(episodeKey)
            let startAt = pendingStart ?? (saved > 5 ? saved : 0)
            pendingStart = nil
            if startAt > 1 {
                player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
                currentTime = startAt
            }
            resumePlayback()
        case .failed:
            fail(with: errorText ?? T("播放失败", "Playback failed"))
        default:
            recomputePhase()
        }
    }

    private func fail(with msg: String) {
        loading = false
        error = msg
        wantsPlayback = false
        stopWatchdog()
        recomputePhase()
    }

    private func tick(_ sec: Double) {
        guard sec.isFinite else { return }
        if !isScrubbing { currentTime = sec }
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
            if let r = item.loadedTimeRanges.last?.timeRangeValue {
                let end = r.start.seconds + r.duration.seconds
                if end.isFinite { bufferedTime = end }
            }
        }
        if abs(sec - lastSavedAt) >= 5 {
            lastSavedAt = sec
            PositionStore.save(sec, episodeKey)
        }
        if let p = pip {
            let active = p.isPictureInPictureActive
            if active != isPiPActive { isPiPActive = active }
        }
        // 连续顺畅播放一段时间后，重置自愈计数
        if phase == .playing, recoveryAttempts > 0,
           Date().timeIntervalSince(lastRecoveryAt) > 20 {
            recoveryAttempts = 0
        }
    }

    private func recordPlayback(_ p: PlayPayload, _ ep: EpisodeItem) {
        let ident = AuthManager.shared.trackIdentity
        TrackingManager.shared.track(.play, userId: ident.id, userType: ident.type,
                                     videoURL: ep.url,
                                     videoTitle: "\(p.seriesTitle) · \(ep.name)",
                                     source: p.playSource)
        PlayRecordStore.shared.add(title: p.seriesTitle, episode: ep.name, url: ep.url,
                                   cover: p.cover, channel: p.channelName, source: p.sourceURL)
        SeriesTrackManager.shared.recordWatch(sourceURL: p.sourceURL, title: p.seriesTitle,
                                             cover: p.cover, episodeName: ep.name,
                                             channelName: p.channelName)
    }

    // MARK: - 播放控制
    func togglePlay() {
        if wantsPlayback { pausePlayback() } else { resumePlayback() }
    }

    private func resumePlayback() {
        guard error == nil else { return }
        wantsPlayback = true
        player.play()
        player.rate = SpeedStore.rate
        rate = SpeedStore.rate
        recomputePhase()
    }

    private func pausePlayback() {
        wantsPlayback = false
        player.pause()
        recomputePhase()
    }

    func setRate(_ r: Float) {
        SpeedStore.rate = r
        rate = r
        if wantsPlayback { player.rate = r }
    }

    /// 相对跳转（±15 秒 / ±5 秒）
    func seek(by delta: Double) { seek(to: displayTime + delta) }

    func seek(to t: Double) {
        let upper = duration > 1 ? duration - 0.3 : max(t, 0)
        let clamped = min(max(0, t), upper)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
        PositionStore.save(clamped, episodeKey)
        lastSavedAt = clamped
        recomputePhase()
    }

    /// 拖动进度条时的实时预览（不真正 seek，拖完再跳）
    func previewScrub(_ t: Double) { isScrubbing = true; scrubTime = t }
    func endScrub(_ t: Double) {
        scrubTime = t
        seek(to: t)
        isScrubbing = false
    }

    func setVolume(_ v: Float) {
        let nv = min(max(v, 0), 1)
        volume = nv
        player.volume = nv
        VolumeStore.value = nv
        if nv > 0, isMuted { isMuted = false; player.isMuted = false }
    }
    func nudgeVolume(_ d: Float) { setVolume(volume + d) }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }

    // MARK: - ⭐ 状态机
    private func observeTimeControlStatus() {
        tcsObs = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
        waitReasonObs = player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
    }

    private func recomputePhase() {
        let newPhase: Phase
        if error != nil {
            newPhase = .failed
        } else if loading {
            newPhase = .loading
        } else {
            switch player.timeControlStatus {
            case .playing:
                newPhase = .playing
            case .waitingToPlayAtSpecifiedRate:
                newPhase = wantsPlayback ? .buffering : .paused
            case .paused:
                newPhase = wantsPlayback ? .buffering : .paused
            @unknown default:
                newPhase = wantsPlayback ? .buffering : .paused
            }
        }

        let cameFromLoading = (phase == .loading)

        if phase != newPhase { phase = newPhase }

        let playing = (newPhase == .playing)
        if isPlaying != playing { isPlaying = playing }

        let intent = wantsPlayback && newPhase != .failed
        if intendsToPlay != intent { intendsToPlay = intent }

        let buffering = (newPhase == .buffering)
        if isBuffering != buffering {
            isBuffering = buffering
            if buffering {
                startWatchdog(immediate: cameFromLoading)
            } else {
                stopWatchdog()
            }
        }

        updateSleepAssertion()
    }

    // MARK: - ⭐ 卡顿看门狗
    private func startWatchdog(immediate: Bool) {
        watchdog?.cancel()
        if immediate { showBusySpinner = true }
        watchdog = Task { @MainActor [weak self] in
            guard let self else { return }

            if !immediate {
                try? await Task.sleep(nanoseconds: self.spinnerDelay)
                guard !Task.isCancelled, self.isBuffering else { return }
                self.showBusySpinner = true
            }

            try? await Task.sleep(nanoseconds: self.slowHintDelay)
            guard !Task.isCancelled, self.isBuffering else { return }
            self.slowNetwork = true

            try? await Task.sleep(nanoseconds: self.autoRecoverDelay)
            guard !Task.isCancelled, self.isBuffering else { return }
            await self.recoverNow(hard: self.recoveryAttempts >= 1)

            try? await Task.sleep(nanoseconds: self.manualRetryDelay)
            guard !Task.isCancelled, self.isBuffering else { return }
            self.offerManualRetry = true
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel(); watchdog = nil
        if showBusySpinner { showBusySpinner = false }
        if slowNetwork { slowNetwork = false }
        if offerManualRetry { offerManualRetry = false }
    }

    private func recoverNow(hard: Bool) async {
        guard !isRecovering, let p = payload, let ep = current else { return }
        isRecovering = true
        recoveryAttempts += 1
        lastRecoveryAt = Date()
        let at = currentTime

        if hard && !isLocal {
            await load(payload: p, episode: ep, startAt: at, resetRecovery: false)
        } else {
            player.pause()
            player.seek(to: CMTime(seconds: at, preferredTimescale: 600)) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.resumePlayback() }
            }
        }
        isRecovering = false
    }

    /// UI 上的"重新加载"
    func retryNow() {
        guard let p = payload, let ep = current else { return }
        let at = currentTime
        offerManualRetry = false
        Task { await load(payload: p, episode: ep, startAt: at, resetRecovery: true) }
    }

    // MARK: - 画中画
    func attach(surface: PlayerSurfaceView) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pip = AVPictureInPictureController(playerLayer: surface.playerLayer)
        pipReady = true
    }
    func togglePiP() {
        guard let p = pip else { return }
        if p.isPictureInPictureActive { p.stopPictureInPicture() } else { p.startPictureInPicture() }
    }

    // MARK: - 防休眠
    private func updateSleepAssertion() {
        let shouldHold = wantsPlayback && error == nil
        if shouldHold {
            if sleepToken == nil {
                sleepToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                    reason: "OVideo playback")
            }
        } else {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        if let t = sleepToken {
            ProcessInfo.processInfo.endActivity(t)
            sleepToken = nil
        }
    }

    // MARK: - 清理
    func stop() {
        wantsPlayback = false
        player.pause()
        if let p = pip, p.isPictureInPictureActive { p.stopPictureInPicture() }
        teardownItemObservers()
        stopWatchdog()
        releaseSleepAssertion()
        player.replaceCurrentItem(with: nil)
        pip = nil
        pipReady = false
        phase = .idle
        isPlaying = false; intendsToPlay = false; isBuffering = false
    }

    private func teardownItemObservers() {
        if let t = timeObs { player.removeTimeObserver(t); timeObs = nil }
        for o in [endObs, stallObs, failEndObs].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(o)
        }
        endObs = nil; stallObs = nil; failEndObs = nil
        statusObs?.invalidate(); statusObs = nil
        bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
        keepUpObs?.invalidate(); keepUpObs = nil
    }
}

// MARK: - 自绘时间轴
struct TimelineSlider: View {
    let duration: Double
    let current: Double
    let buffered: Double
    var buffering: Bool = false
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var hoverX: CGFloat?
    @State private var hoverTime: Double = 0
    @State private var pulse = false

    private let barHeight: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let usable = duration > 0
            let ratio = usable ? min(max((dragging ? dragValue : current) / duration, 0), 1) : 0
            let bufRatio = usable ? min(max(buffered / duration, 0), 1) : 0
            let active = dragging || hoverX != nil
            let knob: CGFloat = active ? 13 : 9

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: barHeight)
                Capsule().fill(Color.white.opacity(0.38))
                    .frame(width: w * CGFloat(bufRatio), height: barHeight)
                Capsule().fill(Color.accentColor)
                    .frame(width: w * CGFloat(ratio), height: barHeight)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(radius: 2)
                    .opacity(buffering && !dragging ? (pulse ? 0.35 : 1) : 1)
                    .offset(x: w * CGFloat(ratio) - knob / 2)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard usable else { return }
                switch phase {
                case .active(let p):
                    let x = min(max(0, p.x), w)
                    hoverX = x
                    hoverTime = duration * Double(x / w)
                case .ended:
                    if !dragging { hoverX = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard usable else { return }
                        dragging = true
                        let x = min(max(0, v.location.x), w)
                        dragValue = duration * Double(x / w)
                        hoverX = x; hoverTime = dragValue
                        onScrub(dragValue)
                    }
                    .onEnded { v in
                        guard usable else { return }
                        let x = min(max(0, v.location.x), w)
                        dragging = false
                        onCommit(duration * Double(x / w))
                    }
            )
            .overlay(alignment: .topLeading) { tooltip(width: w) }
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 22)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private func tooltip(width: CGFloat) -> some View {
        if let x = hoverX, duration > 0 {
            Text(gwTimeString(dragging ? dragValue : hoverTime))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15)))
                .fixedSize()
                .offset(x: min(max(x - 27, 0), max(width - 54, 0)), y: -28)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

// MARK: - 播放窗口
struct PlayerWindowView: View {
    let payload: PlayPayload
    @StateObject private var model = PlayerModel()
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject private var quota = QuotaManager.shared
    @AppStorage("GW_AutoNext") private var autoNext = true

    @State private var showEpisodes = false
    @State private var showReport = false
    @State private var pendingEp: EpisodeItem?
    @State private var showConsume = false
    @State private var showSubscribe = false

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @State private var isFullScreen = false

    @FocusState private var isPlayPauseFocused: Bool

    private var modalUp: Bool { showReport || showSubscribe || showConsume }
    private var currentIndex: Int {
        payload.episodes.firstIndex(where: { $0.url == model.current?.url }) ?? 0
    }
    private var barVisible: Bool {
        controlsVisible || !model.isPlaying || model.loading || model.isBuffering
    }
    private var busyVisible: Bool {
        model.error == nil && (model.loading || model.showBusySpinner)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(player: model.player) { v in model.attach(surface: v) }
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { bumpControls() }
                }
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture(count: 1) { model.togglePlay() }

            if busyVisible {
                busyOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: busyVisible)
            }

            if let e = model.error { errorOverlay(e) }

            VStack(spacing: 0) {
                Spacer()
                controlBar
            }
            .opacity(barVisible ? 1 : 0)
            .allowsHitTesting(barVisible)
            .animation(.easeInOut(duration: 0.22), value: barVisible)

            extraShortcuts
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(WindowAccessor { w in if window !== w { window = w } })
        .navigationTitle(isFullScreen ? "" : "\(payload.seriesTitle) · \(model.current?.name ?? payload.episodeName)")
        .toolbar(isFullScreen ? .hidden : .visible)
        .toolbar {
            ToolbarItemGroup {
                if payload.episodes.count > 1 {
                    Button { showEpisodes = true } label: {
                        Label(lang.t("选集", "Episodes"), systemImage: "list.bullet")
                    }
                    .popover(isPresented: $showEpisodes) { episodePopover }
                }
                if model.isLocal {
                    Label(lang.t("离线", "Offline"), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                }
                Button { showReport = true } label: {
                    Label(lang.t("反馈修复", "Report"), systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .task {
            let ep = payload.episodes.first(where: { $0.url == payload.episodeKey })
                ?? EpisodeItem(number: "1", name: payload.episodeName, url: payload.episodeKey)
            model.onEnded = { if autoNext { jump(1) } }

            if HLSDownloadManager.shared.localURL(forEpisodeKey: ep.url) != nil {
                await model.load(payload: payload, episode: ep)
            } else {
                select(ep)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isPlayPauseFocused = true
            }
        }
        .onDisappear {
            hideTask?.cancel()
            model.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === window { isFullScreen = false }
        }
        .onChangeCompat(of: model.isPlaying) { playing in
            if playing { bumpControls() } else { controlsVisible = true; hideTask?.cancel() }
        }
        .onChangeCompat(of: model.isBuffering) { buffering in
            if buffering {
                controlsVisible = true
                hideTask?.cancel()
                NSCursor.setHiddenUntilMouseMoves(false)
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(title: "\(payload.seriesTitle) · \(model.current?.name ?? "")",
                        sourceURL: payload.sourceURL ?? payload.episodeKey,
                        episodeURL: model.current?.url ?? payload.episodeKey,
                        channel: payload.channelName, episode: model.current?.name,
                        realURL: nil)
        }
        .sheet(isPresented: $showSubscribe) { SubscriptionView() }
        .alert(lang.t("使用免费点数", "Use 1 Free Pass"), isPresented: $showConsume) {
            Button(lang.t("取消", "Cancel"), role: .cancel) { pendingEp = nil }
            Button(lang.t("确认使用", "Confirm")) { Task { await consumeAndPlay() } }
        } message: {
            Text(quota.consumeNote(lang.isEnglish) + "\n" + quota.remainingSummary(lang.isEnglish))
        }
    }

    // MARK: 忙碌 / 卡顿遮罩
    private var busyOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)

            Text(busyText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            if model.offerManualRetry {
                HStack(spacing: 10) {
                    Button(lang.t("重新加载", "Reload")) { model.retryNow() }
                        .buttonStyle(.borderedProminent)
                    Button(lang.t("反馈修复", "Report")) { showReport = true }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
        .allowsHitTesting(model.offerManualRetry)
        .accessibilityLabel(busyText)
    }

    private var busyText: String {
        if model.loading { return lang.t("正在加载…", "Loading…") }
        if model.offerManualRetry {
            return lang.t("加载一直没完成，可以重新加载或换个线路",
                          "Still not loading. Try reloading or another source.")
        }
        if model.slowNetwork {
            return lang.t("网络似乎不太稳定，正在缓冲…", "Network seems unstable, buffering…")
        }
        return lang.t("缓冲中…", "Buffering…")
    }

    // MARK: 错误层
    private func errorOverlay(_ e: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.orange)
            Text(e).foregroundStyle(.white)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button(lang.t("重试", "Retry")) {
                    if let c = model.current {
                        Task { await model.load(payload: payload, episode: c) }
                    }
                }
                Button(lang.t("反馈修复", "Report")) { showReport = true }
            }
        }
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 控制条
    private var controlBar: some View {
        VStack(spacing: 4) {
            TimelineSlider(duration: model.duration,
                           current: model.displayTime,
                           buffered: model.bufferedTime,
                           buffering: model.isBuffering,
                           onScrub: { model.previewScrub($0) },
                           onCommit: { model.endScrub($0) })

            HStack(spacing: 14) {
                Text(gwTimeString(model.displayTime))
                    .font(.system(size: 11).monospacedDigit())
                Text("/").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(gwTimeString(model.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))

                if model.isBuffering {
                    HStack(spacing: 5) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text(lang.t("缓冲中", "Buffering"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .transition(.opacity)
                }

                Spacer(minLength: 8)

                if payload.episodes.count > 1 {
                    ctrl("backward.end.fill", size: 13,
                         help: lang.t("上一集 (⌘[)", "Previous episode (⌘[)")) { jump(-1) }
                        .disabled(currentIndex <= 0)
                        .keyboardShortcut("[", modifiers: .command)
                        .focusable(false)
                }

                ctrl("gobackward.15", size: 19,
                     help: lang.t("后退 15 秒 (J)", "Back 15s (J)")) { model.seek(by: -15) }
                    .focusable(false)

                ctrl(model.intendsToPlay ? "pause.fill" : "play.fill", size: 22,
                     help: lang.t("播放 / 暂停 (空格)", "Play / Pause (Space)")) { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .focused($isPlayPauseFocused)
                    .accessibilityLabel(model.intendsToPlay
                                        ? lang.t("暂停", "Pause")
                                        : lang.t("播放", "Play"))

                ctrl("goforward.15", size: 19,
                     help: lang.t("前进 15 秒 (L/D)", "Forward 15s (L/D)")) { model.seek(by: 15) }
                    .focusable(false)

                if payload.episodes.count > 1 {
                    ctrl("forward.end.fill", size: 13,
                         help: lang.t("下一集 (⌘])", "Next episode (⌘])")) { jump(1) }
                        .disabled(currentIndex >= payload.episodes.count - 1)
                        .keyboardShortcut("]", modifiers: .command)
                        .focusable(false)
                }

                Spacer(minLength: 8)

                volumeControl
                speedMenu

                if payload.episodes.count > 1 {
                    ctrl("list.bullet", size: 14,
                         help: lang.t("选集", "Episodes")) { showEpisodes = true }
                        .popover(isPresented: $showEpisodes) { episodePopover }
                        .focusable(false)
                }
                if model.pipReady {
                    ctrl(model.isPiPActive ? "pip.exit" : "pip.enter", size: 14,
                         help: lang.t("画中画", "Picture in Picture")) { model.togglePiP() }
                        .focusable(false)
                }
                ctrl(isFullScreen ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right",
                     size: 14,
                     help: lang.t("全屏 (F)", "Full screen (F)")) { toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [])
                    .focusable(false)
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.18), value: model.isBuffering)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.28), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onContinuousHover { phase in
            if case .active = phase { controlsVisible = true; hideTask?.cancel() }
            else { bumpControls() }
        }
    }

    private func ctrl(_ icon: String, size: CGFloat, help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .frame(width: max(size + 10, 26), height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var volumeControl: some View {
        HStack(spacing: 5) {
            Button {
                model.toggleMute()
            } label: {
                Image(systemName: model.isMuted || model.volume == 0 ? "speaker.slash.fill"
                      : (model.volume < 0.45 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                    .font(.system(size: 12))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(lang.t("静音 (M)", "Mute (M)"))

            Slider(value: Binding(get: { Double(model.volume) },
                                  set: { model.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 72)
                .controlSize(.mini)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                Button {
                    model.setRate(Float(r))
                } label: {
                    HStack {
                        Text("\(r, specifier: "%g")x")
                        if abs(model.rate - Float(r)) < 0.01 { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Toggle(lang.t("播完自动下一集", "Auto play next"), isOn: $autoNext)
        } label: {
            Text("\(model.rate, specifier: "%g")x")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 36)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(lang.t("倍速", "Speed"))
    }

    private var extraShortcuts: some View {
        Group {
            Button("") { model.togglePlay() }.keyboardShortcut("k", modifiers: [])
            Button("") { model.seek(by: -15) }.keyboardShortcut("a", modifiers: [])
            Button("") { model.togglePlay() }.keyboardShortcut("s", modifiers: [])
            Button("") { model.seek(by: 15) }.keyboardShortcut("d", modifiers: [])
            Button("") { model.seek(by: -15) }.keyboardShortcut("j", modifiers: [])
            Button("") { model.seek(by: 15)  }.keyboardShortcut("l", modifiers: [])

            Button("") { model.togglePlay() }.keyboardShortcut("p", modifiers: .command)
            Button("") { model.seek(by: -5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.seek(by: 5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.nudgeVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { model.nudgeVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { model.toggleMute() }.keyboardShortcut("m", modifiers: [])
            Button("") { model.retryNow() }.keyboardShortcut("r", modifiers: .command)

            if isFullScreen {
                Button("") { toggleFullScreen() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .disabled(modalUp)
    }

    // MARK: 控制条自动隐藏
    private func bumpControls() {
        controlsVisible = true
        hideTask?.cancel()
        guard model.isPlaying, !model.isBuffering, !modalUp else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, model.isPlaying, !model.isBuffering, !modalUp else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: 全屏
    private func toggleFullScreen() {
        (window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    // MARK: 选集
    private var episodePopover: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                ForEach(payload.episodes) { ep in
                    let isCur = ep.url == model.current?.url
                    let cached = HLSDownloadManager.shared.completedKeys.contains(ep.url)
                    Button {
                        showEpisodes = false; select(ep)
                    } label: {
                        Text(ep.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(isCur ? Color.accentColor.opacity(0.85)
                                              : Color.secondary.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(isCur ? .white : .primary)
                            .overlay(alignment: .topTrailing) {
                                if cached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 9)).foregroundStyle(.blue).padding(2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 380, height: 300)
    }

    private func jump(_ delta: Int) {
        let i = currentIndex + delta
        guard i >= 0, i < payload.episodes.count else { return }
        select(payload.episodes[i])
    }

    private func select(_ ep: EpisodeItem) {
        if HLSDownloadManager.shared.localURL(forEpisodeKey: ep.url) != nil {
            Task { await model.load(payload: payload, episode: ep) }
            return
        }
        switch decideAccess(episodeKey: ep.url, auth: auth, quota: quota) {
        case .allowed:      Task { await model.load(payload: payload, episode: ep) }
        case .needLogin:    auth.signInWithApple()
        case .needConsume:  pendingEp = ep; showConsume = true
        case .exhausted:    showSubscribe = true
        }
    }

    private func consumeAndPlay() async {
        guard let ep = pendingEp else { return }
        let uid = QuotaManager.currentUserId(auth: auth)
        let r = await quota.unlock(userId: uid, episodeKey: ep.url,
                                  title: "\(payload.seriesTitle) · \(ep.name)")
        switch r {
        case .success, .alreadyUnlocked: await model.load(payload: payload, episode: ep)
        default: showSubscribe = true
        }
        pendingEp = nil
    }
}

// MARK: - 观看记录
struct HistoryView: View {
    @ObservedObject var store = PlayRecordStore.shared
    @EnvironmentObject var lang: LanguageManager
    @EnvironmentObject var auth: AuthManager
    @ObservedObject var quota = QuotaManager.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showSubscribe = false

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableViewCompat(
                    title: lang.t("暂无观看记录", "No history"),
                    message: "",
                    systemImage: "clock.badge.questionmark")
            } else {
                List {
                    ForEach(store.records, id: \.videoURL) { r in
                        row(for: r)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(lang.t("观看记录", "History"))
        .toolbar {
            if !store.records.isEmpty {
                Button(lang.t("清空", "Clear All"), role: .destructive) { store.clear() }
            }
        }
        .sheet(isPresented: $showSubscribe) { SubscriptionView() }
    }

    @ViewBuilder
    private func row(for r: PlayRecord) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: VideoAPI.coverURL(r.coverImage))
                .frame(width: 42, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(r.videoTitle).font(.callout.weight(.semibold))
                Text(r.episodeName).font(.caption).foregroundStyle(Color.accentColor)
                Text(gwDateFormatter.string(from: r.playTime))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            Button { play(r) } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)

            Button { store.remove(r) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 3)
    }

    private func play(_ r: PlayRecord) {
        Task {
            switch decideAccess(episodeKey: r.videoURL, auth: auth, quota: quota) {
            case .allowed:
                break
            case .needLogin:
                auth.signInWithApple(); return
            case .needConsume:
                let uid = QuotaManager.currentUserId(auth: auth)
                let res = await quota.unlock(userId: uid, episodeKey: r.videoURL,
                                             title: "\(r.videoTitle) · \(r.episodeName)")
                if case .quotaExceeded = res { showSubscribe = true; return }
                if case .failed = res { showSubscribe = true; return }
            case .exhausted:
                showSubscribe = true; return
            }

            let fallback = EpisodeItem(number: "1", name: r.episodeName, url: r.videoURL)
            var eps: [EpisodeItem] = [fallback]
            if let src = r.sourceURL, !src.isEmpty,
               let best = optimalChannels((try? await VideoAPI.fetchPlaylist(url: src)) ?? []).first {
                let list = best.episodeItems()
                eps = list.contains(where: { $0.url == r.videoURL }) ? list : [fallback]
            }

            openWindow(id: "player", value: PlayPayload(
                seriesTitle: r.videoTitle, episodeName: r.episodeName, episodeKey: r.videoURL,
                sourceURL: r.sourceURL, cover: r.coverImage, channelName: r.channelName,
                episodes: eps, playSource: "history"))
        }
    }
}

// MARK: - 兼容工具
private let gwDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()