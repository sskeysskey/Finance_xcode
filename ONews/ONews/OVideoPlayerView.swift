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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // ⭐ 关键：配置音频会话为播放模式（影响 AirPlay 路由能否带视频）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let controller = LifecycleAVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        player.automaticallyWaitsToMinimizeStalling = true

        // ⭐⭐ 关键修复：允许把"画面+声音"整条流投到 AirPlay 接收端
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        // ⭐ 读取上次保存的倍速
        let savedRate = PlaybackSpeedStore.rate

        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect

        controller.onWillDisappear = { [weak coordinator = context.coordinator] in
            guard let coordinator = coordinator else { return }
            if coordinator.isFullScreen || coordinator.isPiP { return }
            coordinator.pause()
        }

        context.coordinator.attach(player: player)

        if #available(iOS 16.0, *) {
            player.defaultRate = savedRate
            player.play()
        } else {
            player.play()
            if savedRate != 1.0 { player.rate = savedRate }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.detach()
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let parent: VideoPlayerView
        private weak var player: AVPlayer?
        private var timeControlObs: NSKeyValueObservation?
        private var keepUpObs: NSKeyValueObservation?
        private var bufferEmptyObs: NSKeyValueObservation?
        private var bufferFullObs: NSKeyValueObservation?
        private var rateObs: NSKeyValueObservation?
        private var defaultRateObs: NSKeyValueObservation?   // ⭐ 新增
        private var currentItemObs: NSKeyValueObservation?
        private var bufferingResetWork: DispatchWorkItem?

        // ⭐ 新增:标记全屏 / 画中画状态,用于在 viewWillDisappear 时判断是否应暂停
        var isFullScreen = false
        var isPiP = false

        init(_ parent: VideoPlayerView) { self.parent = parent }

        // ⭐ 新增:供外部(viewWillDisappear)调用的暂停
        func pause() {
            player?.pause()
        }

        func attach(player: AVPlayer) {
            self.player = player

            timeControlObs = player.observe(\.timeControlStatus,
                                            options: [.new, .initial]) { [weak self] p, _ in
                self?.updateBuffering(from: p)
            }
            rateObs = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
                self?.updateBuffering(from: p)
                // ⭐ 用户改速度（播放中）→ 记住它
                let r = p.rate
                if r > 0 && r <= 2.0 { PlaybackSpeedStore.rate = r }
            }
            // ⭐ iOS16+ 暂停时改速度走的是 defaultRate，单独监听一次
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
        }

        private func attachItemObservers(item: AVPlayerItem?) {
            keepUpObs?.invalidate(); keepUpObs = nil
            bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
            bufferFullObs?.invalidate(); bufferFullObs = nil
            guard let item = item else { return }

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

        private func updateBuffering(from player: AVPlayer) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let waiting = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                self.setBuffering(waiting)
            }
        }

        private func setBuffering(_ value: Bool) {
            if parent.isBuffering != value {
                parent.isBuffering = value
            }
            // 兜底:即使 KVO 漏掉,8 秒后强制复位一次
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

        func detach() {
            timeControlObs?.invalidate()
            keepUpObs?.invalidate()
            bufferEmptyObs?.invalidate()
            bufferFullObs?.invalidate()
            rateObs?.invalidate()
            defaultRateObs?.invalidate()        // ⭐ 新增
            currentItemObs?.invalidate()
            bufferingResetWork?.cancel()
        }

        // MARK: 全屏代理(同时维护 isFullScreen 标记)
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                willBeginFullScreenPresentationWithAnimationCoordinator
                                coordinator: UIViewControllerTransitionCoordinator) {
            isFullScreen = true
            AppDelegate.orientationLock = .landscape
            forceOrientation(.landscapeRight)
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                willEndFullScreenPresentationWithAnimationCoordinator
                                coordinator: UIViewControllerTransitionCoordinator) {
            isFullScreen = false
            AppDelegate.orientationLock = .portrait
            forceOrientation(.portrait)
        }

        // MARK: 画中画代理(维护 isPiP 标记)
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiP = true
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiP = false
        }

        private func forceOrientation(_ orientation: UIInterfaceOrientation) {
            if #available(iOS 16.0, *) {
                guard let scene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                else { return }
                let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscape : .portrait
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
                scene.keyWindow?.rootViewController?
                    .setNeedsUpdateOfSupportedInterfaceOrientations()
            } else {
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
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared

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
            // 【新增】未订阅时显示锁屏，不解析、不播放
            // if !hasAccess {
            //     // lockedOverlay
            // } else {
            //     // 背景渐变
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

                            Spacer(minLength: 30)
                        }
                        .padding(.top, 16)
                    }
                }
            // }
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
            if isResolving {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(isGlobalEnglishMode ? "Resolving..." : "解析中...")
                        .foregroundColor(.white).font(.caption)
                }
            } else if let error = resolveError {
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
            } else if let real = realURL {
                let playURL = downloadManager.getLocalURL(for: real) ?? URL(string: real)!
                VideoPlayerView(videoURL: playURL, isBuffering: $isBuffering)
                    .id(playURL)   // ⭐ 切集时强制重建播放器，避免还放旧视频
                if isBuffering {
                    PlayerLoadingIndicator()
                        .animation(.easeInOut(duration: 0.2), value: isBuffering)
                }
            }
        }
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
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
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
                        VideoPlayerView(videoURL: local, isBuffering: .constant(false))
                            .id(activeEpisodeURL)
                    } else if let url = URL(string: activeEpisodeURL) {
                        VideoPlayerView(videoURL: url, isBuffering: .constant(false))
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
        .alert(isGlobalEnglishMode ? "Free Passes Used Up" : "今日免费额度已用完",
            isPresented: $showQuotaExhaustedAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") {
                // 用户明确点订阅，才弹出订阅页
                showSubscriptionSheet = true
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "You've used all your free passes for today. Come back tomorrow for more, or subscribe now for unlimited access."
                : "您今天的免费额度已用完，订阅后即可以无限畅想所有视频。")
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