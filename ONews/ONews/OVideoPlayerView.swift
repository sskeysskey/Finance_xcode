// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoPlayerView.swift

import SwiftUI
import AVKit

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

// MARK: - ⭐ 新增：播放进度记忆（按 URL 记忆，用于断点续播 / 黑屏自愈后回到原位置）
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
    @Binding var hasStartedPlaying: Bool              // ⭐ 新增：是否已真正出第一帧
    var onPlaybackFailed: ((String) -> Void)? = nil   // ⭐ 新增：播放失败兜底，避免无限转圈

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
        private var statusObs: NSKeyValueObservation?          // ⭐ 新增：监听 item 是否就绪
        private var rateObs: NSKeyValueObservation?
        private var defaultRateObs: NSKeyValueObservation?
        private var currentItemObs: NSKeyValueObservation?
        private var lastPersistedSeconds: Double = 0

        // ⭐ 新增：进度记忆 / 恢复相关
        private var periodicObs: Any?
        private var restoreTime: CMTime = .zero
        private var wasPlayingBeforeBackground = true
        private var pendingSeek: CMTime?
        private var shouldAutoPlayWhenReady = true
        private var didHandleReady = false

        private var bufferingResetWork: DispatchWorkItem?
        private var targetOrientationMask: UIInterfaceOrientationMask?
        private var orientationWork: DispatchWorkItem?

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
            player.automaticallyWaitsToMinimizeStalling = true
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

        // MARK: 生命周期 / 媒体重启监听
        private func registerLifecycleObservers() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(handleEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(handleEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(handleMediaServicesReset),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
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

            // ……（下面保持你原来的重绑/seek 逻辑不变）
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
            // ⭐ 若不需要后台/PiP 常驻播放，离开时释放音频会话
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

        // ⭐ 新增：处理 PiP 上的「恢复」按钮。
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
    var episodes: [VideoEpisodeItem] = []   // ⭐ 新增：当前线路全部集数

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @State private var hasStartedPlaying = false   // ⭐ 视频是否已出第一帧
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @Environment(\.appNavPath) var appNavPath

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false

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

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleCard

                        if let real = realURL {
                            CacheCard(realURL: real,
                                    videoTitle: displayTitle,
                                    coverImage: coverImage,
                                    seriesTitle: seriesBaseTitle,
                                    episodeName: activeEpisodeName,
                                    episodeKey: activeEpisodeURL)
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
        .alert(isGlobalEnglishMode ? "Use a Free Pass" : "使用免费次数",
            isPresented: $showEpisodeConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndSwitchEpisode() }
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "This will use 1 of today's free passes (\(episodeConsumeRemaining) left). After that, you can play / download / watch this episode unlimited times today."
                : "本次将消耗 1 次今日免费次数（剩余 \(episodeConsumeRemaining) 次）。确认后，今天内可无限次在线播放 / 缓存下载 / 离线观看本集。")
        }
    }

    private var hasAccess: Bool {
        authManager.isSubscribed || FreeQuotaManager.shared.isUnlocked(activeEpisodeURL)
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
        if resolveError != nil { return false }   // 出错交给错误视图
        if isResolving { return true }            // 解析中（对用户呈现为「缓冲中」，不暴露技术状态）
        guard realURL != nil else { return true } // 地址还没就绪
        if !hasStartedPlaying { return true }     // 有地址但还没出第一帧
        return isBuffering                        // 播放途中再缓冲
    }

    // 标题卡片
    private var titleCard: some View {
        HStack(spacing: 10) {
            Text(displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(3)
            Spacer()
            if episodes.count > 1 {            // ⭐ 仅多集才显示「选集」
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
                episodes: episodes,
                currentURL: activeEpisodeURL,
                onSelect: { ep in handleEpisodeSelection(ep) }
            )
            .presentationDetents([.medium, .large])   // iOS 16+
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
        
        // ⭐ 新增：先走门禁
        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            proceedToSwitch(episode: ep)
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

    // ⭐ 新增：确认消耗后切集
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

    // ⭐ 新增：真正执行切集（把原来的 handleEpisodeSelection 逻辑搬进来）
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
                } else if !network.isWiFi {
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
        hasStartedPlaying = false         // ⭐ 新增
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
        hasStartedPlaying = false        // ⭐ 新增
        do {
            let url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            self.realURL = url
            recordPlayback(real: url)
        } catch {
            self.resolveError = error.localizedDescription
        }
        isResolving = false
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

// MARK: - 离线缓存播放器
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    var channelName: String? = nil
    var episodeName: String? = nil
    var episodes: [VideoEpisodeItem] = []   // ⭐ 新增：当前剧集全部集数

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appNavPath) var appNavPath
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared

    // ⭐ 新增：选集相关状态
    @State private var showEpisodePicker = false
    @State private var overrideEpisodeURL: String? = nil
    @State private var overrideEpisodeName: String? = nil

    // ⭐ 仅用于「选集切换到未解锁集」时的门禁
    @State private var showCachedConsumeConfirm = false
    @State private var cachedConsumeRemaining = 0
    @State private var showQuotaExhaustedAlert = false
    @State private var pendingSwitchEpisode: VideoEpisodeItem? = nil

    // ⭐ 计算当前实际在播的集数
    private var activeEpisodeURL: String { overrideEpisodeURL ?? realURL }
    private var activeEpisodeName: String? { overrideEpisodeName ?? episodeName }
    private var displayTitle: String {
        let base = title.components(separatedBy: " · ").first ?? title
        if let ep = activeEpisodeName, !ep.isEmpty {
            return "\(base) · \(ep)"
        }
        return title
    }
    
    // ⭐ 过滤出已缓存的集数（用于选集弹窗）
    private var cachedEpisodes: [VideoEpisodeItem] {
        episodes.filter { downloadManager.localBookmarks[$0.url] != nil }
    }
    private var episodeKey: String {
        downloadManager.cacheMetadata[activeEpisodeURL]?.originalEpisodeURL ?? activeEpisodeURL
    }
    private var hasAccess: Bool {
        authManager.isSubscribed || FreeQuotaManager.shared.isUnlocked(episodeKey)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground),
                                    Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let local = downloadManager.getLocalURL(for: activeEpisodeURL) {
                        VideoPlayerView(videoURL: local,
                                        isBuffering: .constant(false),
                                        hasStartedPlaying: .constant(true))
                            .id(activeEpisodeURL)
                    } else if let url = URL(string: activeEpisodeURL) {
                        VideoPlayerView(videoURL: url,
                                        isBuffering: .constant(false),
                                        hasStartedPlaying: .constant(true))
                            .id(activeEpisodeURL)
                    } else {
                        Text(isGlobalEnglishMode ? "Unable to play" : "无法播放")
                            .foregroundColor(.white)
                    }
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Text(displayTitle)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(3)
                            Spacer()
                            if cachedEpisodes.count > 1 {
                                episodeSelectorButton
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 16)

                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            Text(isGlobalEnglishMode
                                ? "Playing from local cache"
                                : "正在使用本地缓存播放")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.green.opacity(0.10)))
                        .padding(.horizontal, 16)

                        Button(role: .destructive) {
                            downloadManager.deleteDownload(urlString: activeEpisodeURL)
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
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        // ⭐ 新增：选集弹窗
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerView(
                episodes: cachedEpisodes,
                currentURL: activeEpisodeURL,
                onSelect: { ep in switchToEpisode(ep) }
            )
            .presentationDetents([.medium, .large])
        }
        .alert(isGlobalEnglishMode ? "Use a Free Pass" : "使用免费次数",
               isPresented: $showCachedConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingSwitchEpisode = nil
            }
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndSwitch() }
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "This will use 1 of today's free passes (\(cachedConsumeRemaining) left). After that, you can play / download / watch this episode unlimited times today."
                : "本次将消耗 1 次今日免费次数（剩余 \(cachedConsumeRemaining) 次）。确认后，今天内可无限次在线播放 / 缓存下载 / 离线观看本集。")
        }
        .alert(isGlobalEnglishMode ? "Free Passes Used Up" : "今日免费额度已用完",
               isPresented: $showQuotaExhaustedAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") {
                showSubscriptionSheet = true
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "You've used all your free passes for today. Come back tomorrow for more, or subscribe now for unlimited access."
                : "您今天的免费额度已用完，订阅后即可以无限畅想所有视频。")
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            recordPlayback()   // 进入即播，权限已在列表页保证
        }
        .onChange(of: authManager.isSubscribed) { newValue in
            if newValue { recordPlayback() }
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

    // ⭐ 选集切换：先门禁，未解锁才弹确认；通过后再切
    private func switchToEpisode(_ ep: VideoEpisodeItem) {
        guard ep.url != activeEpisodeURL else { return }
        let key = downloadManager.cacheMetadata[ep.url]?.originalEpisodeURL ?? ep.url
        switch decideVideoAccess(episodeKey: key, auth: authManager, quota: quotaManager) {
        case .allowed:
            applyEpisode(ep)
        case .needConsume(let r):
            pendingSwitchEpisode = ep
            cachedConsumeRemaining = r
            showCachedConsumeConfirm = true
        case .exhausted:
            showQuotaExhaustedAlert = true
        }
    }

    private func applyEpisode(_ ep: VideoEpisodeItem) {
        overrideEpisodeURL = ep.url
        overrideEpisodeName = ep.name
        recordPlayback()
    }

    private func consumeAndSwitch() async {
        guard let ep = pendingSwitchEpisode else { return }
        let key = downloadManager.cacheMetadata[ep.url]?.originalEpisodeURL ?? ep.url
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let base = title.components(separatedBy: " · ").first ?? title
        let result = await quotaManager.unlock(userId: uid, episodeKey: key,
                                               videoTitle: "\(base) · \(ep.name)")
        switch result {
        case .success, .alreadyUnlocked:
            applyEpisode(ep)
        case .quotaExceeded, .failed:
            showQuotaExhaustedAlert = true
        }
        pendingSwitchEpisode = nil
    }

    private func recordPlayback() {
        guard hasAccess else { return }

        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty {
                return (appleId, "apple")
            } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                return ("dev_" + idfv, "device")
            } else {
                return ("guest_user", "device")
            }
        }()

        let baseTitle = title.components(separatedBy: " · ").first ?? title
        let trackTitle = activeEpisodeName.map { "\(baseTitle) · \($0)" } ?? title

        TrackingManager.shared.track(
            event: .play,
            userId: trackUserId,
            userType: trackUserType,
            videoURL: activeEpisodeURL,
            videoTitle: trackTitle
        )

        let originalKey = downloadManager.cacheMetadata[activeEpisodeURL]?.originalEpisodeURL ?? activeEpisodeURL

        VideoPlayRecordManager.shared.addRecord(
            videoTitle: baseTitle,
            episodeName: activeEpisodeName ?? "",
            videoURL: originalKey,                 // ⭐ 改成原始 episodeURL
            coverImage: downloadManager.cacheMetadata[activeEpisodeURL]?.coverImage,
            channelName: channelName,
            sourceURL: nil
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
                        // 仅对 episodeURL 本身就是缓存 key 的情况（如 m3u8）能直接判断，
                        // 判断不到也不影响功能，只是不显示下载角标
                        let isCached = dm.localBookmarks[ep.url] != nil

                        // ⭐ 新增：判断免费解锁状态
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
                                    .frame(height: 50)   // 稍微增高，给两行文字留空间
                                    .overlay(
                                        Text(ep.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(2)                    // 最多两行
                                            .minimumScaleFactor(0.7)         // 空间不够时自动缩字
                                            .multilineTextAlignment(.center) // 居中
                                            .foregroundColor(isCurrent ? .white : .primary)
                                            .padding(.horizontal, 4)
                                    )
                                // ⭐ 修改后的角标优先级：缓存 > 已解锁 > 锁定
                                if isCached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                        .padding(3)
                                } else if !authManager.isSubscribed {
                                    if isUnlocked {
                                        // 已解锁：绿色对勾（今天内免费可用）
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
                                    // 有剩余次数且未解锁：不显示任何角标
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