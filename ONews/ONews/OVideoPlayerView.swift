// OVideoPlayerView.swift
// VideoPlayerView / VideoPlayerPageView / VideoCacheView / CachedVideoPlayerView

import SwiftUI
import AVKit
import UIKit
import AVFoundation
import Combine

// MARK: - HLS 下载管理器
final class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!

    // 真实进度 (0...1)
    @Published var downloadProgress: [String: Double] = [:]
    // 下载速度 (bytes / sec)
    @Published var downloadSpeed: [String: Double] = [:]
    // 暂停状态
    @Published var isPaused: [String: Bool] = [:]
    // 已完成后的本地书签
    @Published var localBookmarks: [String: Data] = [:]
    // 元数据
    @Published var cacheMetadata: [String: VideoCacheMetadata] = [:]

    // 仅 Wi-Fi 下载（开关）
    @Published var wifiOnly: Bool = UserDefaults.standard.object(forKey: "ONews_WiFiOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: "ONews_WiFiOnly") }
    }

    private var activeTasks: [String: AVAssetDownloadTask] = [:]
    private var lastBytes: [String: Int64] = [:]
    private var lastSampleTime: [String: Date] = [:]
    private var taskStartedAt: [String: Date] = [:]   // 用于"假快"启动判定

    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    private let metadataKey  = "ONews_VideoCacheMetadata"

    private var speedTimer: Timer?

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        downloadSession = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
        loadBookmarks()
        loadMetadata()
        attachOldTasks()      // 冷启动后接管未完成任务（断点续传）
        startSpeedTimer()
        observeNetwork()
    }

    // MARK: 网络监听
    private func observeNetwork() {
        NetworkMonitor.shared.onSwitchedToCellular = { [weak self] in
            guard let self = self, self.wifiOnly else { return }
            // 全部暂停
            for url in self.activeTasks.keys {
                self.pauseDownload(urlString: url)
            }
            print("⚠️ 检测到 Wi-Fi → 蜂窝，已暂停所有下载")
        }
    }

    // MARK: 接管旧任务（断点续传）
    private func attachOldTasks() {
        downloadSession.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            for task in tasks {
                guard let dlTask = task as? AVAssetDownloadTask,
                      let urlString = dlTask.taskDescription else { continue }
                DispatchQueue.main.async {
                    self.activeTasks[urlString] = dlTask
                    self.isPaused[urlString] = (dlTask.state == .suspended)
                    if self.downloadProgress[urlString] == nil {
                        self.downloadProgress[urlString] = 0.0
                    }
                }
            }
        }
    }

    // MARK: 启动下载
    func startDownload(urlString: String, title: String, coverImage: String? = nil) {
        // Wi-Fi only 校验
        if wifiOnly && !NetworkMonitor.shared.isWiFi {
            print("⚠️ 当前不是 Wi-Fi，已阻止下载")
            return
        }

        guard let url = URL(string: urlString) else { return }
        let asset = AVURLAsset(url: url)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else { return }
        task.taskDescription = urlString
        task.resume()

        DispatchQueue.main.async {
            self.activeTasks[urlString] = task
            self.downloadProgress[urlString] = 0.0
            self.downloadSpeed[urlString] = 0
            self.isPaused[urlString] = false
            self.taskStartedAt[urlString] = Date()
            self.cacheMetadata[urlString] = VideoCacheMetadata(
                title: title, coverImage: coverImage, savedAt: Date()
            )
            self.saveMetadata()
        }
    }

    // MARK: 暂停 / 继续
    func pauseDownload(urlString: String) {
        guard let task = activeTasks[urlString] else { return }
        task.suspend()
        DispatchQueue.main.async {
            self.isPaused[urlString] = true
            self.downloadSpeed[urlString] = 0
        }
    }

    func resumeDownload(urlString: String) {
        if wifiOnly && !NetworkMonitor.shared.isWiFi {
            print("⚠️ 当前不是 Wi-Fi，无法继续下载")
            return
        }
        guard let task = activeTasks[urlString] else { return }
        task.resume()
        DispatchQueue.main.async {
            self.isPaused[urlString] = false
            self.lastSampleTime[urlString] = Date()
            self.lastBytes[urlString] = task.countOfBytesReceived
        }
    }

    func cancelDownload(urlString: String) {
        if let task = activeTasks[urlString] {
            task.cancel()
        }
        cleanupTransient(urlString)
    }

    func deleteDownload(urlString: String) {
        if let localURL = getLocalURL(for: urlString) {
            try? FileManager.default.removeItem(at: localURL)
        }
        if let task = activeTasks[urlString] { task.cancel() }
        localBookmarks.removeValue(forKey: urlString)
        cacheMetadata.removeValue(forKey: urlString)
        cleanupTransient(urlString)
        saveBookmarks()
        saveMetadata()
    }

    private func cleanupTransient(_ urlString: String) {
        DispatchQueue.main.async {
            self.activeTasks.removeValue(forKey: urlString)
            self.downloadProgress.removeValue(forKey: urlString)
            self.downloadSpeed.removeValue(forKey: urlString)
            self.isPaused.removeValue(forKey: urlString)
            self.lastBytes.removeValue(forKey: urlString)
            self.lastSampleTime.removeValue(forKey: urlString)
            self.taskStartedAt.removeValue(forKey: urlString)
        }
    }

    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmark = localBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    // MARK: 显示用 "假快" 进度
    /// 真实 < 1/3 用 sqrt 曲线放大；≥ 1/3 直接返回真实值
    func displayedProgress(for urlString: String) -> Double {
        let real = downloadProgress[urlString] ?? 0
        let align = 1.0 / 3.0
        if real >= align { return real }
        // 启动后至少给一个最小目标值，让用户立刻看到 5%~8%
        let started = taskStartedAt[urlString] ?? Date()
        let elapsed = Date().timeIntervalSince(started)
        // 启动 1 秒内最多显示到 0.08；2 秒内最多 0.15
        let bootFloor = min(0.15, elapsed * 0.08)
        let curved = pow(real / align, 0.5) * align     // sqrt 加速曲线
        return min(align, max(curved, bootFloor))
    }

    // MARK: 速度采样
    private func startSpeedTimer() {
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleSpeed()
        }
    }

    private func sampleSpeed() {
        let now = Date()
        for (urlString, task) in activeTasks {
            if isPaused[urlString] == true {
                downloadSpeed[urlString] = 0
                continue
            }
            let bytesNow = task.countOfBytesReceived
            let last = lastBytes[urlString] ?? bytesNow
            let lastTime = lastSampleTime[urlString] ?? now
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                let speed = max(0, Double(bytesNow - last) / dt)
                downloadSpeed[urlString] = speed
            }
            lastBytes[urlString] = bytesNow
            lastSampleTime[urlString] = now
        }
    }

    // MARK: AVAssetDownloadDelegate
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
            let cur = self.downloadProgress[urlString] ?? 0
            self.downloadProgress[urlString] = min(1.0, max(cur, percent))
        }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        do {
            let bookmark = try location.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            DispatchQueue.main.async {
                self.localBookmarks[urlString] = bookmark
                self.saveBookmarks()
            }
        } catch { print("保存书签失败: \(error)") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { return }
        DispatchQueue.main.async {
            self.activeTasks.removeValue(forKey: urlString)
            self.downloadProgress.removeValue(forKey: urlString)
            self.downloadSpeed.removeValue(forKey: urlString)
            self.isPaused.removeValue(forKey: urlString)
            self.lastBytes.removeValue(forKey: urlString)
            self.lastSampleTime.removeValue(forKey: urlString)
            self.taskStartedAt.removeValue(forKey: urlString)
        }
    }

    // MARK: 持久化
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

// MARK: - 速度文本
func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec <= 0 { return "—" }
    let kb = bytesPerSec / 1024.0
    if kb < 1024 { return String(format: "%.1f KB/s", kb) }
    let mb = kb / 1024
    return String(format: "%.2f MB/s", mb)
}

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

// MARK: - 缓存卡片（重做）
struct CacheCard: View {
    let realURL: String
    let videoTitle: String
    let coverImage: String?

    @ObservedObject private var downloadManager = HLSDownloadManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var showWiFiOnlyToggle = false

    var body: some View {
        let isDownloaded = downloadManager.localBookmarks[realURL] != nil
        let isDownloading = downloadManager.activeTasksContains(realURL)
        let isPaused = downloadManager.isPaused[realURL] ?? false
        let displayProgress = downloadManager.displayedProgress(for: realURL)
        let speed = downloadManager.downloadSpeed[realURL] ?? 0

        VStack(alignment: .leading, spacing: 14) {
            // 头部
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
                        .font(.system(size: 15, weight: .bold))
                    Text(isGlobalEnglishMode
                         ? "Save it for offline playback"
                         : "缓存到本地，随时离线观看")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                // Wi-Fi only 切换
                Toggle("", isOn: Binding(
                    get: { downloadManager.wifiOnly },
                    set: { downloadManager.wifiOnly = $0 }
                ))
                .labelsHidden()
                .scaleEffect(0.8)
                .tint(.accentColor)
            }

            Divider().opacity(0.5)

            // 状态行
            if isDownloaded {
                downloadedRow
            } else if isDownloading {
                downloadingRow(progress: displayProgress, speed: speed, isPaused: isPaused)
            } else {
                idleRow
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    // 已缓存
    private var downloadedRow: some View {
        HStack {
            Label(isGlobalEnglishMode ? "Cached, available offline" : "已缓存，可离线播放",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.green)
            Spacer()
            Button {
                downloadManager.deleteDownload(urlString: realURL)
            } label: {
                Label(isGlobalEnglishMode ? "Delete" : "删除",
                      systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
            }
        }
    }

    // 下载中
    private func downloadingRow(progress: Double, speed: Double, isPaused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.blue, .accentColor],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(progress)), height: 6)
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                if !isPaused {
                    Text("· \(formatSpeed(speed))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text(isGlobalEnglishMode ? "· Paused" : "· 已暂停")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }
                Spacer()

                // 暂停 / 继续
                Button {
                    if isPaused {
                        downloadManager.resumeDownload(urlString: realURL)
                    } else {
                        downloadManager.pauseDownload(urlString: realURL)
                    }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(LinearGradient(
                                colors: isPaused
                                    ? [Color.green, Color.green.opacity(0.7)]
                                    : [Color.orange, Color.orange.opacity(0.7)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .shadow(color: (isPaused ? Color.green : Color.orange).opacity(0.4),
                                radius: 6, y: 2)
                }

                // 取消
                Button {
                    downloadManager.cancelDownload(urlString: realURL)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
            }

            // 网络提示
            if downloadManager.wifiOnly && !network.isWiFi {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(isGlobalEnglishMode
                         ? "Switched to cellular, paused to save data"
                         : "已切到蜂窝网络，已暂停以节省流量")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // 未下载
    private var idleRow: some View {
        Button {
            downloadManager.startDownload(urlString: realURL,
                                          title: videoTitle,
                                          coverImage: coverImage)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text(isGlobalEnglishMode ? "Download for offline" : "缓存到本地")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
        }
    }
}

// 给 HLSDownloadManager 增加便捷判定
extension HLSDownloadManager {
    func activeTasksContains(_ url: String) -> Bool {
        downloadProgress[url] != nil
    }
}

// MARK: - 网络指示徽标
struct NetworkBadge: View {
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    var body: some View {
        let color: Color = !network.isConnected ? .red
                         : network.isWiFi ? .green : .orange
        let text: String = !network.isConnected ? (isGlobalEnglishMode ? "Offline" : "无网络")
                         : network.isWiFi ? "Wi-Fi" : (isGlobalEnglishMode ? "Cellular" : "蜂窝")
        let icon: String = !network.isConnected ? "wifi.slash"
                         : network.isWiFi ? "wifi" : "antenna.radiowaves.left.and.right"
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - 缓存管理（重做 UI）
struct VideoCacheView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
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

    private var downloadingItems: [(url: String, title: String)] {
        downloadManager.downloadProgress.keys.map {
            ($0, downloadManager.cacheMetadata[$0]?.title ?? $0)
        }.sorted { $0.title < $1.title }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground),
                         Color.accentColor.opacity(0.05)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            if cachedItems.isEmpty && downloadingItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        topInfoBar

                        if !downloadingItems.isEmpty {
                            sectionHeader(isGlobalEnglishMode ? "Downloading" : "下载中",
                                          count: downloadingItems.count,
                                          icon: "arrow.down.circle.fill",
                                          color: .blue)
                            VStack(spacing: 12) {
                                ForEach(downloadingItems, id: \.url) { row in
                                    DownloadingCard(realURL: row.url, title: row.title)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        if !cachedItems.isEmpty {
                            sectionHeader(isGlobalEnglishMode ? "Cached" : "已缓存",
                                          count: cachedItems.count,
                                          icon: "checkmark.seal.fill",
                                          color: .green)
                            VStack(spacing: 12) {
                                ForEach(cachedItems, id: \.url) { row in
                                    NavigationLink(destination:
                                        CachedVideoPlayerView(realURL: row.url,
                                                              title: row.meta.title)
                                    ) {
                                        CachedItemCard(meta: row.meta, url: row.url)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 12)
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
        .navigationBarTitleDisplayMode(.inline)
    }

    // 顶部信息条
    private var topInfoBar: some View {
        HStack(spacing: 10) {
            NetworkBadge()
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                Text(isGlobalEnglishMode ? "Wi-Fi only" : "仅 Wi-Fi 下载")
                    .font(.system(size: 12, weight: .medium))
                Toggle("", isOn: Binding(
                    get: { downloadManager.wifiOnly },
                    set: { downloadManager.wifiOnly = $0 }
                ))
                .labelsHidden()
                .scaleEffect(0.75)
                .tint(.accentColor)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ title: String, count: Int,
                               icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(title).font(.system(size: 16, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(color))
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.10))
                    .frame(width: 120, height: 120)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(.accentColor)
            }
            Text(isGlobalEnglishMode ? "No cached videos yet" : "还没有缓存的视频")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text(isGlobalEnglishMode
                 ? "Cached videos can be played offline anytime."
                 : "缓存后即可离线随时观看")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 下载中卡片
struct DownloadingCard: View {
    let realURL: String
    let title: String
    @ObservedObject private var dm = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        let progress = dm.displayedProgress(for: realURL)
        let speed = dm.downloadSpeed[realURL] ?? 0
        let paused = dm.isPaused[realURL] ?? false

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.8), .accentColor.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: paused ? "pause.fill" : "arrow.down")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Text("·").foregroundColor(.secondary)
                        if paused {
                            Text(isGlobalEnglishMode ? "Paused" : "已暂停")
                                .font(.system(size: 12)).foregroundColor(.orange)
                        } else {
                            Text(formatSpeed(speed))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(
                            colors: paused ? [Color.orange, Color.orange.opacity(0.7)]
                                           : [Color.blue, Color.accentColor],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(progress)), height: 6)
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 6)

            // 操作按钮
            HStack(spacing: 10) {
                Button {
                    if paused { dm.resumeDownload(urlString: realURL) }
                    else { dm.pauseDownload(urlString: realURL) }
                } label: {
                    Label(paused ? (isGlobalEnglishMode ? "Resume" : "继续")
                                 : (isGlobalEnglishMode ? "Pause" : "暂停"),
                          systemImage: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: paused
                                    ? [Color.green, Color.green.opacity(0.7)]
                                    : [Color.orange, Color.orange.opacity(0.7)],
                                startPoint: .leading, endPoint: .trailing))
                        )
                }

                Button {
                    dm.cancelDownload(urlString: realURL)
                } label: {
                    Label(isGlobalEnglishMode ? "Cancel" : "取消",
                          systemImage: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
    }
}

// MARK: - 已缓存条目卡片
struct CachedItemCard: View {
    let meta: VideoCacheMetadata
    let url: String
    @ObservedObject private var dm = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        HStack(spacing: 12) {
            coverThumb(name: meta.coverImage)
            VStack(alignment: .leading, spacing: 6) {
                Text(meta.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundColor(.secondary)
                    Text(formattedDate(meta.savedAt))
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 11))

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(isGlobalEnglishMode ? "Available offline" : "可离线播放")
                        .foregroundColor(.green)
                }
                .font(.system(size: 11, weight: .medium))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
        .contextMenu {
            Button(role: .destructive) {
                dm.deleteDownload(urlString: url)
            } label: {
                Label(isGlobalEnglishMode ? "Delete" : "删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func coverThumb(name: String?) -> some View {
        if let name = name, !name.isEmpty, let coverURL = OVideoAPI.coverURL(for: name) {
            CachedAsyncImage(url: coverURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 60, height: 84)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.5), .blue.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "film").foregroundColor(.white)
            }
            .frame(width: 60, height: 84)
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - 离线缓存播放器（小幅美化）
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

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