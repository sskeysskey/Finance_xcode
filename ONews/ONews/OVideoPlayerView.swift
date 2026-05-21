// VideoDetailView、VideoPlayerPageView、VideoCacheView、CachedVideoPlayerView
// 详情、播放、缓存管理

import SwiftUI
import AVKit
import UIKit
import AVFoundation

// MARK: - HLS 下载管理器
class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!
    @Published var downloadProgress: [String: Double] = [:]
    @Published var localBookmarks: [String: Data] = [:]
    @Published var cacheMetadata: [String: VideoCacheMetadata] = [:]
    
    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    private let metadataKey  = "ONews_VideoCacheMetadata"
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        downloadSession = AVAssetDownloadURLSession(configuration: config,
                                                    assetDownloadDelegate: self,
                                                    delegateQueue: .main)
        loadBookmarks()
        loadMetadata()
    }
    
    func startDownload(urlString: String, title: String, coverImage: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let asset = AVURLAsset(url: url)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else { return }
        task.taskDescription = urlString
        task.resume()
        DispatchQueue.main.async {
            self.downloadProgress[urlString] = 0.0
            self.cacheMetadata[urlString] = VideoCacheMetadata(title: title,
                                                               coverImage: coverImage,
                                                               savedAt: Date())
            self.saveMetadata()
        }
    }
    
    func deleteDownload(urlString: String) {
        if let localURL = getLocalURL(for: urlString) {
            try? FileManager.default.removeItem(at: localURL)
        }
        localBookmarks.removeValue(forKey: urlString)
        cacheMetadata.removeValue(forKey: urlString)
        saveBookmarks()
        saveMetadata()
    }
    
    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmark = localBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        var percent = 0.0
        for value in loadedTimeRanges {
            let r = value.timeRangeValue
            percent += r.duration.seconds / timeRangeExpectedToLoad.duration.seconds
        }
        DispatchQueue.main.async {
            let current = self.downloadProgress[urlString] ?? 0.0
            self.downloadProgress[urlString] = min(1.0, max(current, percent))
        }
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        do {
            let bookmark = try location.bookmarkData(options: .minimalBookmark,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
            DispatchQueue.main.async {
                self.localBookmarks[urlString] = bookmark
                self.saveBookmarks()
            }
        } catch { print("保存书签失败: \(error)") }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { return }
        DispatchQueue.main.async { self.downloadProgress.removeValue(forKey: urlString) }
    }
    
    private func saveBookmarks() {
        UserDefaults.standard.set(localBookmarks, forKey: bookmarksKey)
    }
    private func loadBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] {
            localBookmarks = saved
        }
    }
    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(cacheMetadata) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }
    private func loadMetadata() {
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let decoded = try? JSONDecoder().decode([String: VideoCacheMetadata].self, from: data) {
            cacheMetadata = decoded
        }
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let videoURL: URL
    @Binding var isBuffering: Bool   // 新增：暴露缓冲状态
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        // 让流播放更稳:
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
    
    // MARK: - Coordinator
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let parent: VideoPlayerView
        private var timeControlObs: NSKeyValueObservation?
        private var keepUpObs: NSKeyValueObservation?
        
        init(_ parent: VideoPlayerView) { self.parent = parent }
        
        func attach(player: AVPlayer) {
            // 1) 监听 timeControlStatus:.waitingToPlayAtSpecifiedRate 即缓冲中
            timeControlObs = player.observe(\.timeControlStatus,
                                             options: [.new, .initial]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    let buffering = (p.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                    self?.parent.isBuffering = buffering
                }
            }
            // 2) 双保险:监听当前 item 的 isPlaybackLikelyToKeepUp
            if let item = player.currentItem {
                keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp,
                                         options: [.new, .initial]) { [weak self] it, _ in
                    DispatchQueue.main.async {
                        if it.isPlaybackLikelyToKeepUp {
                            self?.parent.isBuffering = false
                        }
                    }
                }
            }
        }
        
        func detach() {
            timeControlObs?.invalidate()
            keepUpObs?.invalidate()
        }
        
        // MARK: 全屏 → 横屏
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
                let mask: UIInterfaceOrientationMask =
                    orientation.isLandscape ? .landscape : .portrait
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

struct PlayerLoadingIndicator: View {
    @State private var rotate = false
    
    var body: some View {
        ZStack {
            // 半透明黑色蒙层,提升对比度
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

struct CustomProgressBar: View {
    @Binding var current: Double      // 0...1
    let buffered: Double              // 0...1
    let totalDuration: Double         // 秒
    let onSeek: (Double) -> Void      // 0...1
    
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let display = isDragging ? dragValue : current
            let trackH: CGFloat = isDragging ? 5 : 3
            let thumbSize: CGFloat = isDragging ? 16 : 12
            
            ZStack(alignment: .leading) {
                // 整体可点区域(高,易点中)
                Color.clear.frame(height: 32)
                
                // Track 背景 - 起点也可见
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: w, height: trackH)
                
                // 缓冲层
                Capsule()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: w * CGFloat(buffered), height: trackH)
                
                // 已播放
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: w * CGFloat(display), height: trackH)
                
                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: w * CGFloat(display) - thumbSize / 2)
                
                // 时间气泡
                if isDragging {
                    Text(formatTime(dragValue * totalDuration))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .offset(x: max(0, min(w - 50, w * CGFloat(display) - 25)), y: -28)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !isDragging { isDragging = true; dragValue = current }
                        let p = max(0, min(1, Double(v.location.x / w)))
                        dragValue = p
                    }
                    .onEnded { _ in
                        onSeek(dragValue)
                        isDragging = false
                    }
            )
        }
        .frame(height: 32)
    }
    
    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - 播放页
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?
    
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var isBuffering = false
    
    var body: some View {
        VStack(spacing: 0) {
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
                    }
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(videoTitle)
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 16).padding(.top, 16)
                    
                    if let real = realURL {
                        cacheSection(realURL: real)
                    }
                    
                    if let real = realURL, downloadManager.localBookmarks[real] != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.slash").foregroundColor(.green)
                            Text(isGlobalEnglishMode
                                 ? "Playing from local cache"
                                 : "当前正在使用本地缓存播放")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                    Spacer(minLength: 30)
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .task { if realURL == nil { await resolve() } }
    }
    
    @ViewBuilder
    private func cacheSection(realURL: String) -> some View {
        let isDownloaded = downloadManager.localBookmarks[realURL] != nil
        let progress = downloadManager.downloadProgress[realURL]
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "icloud.and.arrow.down").foregroundColor(.blue)
                Text(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                
                if isDownloaded {
                    Button {
                        downloadManager.deleteDownload(urlString: realURL)
                    } label: {
                        Label(isGlobalEnglishMode ? "Delete" : "删除缓存",
                              systemImage: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.12)).cornerRadius(16)
                    }
                } else if progress != nil {
                    Text("\(Int((progress ?? 0) * 100))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                } else {
                    Button {
                        downloadManager.startDownload(urlString: realURL,
                                                      title: videoTitle,
                                                      coverImage: coverImage)
                    } label: {
                        Label(isGlobalEnglishMode ? "Download" : "缓存到本地",
                              systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12)).cornerRadius(16)
                    }
                }
            }
            
            if isDownloaded {
                Label(isGlobalEnglishMode ? "Cached, available offline" : "已缓存,可离线播放",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundColor(.green)
            } else if let p = progress {
                ProgressView(value: p)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
            } else {
                Text(isGlobalEnglishMode
                     ? "Cache this video for offline playback later."
                     : "缓存后可离线播放,建议在 Wi-Fi 环境下操作。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
    
    private func resolve() async {
        isResolving = true
        resolveError = nil
        do {
            let url = try await OVideoAPI.resolveRealURL(episodeURL: episodeURL)
            self.realURL = url
        } catch {
            self.resolveError = error.localizedDescription
        }
        isResolving = false
    }
}

// MARK: - 缓存管理
struct VideoCacheView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    private var cachedItems: [(url: String, meta: VideoCacheMetadata)] {
        downloadManager.localBookmarks.keys.compactMap { url in
            if let m = downloadManager.cacheMetadata[url] {
                return (url, m)
            } else {
                return (url, VideoCacheMetadata(title: url, coverImage: nil, savedAt: Date()))
            }
        }.sorted { $0.meta.savedAt > $1.meta.savedAt }
    }
    
    private var downloadingItems: [(url: String, progress: Double, title: String)] {
        downloadManager.downloadProgress.compactMap { key, value in
            let title = downloadManager.cacheMetadata[key]?.title ?? key
            return (key, value, title)
        }.sorted { $0.title < $1.title }
    }
    
    var body: some View {
        Group {
            if cachedItems.isEmpty && downloadingItems.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 54))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(isGlobalEnglishMode ? "No cached videos yet" : "还没有缓存的视频")
                        .foregroundColor(.secondary)
                    Text(isGlobalEnglishMode
                         ? "Cached videos can be played offline"
                         : "缓存后即可离线播放")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !downloadingItems.isEmpty {
                        Section(header: Text(isGlobalEnglishMode ? "Downloading" : "下载中")) {
                            ForEach(downloadingItems, id: \.url) { row in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                    HStack {
                                        ProgressView(value: row.progress)
                                        Text("\(Int(row.progress * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    
                    if !cachedItems.isEmpty {
                        Section(header: Text(isGlobalEnglishMode
                                             ? "Cached (\(cachedItems.count))"
                                             : "已缓存 (\(cachedItems.count))")) {
                            ForEach(cachedItems, id: \.url) { row in
                                NavigationLink(destination:
                                    CachedVideoPlayerView(realURL: row.url, title: row.meta.title)
                                ) {
                                    HStack(spacing: 12) {
                                        coverThumb(name: row.meta.coverImage)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.meta.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .lineLimit(2)
                                            Text(formattedDate(row.meta.savedAt))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Label(isGlobalEnglishMode ? "Offline" : "已缓存",
                                                  systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        downloadManager.deleteDownload(urlString: row.url)
                                    } label: {
                                        Label(isGlobalEnglishMode ? "Delete" : "删除",
                                              systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private func coverThumb(name: String?) -> some View {
        if let name = name, !name.isEmpty, let url = OVideoAPI.coverURL(for: name) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 54, height: 80)
            .clipped()
            .cornerRadius(6)
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "film").foregroundColor(.secondary)
            }
            .frame(width: 54, height: 80)
            .cornerRadius(6)
        }
    }
    
    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - 离线缓存播放器
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    var body: some View {
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
            
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 16, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text(isGlobalEnglishMode
                         ? "Playing from local cache"
                         : "当前正在使用本地缓存播放")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button(role: .destructive) {
                    downloadManager.deleteDownload(urlString: realURL)
                } label: {
                    Label(isGlobalEnglishMode ? "Delete Cache" : "删除缓存",
                          systemImage: "trash")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(16)
            
            Spacer()
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
    }
}