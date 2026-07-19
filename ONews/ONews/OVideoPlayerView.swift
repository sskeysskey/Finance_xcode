// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoPlayerView.swift

import SwiftUI
import AVKit
import MediaPlayer   // ⭐ 新增：用于清除锁屏 Now Playing

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

// MARK: - ⭐ 播放进度记忆（按 URL 记忆，用于断点续播 / 黑屏自愈后回到原位置）
enum PlaybackPositionStore {
    private static let prefix = "ONews_Pos_"
    private static let indexKey = "ONews_PosIndex"   // 维护所有 key 的访问顺序
    private static let maxEntries = 300

    private static func key(for url: URL) -> String { prefix + url.absoluteString }

    static func save(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds > 0 else { return }
        let d = UserDefaults.standard
        let k = key(for: url)
        d.set(seconds, forKey: k)

        // ⭐ LRU：最近使用的放末尾，超出上限删最旧
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

    static func load(for url: URL) -> Double {
        UserDefaults.standard.double(forKey: key(for: url))
    }

    static func clear(for url: URL) {
        let d = UserDefaults.standard
        let k = key(for: url)
        d.removeObject(forKey: k)
        var index = d.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == k }
        d.set(index, forKey: indexKey)
    }
}

// MARK: - ⭐ 广告防骗固定提示条（所有播放页通用）
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

// MARK: - 生命周期可感知的播放控制器
final class LifecycleAVPlayerViewController: AVPlayerViewController {
    var onWillDisappear: (() -> Void)?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?()
    }
}

// MARK: - VideoPlayerView (UIKit 包装)
struct VideoPlayerView: UIViewControllerRepresentable {
    let videoURL: URL
    @Binding var isBuffering: Bool
    @Binding var hasStartedPlaying: Bool              // ⭐ 是否已真正出第一帧
    var onPlaybackFailed: ((String) -> Void)? = nil   // ⭐ 播放失败兜底，避免无限转圈

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = LifecycleAVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect

        controller.onWillDisappear = { [weak coordinator = context.coordinator] in
            guard let coordinator = coordinator else { return }
            if coordinator.isFullScreen || coordinator.isPiP { return }
            coordinator.pause()
        }

        // ⭐ 把「创建播放器 + 注册生命周期监听」交给 Coordinator 统一管理
        context.coordinator.setup(controller: controller, url: videoURL)
        return controller
    }

    // ⭐ 始终刷新 parent，保证 binding / 回调指向最新的 state
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.detach()
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: VideoPlayerView
        private weak var controller: AVPlayerViewController?
        private weak var player: AVPlayer?
        private var url: URL?

        // KVO
        private var timeControlObs: NSKeyValueObservation?
        private var keepUpObs: NSKeyValueObservation?
        private var bufferEmptyObs: NSKeyValueObservation?
        private var bufferFullObs: NSKeyValueObservation?
        private var statusObs: NSKeyValueObservation?
        private var rateObs: NSKeyValueObservation?
        private var defaultRateObs: NSKeyValueObservation?
        private var currentItemObs: NSKeyValueObservation?
        private var lastPersistedSeconds: Double = 0

        // 进度记忆 / 恢复相关
        private var periodicObs: Any?
        private var restoreTime: CMTime = .zero
        private var wasPlayingBeforeBackground = true
        private var pendingSeek: CMTime?
        private var shouldAutoPlayWhenReady = true
        private var didHandleReady = false

        private var bufferingResetWork: DispatchWorkItem?
        private var targetOrientationMask: UIInterfaceOrientationMask?
        private var orientationWork: DispatchWorkItem?
        private var loadingView: UIView?

        // 本地下载卡顿自愈 watchdog
        private var stallWatchdog: Timer?
        private var lastWatchdogTime: Double = -1
        private var stalledTicks = 0
        private var stallRecoveryAttempts = 0

        // ⭐⭐ 新增(问题2)：在线弱网自适应策略参数与状态
        private static let startupPeakBitRate: Double = 1_800_000   // 快启动：限码率
        private static let degradedPeakBitRate: Double = 800_000    // 弱网降级码率
        private static let startupForwardBuffer: TimeInterval = 5   // 快启动：小前向缓冲
        private static let steadyForwardBuffer: TimeInterval = 60   // 稳定后：大前向缓冲抗抖动
        private var netWaitingTicks = 0          // 在线流连续 waiting 的秒数
        private var stablePlayTicks = 0          // 连续正常播放的秒数
        private var didLiftStartupCaps = false   // 是否已解除快启动限制
        private var networkRetryCount = 0        // 失败自动重试计数
        private let maxNetworkRetries = 2

        // ⭐⭐ 新增(问题1)：AVKit 控制层卡死自愈
        private var didScrubWhileBuffering = false   // 缓冲期间发生过 seek（用户拖进度条）
        private var controlsResetScheduled = false

        var isFullScreen = false
        var isPiP = false

        init(_ parent: VideoPlayerView) { self.parent = parent }

        func pause() {
            player?.pause()
        }

        // ⭐ 统一入口：标记「已真正开始播放」
        private func markStartedPlaying() {
            if !parent.hasStartedPlaying {
                parent.hasStartedPlaying = true
            }
            updateLoadingOverlay()
        }

        // MARK: 全屏可见的加载指示器（放进 contentOverlayView，会跟随进入全屏）
        private func setupLoadingOverlay() {
            guard let controller = controller else { return }
            controller.loadViewIfNeeded()
            guard let overlay = controller.contentOverlayView else { return }

            let isEnglish = UserDefaults.standard.bool(forKey: "isGlobalEnglishMode")

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
            label.text = isEnglish ? "Buffering…" : "缓冲中…"
            label.textColor = UIColor.white.withAlphaComponent(0.9)
            label.font = .systemFont(ofSize: 13, weight: .medium)

            box.addSubview(spinner)
            box.addSubview(label)
            overlay.addSubview(box)

            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                box.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

                spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
                spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),

                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
                label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
            ])

            loadingView = box
        }

        private func updateLoadingOverlay() {
            let shouldShow = isFullScreen && (!parent.hasStartedPlaying || parent.isBuffering)
            loadingView?.isHidden = !shouldShow
        }

        // MARK: 初始化
        func setup(controller: AVPlayerViewController, url: URL) {
            self.controller = controller
            self.url = url

            let saved = PlaybackPositionStore.load(for: url)
            let resume = saved > 3 ? CMTime(seconds: saved, preferredTimescale: 600) : nil
            restoreTime = resume ?? .zero

            configureAudioSession()
            buildPlayer(resumeTime: resume, autoPlay: true)
            setupLoadingOverlay()
            registerLifecycleObservers()
            startStallWatchdog()
        }

        private func configureAudioSession() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }

        // MARK: 构建 / 重建播放器
        private func buildPlayer(resumeTime: CMTime?, autoPlay: Bool) {
            guard let url = url, let controller = controller else { return }

            teardownPlayerObservers()
            didHandleReady = false

            // ⭐ 重建时重置弱网/控件自愈状态（注意：networkRetryCount 不在这里重置，
            //    否则失败重试会变成无限循环；它只在稳定播放后归零）
            didLiftStartupCaps = false
            didScrubWhileBuffering = false
            netWaitingTicks = 0
            stablePlayTicks = 0

            let isLocal = url.isFileURL
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)

            if !isLocal {
                // ⭐⭐ 快启动模式(问题2)：
                //    限码率 → ABR 一上来就选低档，弱网下更快出第一帧（多码率源有效，单码率源无副作用）；
                //    小前向缓冲 → 不用攒太多数据就起播。
                //    稳定播放约 8 秒后由 watchdog 调 liftStartupCapsIfNeeded() 放开限制并加大缓冲。
                item.preferredPeakBitRate = Self.startupPeakBitRate
                item.preferredForwardBufferDuration = Self.startupForwardBuffer
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            }

            let player = AVPlayer(playerItem: item)
            // 本地下载文件关闭「等待以减少卡顿」，避免假性 waiting；在线流保留以应对网络抖动
            player.automaticallyWaitsToMinimizeStalling = !isLocal
            player.allowsExternalPlayback = true
            player.usesExternalPlaybackWhileExternalScreenIsActive = true

            if let rt = resumeTime, rt.seconds.isFinite, rt.seconds > 1 {
                pendingSeek = rt
            } else {
                pendingSeek = nil
            }
            shouldAutoPlayWhenReady = autoPlay

            if #available(iOS 16.0, *) {
                player.defaultRate = PlaybackSpeedStore.rate
            }

            controller.player = player
            self.player = player
            attachObservers(to: player)
        }

        // MARK: 监听器
        private func attachObservers(to player: AVPlayer) {
            timeControlObs = player.observe(\.timeControlStatus,
                                            options: [.new, .initial]) { [weak self] p, _ in
                self?.updateBuffering(from: p)
            }
            rateObs = player.observe(\.rate, options: [.new]) { _, change in
                if let r = change.newValue, r > 0, r <= 2.0 {
                    PlaybackSpeedStore.rate = r
                }
            }
            if #available(iOS 16.0, *) {
                defaultRateObs = player.observe(\.defaultRate,
                                                options: [.new]) { _, change in
                    if let r = change.newValue, r > 0, r <= 2.0 {
                        PlaybackSpeedStore.rate = r
                    }
                }
            }
            currentItemObs = player.observe(\.currentItem,
                                            options: [.new, .initial]) { [weak self] p, _ in
                self?.attachItemObservers(item: p.currentItem)
            }
            periodicObs = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                queue: .main) { [weak self] time in
                self?.recordProgress(time)
            }
        }

        private func attachItemObservers(item: AVPlayerItem?) {
            keepUpObs?.invalidate(); keepUpObs = nil
            bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
            bufferFullObs?.invalidate(); bufferFullObs = nil
            statusObs?.invalidate(); statusObs = nil
            guard let item = item else { return }

            statusObs = item.observe(\.status,
                                     options: [.new, .initial]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch it.status {
                    case .readyToPlay:
                        self.handleReadyToPlay()
                    case .failed:
                        // ⭐⭐ (问题2) 失败先带退避自动重试，重试用尽才真正报错
                        self.attemptNetworkRetryOrFail(
                            message: it.error?.localizedDescription)
                    default:
                        break
                    }
                }
            }
            keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp,
                                    options: [.new, .initial]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    if it.isPlaybackLikelyToKeepUp { self?.setBuffering(false) }
                }
            }
            bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty,
                                        options: [.new]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    if it.isPlaybackBufferEmpty { self?.setBuffering(true) }
                }
            }
            bufferFullObs = item.observe(\.isPlaybackBufferFull,
                                        options: [.new]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    if it.isPlaybackBufferFull { self?.setBuffering(false) }
                }
            }
        }

        private func handleReadyToPlay() {
            guard !didHandleReady else { return }
            didHandleReady = true
            guard let player = player else { return }

            let resume = { [weak self] in
                guard let self = self, self.shouldAutoPlayWhenReady else { return }
                if #available(iOS 16.0, *) {
                    player.play()
                } else {
                    player.play()
                    let r = PlaybackSpeedStore.rate
                    if r != 1.0 { player.rate = r }
                }
            }

            if let seek = pendingSeek {
                pendingSeek = nil
                player.seek(to: seek, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    resume()
                }
            } else {
                resume()
            }
        }

        private func recordProgress(_ time: CMTime) {
            guard let url = url, time.seconds.isFinite, time.seconds > 0 else { return }
            markStartedPlaying()
            restoreTime = time

            if abs(time.seconds - lastPersistedSeconds) >= 5 {
                lastPersistedSeconds = time.seconds
                PlaybackPositionStore.save(time.seconds, for: url)
            }

            if let item = player?.currentItem {
                let dur = item.duration.seconds
                if dur.isFinite, dur > 0, time.seconds >= dur - 3 {
                    PlaybackPositionStore.clear(for: url)
                }
            }
        }

        // MARK: ⭐⭐ (问题2) 弱网自适应：解除快启动限制 / 降级码率
        private func liftStartupCapsIfNeeded() {
            guard !didLiftStartupCaps,
                  url?.isFileURL == false,
                  let item = player?.currentItem else { return }
            didLiftStartupCaps = true
            item.preferredPeakBitRate = 0                                  // 放开码率，允许升清晰度
            item.preferredForwardBufferDuration = Self.steadyForwardBuffer // 大缓冲抗晚高峰抖动
        }

        private func degradeForWeakNetwork() {
            guard url?.isFileURL == false, let item = player?.currentItem else { return }
            item.preferredPeakBitRate = Self.degradedPeakBitRate
            item.preferredForwardBufferDuration = Self.startupForwardBuffer
            didLiftStartupCaps = false
            stablePlayTicks = 0
        }

        // MARK: ⭐⭐ (问题2) 失败自动重试（带退避），重试用尽才报错
        private func attemptNetworkRetryOrFail(message: String?) {
            if url?.isFileURL == false, networkRetryCount < maxNetworkRetries {
                networkRetryCount += 1
                let delay = Double(networkRetryCount) * 1.5   // 1.5s → 3s
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.rebuildPreservingState()
                }
            } else {
                parent.onPlaybackFailed?(message ?? "视频播放失败")
            }
        }

        // MARK: 卡顿自愈 watchdog（本地 + ⭐ 在线两套策略）
        private func startStallWatchdog() {
            stallWatchdog?.invalidate()
            lastWatchdogTime = -1
            stalledTicks = 0
            stallWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.watchdogTick()
            }
        }

        private func watchdogTick() {
            guard let player = player else { return }
            if url?.isFileURL == true {
                localWatchdogTick(player)
            } else {
                networkWatchdogTick(player)   // ⭐⭐ 新增：在线弱网 watchdog
            }
        }

        // 本地下载：原有逻辑不变
        private func localWatchdogTick(_ player: AVPlayer) {
            let intendsToPlay = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                || (player.timeControlStatus == .playing)
            guard intendsToPlay else {
                lastWatchdogTime = player.currentTime().seconds
                stalledTicks = 0
                stallRecoveryAttempts = 0
                return
            }

            let now = player.currentTime().seconds
            if lastWatchdogTime >= 0, abs(now - lastWatchdogTime) < 0.05 {
                stalledTicks += 1
                if stalledTicks >= 2 {
                    recoverFromStallIfNeeded()
                    stalledTicks = 0
                }
            } else {
                stalledTicks = 0
                stallRecoveryAttempts = 0
            }
            lastWatchdogTime = now
        }

        // ⭐⭐ (问题2) 在线流：分级自愈
        private func networkWatchdogTick(_ player: AVPlayer) {
            let status = player.timeControlStatus

            if status == .playing {
                netWaitingTicks = 0
                stablePlayTicks += 1
                if stablePlayTicks >= 8 {
                    networkRetryCount = 0        // 稳定播放 → 重试计数归零
                    liftStartupCapsIfNeeded()    // 稳定播放 → 放开码率 + 加大缓冲
                }
                return
            }

            stablePlayTicks = 0
            guard status == .waitingToPlayAtSpecifiedRate else {
                netWaitingTicks = 0
                return
            }

            netWaitingTicks += 1

            if netWaitingTicks == 6 {
                // 等 6 秒还在转圈：压低码率档位，帮 ABR 尽快切低清晰度
                degradeForWeakNetwork()
            }
            if netWaitingTicks == 10 {
                // 等 10 秒：只要缓冲里有数据就强行起播，不等系统「攒够」
                if let item = player.currentItem, !item.isPlaybackBufferEmpty {
                    player.playImmediately(atRate: PlaybackSpeedStore.rate)
                }
            }
            if netWaitingTicks >= 20 {
                // 等 20 秒还起不来：整体重建（重建后自动回到低码率+小缓冲的快启动模式）
                netWaitingTicks = 0
                rebuildPreservingState()
            }
        }

        @objc private func handlePlaybackStalled() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.url?.isFileURL == true {
                    self.recoverFromStallIfNeeded()
                } else {
                    // ⭐⭐ (问题2) 在线流播放中卡顿：先降级码率，稍后有缓冲就强行续播
                    self.degradeForWeakNetwork()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self = self,
                              let p = self.player,
                              let item = p.currentItem else { return }
                        if p.timeControlStatus != .playing, !item.isPlaybackBufferEmpty {
                            p.playImmediately(atRate: PlaybackSpeedStore.rate)
                        }
                    }
                }
            }
        }

        private func recoverFromStallIfNeeded() {
            guard let player = player, let item = player.currentItem else { return }
            let dur = item.duration.seconds
            let cur = player.currentTime().seconds
            if dur.isFinite, dur > 0, cur >= dur - 0.5 { return }

            let isLocal = url?.isFileURL ?? false

            stallRecoveryAttempts += 1
            if stallRecoveryAttempts >= 3 {
                stallRecoveryAttempts = 0
                lastWatchdogTime = -1
                stalledTicks = 0
                rebuildPreservingState()
                return
            }

            if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                player.play()
            } else if isLocal {
                let target = CMTime(seconds: max(0, cur - 1.0), preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player?.play()
                }
            }
        }

        // MARK: ⭐⭐ (问题1) AVKit 控制层卡死自愈
        //    缓冲期间发生 seek（用户拖进度条）→ timeJumped 打标记；
        //    真正恢复播放后，关闭再打开 showsPlaybackControls，强制重建控制层。
        @objc private func handleTimeJumped(_ note: Notification) {
            guard let item = note.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let p = self.player else { return }
                if !self.parent.hasStartedPlaying
                    || self.parent.isBuffering
                    || p.timeControlStatus != .playing {
                    self.didScrubWhileBuffering = true
                }
            }
        }

        private func resetControlsIfNeeded() {
            guard didScrubWhileBuffering, !controlsResetScheduled else { return }
            didScrubWhileBuffering = false
            controlsResetScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                self.controlsResetScheduled = false
                guard let c = self.controller, c.showsPlaybackControls else { return }
                c.showsPlaybackControls = false
                DispatchQueue.main.async {
                    c.showsPlaybackControls = true
                }
            }
        }

        // MARK: 生命周期 / 媒体重启监听
        private func registerLifecycleObservers() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(handleEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(handleEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(handleMediaServicesReset),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            nc.addObserver(self, selector: #selector(handlePlaybackStalled),
                           name: AVPlayerItem.playbackStalledNotification, object: nil)
            // ⭐⭐ 新增(问题1)：seek 检测，用于控制层卡死自愈
            nc.addObserver(self, selector: #selector(handleTimeJumped(_:)),
                           name: AVPlayerItem.timeJumpedNotification, object: nil)
            // ⭐⭐ 新增(问题2)：播放中途断流 → 自动重试
            nc.addObserver(self, selector: #selector(handleFailedToPlayToEnd(_:)),
                           name: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil)
        }

        @objc private func handleFailedToPlayToEnd(_ note: Notification) {
            guard let item = note.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.attemptNetworkRetryOrFail(message: msg)
            }
        }

        @objc private func handleEnterBackground() {
            guard let player = player else { return }
            wasPlayingBeforeBackground = (player.timeControlStatus != .paused)
            let t = player.currentTime()
            if t.seconds.isFinite, t.seconds > 0 {
                restoreTime = t
                if let url = url { PlaybackPositionStore.save(t.seconds, for: url) }
            }
        }

        @objc private func handleEnterForeground() {
            if !isFullScreen {
                applyOrientation(fullScreen: false)
            }

            guard !isPiP else { return }
            guard let player = player, let controller = controller else { return }

            let item = player.currentItem
            let failed = (item == nil)
                || (item?.status == .failed)
                || (item?.error != nil)
                || (player.error != nil)

            if failed {
                rebuildPreservingState()
                return
            }

            controller.player = nil
            controller.player = player
            let t = player.currentTime()
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlayingBeforeBackground {
                if #available(iOS 16.0, *) {
                    player.play()
                } else {
                    player.play()
                    let r = PlaybackSpeedStore.rate
                    if r != 1.0 { player.rate = r }
                }
            }
            if url?.isFileURL == true, wasPlayingBeforeBackground {
                let before = player.currentTime().seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, let p = self.player else { return }
                    if p.timeControlStatus != .paused,
                       abs(p.currentTime().seconds - before) < 0.05 {
                        self.lastWatchdogTime = -1
                        self.stalledTicks = 0
                        self.stallRecoveryAttempts = 0
                        self.rebuildPreservingState()
                    }
                }
            }
        }

        @objc private func handleMediaServicesReset() {
            configureAudioSession()
            rebuildPreservingState()
        }

        private func rebuildPreservingState() {
            buildPlayer(resumeTime: restoreTime, autoPlay: wasPlayingBeforeBackground)
        }

        private func updateBuffering(from player: AVPlayer) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let status = player.timeControlStatus
                if status == .playing {
                    self.markStartedPlaying()
                    self.resetControlsIfNeeded()   // ⭐⭐ (问题1) 恢复播放后自愈控制层
                }
                let waiting = (status == .waitingToPlayAtSpecifiedRate)
                self.setBuffering(waiting)
            }
        }

        private func setBuffering(_ value: Bool) {
            if parent.isBuffering != value {
                parent.isBuffering = value
            }
            updateLoadingOverlay()
            bufferingResetWork?.cancel()
            if value {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self,
                          let p = self.player else { return }
                    if p.timeControlStatus != .waitingToPlayAtSpecifiedRate {
                        self.parent.isBuffering = false
                    }
                }
                bufferingResetWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            }
        }

        private func teardownPlayerObservers() {
            if let token = periodicObs, let p = player {
                p.removeTimeObserver(token)
            }
            periodicObs = nil
            timeControlObs?.invalidate(); timeControlObs = nil
            keepUpObs?.invalidate(); keepUpObs = nil
            bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
            bufferFullObs?.invalidate(); bufferFullObs = nil
            statusObs?.invalidate(); statusObs = nil
            rateObs?.invalidate(); rateObs = nil
            defaultRateObs?.invalidate(); defaultRateObs = nil
            currentItemObs?.invalidate(); currentItemObs = nil
        }

        func detach() {
            teardownPlayerObservers()
            NotificationCenter.default.removeObserver(self)
            bufferingResetWork?.cancel()
            orientationWork?.cancel()
            stallWatchdog?.invalidate(); stallWatchdog = nil

            loadingView?.removeFromSuperview()
            loadingView = nil

            if !isPiP {
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                controller?.player = nil
                player = nil
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        // MARK: 全屏代理
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                willBeginFullScreenPresentationWithAnimationCoordinator
                                coordinator: UIViewControllerTransitionCoordinator) {
            isFullScreen = true
            updateLoadingOverlay()
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self = self else { return }
                if context.isCancelled {
                    self.isFullScreen = false
                    self.applyOrientation(fullScreen: false)
                } else {
                    self.isFullScreen = true
                    self.applyOrientation(fullScreen: true)
                }
                self.updateLoadingOverlay()
            }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                willEndFullScreenPresentationWithAnimationCoordinator
                                coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self = self else { return }
                if context.isCancelled {
                    self.isFullScreen = true
                    self.applyOrientation(fullScreen: true)
                } else {
                    self.isFullScreen = false
                    self.applyOrientation(fullScreen: false)
                }
                self.updateLoadingOverlay()
            }
        }

        // MARK: 画中画代理
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiP = true
            if isFullScreen {
                isFullScreen = false
            }
            AppDelegate.orientationLock = .portrait
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiP = false
            if !isFullScreen {
                DispatchQueue.main.async { [weak self] in
                    self?.applyOrientation(fullScreen: false)
                }
            }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                completionHandler: @escaping (Bool) -> Void) {
            isFullScreen = false
            applyOrientation(fullScreen: false)
            completionHandler(true)
        }

        private func applyOrientation(fullScreen: Bool) {
            let mask: UIInterfaceOrientationMask = fullScreen ? .landscape : .portrait
            AppDelegate.orientationLock = mask
            requestRotation(to: mask)
        }

        private func requestRotation(to mask: UIInterfaceOrientationMask) {
            targetOrientationMask = mask
            orientationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let mask = self.targetOrientationMask else { return }
                self.performRotation(mask: mask)
            }
            orientationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        private func performRotation(mask: UIInterfaceOrientationMask) {
            if #available(iOS 16.0, *) {
                guard let scene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                else { return }
                scene.keyWindow?.rootViewController?
                    .setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    #if DEBUG
                    print("requestGeometryUpdate: \(error.localizedDescription)")
                    #endif
                }
            } else {
                let orientation: UIInterfaceOrientation = (mask == .landscape) ? .landscapeRight : .portrait
                UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }
    }
}

// MARK: - 缓冲指示器
struct PlayerLoadingIndicator: View {
    @State private var rotate = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 3)
                        .frame(width: 46, height: 46)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [.white.opacity(0.0), .white]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(rotate ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                                   value: rotate)
                }
                Text("缓冲中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(radius: 2)
            }
        }
        .allowsHitTesting(false)   // ⭐ 关键：整个蒙层不接收点击
        .onAppear { rotate = true }
        .transition(.opacity)
    }
}

// MARK: - 播放页
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []   // ⭐ 当前线路全部集数
    var playSource: String? = nil           // ⭐ 新增：在线播放来源

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @State private var hasStartedPlaying = false   // ⭐ 视频是否已出第一帧
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("hasWarnedCellularOnlinePlay") private var hasWarnedCellularOnlinePlay = false
    @State private var showFirstPlayCellularAlert = false
    @State private var cellularPlayBlocked = false

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @Environment(\.appNavPath) var appNavPath

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false
    @State private var showLoginAlert = false

    // ⭐ 新增：无法播放 / 加载超时的反馈修复弹窗
    @State private var showRepairSheet = false        // 自动检测失败 → 半屏修复弹窗
    @State private var showReportSheet = false         // ⭐ 手动点「反馈修复」→ 全屏直达提交
    @State private var loadTimeoutWork: DispatchWorkItem? = nil

    @State private var showEpisodeConsumeConfirm = false
    @State private var episodeConsumeRemaining = 0
    @State private var pendingEpisodeForSwitch: VideoEpisodeItem? = nil

    // ⭐ 选集相关状态
    @State private var showEpisodePicker = false
    @State private var overrideEpisodeURL: String? = nil
    @State private var overrideEpisodeName: String? = nil
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil
    @State private var pendingOnlineResolvedURL: String? = nil
    @State private var showEpisodeCellularAlert = false

    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true
    @State private var loadedEpisodes: [VideoEpisodeItem] = []

    // 实际可用的集数：外部传入优先，否则用自动加载的
    private var activeEpisodes: [VideoEpisodeItem] {
        episodes.isEmpty ? loadedEpisodes : episodes
    }

    // ⭐ 计算当前实际在播的集数（切集后用 override）
    private var seriesBaseTitle: String {
        videoTitle.components(separatedBy: " · ").first ?? videoTitle
    }
    private var activeEpisodeURL: String { overrideEpisodeURL ?? episodeURL }
    private var activeEpisodeName: String? { overrideEpisodeName ?? episodeName }
    private var displayTitle: String {
        if let ep = activeEpisodeName, !ep.isEmpty {
            return "\(seriesBaseTitle) · \(ep)"
        }
        return videoTitle
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground),
                        Color.accentColor.opacity(0.06),
                        Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                playerArea
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                // ⭐ 固定广告防骗提示条（播放操作面板下方、标题上方）
                //    「反馈修复」现在直达填写页（ReportSheet），省掉中间说明弹窗
                AdWarningBanner()
                    // ⭐ 手动点击「反馈修复」→ 全屏直达填写页
                    .fullScreenCover(isPresented: $showReportSheet) {
                        ReportSheet(
                            videoTitle: displayTitle,
                            sourceURL: sourceURL ?? activeEpisodeURL,
                            episodeURL: activeEpisodeURL,
                            channelName: channelName,
                            episodeName: activeEpisodeName,
                            realURL: realURL ?? activeEpisodeURL
                        )
                    }
                    // ⭐ 程序自动发现播不了 → 半屏修复弹窗(带重试)
                    .sheet(isPresented: $showRepairSheet) {
                        PlaybackRepairSheet(
                            videoTitle: displayTitle,
                            sourceURL: sourceURL ?? activeEpisodeURL,
                            episodeURL: activeEpisodeURL,
                            channelName: channelName,
                            episodeName: activeEpisodeName,
                            realURL: realURL ?? activeEpisodeURL,
                            onRetry: {
                                showRepairSheet = false
                                Task { await resolve() }
                            }
                        )
                        .presentationDetents([.medium, .large])
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleCard

                        if let real = realURL {
                            CacheCard(realURL: real,
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
        // ⭐ 一旦真正出帧，取消超时看门狗
        .onChange(of: hasStartedPlaying) { started in
            if started {
                loadTimeoutWork?.cancel()
                loadTimeoutWork = nil
            }
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            if hasAccess && realURL == nil { await resolve() }

            // ⭐ 没有外部传入集数（如从观看记录进入）时，自动按 sourceURL 拉取该剧播放列表
            if episodes.isEmpty, loadedEpisodes.isEmpty,
            let src = sourceURL, !src.isEmpty {
                let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
                let chosen = channels.first { $0.name == channelName } ?? channels.first
                if let ch = chosen {
                    loadedEpisodes = ch.episodeItems(ascending: isEpisodeAscending)
                }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        .onChange(of: authManager.isSubscribed) { newValue in
            if newValue && realURL == nil {
                Task { await resolve() }
            }
        }
        .onDisappear {
            ReviewManager.shared.recordVideoInteraction()
            loadTimeoutWork?.cancel()   // ⭐ 离开页面清理看门狗
            loadTimeoutWork = nil
        }
        // ⭐ 切集到「在线播放」且当前是蜂窝时的拦截
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showEpisodeCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingOnlineEpisode = nil
                pendingOnlineResolvedURL = nil
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                if let ep = pendingOnlineEpisode {
                    switchToEpisode(ep, resolvedURL: pendingOnlineResolvedURL)
                }
                pendingOnlineEpisode = nil
                pendingOnlineResolvedURL = nil
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        // ⭐ 需求3修复：切集消耗点数的确认弹窗（之前 body 里漏挂，导致 needConsume 分支无反应）
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
        // ⭐ 首次在线播放的蜂窝提醒（确认后永久不再提醒）
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
            isPresented: $showFirstPlayCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                resolveError = isGlobalEnglishMode ? "Playback canceled on cellular network" : "已取消蜂窝网络播放"
                cellularPlayBlocked = false
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                cellularPlayBlocked = false
                scheduleLoadTimeout()   // ⭐ 允许后开始计时超时看门狗
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .onChange(of: authManager.isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
    }

    private var hasAccess: Bool {
        authManager.isSubscribed || FreeQuotaManager.shared.isUnlocked(activeEpisodeURL)
    }

    // ⭐ 已下载的"原始 url"集合（供选集弹窗显示蓝色已下载角标）
    private var cachedOriginalURLs: Set<String> {
        var s = Set<String>()
        for (key, meta) in downloadManager.cacheMetadata where downloadManager.localBookmarks[key] != nil {
            s.insert(key)
            if let orig = meta.originalEpisodeURL, !orig.isEmpty { s.insert(orig) }
        }
        return s
    }

    // ⭐ 加载超时看门狗：20 秒还没出帧就弹反馈修复
    private func scheduleLoadTimeout() {
        loadTimeoutWork?.cancel()
        let work = DispatchWorkItem {
            // showLoadingIndicator 已包含「仍在加载 / 未出帧 / 无错误 / 非蜂窝拦截」判断
            if hasAccess, showLoadingIndicator {
                showRepairSheet = true
            }
        }
        loadTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    // 播放器主区
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
                        Button(isGlobalEnglishMode ? "Retry" : "重试") {
                            Task { await resolve() }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.white.opacity(0.9))
                        .foregroundColor(.black).cornerRadius(16)

                        // ⭐ 错误页也提供一个直接举报入口
                        Button(isGlobalEnglishMode ? "Report" : "反馈修复") {
                            showReportSheet = true          // ⭐ 手动 → 全屏
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.orange.opacity(0.9))
                        .foregroundColor(.white).cornerRadius(16)
                    }
                }
            } else if let real = realURL,
                    !cellularPlayBlocked,
                    let playURL = downloadManager.getLocalURL(for: real) ?? URL(string: real) {
                VideoPlayerView(videoURL: playURL,
                                isBuffering: $isBuffering,
                                hasStartedPlaying: $hasStartedPlaying,
                                onPlaybackFailed: { msg in
                                    resolveError = msg          // 真失败才退回错误页
                                    showRepairSheet = true      // ⭐ 同时弹反馈修复
                                    loadTimeoutWork?.cancel()   // ⭐ 已失败，取消超时看门狗
                                })
                    .id(playURL)
            }

            PlayerLoadingIndicator()
                .opacity(showLoadingIndicator ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: showLoadingIndicator)
    }

    // ⭐ 是否显示「缓冲中」
    private var showLoadingIndicator: Bool {
        if cellularPlayBlocked { return false }
        if resolveError != nil { return false }
        if isResolving { return true }
        guard realURL != nil else { return true }
        if !hasStartedPlaying { return true }
        return isBuffering
    }

    // 标题卡片
    private var titleCard: some View {
        HStack(spacing: 10) {
            Text(displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(3)
            Spacer()
            if activeEpisodes.count > 1 {
                episodeSelectorButton
            }
        }
        .padding(.horizontal, 16)
    }

    // ⭐ 选集按钮
    private var episodeSelectorButton: some View {
        Button {
            showEpisodePicker = true
        } label: {
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
            EpisodePickerView(
                episodes: activeEpisodes,
                currentURL: activeEpisodeURL,
                cachedOriginalURLs: cachedOriginalURLs,
                onSelect: { ep in handleEpisodeSelection(ep) }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func badge(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // ⭐ 选集核心逻辑
    private func handleEpisodeSelection(_ ep: VideoEpisodeItem) {
        guard ep.url != activeEpisodeURL else { showEpisodePicker = false; return }

        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            proceedToSwitch(episode: ep)
        case .needLogin:
            showEpisodePicker = false
            showLoginAlert = true
        case .needConsume(let r):
            pendingEpisodeForSwitch = ep
            episodeConsumeRemaining = r
            showEpisodeConsumeConfirm = true
            showEpisodePicker = false
        case .exhausted:
            showEpisodePicker = false
            showSubscriptionSheet = true
        }
    }

    // ⭐ 确认消耗后切集
    private func consumeAndSwitchEpisode() async {
        guard let ep = pendingEpisodeForSwitch else { return }
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let result = await quotaManager.unlock(userId: uid, episodeKey: ep.url,
                                            videoTitle: "\(seriesBaseTitle) · \(ep.name)")
        switch result {
        case .success, .alreadyUnlocked:
            proceedToSwitch(episode: ep)
        case .quotaExceeded:
            showSubscriptionSheet = true
        case .failed:
            showSubscriptionSheet = true
        }
        pendingEpisodeForSwitch = nil
    }

    // ⭐ 真正执行切集
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

    // ⭐ 原地切到目标集
    private func switchToEpisode(_ ep: VideoEpisodeItem, resolvedURL: String?) {
        overrideEpisodeURL = ep.url
        overrideEpisodeName = ep.name
        resolveError = nil
        hasStartedPlaying = false
        if let resolved = resolvedURL {
            isResolving = false
            realURL = resolved
            scheduleLoadTimeout()          // ⭐ 直接起播，也要挂超时看门狗
            recordPlayback(real: resolved)
        } else {
            realURL = nil
            Task { await resolve() }
        }
    }

    private func resolve() async {
        isResolving = true; resolveError = nil
        hasStartedPlaying = false
        scheduleLoadTimeout()              // ⭐ 开始加载即挂超时看门狗
        do {
            let url: String
            do {
                // 第一次请求解析真实地址
                url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            } catch {
                // 首次失败，等待1.5秒后重试一次
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // 第二次重试请求，若再次失败会抛出错误到外层do-catch
                url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            }
            self.realURL = url
            evaluateCellularGate(real: url)
            recordPlayback(real: url)
        } catch {
            // 首次+重试全部失败，进入错误逻辑
            self.resolveError = error.localizedDescription
            self.showRepairSheet = true    // ⭐ 解析失败：弹反馈修复
            self.loadTimeoutWork?.cancel()
        }
        isResolving = false
    }

    private func evaluateCellularGate(real: String) {
        let isCached = downloadManager.localBookmarks[real] != nil
        if !isCached && !network.isWiFi && !hasWarnedCellularOnlinePlay {
            cellularPlayBlocked = true
            showFirstPlayCellularAlert = true
        }
    }

    // ⭐ 统一的「上报 + 写本地观看记录」
    private func recordPlayback(real: String) {
        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty {
                return (appleId, "apple")
            } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                return ("dev_" + idfv, "device")
            } else {
                return ("guest_user", "device")
            }
        }()

        TrackingManager.shared.track(
            event: .play,
            userId: trackUserId,
            userType: trackUserType,
            videoURL: activeEpisodeURL,
            videoTitle: displayTitle,
            source: playSource
        )

        VideoPlayRecordManager.shared.addRecord(
            videoTitle: seriesBaseTitle,
            episodeName: activeEpisodeName ?? (isGlobalEnglishMode ? "Play" : "播放"),
            videoURL: activeEpisodeURL,
            coverImage: coverImage,
            channelName: channelName,
            sourceURL: sourceURL
        )
    }
}

// MARK: - 离线下载播放器（选集显示全部剧集）
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
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
    @State private var playURL: URL? = nil
    @State private var isResolvingOnline = false
    @State private var isBuffering = false
    @State private var resolveError: String? = nil
    @State private var didInit = false

    // ⭐ 新增：反馈修复弹窗 + 超时看门狗
    @State private var showRepairSheet = false
    @State private var showReportSheet = false     // ⭐ 手动 → 全屏
    @State private var loadTimeoutWork: DispatchWorkItem? = nil

    @State private var showEpisodePicker = false
    @State private var showLoginAlert = false
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var pendingEpisode: VideoEpisodeItem? = nil
    @State private var showQuotaExhausted = false
    @State private var showCellularAlert = false
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil

    private var pickerEpisodes: [VideoEpisodeItem] {
        allEpisodes.isEmpty ? episodes : allEpisodes
    }

    private var baseTitle: String {
        title.components(separatedBy: " · ").first ?? title
    }
    private var displayTitle: String {
        if let ep = activeName, !ep.isEmpty { return "\(baseTitle) · \(ep)" }
        return title
    }

    private var cachedOriginalURLs: Set<String> {
        var s = Set<String>()
        for (key, meta) in downloadManager.cacheMetadata where downloadManager.localBookmarks[key] != nil {
            s.insert(key)
            if let orig = meta.originalEpisodeURL, !orig.isEmpty { s.insert(orig) }
        }
        return s
    }

    private var currentCacheKey: String? {
        if downloadManager.localBookmarks[activeKey] != nil { return activeKey }
        for (key, meta) in downloadManager.cacheMetadata
        where meta.originalEpisodeURL == activeKey && downloadManager.localBookmarks[key] != nil {
            return key
        }
        return nil
    }
    private var isCurrentCached: Bool { currentCacheKey != nil }

    // ⭐ 是否处于「仍在加载」状态（用于超时看门狗判断）
    private var isCachedLoading: Bool {
        if resolveError != nil { return false }
        return isResolvingOnline || isBuffering
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground),
                                    Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let playURL = playURL {
                        VideoPlayerView(videoURL: playURL,
                                        isBuffering: $isBuffering,
                                        hasStartedPlaying: .constant(true),
                                        onPlaybackFailed: { msg in
                                            resolveError = msg
                                            self.playURL = nil
                                            showRepairSheet = true      // ⭐
                                            loadTimeoutWork?.cancel()   // ⭐
                                        })
                            .id(playURL)
                        PlayerLoadingIndicator()
                            .opacity((isBuffering || isResolvingOnline) ? 1 : 0)
                            .allowsHitTesting(false)
                    } else if isResolvingOnline {
                        PlayerLoadingIndicator()
                    } else if let err = resolveError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36)).foregroundColor(.orange)
                            Text(err).foregroundColor(.white).font(.subheadline)
                                .multilineTextAlignment(.center).padding(.horizontal)
                            // ⭐ 错误页直接提供反馈修复入口
                            Button(isGlobalEnglishMode ? "Report" : "反馈修复") {
                                showRepairSheet = true
                            }
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

                // ⭐ 反馈修复弹窗挂在提示条上，避免和其他 sheet 冲突
                AdWarningBanner()
                    .fullScreenCover(isPresented: $showReportSheet) {
                        ReportSheet(
                            videoTitle: displayTitle,
                            sourceURL: sourceURL ?? activeKey,
                            episodeURL: activeKey,
                            channelName: channelName,
                            episodeName: activeName,
                            realURL: activeKey
                        )
                    }
                    .sheet(isPresented: $showRepairSheet) {
                        PlaybackRepairSheet(
                            videoTitle: displayTitle,
                            sourceURL: sourceURL ?? activeKey,
                            episodeURL: activeKey,
                            channelName: channelName,
                            episodeName: activeName,
                            realURL: activeKey,
                            onRetry: {
                                showRepairSheet = false
                                retryCurrent()          // ⭐ 这里用上你已有的 retryCurrent
                            }
                        )
                        .presentationDetents([.medium, .large])
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Text(displayTitle)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(3)
                            Spacer()
                            if pickerEpisodes.count > 1 {
                                episodeSelectorButton
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 16)

                        if let cacheKey = currentCacheKey {
                            Button(role: .destructive) {
                                downloadManager.deleteDownload(urlString: cacheKey)
                                dismiss()
                            } label: {
                                Label(isGlobalEnglishMode ? "Delete Cache" : "删除视频",
                                    systemImage: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.red.opacity(0.12))
                                    )
                            }
                            .padding(.horizontal, 16)
                        }

                        Button(action: {
                            appNavPath?.wrappedValue.append(NavigationTarget.allArticles)
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.blue.opacity(0.1))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "newspaper.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.blue)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isGlobalEnglishMode ? "Back to News" : "返回新闻阅读")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(isGlobalEnglishMode ? "Read all subscribed articles" : "阅读所有订阅文章")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                            )
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer(minLength: 30)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerView(
                episodes: pickerEpisodes,
                currentURL: activeKey,
                cachedOriginalURLs: cachedOriginalURLs,
                onSelect: { ep in selectEpisode(ep) }
            )
            .presentationDetents([.medium, .large])
        }
        .alert(isGlobalEnglishMode
            ? "Use Free Pass (\(consumeRemaining) left)"
            : "今日免费赠送还剩\(consumeRemaining)点",
            isPresented: $showConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndPlay() }
            }
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
            Button(isGlobalEnglishMode ? "Sign in with Apple" : "登录") {
                authManager.signInWithApple()
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "Sign in (free) to unlock your free daily passes."
                : "登录后即可获得每日免费观看点数，登录无需付费。")
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingOnlineEpisode = nil
            }
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
            startInitialPlaybackIfNeeded()
            if isCachedLoading { scheduleLoadTimeout() }   // ⭐
        }
        // ⭐ 加载状态变化：进入加载→计时；结束加载→取消
        .onChange(of: isCachedLoading) { loading in
            if loading {
                scheduleLoadTimeout()
            } else {
                loadTimeoutWork?.cancel()
                loadTimeoutWork = nil
            }
        }
        .onDisappear {
            loadTimeoutWork?.cancel()   // ⭐
            loadTimeoutWork = nil
        }
        .onChange(of: authManager.isLoggedIn) { loggedIn in
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
        Button {
            showEpisodePicker = true
        } label: {
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

    // ⭐ 加载超时看门狗
    private func scheduleLoadTimeout() {
        loadTimeoutWork?.cancel()
        let work = DispatchWorkItem {
            if isCachedLoading { showRepairSheet = true }
        }
        loadTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    // ⭐ 重试当前集（本地优先，否则在线重新解析）
    private func retryCurrent() {
        resolveError = nil
        if let local = localURL(forOriginal: activeKey) {
            playURL = local
            return
        }
        if let ep = pickerEpisodes.first(where: { $0.url == activeKey }) {
            resolveAndPlayOnline(ep)
        }
    }

    // MARK: - 初始化 / 拉取

    private func startInitialPlaybackIfNeeded() {
        guard !didInit else { return }
        didInit = true
        activeName = episodeName
        activeKey = realURL
        playURL = downloadManager.getLocalURL(for: realURL) ?? URL(string: realURL)
        if playURL == nil {
            // ⭐ 连播放地址都构造不出来：直接判定无法播放，弹反馈修复
            resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
            showRepairSheet = true
        } else {
            recordPlayback()
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
            if items.contains(where: { $0.url == orig }) {
                self.activeKey = orig
            }
        }
    }

    // MARK: - 选集

    private func selectEpisode(_ ep: VideoEpisodeItem) {
        showEpisodePicker = false
        guard ep.url != activeKey else { return }

        if let local = localURL(forOriginal: ep.url) {
            activeKey = ep.url
            activeName = ep.name
            resolveError = nil
            playURL = local
            recordPlayback()
            return
        }

        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            startOnline(ep)
        case .needLogin:
            showLoginAlert = true
        case .needConsume(let r):
            pendingEpisode = ep
            consumeRemaining = r
            showConsumeConfirm = true
        case .exhausted:
            showQuotaExhausted = true
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
        activeKey = ep.url
        activeName = ep.name
        resolveError = nil
        playURL = nil
        isResolvingOnline = true
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                isResolvingOnline = false
                if let resolved = resolved, let u = URL(string: resolved) {
                    playURL = u
                    recordPlayback()
                } else {
                    resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
                    showRepairSheet = true   // ⭐ 解析失败：弹反馈修复
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
            case .success, .alreadyUnlocked:
                startOnline(ep)
            case .quotaExceeded, .failed:
                showSubscriptionSheet = true
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
            if let appleId = authManager.userIdentifier, !appleId.isEmpty {
                return (appleId, "apple")
            } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                return ("dev_" + idfv, "device")
            } else {
                return ("guest_user", "device")
            }
        }()

        TrackingManager.shared.track(
            event: .play,
            userId: trackUserId,
            userType: trackUserType,
            videoURL: activeKey,
            videoTitle: displayTitle
        )

        let originalKey = downloadManager.cacheMetadata[activeKey]?.originalEpisodeURL ?? activeKey
        VideoPlayRecordManager.shared.addRecord(
            videoTitle: baseTitle,
            episodeName: activeName ?? "",
            videoURL: originalKey,
            coverImage: downloadManager.cacheMetadata[activeKey]?.coverImage,
            channelName: channelName,
            sourceURL: sourceURL
        )
    }
}

// MARK: - 选集数据模型
struct VideoEpisodeItem: Identifiable, Hashable {
    var id: String { url }
    let number: String   // 网格里显示的简短编号，如 "1"、"2"
    let name: String     // 原始集数名，如 "第5集"、"HD国语"
    let url: String      // 原始 episodeURL（解析前）
}

extension OVideoChannel {
    /// 把当前线路的所有集数转换为选集网格用的数组
    func episodeItems(ascending: Bool = true) -> [VideoEpisodeItem] {
        sortedEpisodes(ascending: ascending).enumerated().map { index, kv in
            VideoEpisodeItem(
                number: Self.shortNumber(from: kv.name, fallbackIndex: index),
                name: kv.name,
                url: kv.url
            )
        }
    }

    private static func shortNumber(from name: String, fallbackIndex: Int) -> String {
        let digits = name.filter { $0.isNumber }
        if !digits.isEmpty, digits.count <= 4, let n = Int(digits) {
            return String(n)         // "第5集" → "5"
        }
        return String(fallbackIndex + 1)  // "HD国语" 等无数字 → 按位置编号
    }
}

// MARK: - 选集弹窗
struct EpisodePickerView: View {
    let episodes: [VideoEpisodeItem]
    let currentURL: String
    var cachedOriginalURLs: Set<String> = []   // ⭐ 新增：已下载的 url 集合
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
                        // ⭐ 已下载判断：合并传入集合 + 直接命中 bookmark
                        let isCached = cachedOriginalURLs.contains(ep.url) || dm.localBookmarks[ep.url] != nil
                        let isUnlocked = quotaManager.isUnlocked(ep.url)
                        let hasQuota = quotaManager.remaining > 0

                        Button {
                            onSelect(ep)
                            dismiss()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isCurrent ? Color.accentColor
                                                    : Color.secondary.opacity(0.15))
                                    .frame(height: 50)
                                    .overlay(
                                        Text(ep.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.7)
                                            .multilineTextAlignment(.center)
                                            .foregroundColor(isCurrent ? .white : .primary)
                                            .padding(.horizontal, 4)
                                    )

                                // ⭐ 角标优先级：已下载(蓝) > 已解锁(绿) > 锁定(橙)
                                if isCached {
                                    // 已下载：蓝色下载角标（与点数解锁的绿色对勾明确区分）
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .padding(2)
                                        .background(Circle().fill(Color.blue))
                                        .padding(3)
                                } else if !authManager.isSubscribed {
                                    if isUnlocked {
                                        // 点数已解锁：绿色对勾
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                            .padding(3)
                                    } else if !hasQuota {
                                        // 额度用完且未解锁：橙色锁
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white)
                                            .padding(3)
                                            .background(Circle().fill(Color.orange))
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

// MARK: - ⭐ 无法播放 / 加载超时的「反馈修复」弹窗(半屏,自动弹出用)
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
                            Circle().fill(Color.blue.opacity(0.12))
                                .frame(width: 64, height: 64)
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.blue)
                        }
                        Text(isGlobalEnglishMode ? "Can't play this video?" : "视频无法播放？")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    Spacer()

                    // ⭐ 复用现有举报卡片:它自带「提交」动作
                    ReportLinkCard(
                        videoTitle: videoTitle,
                        sourceURL: sourceURL,
                        episodeURL: episodeURL,
                        channelName: channelName,
                        episodeName: episodeName,
                        realURL: realURL
                    )
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