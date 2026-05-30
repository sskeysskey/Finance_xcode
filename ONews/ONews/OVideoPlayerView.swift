// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoPlayerView.swift

import SwiftUI
import AVKit

// MARK: - VideoPlayerView (UIKit 包装)
struct VideoPlayerView: UIViewControllerRepresentable {
    let videoURL: URL
    @Binding var isBuffering: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        player.automaticallyWaitsToMinimizeStalling = true
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect
        context.coordinator.attach(player: player)
        player.play()
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
        private var currentItemObs: NSKeyValueObservation?
        private var bufferingResetWork: DispatchWorkItem?

        init(_ parent: VideoPlayerView) { self.parent = parent }

        func attach(player: AVPlayer) {
            self.player = player

            timeControlObs = player.observe(\.timeControlStatus,
                                            options: [.new, .initial]) { [weak self] p, _ in
                self?.updateBuffering(from: p)
            }
            rateObs = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
                // 用户 seek 后 rate 一般会回到 1.0,可借此校正
                self?.updateBuffering(from: p)
            }
            // currentItem 可能在某些场景下被替换,要重新绑定 item 级 KVO
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
            currentItemObs?.invalidate()
            bufferingResetWork?.cancel()
        }

        // 横竖屏代理保持不变 ...
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                willBeginFullScreenPresentationWithAnimationCoordinator
                                coordinator: UIViewControllerTransitionCoordinator) {
            AppDelegate.orientationLock = .landscape
            forceOrientation(.landscapeRight)
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                willEndFullScreenPresentationWithAnimationCoordinator
                                coordinator: UIViewControllerTransitionCoordinator) {
            AppDelegate.orientationLock = .portrait
            forceOrientation(.portrait)
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
    var channelName: String? = nil   // 【新增】playlist 名,如「天堂」
    var episodeName: String? = nil   // 【新增】集数 key,如「HD国语」
    var sourceURL: String? = nil     // 【新增】影片页 url(唯一键)

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    // 【新增】
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false

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
                                        videoTitle: videoTitle,
                                        coverImage: coverImage)
                            }

                            if let real = realURL, downloadManager.localBookmarks[real] != nil {
                                offlineBadge
                            }

                            // ⭐ 新增:错误链接举报入口
                            if let real = realURL {
                                ReportLinkCard(
                                    videoTitle: videoTitle,
                                    sourceURL: sourceURL ?? episodeURL,
                                    episodeURL: episodeURL,
                                    channelName: channelName,
                                    episodeName: episodeName,
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
    }
    
    // 【新增】未订阅锁屏视图
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
                if isBuffering {
                    PlayerLoadingIndicator()
                        .animation(.easeInOut(duration: 0.2), value: isBuffering)
                }
            }
        }
    }

    // 标题卡片
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(videoTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(3)

            // ✨ 修改此处：使用 HStack + Spacer 实现右对齐
            HStack(spacing: 10) {
                NetworkBadge()
                
                Spacer() // 将开关推到最右侧
                
                HStack(spacing: 6) {
                    Text(isGlobalEnglishMode ? "Wi-Fi only" : "仅 Wi-Fi 下缓存")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Toggle("", isOn: $downloadManager.wifiOnly)
                        .labelsHidden()
                        .scaleEffect(0.8)
                        .tint(.accentColor)
                }
            }
        }
        .padding(.horizontal, 16)
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

    private func resolve() async {
        isResolving = true; resolveError = nil
        do {
            let url = try await OVideoAPI.resolveRealURL(episodeURL: episodeURL)
            self.realURL = url
            // 🔥 新增：上报"播放"事件
            TrackingManager.shared.track(
                event: .play,
                userId: authManager.userIdentifier,
                videoURL: episodeURL,            // 用源 URL 作为唯一键
                videoTitle: videoTitle
            )
        } catch {
            self.resolveError = error.localizedDescription
        }
        isResolving = false
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
                            Text(title)
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

                            // ⭐ 新增:错误链接举报入口
                            ReportLinkCard(
                                videoTitle: title,
                                sourceURL: realURL,
                                episodeURL: realURL,
                                channelName: channelName,
                                episodeName: episodeName,
                                realURL: nil
                            )

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