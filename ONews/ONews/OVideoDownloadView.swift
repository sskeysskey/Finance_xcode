// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoDownloadView.swift
// VideoPlayerView / VideoPlayerPageView / VideoCacheView / CachedVideoPlayerView

import SwiftUI
import AVKit
import UIKit

// MARK: - 缓存播放跳转目标（用于门禁通过后再跳转）
struct CachedPlayTarget: Identifiable {
    var id: String { primaryURL }
    let primaryURL: String          // 要播放的 url（也用于推导 episodeKey）
    let title: String               // 剧名
    let episodeName: String?
    let episodes: [VideoEpisodeItem]
}

final class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!

    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadSpeed:    [String: Double] = [:]
    @Published var isPaused:         [String: Bool]   = [:]
    @Published var localBookmarks:   [String: Data]   = [:]
    @Published var cacheMetadata:    [String: VideoCacheMetadata] = [:]

    private var lastNonZeroSpeed: [String: Double] = [:]
    private var cancelledUrls:    Set<String>      = []

    // ✨ 关键新增:暂存 didFinishDownloadingTo 的 bookmark,等真正完成才提升到 localBookmarks
    private var pendingBookmarks: [String: Data] = [:]

    private var activeTasks:    [String: AVAssetDownloadTask] = [:]
    private var lastBytes:      [String: Int64] = [:]
    private var lastSampleTime: [String: Date]  = [:]

    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    private let metadataKey  = "ONews_VideoCacheMetadata"
    private let progressKey  = "ONews_DownloadProgress"
    private let pausedKey    = "ONews_DownloadPaused"

    private var speedTimer: Timer?
    private var lastPersistTime = Date.distantPast
    private let pendingKey = "ONews_PendingHLSBookmarks"

    var backgroundCompletionHandler: (() -> Void)?

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
        loadPendingBookmarks() 
        loadPersistedProgress()
        handleColdLaunchRecovery()
        startSpeedTimer()
        observeNetwork()
        observeAppLifecycle()
    }

    private func savePendingBookmarks() {
        UserDefaults.standard.set(pendingBookmarks, forKey: pendingKey)
    }
    private func loadPendingBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Data] {
            pendingBookmarks = saved
        }
    }

    // MARK: 冷启动恢复
    private func handleColdLaunchRecovery() {
        // 所有未拿到 bookmark 的下载,都先打成"已暂停"
        for urlString in downloadProgress.keys where localBookmarks[urlString] == nil {
            isPaused[urlString]      = true
            downloadSpeed[urlString] = 0
        }
        savePersistedProgress()

        downloadSession.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 1) 先收集 session 中仍然存活的任务对应的 URL
                var aliveUrls = Set<String>()
                for task in tasks {
                    guard let dlTask = task as? AVAssetDownloadTask,
                        let urlString = dlTask.taskDescription else {
                        task.cancel()
                        continue
                    }
                    if self.downloadProgress[urlString] == nil &&
                    self.localBookmarks[urlString]   == nil {
                        dlTask.cancel()
                        continue
                    }
                    if dlTask.state == .completed || dlTask.state == .canceling { continue }

                    self.activeTasks[urlString] = dlTask
                    aliveUrls.insert(urlString)
                    if dlTask.state == .running { dlTask.suspend() }
                }

                // 2) 🛠️ 副防线:对那些"有 pendingBookmark 但 session 已经没有对应任务"
                //    的 URL,它们的局部包永远不可能再续传了 → 立刻清磁盘 + 进度归零,
                //    防止用户从不点继续/不点删除时残留僵尸文件。
                let orphanUrls = self.pendingBookmarks.keys.filter { !aliveUrls.contains($0) }
                for urlString in orphanUrls {
                    // 已经下载完成的不要动(localBookmarks 才是终态)
                    if self.localBookmarks[urlString] != nil { continue }

                    self.purgeStalePartial(for: urlString)
                    if self.downloadProgress[urlString] != nil {
                        self.downloadProgress[urlString] = 0
                    }
                }
                self.savePersistedProgress()
            }
        }
    }

    // MARK: 启动下载
    func startDownload(urlString: String, title: String, coverImage: String? = nil,
                   seriesTitle: String? = nil, episodeName: String? = nil,
                   episodeKey: String? = nil) { 
        cancelledUrls.remove(urlString)

        guard let url = URL(string: urlString) else { return }
        let asset = AVURLAsset(url: url)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else { return }
        task.taskDescription = urlString
        task.resume()

        DispatchQueue.main.async {
            self.activeTasks[urlString] = task
            if self.downloadProgress[urlString] == nil {
                self.downloadProgress[urlString] = 0.0
            }
            self.downloadSpeed[urlString] = 0
            self.isPaused[urlString]      = false
            if self.cacheMetadata[urlString] == nil {
                self.cacheMetadata[urlString] = VideoCacheMetadata(
                    title: title, coverImage: coverImage, savedAt: Date(),
                    seriesTitle: seriesTitle, episodeName: episodeName,
                    originalEpisodeURL: episodeKey 
                )
            }
            self.saveMetadata()
            self.savePersistedProgress()
        }
    }

    // MARK: 暂停
    func pauseDownload(urlString: String) {
        if let task = activeTasks[urlString] { task.suspend() }
        DispatchQueue.main.async {
            self.isPaused[urlString]      = true
            self.downloadSpeed[urlString] = 0
            self.savePersistedProgress()
        }
    }

    // MARK: 继续
    func resumeDownload(urlString: String) {
        if let task = activeTasks[urlString],
           task.state != .completed,
           task.state != .canceling {
            task.resume()
            DispatchQueue.main.async {
                self.isPaused[urlString]       = false
                self.lastSampleTime[urlString] = Date()
                self.lastBytes[urlString]      = task.countOfBytesReceived
                self.savePersistedProgress()
            }
        } else {
            recreateAndResume(urlString: urlString)
        }
    }

    private func recreateAndResume(urlString: String) {
        guard let remoteURL = URL(string: urlString) else { return }
        let title = cacheMetadata[urlString]?.title ?? urlString

        // 🛠️ 关键修复 1：在创建新下载任务前，先把旧的局部包从磁盘删掉，
        //    否则 AVFoundation 会另起一个新的 .movpkg,导致旧包成为永久僵尸文件。
        purgeStalePartial(for: urlString)

        // 🛠️ 关键修复 2：既然是真正重下,进度也要诚实归零,不再骗用户。
        DispatchQueue.main.async {
            self.downloadProgress[urlString] = 0
            self.savePersistedProgress()
        }

        let asset = AVURLAsset(url: remoteURL)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else {
            DispatchQueue.main.async {
                self.isPaused[urlString] = true
                self.savePersistedProgress()
            }
            return
        }
        task.taskDescription = urlString
        task.resume()

        DispatchQueue.main.async {
            self.activeTasks[urlString]    = task
            self.isPaused[urlString]       = false
            self.lastBytes[urlString]      = 0
            self.lastSampleTime[urlString] = Date()
            self.savePersistedProgress()
        }
    }

    /// 把 urlString 关联的本地局部包（已无法用于真续传）从磁盘干净抹掉
    private func purgeStalePartial(for urlString: String) {
        if let bookmark = pendingBookmarks[urlString] {
            var isStale = false
            if let oldPartialURL = try? URL(
                resolvingBookmarkData: bookmark,
                bookmarkDataIsStale: &isStale
            ) {
                do {
                    try FileManager.default.removeItem(at: oldPartialURL)
                    print("🗑️ 已清理旧局部包(防僵尸): \(oldPartialURL.lastPathComponent)")
                } catch {
                    let nsErr = error as NSError
                    // 文件本来就不存在 → 视为成功
                    if !(nsErr.domain == NSCocoaErrorDomain &&
                        nsErr.code == NSFileNoSuchFileError) {
                        print("⚠️ 清理旧局部包失败: \(error)")
                    }
                }
            }
        }
        pendingBookmarks.removeValue(forKey: urlString)
        savePendingBookmarks()
    }

    // MARK: 取消/删除
    func cancelDownload(urlString: String) {
        cancelledUrls.insert(urlString)
        if let task = activeTasks[urlString] { task.cancel() }
        cleanupTransient(urlString)
    }

    // 🛠️ 修改后：彻底清除本地缓存（包含已完成的和未完成的局部包）
    func deleteDownload(urlString: String) {
        cancelledUrls.insert(urlString)
        
        // 1. 尝试取消 activeTasks 中的任务
        if let task = activeTasks[urlString] {
            task.cancel()
        }
        
        // 2. 额外保险：遍历 session 中所有可能处于恢复状态、但未被 activeTasks 记录的后台任务并取消
        downloadSession.getAllTasks { tasks in
            for task in tasks {
                if let dlTask = task as? AVAssetDownloadTask, dlTask.taskDescription == urlString {
                    dlTask.cancel()
                }
            }
        }

        // 3. 彻底删除本地文件：同时尝试删除 localBookmarks 和 pendingBookmarks（局部包）对应的路径
        if let localURL = getLocalURL(for: urlString) {
            try? FileManager.default.removeItem(at: localURL)
            print("🗑️ 已删除已完成的本地包: \(localURL.path)")
        }
        
        if let pendingURL = getPendingLocalURL(for: urlString) {
            try? FileManager.default.removeItem(at: pendingURL)
            print("🗑️ 已删除未完成的局部包: \(pendingURL.path)")
        }

        // 4. 清理内存和持久化数据
        localBookmarks.removeValue(forKey: urlString)
        pendingBookmarks.removeValue(forKey: urlString)
        cacheMetadata.removeValue(forKey: urlString)
        lastNonZeroSpeed.removeValue(forKey: urlString)
        
        cleanupTransient(urlString)
        
        saveBookmarks()
        savePendingBookmarks()
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
            self.savePersistedProgress()
        }
    }

    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmark = localBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    // 🛠️ 新增：获取临时局部包的本地 URL
    func getPendingLocalURL(for urlString: String) -> URL? {
        guard let bookmark = pendingBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    func displayedProgress(for urlString: String) -> Double {
        return downloadProgress[urlString] ?? 0
    }

    func displaySpeed(for urlString: String) -> Double {
        let real = downloadSpeed[urlString] ?? 0
        if real > 0 { return real }
        if let last = lastNonZeroSpeed[urlString], last > 0 { return last }
        return 0
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
            let last     = lastBytes[urlString] ?? bytesNow
            let lastTime = lastSampleTime[urlString] ?? now
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                let speed = max(0, Double(bytesNow - last) / dt)
                downloadSpeed[urlString] = speed
                if speed > 0 { lastNonZeroSpeed[urlString] = speed }
            }
            lastBytes[urlString]      = bytesNow
            lastSampleTime[urlString] = now
        }
    }

    private func savePersistedProgressIfNeeded() {
        if Date().timeIntervalSince(lastPersistTime) > 1.5 {
            savePersistedProgress()
            lastPersistTime = Date()
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
            self.savePersistedProgressIfNeeded()
        }
    }

    // ✨ 关键修复 1:不再立即写 localBookmarks!先暂存到 pendingBookmarks
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }

        // 用户主动取消的:直接清残留,不入 pendingBookmarks
        if cancelledUrls.contains(urlString) {
            try? FileManager.default.removeItem(at: location)
            DispatchQueue.main.async {
                self.cancelledUrls.remove(urlString)
                self.localBookmarks.removeValue(forKey: urlString)
                self.pendingBookmarks.removeValue(forKey: urlString)
                self.cacheMetadata.removeValue(forKey: urlString)
                self.saveBookmarks()
                self.saveMetadata()
            }
            return
        }

        // ⚠️ 这里的 location 可能只是部分包(杀进程/网络中断都会触发本回调)
        // 不能直接写 localBookmarks,否则 UI 会把它当成"已缓存",哪怕只下了 16%
        do {
            let bookmark = try location.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            DispatchQueue.main.async {
                self.pendingBookmarks[urlString] = bookmark
                self.savePendingBookmarks()
            }
        } catch { print("生成临时书签失败: \(error)") }
    }

    // ✨ 关键修复 2:用 error + 进度双重判断,确认是否真正完成，并在完成后上报后台
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { return }
        DispatchQueue.main.async {
            self.activeTasks.removeValue(forKey: urlString)
            self.lastBytes.removeValue(forKey: urlString)
            self.lastSampleTime.removeValue(forKey: urlString)

            let wasCancelled  = self.cancelledUrls.contains(urlString)
            let progress      = self.downloadProgress[urlString] ?? 0
            // 真正完成:无错误 且 进度接近 1.0
            let didTrulyFinish = (error == nil) && (progress >= 0.999)

            if wasCancelled {
                // 用户取消 → 全部清理
                self.cancelledUrls.remove(urlString)
                self.pendingBookmarks.removeValue(forKey: urlString)
                self.savePendingBookmarks()
                self.downloadProgress.removeValue(forKey: urlString)
                self.isPaused.removeValue(forKey: urlString)
                self.downloadSpeed.removeValue(forKey: urlString)
            } else if didTrulyFinish {
                // 真正完成 → pendingBookmarks 提升到 localBookmarks
                if let bookmark = self.pendingBookmarks[urlString] {
                    self.localBookmarks[urlString] = bookmark
                    self.saveBookmarks()
                }
                
                // 🚀 解析用户身份，与播放/新闻打点统一
                let storedUserId = UserDefaults.standard.string(forKey: "current_user_id")
                let (finalUserId, finalUserType): (String, String) = {
                    if let uid = storedUserId, !uid.isEmpty {
                        return (uid, uid.hasPrefix("dev_") ? "device" : "apple")
                    } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                        return ("dev_" + idfv, "device")
                    } else {
                        return ("guest_user", "device")
                    }
                }()
                let title = self.cacheMetadata[urlString]?.title ?? "Unknown Video"

                TrackingManager.shared.track(
                    event: .downloadComplete,
                    userId: finalUserId,
                    userType: finalUserType,
                    videoURL: urlString,
                    videoTitle: title
                )
                
                self.pendingBookmarks.removeValue(forKey: urlString)
                self.savePendingBookmarks()
                self.downloadProgress.removeValue(forKey: urlString)
                self.isPaused.removeValue(forKey: urlString)
                self.downloadSpeed.removeValue(forKey: urlString)
            } else {
                // 中断(杀进程/网络/系统投递的 cancel)
                // 保留进度,标记暂停。pendingBookmarks 也保留:本进程内续传可能用得上
                // 但绝对不进 localBookmarks → 不会被错误地归到"已缓存"
                self.isPaused[urlString]      = true
                self.downloadSpeed[urlString] = 0
                self.savePendingBookmarks()
                if let nsErr = error as NSError? {
                    print("⚠️ 下载中断 [\(urlString)]: domain=\(nsErr.domain) code=\(nsErr.code)")
                }
            }
            self.savePersistedProgress()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
            print("✨ 后台 Session 事件全部处理完毕")
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
    private func savePersistedProgress() {
        UserDefaults.standard.set(downloadProgress, forKey: progressKey)
        UserDefaults.standard.set(isPaused,         forKey: pausedKey)
    }
    private func loadPersistedProgress() {
        if let p = UserDefaults.standard.dictionary(forKey: progressKey) as? [String: Double] {
            downloadProgress = p
        }
        if let pa = UserDefaults.standard.dictionary(forKey: pausedKey) as? [String: Bool] {
            isPaused = pa
        }
    }

    private func observeNetwork() {
        NetworkMonitor.shared.onSwitchedToCellular = { [weak self] in
            guard let self = self else { return }                 // ← 去掉 self.wifiOnly 判断
            for url in self.activeTasks.keys { self.pauseDownload(urlString: url) }
            print("⚠️ 检测到 Wi-Fi → 5G蜂窝,已暂停所有下载")
        }
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.savePersistedProgress() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.savePersistedProgress() }
    }
}

extension HLSDownloadManager {
    func activeTasksContains(_ url: String) -> Bool {
        downloadProgress[url] != nil
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

// MARK: - 缓存卡片 (已集成高级缓存管理入口)
struct CacheCard: View {
    let realURL: String
    let videoTitle: String
    let coverImage: String?
    var seriesTitle: String? = nil
    var episodeName: String? = nil
    var episodeKey: String? = nil

    @ObservedObject private var downloadManager = HLSDownloadManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    // ⭐ 新增：首次缓存的广告提示是否已确认（确认后永不再弹）
    @AppStorage("hasAcknowledgedAdWarning") private var hasAcknowledgedAdWarning = false
    @State private var showAdWarningAlert = false

    // 【新增】
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    
    @State private var showCellularAlert = false // 控制蜂窝网络下载提示弹窗
    @State private var showCancelAlert = false // 控制取消下载的弹窗

    var body: some View {
        let isDownloaded = downloadManager.localBookmarks[realURL] != nil
        let isDownloading = downloadManager.activeTasksContains(realURL)
        let isPaused = downloadManager.isPaused[realURL] ?? false
        let displayProgress = downloadManager.displayedProgress(for: realURL)

        VStack(alignment: .leading, spacing: 14) {
            // 状态行
            if isDownloaded {
                downloadedRow
            } else if isDownloading {
                downloadingRow(progress: displayProgress, isPaused: isPaused)
            } else {
                idleRow
            }
            
            // ⭐ 新增：高级感“查看全部缓存”入口
            Divider().opacity(0.3)
            cacheListNavigationRow
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
        // 蜂窝网络下拦截下载的 Alert 提示
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示", isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Download Anyway" : "允许并下载") {
                downloadManager.startDownload(urlString: realURL, title: videoTitle, coverImage: coverImage,
                              seriesTitle: seriesTitle, episodeName: episodeName,
                              episodeKey: episodeKey) 
            }
        } message: {
            Text(isGlobalEnglishMode 
                 ? "You are currently on a cellular network and 'Wi-Fi Only' is enabled. Do you want to disable 'Wi-Fi Only' and start downloading?" 
                 : "当前处于蜂窝移动网络，且已开启“仅 Wi-Fi 缓存”。是否关闭该限制并继续下载？")
        }
        // ⭐ 新增：首次点击“缓存到本地”时的广告防骗提示
        .alert(isGlobalEnglishMode ? "Notice" : "温馨提示", isPresented: $showAdWarningAlert) {
            Button(isGlobalEnglishMode ? "Got it" : "我知道了") {
                hasAcknowledgedAdWarning = true
                startDownloadFlow()
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "Ads inside the video are NOT placed by our platform. Do not tap them, to avoid being scammed."
                 : "视频内广告链接非本平台植入，切勿点击，防止被骗")
        }
        // 【新增】
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
    }

    private var hasAccess: Bool {
        guard let key = episodeKey, !key.isEmpty else { return authManager.isSubscribed }
        return authManager.isSubscribed || FreeQuotaManager.shared.isUnlocked(key)
    }

    // ⭐ 抽出真正的下载动作（蜂窝判断 + 启动）
    private func startDownloadFlow() {
        if !network.isWiFi {
            showCellularAlert = true
        } else {
            downloadManager.startDownload(
                urlString: realURL,
                title: videoTitle,
                coverImage: coverImage,
                seriesTitle: seriesTitle,
                episodeName: episodeName,
                episodeKey: episodeKey
            )
        }
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
    private func downloadingRow(progress: Double, isPaused: Bool) -> some View {
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
                    let speed = downloadManager.displaySpeed(for: realURL)
                    if speed > 0 {
                        Text("· \(formatSpeed(speed))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text(isGlobalEnglishMode ? "· Caching..." : "· 数据加载中...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(isGlobalEnglishMode ? "· Paused" : "· 已暂停")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }
                Spacer()

                // 暂停 / 继续
                Button {
                    if isPaused {
                        // 【新增】继续下载也需要订阅
                        guard authManager.canAccessVideoContent() else {
                            showSubscriptionSheet = true
                            return
                        }
                        if !network.isWiFi {
                            showCellularAlert = true
                        } else {
                            downloadManager.resumeDownload(urlString: realURL)
                        }
                    } else {
                        downloadManager.pauseDownload(urlString: realURL)  // 暂停不需要订阅
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
                    showCancelAlert = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .alert(isGlobalEnglishMode ? "Cancel Download" : "取消下载", isPresented: $showCancelAlert) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Confirm" : "确定", role: .destructive) {
                        downloadManager.deleteDownload(urlString: realURL)
                    }
                } message: {
                    Text(isGlobalEnglishMode ? "Are you sure you want to cancel and clear all downloaded data?" : "确定要取消下载并清除所有已下载的数据吗？")
                }
            }

            // 网络提示
            if !network.isWiFi {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(isGlobalEnglishMode
                         ? "Switched to cellular, paused to save data"
                         : "已切换到5G，下载请关注流量")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // 未下载
    private var idleRow: some View {
        Button {
            guard hasAccess else {
                // 未订阅且未解锁：看剩余点数决定弹什么
                if FreeQuotaManager.shared.remaining > 0 {
                    showSubscriptionSheet = true
                } else {
                    showSubscriptionSheet = true
                }
                return
            }
            // ⭐ 首次缓存：先弹「广告非平台植入」提示，确认后才真正进入下载流程
            if !hasAcknowledgedAdWarning {
                showAdWarningAlert = true
                return
            }
            startDownloadFlow()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(isGlobalEnglishMode ? "Download" : "缓存到本地")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            // 移除 .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 20) // 添加水平内边距，让按钮宽度根据内容自适应
            .background(
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                        startPoint: .leading, endPoint: .trailing))
            )
            .shadow(color: Color.accentColor.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity, alignment: .center)
    }
    
    // ⭐ 优化：将入口改为“功能块”样式，使其更显眼
    private var cacheListNavigationRow: some View {
        NavigationLink(destination: VideoCacheView()) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1)) // 更浅的图标背景
                        .frame(width: 36, height: 36)
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                
                HStack(spacing: 2) {
                    Text(isGlobalEnglishMode ? "Manage Offline Cache" : "缓存下载管理")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    let downloadingCount = downloadManager.downloadProgress.keys.count
                    let cachedCount = downloadManager.localBookmarks.keys.count
                    
                    if downloadingCount > 0 {
                        Text(isGlobalEnglishMode ? "\(downloadingCount) tasks downloading" : "\(downloadingCount)个任务下载中")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                    } else if cachedCount > 0 {
                        Text(isGlobalEnglishMode ? "\(cachedCount) videos cached" : "已缓存 \(cachedCount) 个视频")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text(isGlobalEnglishMode ? "View all cached content" : "查看所有已缓存内容")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())   // 保证整行可点
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 4)
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
                         : network.isWiFi ? "Wi-Fi" : (isGlobalEnglishMode ? "Cellular" : "蜂窝/5G")
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

// MARK: - 已缓存剧集分组模型
struct CachedSeriesGroup: Identifiable {
    let id: String                                       // = groupKey
    let seriesTitle: String
    let coverImage: String?
    let episodes: [(url: String, meta: VideoCacheMetadata)]
    let latestSavedAt: Date
}

// MARK: - 缓存管理
struct VideoCacheView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    // 【新增】订阅 / 蜂窝拦截
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared   // ⭐ 新增
    @State private var showSubscriptionSheet = false
    @State private var showCellularAlert = false

    // ⭐ 门禁 / 程序化跳转状态
    @State private var cachedPlayTarget: CachedPlayTarget? = nil
    @State private var navigateToCachedPlayer = false
    @State private var pendingCachedTarget: CachedPlayTarget? = nil
    @State private var showCachedConsumeConfirm = false
    @State private var cachedConsumeRemaining = 0
    @State private var showQuotaExhausted = false

    private var groupedCachedItems: [CachedSeriesGroup] {
        var dict: [String: [(url: String, meta: VideoCacheMetadata)]] = [:]
        for url in downloadManager.localBookmarks.keys {
            let meta = downloadManager.cacheMetadata[url]
                ?? VideoCacheMetadata(title: url, coverImage: nil, savedAt: Date(),
                                      seriesTitle: nil, episodeName: nil)
            dict[meta.groupKey, default: []].append((url, meta))
        }
        return dict.map { key, items in
            let sorted = items.sorted {
                ($0.meta.episodeName ?? "").localizedStandardCompare($1.meta.episodeName ?? "") == .orderedAscending
            }
            let latest = items.map { $0.meta.savedAt }.max() ?? Date()
            let title: String
            if let st = items.first?.meta.seriesTitle, !st.isEmpty {
                title = st
            } else if let t = items.first?.meta.title {
                title = t.components(separatedBy: " · ").first ?? t
            } else {
                title = key
            }
            let cover  = items.compactMap { $0.meta.coverImage }.first
            return CachedSeriesGroup(id: key, seriesTitle: title,
                                     coverImage: cover, episodes: sorted, latestSavedAt: latest)
        }.sorted { $0.latestSavedAt > $1.latestSavedAt }
    }

    private var cachedCount: Int { downloadManager.localBookmarks.count }

    private var downloadingItems: [(url: String, title: String)] {
        downloadManager.downloadProgress.keys.map {
            ($0, downloadManager.cacheMetadata[$0]?.title ?? $0)
        }.sorted { $0.title < $1.title }
    }

    // 【新增】当前处于暂停状态的任务数量
    private var pausedCount: Int {
        downloadingItems.filter { downloadManager.isPaused[$0.url] ?? false }.count
    }

    // ⭐ 把一个分组转成选集用的 VideoEpisodeItem 数组
    private func makeEpisodeItems(from group: CachedSeriesGroup) -> [VideoEpisodeItem] {
        group.episodes.enumerated().map { index, item in
            let name = item.meta.episodeName ?? item.meta.title
            let digits = name.filter { $0.isNumber }
            let number = (!digits.isEmpty && digits.count <= 4 && Int(digits) != nil)
                ? digits : String(index + 1)
            return VideoEpisodeItem(number: number, name: name, url: item.url)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground),
                         Color.accentColor.opacity(0.05)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            if groupedCachedItems.isEmpty && downloadingItems.isEmpty {
                emptyState
            } else {
                // 🛠️ 修改：将 ScrollView 替换为 List，以支持左滑删除
                List {
                    // 下载中列表
                    if !downloadingItems.isEmpty {
                        Section(header: downloadingHeader) {
                            ForEach(downloadingItems, id: \.url) { row in
                                DownloadingCard(realURL: row.url, title: row.title)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }

                    // 已缓存列表（按剧集分组）
                    if !groupedCachedItems.isEmpty {
                        Section(header: sectionHeader(
                            isGlobalEnglishMode ? "Cached" : "已缓存",
                            count: cachedCount,
                            icon: "checkmark.seal.fill",
                            color: .green,
                            subtitle: isGlobalEnglishMode ? "Subscription required for playback" : "订阅后即可无限畅享离线缓存视频"
                        )) {
                            ForEach(groupedCachedItems) { group in
                                if group.episodes.count == 1 {
                                    // ⭐ 单集：Button + 门禁，不再直接 NavigationLink
                                    let row = group.episodes[0]
                                    let seriesTitle = row.meta.seriesTitle?.isEmpty == false
                                        ? row.meta.seriesTitle!
                                        : row.meta.title.components(separatedBy: " · ").first ?? row.meta.title
                                    let eps = makeEpisodeItems(from: group)

                                    Button {
                                        attemptPlayCached(CachedPlayTarget(
                                            primaryURL: row.url,
                                            title: seriesTitle,
                                            episodeName: row.meta.episodeName,
                                            episodes: eps
                                        ))
                                    } label: {
                                        CachedItemCard(meta: row.meta, url: row.url)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            withAnimation { downloadManager.deleteDownload(urlString: row.url) }
                                        } label: {
                                            Label(isGlobalEnglishMode ? "Delete" : "删除", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                } else {
                                    // 多集剧集：仍然只是跳到详情列表（不涉及播放，无需门禁）
                                    ZStack {
                                        CachedSeriesCard(group: group)
                                        NavigationLink(destination: CachedSeriesDetailView(
                                            groupKey: group.id,
                                            seriesTitle: group.seriesTitle,
                                            coverImage: group.coverImage)) {
                                            EmptyView()
                                        }
                                        .opacity(0)
                                    }
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            withAnimation {
                                                for ep in group.episodes {
                                                    downloadManager.deleteDownload(urlString: ep.url)
                                                }
                                            }
                                        } label: {
                                            Label(isGlobalEnglishMode ? "Delete All" : "删除整部", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .background(Color.clear)
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        // ⭐ 程序化跳转：门禁通过后才进播放页
        .navigationDestination(isPresented: $navigateToCachedPlayer) {
            if let t = cachedPlayTarget {
                CachedVideoPlayerView(
                    realURL: t.primaryURL,
                    title: t.title,
                    episodeName: t.episodeName,
                    episodes: t.episodes
                )
            }
        }
        .toolbar {
            // 📺 【核心修改】：在右侧增加“观看记录”文本和时钟图标，并改用 NavigationLink 进行全屏推入
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                NavigationLink(destination: VideoPlayHistoryView()) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(isGlobalEnglishMode ? "History" : "观看记录")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                
                NetworkBadge()
            }
        }
        // 【新增】订阅弹窗
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        // 【新增】一键继续时的蜂窝拦截
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Resume Anyway" : "允许并继续") {
                downloadManager.resumeAllPausedDownloads()
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are currently on a cellular network and 'Wi-Fi Only' is enabled. Do you want to disable 'Wi-Fi Only' and resume downloading?"
                 : "当前处于蜂窝移动网络，且已开启“仅 Wi-Fi 缓存”。是否关闭该限制并继续下载？")
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }

    // MARK: - 门禁逻辑
    private func attemptPlayCached(_ target: CachedPlayTarget) {
        // ⭐ 离线缓存视频：已下载即可免费播放，不再消耗点数，也不要求登录/订阅
        cachedPlayTarget = target
        navigateToCachedPlayer = true
    }

    private func resumeAllAction() {
        guard authManager.canAccessVideoContent() else {
            showSubscriptionSheet = true
            return
        }
        if !network.isWiFi {            // ← 去掉 downloadManager.wifiOnly &&
            showCellularAlert = true
            return
        }
        downloadManager.resumeAllPausedDownloads()
    }

    // 【新增】带一键继续按钮的“下载中”标题栏
    private var downloadingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
            Text(isGlobalEnglishMode ? "Downloading" : "下载中")
                .font(.system(size: 16, weight: .bold))
            Text("\(downloadingItems.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.blue))

            Spacer()

            // 只有存在暂停任务时才出现
            if pausedCount >= 1 {
                Button {
                    resumeAllAction()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(isGlobalEnglishMode ? "Resume All" : "一键继续")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing))
                    )
                    .shadow(color: Color.green.opacity(0.35), radius: 5, y: 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .textCase(nil) // 避免 List Header 默认大写
    }

    // 🛠️ 【修改】：支持传入 subtitle 副标题，用于显示“已缓存视频也需订阅才能播放”
    private func sectionHeader(_ title: String, count: Int,
                               icon: String, color: Color,
                               subtitle: String? = nil) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(title).font(.system(size: 16, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(color))
            
            if let sub = subtitle {
                Spacer()
                Text(sub)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .textCase(nil)
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
    @ObservedObject private var network = NetworkMonitor.shared // 新增：引入 network
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var showCancelAlert = false // 控制取消下载的弹窗
    @State private var showCellularAlert = false // 控制蜂窝网络下载提示弹窗
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false

    var body: some View {
        let progress = dm.displayedProgress(for: realURL)
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
                            let speed = dm.displaySpeed(for: realURL)
                            if speed > 0 {
                                Text(formatSpeed(speed))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(isGlobalEnglishMode ? "Caching..." : "数据下载中...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
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
                    if paused {
                        guard authManager.canAccessVideoContent() else {
                            showSubscriptionSheet = true
                            return
                        }
                        if !network.isWiFi {
                            showCellularAlert = true
                        } else {
                            dm.resumeDownload(urlString: realURL)
                        }
                    } else {
                        dm.pauseDownload(urlString: realURL)
                    }
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
                .buttonStyle(BorderlessButtonStyle())   // ✅ 关键修复：让按钮独立响应点击

                Button {
                    showCancelAlert = true
                } label: {
                    Label(isGlobalEnglishMode ? "Cancel" : "取消",
                          systemImage: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(BorderlessButtonStyle())   // ✅ 关键修复：让按钮独立响应点击
                .alert(isGlobalEnglishMode ? "Cancel Download" : "取消下载", isPresented: $showCancelAlert) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Confirm" : "确定", role: .destructive) {
                        dm.deleteDownload(urlString: realURL)
                    }
                } message: {
                    Text(isGlobalEnglishMode ? "Are you sure you want to cancel and clear all downloaded data?" : "确定要取消下载并清除所有已下载的数据吗？")
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
        // 蜂窝网络下拦截继续下载的 Alert 提示
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示", isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Resume Anyway" : "允许并继续") {
                dm.resumeDownload(urlString: realURL)
            }
        } message: {
            Text(isGlobalEnglishMode 
                 ? "You are currently on a cellular network and 'Wi-Fi Only' is enabled. Do you want to disable 'Wi-Fi Only' and resume downloading?" 
                 : "当前处于蜂窝移动网络，且已开启“仅 Wi-Fi 缓存”。是否关闭该限制并继续下载？")
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
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

extension HLSDownloadManager {
    /// 一键继续所有处于暂停状态的下载
    func resumeAllPausedDownloads() {
        let pausedUrls = downloadProgress.keys.filter { isPaused[$0] == true }
        for url in pausedUrls {
            resumeDownload(urlString: url)
        }
    }
}

// MARK: - 观看记录全屏界面（支持左滑删除单个、隐藏线路名）
struct VideoPlayHistoryView: View {
    @StateObject private var recordManager = VideoPlayRecordManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false
    @State private var showLoginAlert = false

    // ⭐ 门禁 / 程序化跳转
    @State private var playRecord: VideoPlayRecord? = nil
    @State private var navigateToPlayer = false
    @State private var pendingRecord: VideoPlayRecord? = nil
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var showQuotaExhausted = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground), Color.accentColor.opacity(0.02)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            if recordManager.records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(recordManager.records) { record in
                        Button {
                            attemptPlay(record)
                        } label: {
                            recordRow(record)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation { recordManager.removeRecord(record) }
                            } label: {
                                Label(isGlobalEnglishMode ? "Delete" : "删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .background(Color.clear)
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Watch History" : "观看记录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToPlayer) {
            if let r = playRecord {
                VideoPlayerPageView(
                    episodeURL: r.videoURL,
                    videoTitle: "\(r.videoTitle) · \(r.episodeName)",
                    coverImage: r.coverImage,
                    channelName: r.channelName,
                    episodeName: r.episodeName,
                    sourceURL: r.sourceURL
                )
            }
        }
        .toolbar {
            if !recordManager.records.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        withAnimation { recordManager.clearAll() }
                    } label: {
                        Text(isGlobalEnglishMode ? "Clear All" : "清空")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
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
            Text(isGlobalEnglishMode
                ? "This will use 1 pass."
                : "当前视频将消耗 1 点")
        }
        // ⭐ 新增：额度用完的中间提示窗
        .alert(isGlobalEnglishMode
            ? "Free Passes Used Up (0 left)"
            : "今日免费额度不足",
            isPresented: $showQuotaExhausted) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") {
                showSubscriptionSheet = true
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "You've used all your free passes for today. Come back tomorrow for more, or subscribe now for unlimited access."
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
                ? "Sign in (free, no purchase needed) to unlock your free daily passes."
                : "登录后即可获得每日免费观看点数，登录无需付费。")
        }
        .onChange(of: authManager.isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }

    // MARK: - 门禁
    private func attemptPlay(_ record: VideoPlayRecord) {
        switch decideVideoAccess(episodeKey: record.videoURL, auth: authManager, quota: quotaManager) {
        case .allowed:
            playRecord = record
            navigateToPlayer = true
        case .needLogin:                 // ⭐ 新增
            showLoginAlert = true
        case .needConsume(let r):
            pendingRecord = record
            consumeRemaining = r
            showConsumeConfirm = true
        case .exhausted:
            showQuotaExhausted = true
        }
    }

    private func consumeAndPlay() async {
        guard let record = pendingRecord else { return }
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let result = await quotaManager.unlock(
            userId: uid,
            episodeKey: record.videoURL,
            videoTitle: "\(record.videoTitle) · \(record.episodeName)"
        )
        switch result {
        case .success, .alreadyUnlocked:
            playRecord = record
            navigateToPlayer = true
        case .quotaExceeded, .failed:
            showQuotaExhausted = true
        }
        pendingRecord = nil
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.08))
                    .frame(width: 90, height: 90)
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(.secondary)
            }
            Text(isGlobalEnglishMode ? "No history records" : "暂无观看记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    private func recordRow(_ record: VideoPlayRecord) -> some View {
        HStack(spacing: 12) {
            coverThumb(name: record.coverImage)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.videoTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.episodeName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(formattedDate(record.playTime))
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor.opacity(0.8))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 6, y: 2)
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
            .frame(width: 45, height: 63)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "film").foregroundColor(.accentColor).font(.caption)
            }
            .frame(width: 45, height: 63)
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }
}

// MARK: - 已缓存剧集分组卡片
struct CachedSeriesCard: View {
    let group: CachedSeriesGroup
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        HStack(spacing: 12) {
            coverThumb(name: group.coverImage)
            VStack(alignment: .leading, spacing: 6) {
                Text(group.seriesTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundColor(.accentColor)
                    Text(isGlobalEnglishMode ? "\(group.episodes.count) episodes cached"
                                             : "已缓存 \(group.episodes.count) 集")
                        .foregroundColor(.accentColor)
                }
                .font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundColor(.secondary)
                    Text(formattedDate(group.latestSavedAt)).foregroundColor(.secondary)
                }
                .font(.system(size: 11))
            }
            Spacer()
            Text("\(group.episodes.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor))
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
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
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.5), .blue.opacity(0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "rectangle.stack.fill").foregroundColor(.white)
            }
            .frame(width: 60, height: 84)
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - 已缓存剧集详情（列出该剧所有已缓存集数）
struct CachedSeriesDetailView: View {
    let groupKey: String
    let seriesTitle: String
    let coverImage: String?
    @ObservedObject private var dm = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false

    // ⭐ 门禁 / 程序化跳转
    @State private var cachedPlayTarget: CachedPlayTarget? = nil
    @State private var navigateToCachedPlayer = false
    @State private var pendingCachedTarget: CachedPlayTarget? = nil
    @State private var showCachedConsumeConfirm = false
    @State private var cachedConsumeRemaining = 0
    @State private var showQuotaExhausted = false

    private var episodes: [(url: String, meta: VideoCacheMetadata)] {
        dm.localBookmarks.keys.compactMap { url -> (String, VideoCacheMetadata)? in
            let meta = dm.cacheMetadata[url]
                ?? VideoCacheMetadata(title: url, coverImage: nil, savedAt: Date(),
                                      seriesTitle: nil, episodeName: nil)
            guard meta.groupKey == groupKey else { return nil }
            return (url, meta)
        }
        .sorted {
            ($0.meta.episodeName ?? "").localizedStandardCompare($1.meta.episodeName ?? "") == .orderedAscending
        }
    }

    // ⭐ 当前所有集（供选集用）
    private var episodeItems: [VideoEpisodeItem] {
        episodes.enumerated().map { index, item in
            let name = item.meta.episodeName ?? item.meta.title
            let digits = name.filter { $0.isNumber }
            let number = (!digits.isEmpty && digits.count <= 4 && Int(digits) != nil)
                ? digits : String(index + 1)
            return VideoEpisodeItem(number: number, name: name, url: item.url)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemGroupedBackground), Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            List {
                ForEach(Array(episodes.enumerated()), id: \.element.url) { index, row in
                    Button {
                        attemptPlayCached(CachedPlayTarget(
                            primaryURL: row.url,
                            title: seriesTitle,
                            episodeName: row.meta.episodeName,
                            episodes: episodeItems
                        ))
                    } label: {
                        episodeRow(index: index, meta: row.meta)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            withAnimation { dm.deleteDownload(urlString: row.url) }
                        } label: {
                            Label(isGlobalEnglishMode ? "Delete" : "删除", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .background(Color.clear)
        }
        .navigationTitle(seriesTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToCachedPlayer) {
            if let t = cachedPlayTarget {
                CachedVideoPlayerView(
                    realURL: t.primaryURL,
                    title: t.title,
                    episodeName: t.episodeName,
                    episodes: t.episodes
                )
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }

    // MARK: - 门禁
    private func attemptPlayCached(_ target: CachedPlayTarget) {
        // ⭐ 同上，缓存剧集直接播放
        cachedPlayTarget = target
        navigateToCachedPlayer = true
    }

    private func episodeRow(index: Int, meta: VideoCacheMetadata) -> some View {
        let displayEpisodeName: String = {
            if let epName = meta.episodeName, !epName.isEmpty { return epName }
            if meta.title.contains(" · ") {
                let components = meta.title.components(separatedBy: " · ")
                if let lastComponent = components.last, !lastComponent.isEmpty {
                    return lastComponent
                }
            }
            return meta.title
        }()

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "play.fill").foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(displayEpisodeName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(isGlobalEnglishMode ? "Available offline" : "可离线播放").foregroundColor(.green)
                }
                .font(.system(size: 11, weight: .medium))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
    }
}