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

        // ⭐ 新增：卡顿自愈 watchdog（针对本地缓存横屏全屏偶发停住）
        private var stallWatchdog: Timer?
        private var lastWatchdogTime: Double = -1
        private var stalledTicks = 0

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
        }

        // MARK: 初始化（创建播放器 + 注册生命周期监听）
        func setup(controller: AVPlayerViewController, url: URL) {
            self.controller = controller
            self.url = url

            // 初始进度：读取持久化记忆（进程被杀后再进入时的兜底续播）
            let saved = PlaybackPositionStore.load(for: url)
            let resume = saved > 3 ? CMTime(seconds: saved, preferredTimescale: 600) : nil
            restoreTime = resume ?? .zero

            configureAudioSession()
            buildPlayer(resumeTime: resume, autoPlay: true)
            registerLifecycleObservers()
            startStallWatchdog()   // ⭐ 启动卡顿自愈
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
            
            // ⭐ 新增：更保守的策略，仅对本地缓存文件（isFileURL）启用卡顿检测
            // 在线播放完全交给 AVPlayer 和系统网络层自行调度，避免因网络波动导致的误判干预
            guard url?.isFileURL == true else {
                lastWatchdogTime = -1
                stalledTicks = 0
                return
            }

            // 仅在「期望播放」时检测；用户主动暂停时 timeControlStatus == .paused，不干预
            let intendsToPlay = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                || (player.timeControlStatus == .playing)
            guard intendsToPlay else {
                lastWatchdogTime = player.currentTime().seconds
                stalledTicks = 0
                return
            }
            
            let now = player.currentTime().seconds
            if lastWatchdogTime >= 0, abs(now - lastWatchdogTime) < 0.05 {
                stalledTicks += 1
                if stalledTicks >= 2 {           // 连续 ~2 秒时间不前进 → 判定卡死
                    recoverFromStallIfNeeded()
                    stalledTicks = 0
                }
            } else {
                stalledTicks = 0
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
            // 已到结尾就不折腾
            let dur = item.duration.seconds
            let cur = player.currentTime().seconds
            if dur.isFinite, dur > 0, cur >= dur - 0.5 { return }

            let isLocal = url?.isFileURL ?? false

            if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                // 缓冲足够却卡住：直接续播
                player.play()
            } else if isLocal {
                // ⭐ 本地缓存却卡住：轻微回退触发重新解码/缓冲，
                //    等价于你手动「后退一点再播放」的自愈手法
                let target = CMTime(seconds: max(0, cur - 1.0), preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player?.play()
                }
            }
            // 在线且缓冲不足：交给系统继续缓冲，不强行干预，避免拖累网络
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
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self = self else { return }
                if context.isCancelled {
                    self.isFullScreen = false
                    self.applyOrientation(fullScreen: false)
                } else {
                    self.isFullScreen = true
                    self.applyOrientation(fullScreen: true)
                }
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

// MARK: - 播放页（重做 UI）
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []   // ⭐ 当前线路全部集数

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @State private var hasStartedPlaying = false   // ⭐ 视频是否已出第一帧
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("hasWarnedCellularOnlinePlay") private var hasWarnedCellularOnlinePlay = false  // ⭐ 新增
    @State private var showFirstPlayCellularAlert = false   // ⭐ 新增
    @State private var cellularPlayBlocked = false          // ⭐ 新增

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @Environment(\.appNavPath) var appNavPath

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false
    @State private var showLoginAlert = false

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
                AdWarningBanner()

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

                        if let real = realURL, downloadManager.localBookmarks[real] != nil {
                            offlineBadge
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
                        // 【新增】跳转到 Article All 入口
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
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            if hasAccess && realURL == nil { await resolve() }

            // ⭐ 没有外部传入集数（如从观看记录进入）时，自动按 sourceURL 拉取该剧播放列表
            if episodes.isEmpty, loadedEpisodes.isEmpty,
            let src = sourceURL, !src.isEmpty {
                let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
                // 优先匹配当时的线路名，匹配不到则用第一条
                let chosen = channels.first { $0.name == channelName } ?? channels.first
                if let ch = chosen {
                    loadedEpisodes = ch.episodeItems(ascending: isEpisodeAscending)
                }
            }
        }
        // 【新增】
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        // 【新增】订阅成功后自动开始解析
        .onChange(of: authManager.isSubscribed) { newValue in
            if newValue && realURL == nil {
                Task { await resolve() }
            }
        }
        // 【新增】当用户退出播放器（返回详情页）时，记录一次视频模块的有效交互
        .onDisappear {
            ReviewManager.shared.recordVideoInteraction()
        }
        // ⭐ 切集到「在线播放」且当前是蜂窝时的拦截
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showEpisodeCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingOnlineEpisode = nil
                pendingOnlineResolvedURL = nil
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true   // ⭐ 新增
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
        // ⭐ 新增：首次在线播放的蜂窝提醒（确认后永久不再提醒）
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
            isPresented: $showFirstPlayCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                resolveError = isGlobalEnglishMode ? "Playback canceled on cellular network" : "已取消蜂窝网络播放"
                cellularPlayBlocked = false
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                cellularPlayBlocked = false
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
                    Button(isGlobalEnglishMode ? "Retry" : "重试") {
                        Task { await resolve() }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.white.opacity(0.9))
                    .foregroundColor(.black).cornerRadius(16)
                }
            } else if let real = realURL,
                    !cellularPlayBlocked,
                    let playURL = downloadManager.getLocalURL(for: real) ?? URL(string: real) {
                // ⭐ 顺手修掉原来的强解包 URL(string: real)! 崩溃风险
                VideoPlayerView(videoURL: playURL,
                                isBuffering: $isBuffering,
                                hasStartedPlaying: $hasStartedPlaying,
                                onPlaybackFailed: { msg in
                                    resolveError = msg     // 真失败才退回错误页
                                })
                    .id(playURL)
            }

            // ⭐ 统一「缓冲中」蒙层：解析中 / 等待首帧 / 播放中再缓冲 都走它，
            //    用户在画面真正出现前始终看到「缓冲中…」，不再有空窗或一闪而过。
            //    PlayerLoadingIndicator 已 allowsHitTesting(false)，不挡播放/快进等按钮。
            if showLoadingIndicator {
                PlayerLoadingIndicator()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showLoadingIndicator)
    }

    // ⭐ 是否显示「缓冲中」
    private var showLoadingIndicator: Bool {
        if cellularPlayBlocked { return false }   // ⭐ 新增：等待用户决定，不显示缓冲
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
            if activeEpisodes.count > 1 {            // ⭐ 原来是 episodes.count > 1
                episodeSelectorButton
            }
            NetworkBadge()
        }
        .padding(.horizontal, 16)
    }

    // ⭐ 选集按钮（把弹窗 sheet 挂在按钮上，避免和订阅 sheet 冲突）
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
                episodes: activeEpisodes,        // ⭐ 原来是 episodes
                currentURL: activeEpisodeURL,
                cachedOriginalURLs: cachedOriginalURLs,   // ⭐ 新增
                onSelect: { ep in handleEpisodeSelection(ep) }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var offlineBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            Text(isGlobalEnglishMode
                 ? "Playing from local cache"
                 : "正在使用本地缓存播放，此时不消耗流量。")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Color.green.opacity(0.10)))
        .padding(.horizontal, 16)
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

    // ⭐ 选集核心逻辑：先解析→判断缓存→决定本地/在线（在线+蜂窝才提示）
    private func handleEpisodeSelection(_ ep: VideoEpisodeItem) {
        guard ep.url != activeEpisodeURL else { showEpisodePicker = false; return }
        
        // ⭐ 先走门禁
        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            proceedToSwitch(episode: ep)
        case .needLogin:                 // ⭐ 新增
            showEpisodePicker = false
            showLoginAlert = true
        case .needConsume(let r):
            pendingEpisodeForSwitch = ep
            episodeConsumeRemaining = r
            showEpisodeConsumeConfirm = true
            showEpisodePicker = false   // 先关掉选集弹窗，再弹确认
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
        isResolving = true            // ⭐ 立刻给出「解析中」反馈
        resolveError = nil
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                isResolving = false   // ⭐ 解析结束先收掉 loading，再决定走哪条分支
                let realKey = resolved ?? ep.url
                let cached = (resolved != nil) && (downloadManager.localBookmarks[realKey] != nil)
                if cached {
                    switchToEpisode(ep, resolvedURL: realKey)
                } else if !network.isWiFi && !hasWarnedCellularOnlinePlay {   // ⭐ 加条件
                    pendingOnlineEpisode = ep
                    pendingOnlineResolvedURL = resolved
                    showEpisodeCellularAlert = true
                } else {
                    switchToEpisode(ep, resolvedURL: resolved)
                }
            }
        }
    }

    // ⭐ 原地切到目标集；resolvedURL 有值就直接用，否则重新解析
    private func switchToEpisode(_ ep: VideoEpisodeItem, resolvedURL: String?) {
        overrideEpisodeURL = ep.url
        overrideEpisodeName = ep.name
        resolveError = nil
        hasStartedPlaying = false
        if let resolved = resolvedURL {
            isResolving = false
            realURL = resolved
            recordPlayback(real: resolved)
        } else {
            realURL = nil
            Task { await resolve() }
        }
    }

    private func resolve() async {
        isResolving = true; resolveError = nil
        hasStartedPlaying = false
        do {
            let url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            self.realURL = url
            evaluateCellularGate(real: url)   // ⭐ 新增：在线 + 蜂窝 + 首次 → 拦截
            recordPlayback(real: url)
        } catch {
            self.resolveError = error.localizedDescription
        }
        isResolving = false
    }

    // ⭐ 新增
    private func evaluateCellularGate(real: String) {
        let isCached = downloadManager.localBookmarks[real] != nil
        if !isCached && !network.isWiFi && !hasWarnedCellularOnlinePlay {
            cellularPlayBlocked = true
            showFirstPlayCellularAlert = true
        }
    }

    // ⭐ 统一的「上报 + 写本地观看记录」，切集和首次播放共用
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
            videoTitle: displayTitle
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
    var sourceURL: String? = nil            // ⭐ 新增：拉取完整剧集
    var episodes: [VideoEpisodeItem] = []   // 兜底：仅已缓存集

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

    // ⭐ 全部剧集（按需在线拉取）
    @State private var allEpisodes: [VideoEpisodeItem] = []

    // ⭐ 当前在播集（key 取 pickerEpisodes 的 url 空间）
    @State private var activeKey: String = ""
    @State private var activeName: String? = nil
    @State private var playURL: URL? = nil
    @State private var isResolvingOnline = false
    @State private var isBuffering = false
    @State private var resolveError: String? = nil
    @State private var didInit = false

    // ⭐ 选集 / 门禁 / 蜂窝
    @State private var showEpisodePicker = false
    @State private var showLoginAlert = false
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var pendingEpisode: VideoEpisodeItem? = nil
    @State private var showQuotaExhausted = false
    @State private var showCellularAlert = false
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil

    // 选集用的剧集列表：优先全部，拉取失败回退到已缓存集
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

    // ⭐ 已缓存的"原始 url"集合（供选集角标判断；含 resolved key 与 original key）
    private var cachedOriginalURLs: Set<String> {
        var s = Set<String>()
        for (key, meta) in downloadManager.cacheMetadata where downloadManager.localBookmarks[key] != nil {
            s.insert(key)
            if let orig = meta.originalEpisodeURL, !orig.isEmpty { s.insert(orig) }
        }
        return s
    }

    // 当前在播集对应的本地缓存 key（没有则代表当前在在线播放）
    private var currentCacheKey: String? {
        if downloadManager.localBookmarks[activeKey] != nil { return activeKey }
        for (key, meta) in downloadManager.cacheMetadata
        where meta.originalEpisodeURL == activeKey && downloadManager.localBookmarks[key] != nil {
            return key
        }
        return nil
    }
    private var isCurrentCached: Bool { currentCacheKey != nil }

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
                                        })
                            .id(playURL)
                        if isBuffering || isResolvingOnline {
                            PlayerLoadingIndicator()
                        }
                    } else if isResolvingOnline {
                        PlayerLoadingIndicator()
                    } else if let err = resolveError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36)).foregroundColor(.orange)
                            Text(err).foregroundColor(.white).font(.subheadline)
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                    } else {
                        Text(isGlobalEnglishMode ? "Unable to play" : "无法播放")
                            .foregroundColor(.white)
                    }
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                AdWarningBanner()

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

                        // 当前播放来源徽标
                        HStack(spacing: 6) {
                            if isCurrentCached {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                                Text(isGlobalEnglishMode
                                    ? "Playing from local cache"
                                    : "正在使用本地缓存播放")
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                Image(systemName: "wifi").foregroundColor(.orange)
                                Text(isGlobalEnglishMode
                                    ? "Playing online (not cached)"
                                    : "该集未缓存，正在在线播放")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(
                            (isCurrentCached ? Color.green : Color.orange).opacity(0.10)))
                        .padding(.horizontal, 16)

                        // 仅已缓存集允许删除
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

                        // 返回新闻阅读
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
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
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
        // 切到未缓存集的门禁提示
        .alert(isGlobalEnglishMode
            ? "Use Free Pass (\(consumeRemaining) left)"
            : "今日免费赠送还剩\(consumeRemaining)点",
            isPresented: $showConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndPlay() }
            }
        } message: {
            Text(isGlobalEnglishMode ? "This will use 1 pass." : "当前视频将消耗 1 点")
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
        // 未缓存集在线播放的蜂窝提醒（与主播放页共用"只提醒一次"）
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
        .onAppear { startInitialPlaybackIfNeeded() }
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

    // MARK: - 初始化 / 拉取

    private func startInitialPlaybackIfNeeded() {
        guard !didInit else { return }
        didInit = true
        activeName = episodeName
        activeKey = realURL   // 先用传入的 resolved key
        playURL = downloadManager.getLocalURL(for: realURL) ?? URL(string: realURL)
        recordPlayback()
    }

    private func loadAllEpisodes() async {
        guard allEpisodes.isEmpty, let src = sourceURL, !src.isEmpty else { return }
        let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
        guard let best = optimalSortedChannels(channels).first else { return }
        let items = best.episodeItems(ascending: isEpisodeAscending)
        await MainActor.run {
            self.allEpisodes = items
            // 把 activeKey 从 resolved key 迁移到 original key，便于选集高亮
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

        // 已缓存 → 直接本地播放
        if let local = localURL(forOriginal: ep.url) {
            activeKey = ep.url
            activeName = ep.name
            resolveError = nil
            playURL = local
            recordPlayback()
            return
        }

        // 未缓存 → 在线播放，走门禁
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

    // 给定"原始 url"，找到本地缓存文件 URL（同时兼容 resolved key 自身）
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

        // 观看记录里 videoURL 用"原始 episodeURL"
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