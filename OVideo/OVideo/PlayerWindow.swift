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

    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }

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
    let player = AVPlayer()

    @Published var loading = true
    @Published var error: String?
    @Published var current: EpisodeItem?
    @Published var isLocal = false

    @Published var isPlaying = false
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

    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var pip: AVPictureInPictureController?
    private var sleepToken: NSObjectProtocol?
    private var episodeKey = ""
    private var lastSavedAt: Double = -100

    /// UI 用的"当前时间"（拖动时显示拖动位置）
    var displayTime: Double { isScrubbing ? scrubTime : currentTime }

    init() {
        player.volume = VolumeStore.value
        player.actionAtItemEnd = .pause
        observeTimeControlStatus()
    }

    // MARK: 载入
    func load(payload p: PlayPayload, episode: EpisodeItem) async {
        payload = p; current = episode
        loading = true; error = nil
        teardownItemObservers()

        currentTime = 0; duration = 0; bufferedTime = 0
        isScrubbing = false; lastSavedAt = -100
        episodeKey = episode.url

        var target: URL?
        if let local = HLSDownloadManager.shared.localURL(forEpisodeKey: episode.url) {
            target = local; isLocal = true
        } else {
            isLocal = false
            do {
                let real = try await VideoAPI.resolveRealURL(episodeURL: episode.url)
                target = URL(string: real)
            } catch {
                self.error = error.localizedDescription
                self.loading = false
                return
            }
        }
        guard let url = target else {
            error = T("无法播放", "Unable to play"); loading = false; return
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
            Task { @MainActor in
                self.handleStatus(status, errorText: errText, episodeKey: key)
            }
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
                self.onEnded?()
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
            if saved > 5 {
                player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
                currentTime = saved
            }
            player.play()
            player.rate = SpeedStore.rate
            rate = SpeedStore.rate
        case .failed:
            loading = false
            error = errorText ?? T("播放失败", "Playback failed")
        default:
            break
        }
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

    // MARK: 播放控制
    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
            player.rate = SpeedStore.rate
        }
    }

    func setRate(_ r: Float) {
        SpeedStore.rate = r
        rate = r
        if player.timeControlStatus == .playing { player.rate = r }
    }

    /// ⭐ 相对跳转（±15 秒 / ±5 秒）
    func seek(by delta: Double) { seek(to: displayTime + delta) }

    func seek(to t: Double) {
        let upper = duration > 1 ? duration - 0.3 : max(t, 0)
        let clamped = min(max(0, t), upper)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        PositionStore.save(clamped, episodeKey)
        lastSavedAt = clamped
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

    // MARK: 画中画
    func attach(surface: PlayerSurfaceView) {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let c = AVPictureInPictureController(playerLayer: surface.playerLayer)
        pip = c
        pipReady = true
    }
    func togglePiP() {
        guard let p = pip else { return }
        if p.isPictureInPictureActive { p.stopPictureInPicture() } else { p.startPictureInPicture() }
    }

    // MARK: ⭐ 播放时禁止休眠
    private func observeTimeControlStatus() {
        tcsObs = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            guard let self else { return }
            let playing = (p.timeControlStatus == .playing)
            Task { @MainActor in self.setPlaying(playing) }
        }
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing {
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

    // MARK: 清理
    func stop() {
        player.pause()
        if let p = pip, p.isPictureInPictureActive { p.stopPictureInPicture() }
        teardownItemObservers()
        releaseSleepAssertion()
        player.replaceCurrentItem(with: nil)
        pip = nil
        pipReady = false
    }

    private func teardownItemObservers() {
        if let t = timeObs { player.removeTimeObserver(t); timeObs = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        statusObs?.invalidate(); statusObs = nil
    }
    // ⚠️ 不写 deinit：@MainActor 类的 deinit 访问隔离属性在 Swift 6 是错误；
    //    视图 onDisappear 调用 stop() 完成清理。
}

// MARK: - ⭐ 自绘时间轴（悬停 / 拖动都显示具体时间）
struct TimelineSlider: View {
    let duration: Double
    let current: Double
    let buffered: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var hoverX: CGFloat?
    @State private var hoverTime: Double = 0

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
                    .offset(x: w * CGFloat(ratio) - knob / 2)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            // ⭐ 悬停显示时间
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
            // ⭐ 点击 / 拖动跳转
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

    // ⭐ 优化 3：焦点默认落在播放/暂停按钮上
    @FocusState private var isPlayPauseFocused: Bool

    private var modalUp: Bool { showReport || showSubscribe || showConsume }
    private var currentIndex: Int {
        payload.episodes.firstIndex(where: { $0.url == model.current?.url }) ?? 0
    }
    private var barVisible: Bool { controlsVisible || !model.isPlaying || model.loading }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(player: model.player) { v in model.attach(surface: v) }
                .ignoresSafeArea()

            // 透明层：负责 hover 唤出控制条 + 单击暂停 / 双击全屏
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { bumpControls() }
                }
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture(count: 1) { model.togglePlay() }

            if model.loading {
                ProgressView().controlSize(.large).tint(.white)
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
        // ⭐ 优化 1：全屏时隐藏上方整条 toolbar 与标题横条，做到真正全屏
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

            // ⭐ 优化 3：加载后自动将键盘焦点指向播放按钮
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

    // MARK: ⭐ 控制条
    private var controlBar: some View {
        VStack(spacing: 4) {
            TimelineSlider(duration: model.duration,
                           current: model.displayTime,
                           buffered: model.bufferedTime,
                           onScrub: { model.previewScrub($0) },
                           onCommit: { model.endScrub($0) })

            HStack(spacing: 14) {
                Text(gwTimeString(model.displayTime))
                    .font(.system(size: 11).monospacedDigit())
                Text("/").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(gwTimeString(model.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))

                Spacer(minLength: 8)

                // 上一集
                if payload.episodes.count > 1 {
                    ctrl("backward.end.fill", size: 13,
                         help: lang.t("上一集 (⌘[)", "Previous episode (⌘[)")) { jump(-1) }
                        .disabled(currentIndex <= 0)
                        .keyboardShortcut("[", modifiers: .command)
                        .focusable(false)
                }

                // 后退 15 秒（快捷键 J，不抢焦点）
                ctrl("gobackward.15", size: 19,
                     help: lang.t("后退 15 秒 (J)", "Back 15s (J)")) { model.seek(by: -15) }
                    .keyboardShortcut("j", modifiers: [])
                    .focusable(false)

                // ⭐ 播放 / 暂停（默认 Tab 焦点落在该按钮上）
                ctrl(model.isPlaying ? "pause.fill" : "play.fill", size: 22,
                     help: lang.t("播放 / 暂停 (空格)", "Play / Pause (Space)")) { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .focused($isPlayPauseFocused)

                // 前进 15 秒（快捷键 L，不抢焦点）
                ctrl("goforward.15", size: 19,
                    help: lang.t("前进 15 秒 (L/D)", "Forward 15s (L/D)")) { model.seek(by: 15) }
                    .keyboardShortcut("l", modifiers: [])
                    .focusable(false)

                // 下一集
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
                // 全屏（快捷键 F）
                ctrl(isFullScreen ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right",
                     size: 14,
                     help: lang.t("全屏 (F)", "Full screen (F)")) { toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [])
                    .focusable(false)
            }
            .frame(height: 34)
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
            // 鼠标在控制条上时不要自动隐藏
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

    /// ⭐ 其余快捷键（零尺寸隐形按钮，始终在视图树里所以永远生效）
    private var extraShortcuts: some View {
        Group {
            // --- 核心播放控制 (J/K/L & A/S/D) ---
            // (注：J 与 L 已分别直接绑定在 controlBar 的后退与前进按钮上)
            Button("") { model.togglePlay() }.keyboardShortcut("k", modifiers: []) // K: 播放/暂停
            Button("") { model.seek(by: -15) }.keyboardShortcut("a", modifiers: []) // A: 后退 15s
            Button("") { model.togglePlay() }.keyboardShortcut("s", modifiers: []) // S: 播放/暂停
            Button("") { model.seek(by: 15) }.keyboardShortcut("d", modifiers: [])  // D: 前进 15s

            // --- 其他已有快捷键 ---
            Button("") { model.togglePlay() }.keyboardShortcut("p", modifiers: .command)
            Button("") { model.seek(by: -5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.seek(by: 5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.nudgeVolume(0.05) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { model.nudgeVolume(-0.05) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { model.toggleMute() }.keyboardShortcut("m", modifiers: [])
            
            // 全屏状态下按 ESC 退出全屏
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
        guard model.isPlaying, !modalUp else { return }
        hideTask = Task { @MainActor in
            // ⭐ 将 3 秒修改为 1.5 秒（根据喜好调整，例如 1.2 秒可写为 1_200_000_000）
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, model.isPlaying, !modalUp else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: ⭐ c. 全屏
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

// MARK: - 观看记录（逻辑未变）
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