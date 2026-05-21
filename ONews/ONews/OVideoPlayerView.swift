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
        private var timeControlObs: NSKeyValueObservation?
        private var keepUpObs: NSKeyValueObservation?

        init(_ parent: VideoPlayerView) { self.parent = parent }

        func attach(player: AVPlayer) {
            timeControlObs = player.observe(\.timeControlStatus,
                                             options: [.new, .initial]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    let buffering = (p.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                    self?.parent.isBuffering = buffering
                }
            }
            if let item = player.currentItem {
                keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp,
                                         options: [.new, .initial]) { [weak self] it, _ in
                    DispatchQueue.main.async {
                        if it.isPlaybackLikelyToKeepUp { self?.parent.isBuffering = false }
                    }
                }
            }
        }
        func detach() { timeControlObs?.invalidate(); keepUpObs?.invalidate() }

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
        .onAppear { rotate = true }
        .transition(.opacity)
    }
}

// MARK: - 播放页（重做 UI）
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?

    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false

    var body: some View {
        ZStack {
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

                        Spacer(minLength: 30)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .task { if realURL == nil { await resolve() } }
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
                if isBuffering { PlayerLoadingIndicator() }
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

            HStack(spacing: 10) {
                NetworkBadge()
                if downloadManager.wifiOnly {
                    badge(text: isGlobalEnglishMode ? "Wi-Fi only" : "仅 Wi-Fi 下载",
                          systemImage: "wifi", color: .blue)
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
                 : "正在使用本地缓存播放")
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
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
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
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
    }
}