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
        var parent: VideoPlayerView                    // ⭐ let -> var
        private weak var controller: AVPlayerViewController?
        private weak var player: AVPlayer?
        private var url: URL?

        // KVO
        private var timeControlObs: NSKeyValueObservation?
        private var keepUpObs: NSKeyValueObservation?
        private var bufferEmptyObs: NSKeyValueObservation?
        private var bufferFullObs: NSKeyValueObservation?
        private var statusObs: NSKeyValueObservation?          // ⭐ 监听 item 是否就绪
        private var rateObs: NSKeyValueObservation?
        private var defaultRateObs: NSKeyValueObservation?
        private var currentItemObs: NSKeyValueObservation?
        private var lastPersistedSeconds: Double = 0

        // ⭐ 进度记忆 / 恢复相关
        private var periodicObs: Any?
        private var restoreTime: CMTime = .zero
        private var wasPlayingBeforeBackground = true
        private var pendingSeek: CMTime?
        private var shouldAutoPlayWhenReady = true
        private var didHandleReady = false

        private var bufferingResetWork: DispatchWorkItem?
        private var targetOrientationMask: UIInterfaceOrientationMask?
        private var orientationWork: DispatchWorkItem?
        // ⭐ 全屏时用的原生加载指示器（挂在 contentOverlayView 上，会跟随进入全屏）
        private var loadingView: UIView?

        // ⭐ 新增：卡顿自愈 watchdog（针对本地缓存横屏全屏偶发停住）
        private var stallWatchdog: Timer?
        private var lastWatchdogTime: Double = -1
        private var stalledTicks = 0
        private var stallRecoveryAttempts = 0   // ⭐ 自愈升级计数：多次轻量自愈无效则重建

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
            updateLoadingOverlay()        // ⭐ 新增
        }

        // MARK: ⭐ 全屏可见的加载指示器（放进 contentOverlayView，会跟随进入全屏）
        private func setupLoadingOverlay() {
            guard let controller = controller else { return }
            controller.loadViewIfNeeded()                       // 确保 contentOverlayView 已就绪
            guard let overlay = controller.contentOverlayView else { return }

            let isEnglish = UserDefaults.standard.bool(forKey: "isGlobalEnglishMode")

            let box = UIView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            box.layer.cornerRadius = 12
            box.isUserInteractionEnabled = false                // ⭐ 不拦截播放/快进手势
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

        // ⭐ 仅在全屏时显示（竖屏内嵌仍由 SwiftUI 的 PlayerLoadingIndicator 负责，避免重复转圈）
        private func updateLoadingOverlay() {
            let shouldShow = isFullScreen && (!parent.hasStartedPlaying || parent.isBuffering)
            loadingView?.isHidden = !shouldShow
        }

        // MARK: 初始化（创建播放器 + 注册生命周期监听）
        func setup(controller: AVPlayerViewController, url: URL) {
            self.controller = controller
            self.url = url

            let saved = PlaybackPositionStore.load(for: url)
            let resume = saved > 3 ? CMTime(seconds: saved, preferredTimescale: 600) : nil
            restoreTime = resume ?? .zero

            configureAudioSession()
            buildPlayer(resumeTime: resume, autoPlay: true)
            setupLoadingOverlay()          // ⭐ 新增：构建全屏可见的加载指示器
            registerLifecycleObservers()
            startStallWatchdog()
        }

        // MARK: 音频会话（首次 & mediaServices 重启后都要配）
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

            let player = AVPlayer(url: url)
            // ⭐ 关键修复(问题2)：本地缓存文件关闭「等待以减少卡顿」，
            //    避免本地播放时 AVPlayer 进入假性 waiting 而停住；在线流仍保留以应对网络抖动。
            player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
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
            // ⭐ 每秒记录一次进度（内存 + 持久化）
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

            // ⭐ 就绪后再 seek 到目标位置并起播（保证 seek 不被吞掉）
            statusObs = item.observe(\.status,
                                     options: [.new, .initial]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch it.status {
                    case .readyToPlay:
                        self.handleReadyToPlay()
                    case .failed:
                        // ⭐ 真正失败才报错，避免无限「缓冲中」
                        self.parent.onPlaybackFailed?(
                            it.error?.localizedDescription ?? "视频播放失败")
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
                    player.play()   // 使用 defaultRate
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
            markStartedPlaying()   // ⭐ 时间在走 = 已出帧，收掉「缓冲中」
            restoreTime = time

            // ⭐ 磁盘写入节流：每累计 5 秒才落盘一次
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

        // MARK: ⭐ 卡顿自愈 watchdog
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

            // 仅对本地缓存文件启用卡顿检测；在线交给系统网络层
            guard url?.isFileURL == true else {
                lastWatchdogTime = -1
                stalledTicks = 0
                stallRecoveryAttempts = 0
                return
            }

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
                if stalledTicks >= 2 {           // 连续 ~2 秒不前进 → 判定卡死
                    recoverFromStallIfNeeded()
                    stalledTicks = 0
                }
            } else {
                stalledTicks = 0
                stallRecoveryAttempts = 0        // ⭐ 时间正常前进，重置升级计数
            }
            lastWatchdogTime = now
        }

        @objc private func handlePlaybackStalled() {
            DispatchQueue.main.async { [weak self] in
                self?.recoverFromStallIfNeeded()
            }
        }

        private func recoverFromStallIfNeeded() {
            guard let player = player, let item = player.currentItem else { return }
            let dur = item.duration.seconds
            let cur = player.currentTime().seconds
            if dur.isFinite, dur > 0, cur >= dur - 0.5 { return }

            let isLocal = url?.isFileURL ?? false

            // ⭐ 自愈升级：连续多次轻量自愈仍无效，说明渲染层可能已失效（黑屏），
            //    直接彻底重建播放器以恢复画面。
            stallRecoveryAttempts += 1
            if stallRecoveryAttempts >= 3 {
                stallRecoveryAttempts = 0
                lastWatchdogTime = -1
                stalledTicks = 0
                rebuildPreservingState()
                return
            }

            if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                // 缓冲足够却卡住：直接续播
                player.play()
            } else if isLocal {
                // 本地缓存却卡住：轻微回退触发重新解码/缓冲
                let target = CMTime(seconds: max(0, cur - 1.0), preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player?.play()
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
            // ⭐ 新增：系统的卡顿通知，作为 watchdog 之外的另一条自愈触发途径
            nc.addObserver(self, selector: #selector(handlePlaybackStalled),
                           name: AVPlayerItem.playbackStalledNotification, object: nil)
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
            // ⭐ 回前台先校正方向：不在全屏就一定恢复竖屏锁，
            //    修复「全屏→PiP→退后台→恢复」后卡横屏的问题。
            if !isFullScreen {
                applyOrientation(fullScreen: false)
            }

            // PiP 期间画面在小窗持续渲染，不存在黑屏，无需干预播放器重绑
            guard !isPiP else { return }
            guard let player = player, let controller = controller else { return }

            // ……（下面保持原来的重绑/seek 逻辑不变）
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
            // ⭐ 本地缓存兜底：回前台后做一次延迟校验，若仍想播放但时间没前进
            //    （渲染层在长时间后台/内存压力下可能失效导致黑屏），则彻底重建播放器。
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
            // mediaserverd 被重启：所有音视频对象失效，必须连音频会话一起重建
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
                if status == .playing { self.markStartedPlaying() }   // ⭐ 真正播放
                let waiting = (status == .waitingToPlayAtSpecifiedRate)
                self.setBuffering(waiting)
            }
        }

        private func setBuffering(_ value: Bool) {
            if parent.isBuffering != value {
                parent.isBuffering = value
            }
            updateLoadingOverlay()        // ⭐ 新增
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

            loadingView?.removeFromSuperview()                  // ⭐ 新增
            loadingView = nil                                   // ⭐ 新增

            // ⭐ 非画中画时：彻底释放播放器 + 清掉锁屏「正在播放」信息
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
            updateLoadingOverlay()                              // ⭐ 新增：刚进全屏立即判断是否要显示
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self = self else { return }
                if context.isCancelled {
                    self.isFullScreen = false
                    self.applyOrientation(fullScreen: false)
                } else {
                    self.isFullScreen = true
                    self.applyOrientation(fullScreen: true)
                }
                self.updateLoadingOverlay()                     // ⭐ 新增
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
                self.updateLoadingOverlay()                     // ⭐ 新增：退出全屏后收起原生指示器
            }
        }

        // MARK: 画中画代理
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiP = true
            // ⭐ 进入 PiP 系统会收起全屏界面。若此前处于横屏全屏，
            //    必须同步作废全屏状态，否则回到 App 会卡在横屏。
            if isFullScreen {
                isFullScreen = false
            }
            AppDelegate.orientationLock = .portrait   // 仅复位锁；旋转留到回前台/active 时执行
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiP = false
            // ⭐ PiP 结束（含自动结束）后，只要不在全屏就强制回竖屏。
            //    这里 App 已 active，requestGeometryUpdate 能真正生效。
            if !isFullScreen {
                DispatchQueue.main.async { [weak self] in
                    self?.applyOrientation(fullScreen: false)
                }
            }
        }

        // ⭐ 处理 PiP 上的「恢复」按钮。
        //    我们不恢复全屏，直接完成并保持竖屏内嵌，符合「上滑离开全屏」的预期。
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

                        // ⭐ 在线播放页：保留错误链接举报入口
                        if let real = realURL {
                            ReportLinkCard(
                                videoTitle: displayTitle,
                                sourceURL: sourceURL ?? activeEpisodeURL,
                                episodeURL: activeEpisodeURL,
                                channelName: channelName,
                                episodeName: activeEpisodeName,
                                realURL: real
                            )
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

    // ⭐ 已缓存的"原始 url"集合（供选集弹窗显示蓝色已下载角标）
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
            let url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            self.realURL = url
            evaluateCellularGate(real: url)
            recordPlayback(real: url)
        } catch {
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

// MARK: - 离线缓存播放器（选集显示全部剧集）
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
                                Label(isGlobalEnglishMode ? "Delete Cache" : "删除缓存",
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