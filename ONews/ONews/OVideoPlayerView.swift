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
        let controller = LifecycleAVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        player.automaticallyWaitsToMinimizeStalling = true

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

        // ⭐ 应用倍速并起播
        if #available(iOS 16.0, *) {
            player.defaultRate = savedRate
            player.play()                       // 16+ 会按 defaultRate 起播
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

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false

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
            if !authManager.isSubscribed {
                lockedOverlay
            } else {
                // 背景渐变
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
                                        episodeName: activeEpisodeName)
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
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 【修改】只有已订阅才解析
            if authManager.isSubscribed && realURL == nil {
                await resolve()
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
    }

    private var lockedOverlay: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text(isGlobalEnglishMode ? "Subscription Required" : "需要订阅")
                .font(.title2.bold())
            Text(isGlobalEnglishMode
                 ? "Subscribe to unlock video playback and offline caching."
                 : "订阅后即可在线播放并使用离线缓存功能")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showSubscriptionSheet = true
            } label: {
                Text(isGlobalEnglishMode ? "Subscribe Now" : "立即订阅")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40).padding(.vertical, 12)
                    .background(Capsule().fill(Color.orange))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.viewBackground.ignoresSafeArea())
        .onAppear {
            // 进来就直接弹订阅页
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showSubscriptionSheet = true
            }
        }
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
        showEpisodePicker = false
        Task {
            // resolveRealURL 对 m3u8 会直接短路返回，不走网络；其它是一个很小的解析请求
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                let realKey = resolved ?? ep.url
                let cached = (resolved != nil) && (downloadManager.localBookmarks[realKey] != nil)

                if cached {
                    // 本地缓存：直接播，蜂窝也不提示
                    switchToEpisode(ep, resolvedURL: realKey)
                } else if !network.isWiFi {
                    // 在线 + 蜂窝：先提示
                    pendingOnlineEpisode = ep
                    pendingOnlineResolvedURL = resolved
                    showEpisodeCellularAlert = true
                } else {
                    // 在线 + Wi-Fi：直接播
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
    var channelName: String? = nil   // 【新增】
    var episodeName: String? = nil   // 【新增】
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @State private var hasTracked = false

    var body: some View {
        ZStack {
            if !authManager.isSubscribed {
                lockedOverlay   // 1. 修复：已在下方补充 lockedOverlay 属性
            } else {
                LinearGradient(colors: [Color(.systemBackground),
                                        Color.accentColor.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom).ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        if let local = downloadManager.getLocalURL(for: realURL) {
                            VideoPlayerView(videoURL: local, isBuffering: .constant(false))
                        } else if let url = URL(string: realURL) {
                            VideoPlayerView(videoURL: url, isBuffering: .constant(false))
                        } else {
                            Text(isGlobalEnglishMode ? "Unable to play" : "无法播放")
                                .foregroundColor(.white)
                        }
                    }
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            let displayTitle = episodeName.map { "\(title) · \($0)" } ?? title

                            Text(displayTitle)   // ← 改为组合标题
                                .font(.system(size: 17, weight: .bold))
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

                            // 🛠️ 已移除：ReportLinkCard（离线缓存播放无需举报功能）

                            Button(role: .destructive) {
                                downloadManager.deleteDownload(urlString: realURL)
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
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        // 2. 修复：移除了多余的 .task 和 .onChange(of: authManager.isSubscribed) 里的 resolve()，因为缓存播放器不需要解析 URL
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        .task {
            trackCachedPlayIfNeeded()
        }
        .onChange(of: authManager.isSubscribed) { newValue in
            if newValue { trackCachedPlayIfNeeded() }
        }
    }

    private func trackCachedPlayIfNeeded() {
        // 必须已订阅，且本次进入只打一次
        guard authManager.isSubscribed, !hasTracked else { return }
        hasTracked = true

        // 与在线播放、下载完成统一的用户身份解析
        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty {
                return (appleId, "apple")
            } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                return ("dev_" + idfv, "device")
            } else {
                return ("guest_user", "device")
            }
        }()

        // 1) 上报后台统计（event = play）
        let trackTitle = episodeName.map { "\(title) · \($0)" } ?? title
        TrackingManager.shared.track(
            event: .play,
            userId: trackUserId,
            userType: trackUserType,
            videoURL: realURL,
            videoTitle: trackTitle
        )

        // 2) 同步写入本地观看记录
        VideoPlayRecordManager.shared.addRecord(
            videoTitle: title.components(separatedBy: " · ").first ?? title,
            episodeName: episodeName ?? "",  // 新数据一定有值，不需要 fallback
            videoURL: realURL,
            coverImage: downloadManager.cacheMetadata[realURL]?.coverImage,
            channelName: channelName,
            sourceURL: nil
        )
    }
    
    // 【新增】未订阅锁屏视图 (供 CachedVideoPlayerView 内部使用)
    private var lockedOverlay: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text(isGlobalEnglishMode ? "Subscription Required" : "需要订阅")
                .font(.title2.bold())
            Text(isGlobalEnglishMode 
                 ? "Subscribe to unlock video playback and offline caching."
                 : "订阅后即可在线播放并使用离线缓存功能")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showSubscriptionSheet = true
            } label: {
                Text(isGlobalEnglishMode ? "Subscribe Now" : "立即订阅")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40).padding(.vertical, 12)
                    .background(Capsule().fill(Color.orange))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.viewBackground.ignoresSafeArea())
        .onAppear {
            // 进来就直接弹订阅页
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showSubscriptionSheet = true
            }
        }
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
    @ObservedObject private var dm = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(episodes) { ep in
                        let isCurrent = ep.url == currentURL
                        // 仅对 episodeURL 本身就是缓存 key 的情况（如 m3u8）能直接判断，
                        // 判断不到也不影响功能，只是不显示下载角标
                        let isCached = dm.localBookmarks[ep.url] != nil

                        Button {
                            onSelect(ep)
                            dismiss()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isCurrent ? Color.accentColor
                                                    : Color.secondary.opacity(0.15))
                                    .frame(height: 44)
                                    .overlay(
                                        Text(ep.number)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(isCurrent ? .white : .primary)
                                    )
                                if isCached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                        .padding(3)
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