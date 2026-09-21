// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoPlayerView.swift

import SwiftUI
import AVKit
import MediaPlayer

// MARK: - 倍速记忆
enum PlaybackSpeedStore {
    private static let key = "ONews_PlaybackSpeed"
    static var rate: Float {
        get {
            let v = UserDefaults.standard.float(forKey: key)
            return (v > 0 && v <= 2.0) ? v : 1.0
        }
        set {
            let clamped = min(max(newValue, 0.5), 2.0)
            UserDefaults.standard.set(clamped, forKey: key)
        }
    }
}

// MARK: - 播放进度记忆（LRU）
enum PlaybackPositionStore {
    private static let prefix = "ONews_Pos_"
    private static let indexKey = "ONews_PosIndex"
    private static let maxEntries = 300

    private static func storageKey(_ raw: String) -> String { prefix + raw }

    static func save(_ seconds: Double, forKey raw: String) {
        guard seconds.isFinite, seconds > 0, !raw.isEmpty else { return }
        let d = UserDefaults.standard
        let k = storageKey(raw)
        d.set(seconds, forKey: k)

        var index = d.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == k }
        index.append(k)
        if index.count > maxEntries {
            let overflow = index.count - maxEntries
            for old in index.prefix(overflow) { d.removeObject(forKey: old) }
            index.removeFirst(overflow)
        }
        d.set(index, forKey: indexKey)
    }

    static func load(forKey raw: String) -> Double {
        guard !raw.isEmpty else { return 0 }
        return UserDefaults.standard.double(forKey: storageKey(raw))
    }

    static func clear(forKey raw: String) {
        guard !raw.isEmpty else { return }
        let d = UserDefaults.standard
        let k = storageKey(raw)
        d.removeObject(forKey: k)
        var index = d.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == k }
        d.set(index, forKey: indexKey)
    }

    static func save(_ seconds: Double, for url: URL) { save(seconds, forKey: url.absoluteString) }
    static func load(for url: URL) -> Double { load(forKey: url.absoluteString) }
    static func clear(for url: URL) { clear(forKey: url.absoluteString) }
}

// MARK: - 广告防骗固定提示条
struct AdWarningBanner: View {
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
            Text(isGlobalEnglishMode
                 ? "Ads in the video are NOT from our platform. Do not tap them, to avoid being scammed."
                 : "视频内广告链接非本平台植入，切勿点击，防止被骗")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - ⭐️ 统一播放引擎
@MainActor
final class OVideoPlayerEngine: ObservableObject {

    enum Phase: Equatable { case idle, loading, playing, buffering, paused, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var showBusySpinner = false
    @Published private(set) var slowNetwork = false
    @Published private(set) var offerManualRetry = false
    @Published private(set) var hasStartedPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var errorText: String?
    @Published private(set) var playerGeneration = 0
    @Published private(set) var controlsRefreshToken = 0

    var isFullScreen = false
    var isPiPActive = false

    private(set) var player = AVPlayer()

    var resolver: (() async throws -> String)?

    private(set) var isLocal = false
    private var currentURL: URL?
    private var positionKey = ""
    private var currentTime: Double = 0
    private var duration: Double = 0
    private var lastSaved: Double = -100
    private var wantsPlayback = false
    private var wasPlayingBeforeBackground = true
    private var pendingStart: Double?

    private var statusObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var keepUpObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var waitObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var defaultRateObs: NSKeyValueObservation?
    private var periodicObs: Any?

    private var endObs: NSObjectProtocol?
    private var stallObs: NSObjectProtocol?
    private var failObs: NSObjectProtocol?

    private var watchdog: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var lastRecoveryAt = Date.distantPast
    private var isRecovering = false

    private var stallTimer: Timer?
    private var lastProgressTime: Double = -1
    private var lastProgressAt = Date()

    private let spinnerDelay: UInt64     =    350_000_000
    private let slowHintDelay: UInt64    =  5_650_000_000
    private let autoRecoverDelay: UInt64 =  9_000_000_000
    private let manualRetryDelay: UInt64 = 10_000_000_000

    private let networkForwardBuffer: TimeInterval = 10

    private var isEnglish: Bool { UserDefaults.standard.bool(forKey: "isGlobalEnglishMode") }

    init() {
        configureAudioSession()
        attachPlayerObservers()
        registerLifecycleObservers()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    func prepare(url: URL,
                 positionKey: String,
                 isLocal: Bool,
                 resolver: (() async throws -> String)? = nil,
                 startAt: Double? = nil,
                 resetRecovery: Bool = true) {

        teardownItemObservers()
        stopWatchdog()

        self.currentURL = url
        self.positionKey = positionKey
        self.isLocal = isLocal
        if resolver != nil { self.resolver = resolver }

        errorText = nil
        isPreparing = true
        hasStartedPlaying = false
        currentTime = startAt ?? 0
        duration = 0
        lastSaved = -100
        pendingStart = startAt
        wantsPlayback = true
        lastProgressTime = -1
        lastProgressAt = Date()
        if resetRecovery { recoveryAttempts = 0 }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if !isLocal {
            item.preferredForwardBufferDuration = networkForwardBuffer
        }

        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = !isLocal
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        if #available(iOS 12.0, *) { player.preventsDisplaySleepDuringVideoPlayback = true }
        if #available(iOS 16.0, *) { player.defaultRate = PlaybackSpeedStore.rate }

        player.replaceCurrentItem(with: item)

        attachItemObservers(item)
        startStallTimer()
        recomputePhase()
    }

    private func attachPlayerObservers() {
        tcsObs = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
        waitObs = player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
        rateObs = player.observe(\.rate, options: [.new]) { _, change in
            if let r = change.newValue, r > 0, r <= 2.0 { PlaybackSpeedStore.rate = r }
        }
        if #available(iOS 16.0, *) {
            defaultRateObs = player.observe(\.defaultRate, options: [.new]) { _, change in
                if let r = change.newValue, r > 0, r <= 2.0 { PlaybackSpeedStore.rate = r }
            }
        }
        periodicObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main) { [weak self] t in
                guard let self else { return }
                let sec = t.seconds
                Task { @MainActor in self.tick(sec) }
            }
    }

    private func teardownPlayerObservers() {
        if let t = periodicObs { player.removeTimeObserver(t); periodicObs = nil }
        tcsObs?.invalidate(); tcsObs = nil
        waitObs?.invalidate(); waitObs = nil
        rateObs?.invalidate(); rateObs = nil
        defaultRateObs?.invalidate(); defaultRateObs = nil
    }

    private func attachItemObservers(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            guard let self else { return }
            let status = observed.status
            let msg = observed.error?.localizedDescription
            Task { @MainActor in self.handleStatus(status, message: msg) }
        }
        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }
        keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.recomputePhase() }
        }

        let key = positionKey
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    PlaybackPositionStore.clear(forKey: key)
                    self.wantsPlayback = false
                    self.recomputePhase()
                }
            }

        stallObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if self.isLocal { await self.recoverNow(hard: false) }
                    else { self.recomputePhase() }
                }
            }

        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                guard let self else { return }
                let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription
                Task { @MainActor in
                    if self.recoveryAttempts < 2 {
                        await self.recoverNow(hard: true)
                    } else {
                        self.fail(with: msg ?? (self.isEnglish ? "Playback interrupted" : "播放中断"))
                    }
                }
            }
    }

    private func teardownItemObservers() {
        statusObs?.invalidate(); statusObs = nil
        bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
        keepUpObs?.invalidate(); keepUpObs = nil
        for o in [endObs, stallObs, failObs].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(o)
        }
        endObs = nil; stallObs = nil; failObs = nil
    }

    private func handleStatus(_ status: AVPlayerItem.Status, message: String?) {
        switch status {
        case .readyToPlay:
            isPreparing = false
            if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }

            let saved = PlaybackPositionStore.load(forKey: positionKey)
            var start = pendingStart ?? (saved > 5 ? saved : 0)
            pendingStart = nil
            if duration > 0, start > duration - 10 { start = 0 }
            if start > 1 {
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                currentTime = start
            }
            playAtPreferredRate()
            recomputePhase()

        case .failed:
            if !isLocal, recoveryAttempts < 2 {
                Task { await recoverNow(hard: true) }
            } else {
                fail(with: message ?? (isEnglish ? "Playback failed" : "视频播放失败"))
            }

        default:
            recomputePhase()
        }
    }

    private func fail(with msg: String) {
        isPreparing = false
        errorText = msg
        wantsPlayback = false
        stopWatchdog()
        stopStallTimer()
        recomputePhase()
    }

    private func playAtPreferredRate() {
        wantsPlayback = true
        if #available(iOS 16.0, *) {
            player.defaultRate = PlaybackSpeedStore.rate
            player.play()
        } else {
            player.play()
            let r = PlaybackSpeedStore.rate
            if r != 1.0 { player.rate = r }
        }
    }

    private func recomputePhase() {
        let newPhase: Phase
        if errorText != nil {
            newPhase = .failed
        } else if isPreparing {
            newPhase = .loading
        } else {
            switch player.timeControlStatus {
            case .playing:
                newPhase = .playing
            case .waitingToPlayAtSpecifiedRate:
                newPhase = .buffering
            case .paused:
                newPhase = .paused
            @unknown default:
                newPhase = .paused
            }
        }

        let cameFromLoading = (phase == .loading)
        if phase != newPhase { phase = newPhase }

        if newPhase == .playing, !hasStartedPlaying { hasStartedPlaying = true }

        if !isPreparing, !isRecovering {
            wantsPlayback = (player.timeControlStatus != .paused)
        }

        let busy = (newPhase == .buffering || newPhase == .loading)
        if isBuffering != (newPhase == .buffering) { isBuffering = (newPhase == .buffering) }

        if busy {
            if watchdog == nil { startWatchdog(immediate: newPhase == .loading || cameFromLoading) }
        } else {
            stopWatchdog()
        }
    }

    private func startWatchdog(immediate: Bool) {
        watchdog?.cancel()
        if immediate { showBusySpinner = true }
        watchdog = Task { @MainActor [weak self] in
            guard let self else { return }

            if !immediate {
                try? await Task.sleep(nanoseconds: self.spinnerDelay)
                guard !Task.isCancelled, self.isBusyNow else { return }
                self.showBusySpinner = true
            }

            try? await Task.sleep(nanoseconds: self.slowHintDelay)
            guard !Task.isCancelled, self.isBusyNow else { return }
            self.slowNetwork = true

            try? await Task.sleep(nanoseconds: self.autoRecoverDelay)
            guard !Task.isCancelled, self.isBusyNow else { return }
            await self.recoverNow(hard: self.recoveryAttempts >= 1)

            try? await Task.sleep(nanoseconds: self.manualRetryDelay)
            guard !Task.isCancelled, self.isBusyNow else { return }
            self.offerManualRetry = true
        }
    }

    private var isBusyNow: Bool { phase == .buffering || phase == .loading }

    private func stopWatchdog() {
        watchdog?.cancel(); watchdog = nil
        if showBusySpinner { showBusySpinner = false }
        if slowNetwork { slowNetwork = false }
        if offerManualRetry { offerManualRetry = false }
    }

    private func recoverNow(hard: Bool) async {
        guard !isRecovering, errorText == nil, recoveryAttempts < 3 else { return }
        isRecovering = true
        recoveryAttempts += 1
        lastRecoveryAt = Date()
        let at = max(0, currentTime)

        if hard {
            await hardReload(startAt: at)
        } else {
            player.pause()
            player.seek(to: CMTime(seconds: at, preferredTimescale: 600)) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.playAtPreferredRate()
                    self.recomputePhase()
                }
            }
        }
        isRecovering = false
    }

    private func hardReload(startAt: Double) async {
        if !isLocal, let resolver {
            if let s = try? await resolver(), let u = URL(string: s) {
                prepare(url: u, positionKey: positionKey, isLocal: false,
                        startAt: startAt, resetRecovery: false)
                bumpControlsRefresh()
                return
            }
        }
        if let u = currentURL {
            prepare(url: u, positionKey: positionKey, isLocal: isLocal,
                    startAt: startAt, resetRecovery: false)
            bumpControlsRefresh()
        }
    }

    private func bumpControlsRefresh() {
        guard !isFullScreen else { return }
        controlsRefreshToken += 1
    }

    func retryNow() {
        errorText = nil
        offerManualRetry = false
        recoveryAttempts = 0
        Task { await hardReload(startAt: max(0, currentTime)) }
    }

    private func startStallTimer() {
        stallTimer?.invalidate()
        lastProgressTime = -1
        lastProgressAt = Date()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.stallTimerTick() }
        }
    }

    private func stopStallTimer() { stallTimer?.invalidate(); stallTimer = nil }

    private func stallTimerTick() {
        guard errorText == nil, player.currentItem != nil else { return }
        guard player.timeControlStatus == .playing else {
            lastProgressTime = player.currentTime().seconds
            lastProgressAt = Date()
            return
        }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }

        if lastProgressTime >= 0, abs(now - lastProgressTime) < 0.05 {
            if Date().timeIntervalSince(lastProgressAt) > 2.5 {
                lastProgressAt = Date()
                Task { await recoverNow(hard: recoveryAttempts >= 2) }
            }
        } else {
            lastProgressTime = now
            lastProgressAt = Date()
            if recoveryAttempts > 0, Date().timeIntervalSince(lastRecoveryAt) > 20 {
                recoveryAttempts = 0
            }
        }
    }

    private func tick(_ sec: Double) {
        guard sec.isFinite, sec >= 0 else { return }
        currentTime = sec
        if sec > 0, !hasStartedPlaying { hasStartedPlaying = true }

        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
        }
        if abs(sec - lastSaved) >= 5 {
            lastSaved = sec
            PlaybackPositionStore.save(sec, forKey: positionKey)
        }
        if duration > 0, sec >= duration - 3 {
            PlaybackPositionStore.clear(forKey: positionKey)
        }
    }

    private func saveProgress() {
        let t = player.currentTime().seconds
        if t.isFinite, t > 0 { PlaybackPositionStore.save(t, forKey: positionKey) }
    }

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaServicesWereReset),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        Task { @MainActor in
            self.wasPlayingBeforeBackground = (self.player.timeControlStatus != .paused)
            self.saveProgress()
        }
    }

    @objc private func appWillEnterForeground() {
        Task { @MainActor in
            guard !self.isPiPActive else { return }
            self.configureAudioSession()

            let item = self.player.currentItem
            let broken = (item == nil) || (item?.status == .failed)
                || (item?.error != nil) || (self.player.error != nil)
            if broken {
                await self.recoverNow(hard: true)
                return
            }
            if self.wasPlayingBeforeBackground, self.player.timeControlStatus == .paused {
                self.playAtPreferredRate()
            }
            self.recomputePhase()
        }
    }

    @objc private func mediaServicesWereReset() {
        Task { @MainActor in
            self.configureAudioSession()
            let at = max(0, self.currentTime)
            self.teardownItemObservers()
            self.teardownPlayerObservers()
            self.player.replaceCurrentItem(with: nil)
            self.player = AVPlayer()
            self.attachPlayerObservers()
            self.playerGeneration += 1
            if let u = self.currentURL {
                self.prepare(url: u, positionKey: self.positionKey,
                             isLocal: self.isLocal, startAt: at, resetRecovery: false)
            }
        }
    }

    func pauseForDisappear() {
        guard !isPiPActive, !isFullScreen else { return }
        player.pause()
        saveProgress()
    }

    func teardown() {
        guard !isPiPActive else { return }
        wantsPlayback = false
        player.pause()
        saveProgress()
        stopWatchdog()
        stopStallTimer()
        teardownItemObservers()
        player.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
        isBuffering = false
    }

    var isBusyForUI: Bool {
        errorText == nil && (isPreparing || showBusySpinner)
    }

    var busyText: String {
        if isPreparing { return isEnglish ? "Loading…" : "正在加载…" }
        if offerManualRetry {
            return isEnglish ? "Still not loading. Try reloading or report it."
                             : "一直加载不出来，可以重新加载或反馈修复"
        }
        if slowNetwork {
            return isEnglish ? "Network seems unstable, buffering…" : "网络似乎不太稳定，正在缓冲…"
        }
        return isEnglish ? "Buffering…" : "缓冲中…"
    }
}

// MARK: - 生命周期可感知的播放控制器
@MainActor
final class LifecycleAVPlayerViewController: AVPlayerViewController {
    var onWillDisappear: (@MainActor () -> Void)?
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?()
    }
}

// MARK: - ⭐️ 播放画面
@MainActor
struct OVideoPlayerSurface: UIViewControllerRepresentable {
    let engine: OVideoPlayerEngine
    var onFullScreenChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = LifecycleAVPlayerViewController()
        c.allowsPictureInPicturePlayback = true
        c.delegate = context.coordinator
        c.videoGravity = .resizeAspect
        c.player = engine.player
        c.onWillDisappear = { [weak coordinator = context.coordinator] in
            coordinator?.handleWillDisappear()
        }
        context.coordinator.controller = c
        context.coordinator.installOverlay()
        return c
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        if vc.player !== engine.player { vc.player = engine.player }
        context.coordinator.syncOverlay(busy: engine.isBusyForUI, text: engine.busyText)
        context.coordinator.syncControlsRefresh(token: engine.controlsRefreshToken)
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    // ✅ 关键修复：加入 @preconcurrency 消除委托 cross main-actor 警告
    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        var parent: OVideoPlayerSurface
        weak var controller: AVPlayerViewController?
        private var overlayBox: UIView?
        private var overlayLabel: UILabel?
        private var lastControlsToken = 0
        private var orientationWork: DispatchWorkItem?
        private var targetMask: UIInterfaceOrientationMask?

        private var engine: OVideoPlayerEngine { parent.engine }

        init(_ parent: OVideoPlayerSurface) {
            self.parent = parent
            self.lastControlsToken = parent.engine.controlsRefreshToken
        }

        func handleWillDisappear() {
            if engine.isFullScreen || engine.isPiPActive { return }
            engine.pauseForDisappear()
        }

        func installOverlay() {
            guard let c = controller else { return }
            c.loadViewIfNeeded()
            guard let overlay = c.contentOverlayView else { return }

            let box = UIView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            box.layer.cornerRadius = 12
            box.isUserInteractionEnabled = false
            box.isHidden = true

            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = .white
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = UIColor.white.withAlphaComponent(0.9)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.numberOfLines = 2
            label.textAlignment = .center

            box.addSubview(spinner)
            box.addSubview(label)
            overlay.addSubview(box)

            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                box.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
                box.widthAnchor.constraint(lessThanOrEqualToConstant: 280),

                spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
                spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),

                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
                label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
            ])
            overlayBox = box
            overlayLabel = label
        }

        func syncOverlay(busy: Bool, text: String) {
            overlayLabel?.text = text
            overlayBox?.isHidden = !(engine.isFullScreen && busy)
        }

        func syncControlsRefresh(token: Int) {
            guard token != lastControlsToken else { return }
            lastControlsToken = token
            guard let c = controller, c.showsPlaybackControls, !engine.isFullScreen else { return }
            c.showsPlaybackControls = false
            Task { @MainActor in
                c.showsPlaybackControls = true
            }
        }

        func cleanup() {
            orientationWork?.cancel()
            overlayBox?.removeFromSuperview()
            overlayBox = nil; overlayLabel = nil
            if !engine.isPiPActive {
                engine.isFullScreen = false
                AppDelegate.orientationLock = .portrait
                performRotation(mask: .portrait)
            }
        }

        func playerViewController(_ pvc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator
                                  coordinator: UIViewControllerTransitionCoordinator) {
            setFullScreen(true)
            coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                guard let self else { return }
                Task { @MainActor in
                    self.setFullScreen(!ctx.isCancelled)
                    self.applyOrientation(fullScreen: !ctx.isCancelled)
                }
            }
        }

        func playerViewController(_ pvc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator
                                  coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                guard let self else { return }
                Task { @MainActor in
                    self.setFullScreen(ctx.isCancelled)
                    self.applyOrientation(fullScreen: ctx.isCancelled)
                }
            }
        }

        private func setFullScreen(_ v: Bool) {
            guard engine.isFullScreen != v else { return }
            engine.isFullScreen = v
            syncOverlay(busy: engine.isBusyForUI, text: engine.busyText)
            let cb = parent.onFullScreenChanged
            Task { @MainActor in
                cb?(v)
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ pvc: AVPlayerViewController) {
            engine.isPiPActive = true
            if engine.isFullScreen { setFullScreen(false) }
            AppDelegate.orientationLock = .portrait
        }

        func playerViewControllerDidStopPictureInPicture(_ pvc: AVPlayerViewController) {
            engine.isPiPActive = false
            if !engine.isFullScreen {
                Task { @MainActor [weak self] in
                    self?.applyOrientation(fullScreen: false)
                }
            }
        }

        func playerViewController(_ pvc: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                  completionHandler: @escaping (Bool) -> Void) {
            setFullScreen(false)
            applyOrientation(fullScreen: false)
            completionHandler(true)
        }

        private func applyOrientation(fullScreen: Bool) {
            let mask: UIInterfaceOrientationMask = fullScreen ? .landscape : .portrait
            AppDelegate.orientationLock = mask
            targetMask = mask
            orientationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let m = self.targetMask else { return }
                    self.performRotation(mask: m)
                }
            }
            orientationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        func performRotation(mask: UIInterfaceOrientationMask) {
            if #available(iOS 16.0, *) {
                guard let scene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                else { return }
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    #if DEBUG
                    print("requestGeometryUpdate: \(error.localizedDescription)")
                    #endif
                }
            } else {
                let o: UIInterfaceOrientation = (mask == .landscape) ? .landscapeRight : .portrait
                UIDevice.current.setValue(o.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }
    }
}

// MARK: - 旧签名兼容壳
struct VideoPlayerView: View {
    let videoURL: URL
    @Binding var isBuffering: Bool
    @Binding var hasStartedPlaying: Bool
    var onPlaybackFailed: ((String) -> Void)? = nil
    var onFullScreenChanged: ((Bool) -> Void)? = nil

    @StateObject private var engine = OVideoPlayerEngine()

    var body: some View {
        OVideoPlayerSurface(engine: engine, onFullScreenChanged: onFullScreenChanged)
            .onAppear {
                engine.prepare(url: videoURL,
                               positionKey: videoURL.absoluteString,
                               isLocal: videoURL.isFileURL)
            }
            .onDisappear { engine.teardown() }
            .onChange(of: engine.showBusySpinner) { _, v in isBuffering = v }
            .onChange(of: engine.hasStartedPlaying) { _, v in hasStartedPlaying = v }
            .onChange(of: engine.errorText) { _, v in if let v { onPlaybackFailed?(v) } }
    }
}

// MARK: - 缓冲指示器
struct PlayerLoadingIndicator: View {
    var text: String? = nil
    @State private var rotate = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                        .frame(width: 46, height: 46)
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(AngularGradient(gradient: Gradient(colors: [.white.opacity(0.0), .white]),
                                                center: .center),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(rotate ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotate)
                }
                Text(text ?? "缓冲中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
                    .shadow(radius: 2)
            }
        }
        .allowsHitTesting(false)
        .onAppear { rotate = true }
        .transition(.opacity)
    }
}

// MARK: - 局部观察下载进度的宿主
private struct CacheCardHost: View {
    @ObservedObject private var dm = HLSDownloadManager.shared
    let realURL: String
    let videoTitle: String
    let coverImage: String?
    let seriesTitle: String
    let episodeName: String?
    let episodeKey: String
    let sourceURL: String?

    var body: some View {
        CacheCard(realURL: realURL,
                  videoTitle: videoTitle,
                  coverImage: coverImage,
                  seriesTitle: seriesTitle,
                  episodeName: episodeName,
                  episodeKey: episodeKey,
                  sourceURL: sourceURL)
    }
}

private struct DeleteCacheButton: View {
    @ObservedObject private var dm = HLSDownloadManager.shared
    let activeKey: String
    let onDeleted: () -> Void
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    private var cacheKey: String? {
        if dm.localBookmarks[activeKey] != nil { return activeKey }
        for (key, meta) in dm.cacheMetadata
        where meta.originalEpisodeURL == activeKey && dm.localBookmarks[key] != nil {
            return key
        }
        return nil
    }

    var body: some View {
        if let key = cacheKey {
            Button(role: .destructive) {
                dm.deleteDownload(urlString: key)
                onDeleted()
            } label: {
                Label(isGlobalEnglishMode ? "Delete Cache" : "删除视频", systemImage: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.12)))
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - 在线播放页
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []
    var playSource: String? = nil

    private let downloadManager = HLSDownloadManager.shared
    private let network = NetworkMonitor.shared

    @StateObject private var engine = OVideoPlayerEngine()

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("hasWarnedCellularOnlinePlay") private var hasWarnedCellularOnlinePlay = false
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true

    @State private var showFirstPlayCellularAlert = false
    @State private var cellularPlayBlocked = false

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @Environment(\.appNavPath) var appNavPath

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var showLoginAlert = false

    @State private var showRepairSheet = false
    @State private var showReportSheet = false
    @State private var resolveTimeoutWork: DispatchWorkItem? = nil

    @State private var isPlayerFullScreen = false
    @State private var pendingRepairPrompt = false

    @State private var showEpisodeConsumeConfirm = false
    @State private var episodeConsumeRemaining = 0
    @State private var pendingEpisodeForSwitch: VideoEpisodeItem? = nil

    @State private var showEpisodePicker = false
    @State private var overrideEpisodeURL: String? = nil
    @State private var overrideEpisodeName: String? = nil
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil
    @State private var pendingOnlineResolvedURL: String? = nil
    @State private var showEpisodeCellularAlert = false
    @State private var loadedEpisodes: [VideoEpisodeItem] = []

    private var activeEpisodes: [VideoEpisodeItem] {
        episodes.isEmpty ? loadedEpisodes : episodes
    }
    private var seriesBaseTitle: String {
        videoTitle.components(separatedBy: " · ").first ?? videoTitle
    }
    private var activeEpisodeURL: String { overrideEpisodeURL ?? episodeURL }
    private var activeEpisodeName: String? { overrideEpisodeName ?? episodeName }
    private var displayTitle: String {
        if let ep = activeEpisodeName, !ep.isEmpty { return "\(seriesBaseTitle) · \(ep)" }
        return videoTitle
    }
    private var hasAccess: Bool {
        authManager.isSubscribed || FreeQuotaManager.shared.isUnlocked(activeEpisodeURL)
    }

    private func cachedOriginalURLs() -> Set<String> {
        var s = Set<String>()
        for (key, meta) in downloadManager.cacheMetadata
        where downloadManager.localBookmarks[key] != nil {
            s.insert(key)
            if let orig = meta.originalEpisodeURL, !orig.isEmpty { s.insert(orig) }
        }
        return s
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground),
                                    Color.accentColor.opacity(0.06),
                                    Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                playerArea
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                AdWarningBanner()
                    .fullScreenCover(isPresented: $showReportSheet) {
                        ReportSheet(videoTitle: displayTitle,
                                    sourceURL: sourceURL ?? activeEpisodeURL,
                                    episodeURL: activeEpisodeURL,
                                    channelName: channelName,
                                    episodeName: activeEpisodeName,
                                    realURL: realURL ?? activeEpisodeURL)
                    }
                    .sheet(isPresented: $showRepairSheet) {
                        PlaybackRepairSheet(videoTitle: displayTitle,
                                            sourceURL: sourceURL ?? activeEpisodeURL,
                                            episodeURL: activeEpisodeURL,
                                            channelName: channelName,
                                            episodeName: activeEpisodeName,
                                            realURL: realURL ?? activeEpisodeURL,
                                            onRetry: {
                                                showRepairSheet = false
                                                retryCurrent()
                                            })
                        .presentationDetents([.medium, .large])
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleCard
                        if let real = realURL {
                            CacheCardHost(realURL: real,
                                          videoTitle: displayTitle,
                                          coverImage: coverImage,
                                          seriesTitle: seriesBaseTitle,
                                          episodeName: activeEpisodeName,
                                          episodeKey: activeEpisodeURL,
                                          sourceURL: sourceURL)
                        }
                    }
                    .padding(.top, 16)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // ✅ 修复：iOS 17+ 双参 onChange
        .onChange(of: engine.offerManualRetry) { _, offer in
            if offer { requestRepairSheet() }
        }
        .onChange(of: engine.errorText) { _, msg in
            if let msg {
                resolveError = msg
                requestRepairSheet()
            }
        }
        .onChange(of: isPlayerFullScreen) { _, full in
            if !full, pendingRepairPrompt {
                pendingRepairPrompt = false
                AppDelegate.orientationLock = .portrait
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showRepairSheet = true }
            }
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            if hasAccess && realURL == nil { await resolve() }

            if episodes.isEmpty, loadedEpisodes.isEmpty,
               let src = sourceURL, !src.isEmpty {
                let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
                let chosen = channels.first { $0.name == channelName } ?? channels.first
                if let ch = chosen { loadedEpisodes = ch.episodeItems(ascending: isEpisodeAscending) }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onChange(of: authManager.isSubscribed) { _, newValue in
            if newValue && realURL == nil { Task { await resolve() } }
        }
        .onAppear { NotificationPermissionManager.shared.suppress(true) }
        .onDisappear {
            NotificationPermissionManager.shared.suppress(false)
            ReviewManager.shared.recordVideoInteraction()
            resolveTimeoutWork?.cancel(); resolveTimeoutWork = nil
            engine.teardown()
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showEpisodeCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingOnlineEpisode = nil; pendingOnlineResolvedURL = nil
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                if let ep = pendingOnlineEpisode {
                    switchToEpisode(ep, resolvedURL: pendingOnlineResolvedURL)
                }
                pendingOnlineEpisode = nil; pendingOnlineResolvedURL = nil
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .alert(isGlobalEnglishMode ? "Use 1 Free Pass" : "使用免费点数",
               isPresented: $showEpisodeConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingEpisodeForSwitch = nil
            }
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndSwitchEpisode() }
            }
        } message: {
            Text(quotaManager.consumeSourceNote(english: isGlobalEnglishMode)
                 + "\n" + quotaManager.remainingSummary(english: isGlobalEnglishMode))
        }
        .alert(isGlobalEnglishMode ? "Sign in to Watch Free" : "登录后免费观看",
               isPresented: $showLoginAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Sign in with Apple" : "登录") {
                authManager.signInWithApple()
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "Sign in (free, no purchase needed) to unlock your free daily passes."
                 : "登录后即可获得每日免费观看点数，登录无需付费。")
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showFirstPlayCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                resolveError = isGlobalEnglishMode ? "Playback canceled on cellular network" : "已取消蜂窝网络播放"
                cellularPlayBlocked = false
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                cellularPlayBlocked = false
                if let real = realURL { startPlayback(real: real) }
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .onChange(of: authManager.isLoggedIn) { _, loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
    }

    // MARK: 播放器主区
    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Color.black

            if let error = resolveError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36)).foregroundColor(.orange)
                    Text(error).foregroundColor(.white).font(.subheadline)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    HStack(spacing: 10) {
                        Button(isGlobalEnglishMode ? "Retry" : "重试") { retryCurrent() }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Color.white.opacity(0.9))
                            .foregroundColor(.black).cornerRadius(16)
                        Button(isGlobalEnglishMode ? "Report" : "反馈修复") { showReportSheet = true }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.white).cornerRadius(16)
                    }
                }
            } else if realURL != nil, !cellularPlayBlocked {
                OVideoPlayerSurface(engine: engine,
                                    onFullScreenChanged: { full in isPlayerFullScreen = full })
            }

            if showLoadingIndicator {
                PlayerLoadingIndicator(text: engine.busyText)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showLoadingIndicator)
    }

    private var showLoadingIndicator: Bool {
        if cellularPlayBlocked { return false }
        if resolveError != nil { return false }
        if isResolving { return true }
        if realURL == nil { return true }
        return engine.isBusyForUI
    }

    // MARK: 标题 / 选集
    private var titleCard: some View {
        HStack(spacing: 10) {
            Text(displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(3)
            Spacer()
            if activeEpisodes.count > 1 { episodeSelectorButton }
        }
        .padding(.horizontal, 16)
    }

    private var episodeSelectorButton: some View {
        Button { showEpisodePicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill")
                Text(isGlobalEnglishMode ? "Episodes" : "选集")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerView(episodes: activeEpisodes,
                              currentURL: activeEpisodeURL,
                              cachedOriginalURLs: cachedOriginalURLs(),
                              onSelect: { ep in handleEpisodeSelection(ep) })
                .presentationDetents([.medium, .large])
        }
    }

    private func requestRepairSheet() {
        if isPlayerFullScreen { pendingRepairPrompt = true; return }
        AppDelegate.orientationLock = .portrait
        showRepairSheet = true
    }

    private func scheduleResolveTimeout() {
        resolveTimeoutWork?.cancel()
        let work = DispatchWorkItem {
            if isResolving, realURL == nil { requestRepairSheet() }
        }
        resolveTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func retryCurrent() {
        resolveError = nil
        if realURL != nil {
            engine.retryNow()
        } else {
            Task { await resolve() }
        }
    }

    private func handleEpisodeSelection(_ ep: VideoEpisodeItem) {
        guard ep.url != activeEpisodeURL else { showEpisodePicker = false; return }
        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            proceedToSwitch(episode: ep)
        case .needLogin:
            showEpisodePicker = false; showLoginAlert = true
        case .needConsume(let r):
            pendingEpisodeForSwitch = ep
            episodeConsumeRemaining = r
            showEpisodeConsumeConfirm = true
            showEpisodePicker = false
        case .exhausted:
            showEpisodePicker = false; showSubscriptionSheet = true
        }
    }

    private func consumeAndSwitchEpisode() async {
        guard let ep = pendingEpisodeForSwitch else { return }
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let result = await quotaManager.unlock(userId: uid, episodeKey: ep.url,
                                               videoTitle: "\(seriesBaseTitle) · \(ep.name)")
        switch result {
        case .success, .alreadyUnlocked: proceedToSwitch(episode: ep)
        case .quotaExceeded, .failed:    showSubscriptionSheet = true
        }
        pendingEpisodeForSwitch = nil
    }

    private func proceedToSwitch(episode ep: VideoEpisodeItem) {
        showEpisodePicker = false
        isResolving = true
        resolveError = nil
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                isResolving = false
                let realKey = resolved ?? ep.url
                let cached = (resolved != nil) && (downloadManager.localBookmarks[realKey] != nil)
                if cached {
                    switchToEpisode(ep, resolvedURL: realKey)
                } else if !network.isWiFi && !hasWarnedCellularOnlinePlay {
                    pendingOnlineEpisode = ep
                    pendingOnlineResolvedURL = resolved
                    showEpisodeCellularAlert = true
                } else {
                    switchToEpisode(ep, resolvedURL: resolved)
                }
            }
        }
    }

    private func switchToEpisode(_ ep: VideoEpisodeItem, resolvedURL: String?) {
        overrideEpisodeURL = ep.url
        overrideEpisodeName = ep.name
        resolveError = nil
        if let resolved = resolvedURL {
            isResolving = false
            realURL = resolved
            startPlayback(real: resolved)
            recordPlayback(real: resolved)
        } else {
            realURL = nil
            Task { await resolve() }
        }
    }

    private func resolve() async {
        isResolving = true
        resolveError = nil
        scheduleResolveTimeout()
        do {
            let url: String
            do {
                url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            } catch {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            }
            self.realURL = url
            self.resolveTimeoutWork?.cancel()
            self.evaluateCellularGate(real: url)
            if !cellularPlayBlocked { startPlayback(real: url) }
            recordPlayback(real: url)
        } catch {
            self.resolveError = error.localizedDescription
            self.requestRepairSheet()
            self.resolveTimeoutWork?.cancel()
        }
        isResolving = false
    }

    private func startPlayback(real: String) {
        let key = activeEpisodeURL
        if let local = downloadManager.getLocalURL(for: real) {
            engine.prepare(url: local, positionKey: key, isLocal: true, resolver: nil)
            return
        }
        guard let u = URL(string: real) else {
            resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
            requestRepairSheet()
            return
        }
        engine.prepare(url: u, positionKey: key, isLocal: false,
                       resolver: { try await OVideoAPI.resolveRealURL(episodeURL: key) })
    }

    private func evaluateCellularGate(real: String) {
        let isCached = downloadManager.localBookmarks[real] != nil
        if !isCached && !network.isWiFi && !hasWarnedCellularOnlinePlay {
            cellularPlayBlocked = true
            showFirstPlayCellularAlert = true
        }
    }

    private func recordPlayback(real: String) {
        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty { return (appleId, "apple") }
            if let idfv = UIDevice.current.identifierForVendor?.uuidString { return ("dev_" + idfv, "device") }
            return ("guest_user", "device")
        }()

        TrackingManager.shared.track(event: .play,
                                     userId: trackUserId,
                                     userType: trackUserType,
                                     videoURL: activeEpisodeURL,
                                     videoTitle: displayTitle,
                                     source: playSource)

        VideoPlayRecordManager.shared.addRecord(videoTitle: seriesBaseTitle,
                                                episodeName: activeEpisodeName ?? (isGlobalEnglishMode ? "Play" : "播放"),
                                                videoURL: activeEpisodeURL,
                                                coverImage: coverImage,
                                                channelName: channelName,
                                                sourceURL: sourceURL)

        SeriesTrackManager.shared.recordWatch(sourceURL: sourceURL,
                                              title: seriesBaseTitle,
                                              cover: coverImage,
                                              episodeName: activeEpisodeName,
                                              channelName: channelName)
    }
}

// MARK: - 离线下载播放器
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []

    private let downloadManager = HLSDownloadManager.shared
    private let network = NetworkMonitor.shared

    @StateObject private var engine = OVideoPlayerEngine()

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true
    @AppStorage("hasWarnedCellularOnlinePlay") private var hasWarnedCellularOnlinePlay = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appNavPath) var appNavPath
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false

    @State private var allEpisodes: [VideoEpisodeItem] = []
    @State private var activeKey: String = ""
    @State private var activeName: String? = nil
    @State private var hasPlayable = false
    @State private var isResolvingOnline = false
    @State private var resolveError: String? = nil
    @State private var didInit = false

    @State private var showRepairSheet = false
    @State private var showReportSheet = false
    @State private var isPlayerFullScreen = false
    @State private var pendingRepairPrompt = false

    @State private var showEpisodePicker = false
    @State private var showLoginAlert = false
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var pendingEpisode: VideoEpisodeItem? = nil
    @State private var showQuotaExhausted = false
    @State private var showCellularAlert = false
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil

    private var pickerEpisodes: [VideoEpisodeItem] { allEpisodes.isEmpty ? episodes : allEpisodes }
    private var baseTitle: String { title.components(separatedBy: " · ").first ?? title }
    private var displayTitle: String {
        if let ep = activeName, !ep.isEmpty { return "\(baseTitle) · \(ep)" }
        return title
    }

    private func cachedOriginalURLs() -> Set<String> {
        var s = Set<String>()
        for (key, meta) in downloadManager.cacheMetadata
        where downloadManager.localBookmarks[key] != nil {
            s.insert(key)
            if let orig = meta.originalEpisodeURL, !orig.isEmpty { s.insert(orig) }
        }
        return s
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground), Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if hasPlayable {
                        OVideoPlayerSurface(engine: engine,
                                            onFullScreenChanged: { full in isPlayerFullScreen = full })
                        if engine.isBusyForUI || isResolvingOnline {
                            PlayerLoadingIndicator(text: engine.busyText)
                        }
                    } else if isResolvingOnline {
                        PlayerLoadingIndicator()
                    } else if let err = resolveError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36)).foregroundColor(.orange)
                            Text(err).foregroundColor(.white).font(.subheadline)
                                .multilineTextAlignment(.center).padding(.horizontal)
                            Button(isGlobalEnglishMode ? "Report" : "反馈修复") { requestRepairSheet() }
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .background(Color.orange.opacity(0.9))
                                .foregroundColor(.white).cornerRadius(16)
                        }
                    } else {
                        Text(isGlobalEnglishMode ? "Unable to play" : "无法播放")
                            .foregroundColor(.white)
                    }
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)

                AdWarningBanner()
                    .fullScreenCover(isPresented: $showReportSheet) {
                        ReportSheet(videoTitle: displayTitle,
                                    sourceURL: sourceURL ?? activeKey,
                                    episodeURL: activeKey,
                                    channelName: channelName,
                                    episodeName: activeName,
                                    realURL: activeKey)
                    }
                    .sheet(isPresented: $showRepairSheet) {
                        PlaybackRepairSheet(videoTitle: displayTitle,
                                            sourceURL: sourceURL ?? activeKey,
                                            episodeURL: activeKey,
                                            channelName: channelName,
                                            episodeName: activeName,
                                            realURL: activeKey,
                                            onRetry: {
                                                showRepairSheet = false
                                                retryCurrent()
                                            })
                        .presentationDetents([.medium, .large])
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Text(displayTitle)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.primary).lineLimit(3)
                            Spacer()
                            if pickerEpisodes.count > 1 { episodeSelectorButton }
                        }
                        .padding(.horizontal, 16).padding(.top, 16)

                        DeleteCacheButton(activeKey: activeKey, onDeleted: { dismiss() })

                        Button(action: { appNavPath?.wrappedValue.append(NavigationTarget.allArticles) }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.blue.opacity(0.1)).frame(width: 40, height: 40)
                                    Image(systemName: "newspaper.fill")
                                        .font(.system(size: 18)).foregroundColor(.blue)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isGlobalEnglishMode ? "Back to News" : "返回新闻阅读")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(isGlobalEnglishMode ? "Read all subscribed articles" : "阅读所有订阅文章")
                                        .font(.system(size: 12)).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(UIColor.secondarySystemGroupedBackground)))
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer(minLength: 30)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerView(episodes: pickerEpisodes,
                              currentURL: activeKey,
                              cachedOriginalURLs: cachedOriginalURLs(),
                              onSelect: { ep in selectEpisode(ep) })
                .presentationDetents([.medium, .large])
        }
        .alert(isGlobalEnglishMode ? "Use Free Pass (\(consumeRemaining) left)"
                                   : "今日免费赠送还剩\(consumeRemaining)点",
               isPresented: $showConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") { Task { await consumeAndPlay() } }
        } message: {
            Text(quotaManager.consumeSourceNote(english: isGlobalEnglishMode)
                 + "\n" + quotaManager.remainingSummary(english: isGlobalEnglishMode))
        }
        .alert(isGlobalEnglishMode ? "Free Passes Used Up (0 left)" : "今日免费额度不足",
               isPresented: $showQuotaExhausted) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") { showSubscriptionSheet = true }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You've used all your free passes for today. Subscribe for unlimited access."
                 : "您今天的免费额度已用完，订阅后即可无限畅享所有视频。")
        }
        .alert(isGlobalEnglishMode ? "Sign in to Watch Free" : "登录后免费观看",
               isPresented: $showLoginAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Sign in with Apple" : "登录") { authManager.signInWithApple() }
        } message: {
            Text(isGlobalEnglishMode
                 ? "Sign in (free) to unlock your free daily passes."
                 : "登录后即可获得每日免费观看点数，登录无需付费。")
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { pendingOnlineEpisode = nil }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                if let ep = pendingOnlineEpisode { resolveAndPlayOnline(ep) }
                pendingOnlineEpisode = nil
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .onAppear {
            NotificationPermissionManager.shared.suppress(true)
            startInitialPlaybackIfNeeded()
        }
        // ✅ 修复：iOS 17+ 双参 onChange
        .onChange(of: engine.offerManualRetry) { _, offer in
            if offer, !engine.isLocal { requestRepairSheet() }
        }
        .onChange(of: engine.errorText) { _, msg in
            if let msg { resolveError = msg; requestRepairSheet() }
        }
        .onChange(of: isPlayerFullScreen) { _, full in
            if !full, pendingRepairPrompt {
                pendingRepairPrompt = false
                AppDelegate.orientationLock = .portrait
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showRepairSheet = true }
            }
        }
        .onDisappear {
            NotificationPermissionManager.shared.suppress(false)
            engine.teardown()
        }
        .onChange(of: authManager.isLoggedIn) { _, loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            await loadAllEpisodes()
        }
    }

    private var episodeSelectorButton: some View {
        Button { showEpisodePicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill")
                Text(isGlobalEnglishMode ? "Episodes" : "选集")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func requestRepairSheet() {
        if isPlayerFullScreen { pendingRepairPrompt = true; return }
        AppDelegate.orientationLock = .portrait
        showRepairSheet = true
    }

    private func retryCurrent() {
        resolveError = nil
        if let local = localURL(forOriginal: activeKey) {
            hasPlayable = true
            engine.prepare(url: local, positionKey: activeKey, isLocal: true, resolver: nil)
            return
        }
        if let ep = pickerEpisodes.first(where: { $0.url == activeKey }) {
            resolveAndPlayOnline(ep)
        } else {
            engine.retryNow()
        }
    }

    private func startInitialPlaybackIfNeeded() {
        guard !didInit else { return }
        didInit = true
        activeName = episodeName
        activeKey = realURL
        let posKey = downloadManager.cacheMetadata[realURL]?.originalEpisodeURL ?? realURL

        if let local = downloadManager.getLocalURL(for: realURL) {
            hasPlayable = true
            engine.prepare(url: local, positionKey: posKey, isLocal: true, resolver: nil)
            recordPlayback()
        } else if let u = URL(string: realURL) {
            hasPlayable = true
            engine.prepare(url: u, positionKey: posKey, isLocal: false,
                           resolver: { try await OVideoAPI.resolveRealURL(episodeURL: posKey) })
            recordPlayback()
        } else {
            hasPlayable = false
            resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
            requestRepairSheet()
        }
    }

    private func loadAllEpisodes() async {
        guard allEpisodes.isEmpty, let src = sourceURL, !src.isEmpty else { return }
        let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
        guard let best = optimalSortedChannels(channels).first else { return }
        let items = best.episodeItems(ascending: isEpisodeAscending)
        await MainActor.run {
            self.allEpisodes = items
            let orig = downloadManager.cacheMetadata[realURL]?.originalEpisodeURL ?? realURL
            if items.contains(where: { $0.url == orig }) { self.activeKey = orig }
        }
    }

    private func selectEpisode(_ ep: VideoEpisodeItem) {
        showEpisodePicker = false
        guard ep.url != activeKey else { return }

        if let local = localURL(forOriginal: ep.url) {
            activeKey = ep.url; activeName = ep.name; resolveError = nil
            hasPlayable = true
            engine.prepare(url: local, positionKey: ep.url, isLocal: true, resolver: nil)
            recordPlayback()
            return
        }

        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:            startOnline(ep)
        case .needLogin:          showLoginAlert = true
        case .needConsume(let r): pendingEpisode = ep; consumeRemaining = r; showConsumeConfirm = true
        case .exhausted:          showQuotaExhausted = true
        }
    }

    private func startOnline(_ ep: VideoEpisodeItem) {
        if !network.isWiFi && !hasWarnedCellularOnlinePlay {
            pendingOnlineEpisode = ep
            showCellularAlert = true
        } else {
            resolveAndPlayOnline(ep)
        }
    }

    private func resolveAndPlayOnline(_ ep: VideoEpisodeItem) {
        activeKey = ep.url; activeName = ep.name
        resolveError = nil
        hasPlayable = false
        isResolvingOnline = true
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                isResolvingOnline = false
                if let resolved, let u = URL(string: resolved) {
                    hasPlayable = true
                    engine.prepare(url: u, positionKey: ep.url, isLocal: false,
                                   resolver: { try await OVideoAPI.resolveRealURL(episodeURL: ep.url) })
                    recordPlayback()
                } else {
                    resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
                    requestRepairSheet()
                }
            }
        }
    }

    private func consumeAndPlay() async {
        guard let ep = pendingEpisode else { return }
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let result = await quotaManager.unlock(userId: uid, episodeKey: ep.url,
                                               videoTitle: "\(baseTitle) · \(ep.name)")
        await MainActor.run {
            switch result {
            case .success, .alreadyUnlocked: startOnline(ep)
            case .quotaExceeded, .failed:    showSubscriptionSheet = true
            }
            pendingEpisode = nil
        }
    }

    private func localURL(forOriginal original: String) -> URL? {
        if let u = downloadManager.getLocalURL(for: original) { return u }
        for (key, meta) in downloadManager.cacheMetadata where meta.originalEpisodeURL == original {
            if let u = downloadManager.getLocalURL(for: key) { return u }
        }
        return nil
    }

    private func recordPlayback() {
        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty { return (appleId, "apple") }
            if let idfv = UIDevice.current.identifierForVendor?.uuidString { return ("dev_" + idfv, "device") }
            return ("guest_user", "device")
        }()

        TrackingManager.shared.track(event: .play,
                                     userId: trackUserId,
                                     userType: trackUserType,
                                     videoURL: activeKey,
                                     videoTitle: displayTitle)

        let originalKey = downloadManager.cacheMetadata[activeKey]?.originalEpisodeURL ?? activeKey
        VideoPlayRecordManager.shared.addRecord(videoTitle: baseTitle,
                                               episodeName: activeName ?? "",
                                               videoURL: originalKey,
                                               coverImage: downloadManager.cacheMetadata[activeKey]?.coverImage,
                                               channelName: channelName,
                                               sourceURL: sourceURL)

        SeriesTrackManager.shared.recordWatch(sourceURL: sourceURL,
                                              title: baseTitle,
                                              cover: downloadManager.cacheMetadata[activeKey]?.coverImage,
                                              episodeName: activeName,
                                              channelName: channelName)
    }
}

// MARK: - 选集数据模型
struct VideoEpisodeItem: Identifiable, Hashable {
    var id: String { url }
    let number: String
    let name: String
    let url: String
}

extension OVideoChannel {
    func episodeItems(ascending: Bool = true) -> [VideoEpisodeItem] {
        sortedEpisodes(ascending: ascending).enumerated().map { index, kv in
            VideoEpisodeItem(number: Self.shortNumber(from: kv.name, fallbackIndex: index),
                             name: kv.name,
                             url: kv.url)
        }
    }

    private static func shortNumber(from name: String, fallbackIndex: Int) -> String {
        let digits = name.filter { $0.isNumber }
        if !digits.isEmpty, digits.count <= 4, let n = Int(digits) { return String(n) }
        return String(fallbackIndex + 1)
    }
}

// MARK: - 选集弹窗
struct EpisodePickerView: View {
    let episodes: [VideoEpisodeItem]
    let currentURL: String
    var cachedOriginalURLs: Set<String> = []
    let onSelect: (VideoEpisodeItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var dm = HLSDownloadManager.shared
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(episodes) { ep in
                        let isCurrent = ep.url == currentURL
                        let isCached = cachedOriginalURLs.contains(ep.url) || dm.localBookmarks[ep.url] != nil
                        let isUnlocked = quotaManager.isUnlocked(ep.url)
                        let hasQuota = quotaManager.remaining > 0

                        Button {
                            onSelect(ep)
                            dismiss()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .frame(height: 50)
                                    .overlay(
                                        Text(ep.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(2).minimumScaleFactor(0.7)
                                            .multilineTextAlignment(.center)
                                            .foregroundColor(isCurrent ? .white : .primary)
                                            .padding(.horizontal, 4)
                                    )

                                if isCached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 12)).foregroundColor(.white)
                                        .padding(2).background(Circle().fill(Color.blue)).padding(3)
                                } else if !authManager.isSubscribed {
                                    if isUnlocked {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10)).foregroundColor(.green).padding(3)
                                    } else if !hasQuota {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8)).foregroundColor(.white)
                                            .padding(3).background(Circle().fill(Color.orange))
                                    }
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(16)
            }
            .navigationTitle(isGlobalEnglishMode ? "Episodes" : "选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isGlobalEnglishMode ? "Done" : "完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 无法播放 / 持续卡顿的「反馈修复」弹窗
struct PlaybackRepairSheet: View {
    let videoTitle: String
    let sourceURL: String
    let episodeURL: String
    var channelName: String? = nil
    var episodeName: String? = nil
    let realURL: String
    var onRetry: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.12)).frame(width: 64, height: 64)
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 26)).foregroundColor(.blue)
                        }
                        Text(isGlobalEnglishMode ? "Can't play this video?" : "视频无法播放？")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                    }
                    .padding(.top, 8).padding(.horizontal, 16)

                    if let onRetry {
                        Button(action: onRetry) {
                            Label(isGlobalEnglishMode ? "Reload" : "重新加载",
                                  systemImage: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12)))
                        }
                        .padding(.horizontal, 16)
                    }

                    Spacer()

                    ReportLinkCard(videoTitle: videoTitle,
                                   sourceURL: sourceURL,
                                   episodeURL: episodeURL,
                                   channelName: channelName,
                                   episodeName: episodeName,
                                   realURL: realURL)
                }
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isGlobalEnglishMode ? "Close" : "关闭") { dismiss() }
                }
            }
        }
    }
}