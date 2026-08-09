// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoDownloadView.swift
// VideoPlayerView / VideoPlayerPageView / VideoCacheView / CachedVideoPlayerView

import SwiftUI
import AVKit
import UIKit

// ⭐ 用最少字段构造一个 OVideoItem（供「下载更多」复用 BatchDownloadView）
extension OVideoItem {
    init(seriesName: String, sourceURL: String, cover: String?) {
        self.init(time: nil, name: seriesName, url: sourceURL, info: nil,
                  image: cover, director: nil, writers: nil, cast: nil,
                  types: nil, region: nil, date: nil, alias: nil, intro: nil,
                  ratings: nil, playlist: nil, update: nil)
    }
}

// ⭐ 选最优线路（集数多优先 → 画质高优先），与详情页逻辑一致
func optimalSortedChannels(_ channels: [OVideoChannel]) -> [OVideoChannel] {
    let indexed = channels.enumerated().map { (index, channel) -> (Int, OVideoChannel, Int) in
        var quality = 1
        let keys = channel.episodes.keys
        let hasLow = keys.contains {
            let k = $0.uppercased()
            return k.contains("TC") || k.contains("TS") || k.contains("HC") || k.contains("抢先")
        }
        let hasHigh = keys.contains {
            let k = $0.uppercased()
            return k.contains("HD") || k.contains("正片")
        }
        if hasLow { quality = 0 } else if hasHigh { quality = 2 }
        return (index, channel, quality)
    }
    return indexed.sorted { a, b in
        if a.1.episodes.count != b.1.episodes.count { return a.1.episodes.count > b.1.episodes.count }
        if a.2 != b.2 { return a.2 > b.2 }
        return a.0 < b.0
    }.map { $0.1 }
}

// ⭐ 「下载更多」sheet 载荷
struct DownloadMorePayload: Identifiable {
    let id = UUID()
    let item: OVideoItem
    let channel: OVideoChannel
}

// MARK: - 下载播放跳转目标（用于门禁通过后再跳转）
struct CachedPlayTarget: Identifiable {
    var id: String { primaryURL }
    let primaryURL: String
    let title: String
    let episodeName: String?
    let episodes: [VideoEpisodeItem]
    var sourceURL: String? = nil
}

// =====================================================================
// MARK: - 下载管理器（重写：身份校验 / 并发闸门 / 磁盘测速 / 自动重试）
// =====================================================================
final class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!

    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadSpeed:    [String: Double] = [:]
    @Published var isPaused:         [String: Bool]   = [:]
    /// ⭐ 新增：排队等待启动（并发闸门）
    @Published var isQueued:         [String: Bool]   = [:]
    @Published var localBookmarks:   [String: Data]   = [:]
    @Published var cacheMetadata:    [String: VideoCacheMetadata] = [:]

    // ---- 任务管理 ----
    private var activeTasks:   [String: AVAssetDownloadTask] = [:]
    private var waitingQueue:  [String] = []
    private var userPausedUrls: Set<String> = []
    private var retryCounts:   [String: Int] = [:]
    private let maxConcurrent = 3

    // ---- 局部包（.movpkg）书签：willDownloadTo 就写入，用于测速 + 清理 ----
    private var pendingBookmarks: [String: Data] = [:]

    // ---- 测速 ----
    private var speedEMA:       [String: Double] = [:]
    private var zeroSpeedTicks: [String: Int]    = [:]
    private var lastDiskBytes:  [String: Int64]  = [:]
    private var lastTaskBytes:  [String: Int64]  = [:]
    private var lastSampleTime: [String: Date]   = [:]
    private let sizeQueue = DispatchQueue(label: "ONews.HLSDiskSize", qos: .utility)
    private var isSampling = false

    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    private let metadataKey  = "ONews_VideoCacheMetadata"
    private let progressKey  = "ONews_DownloadProgress"
    private let pausedKey    = "ONews_DownloadPaused"
    private let pendingKey   = "ONews_PendingHLSBookmarks"

    private var speedTimer: Timer?
    private var lastPersistTime = Date.distantPast

    var backgroundCompletionHandler: (() -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        downloadSession = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: .main          // ⭐ 所有回调都在主线程
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

    // MARK: 主线程保护
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - 冷启动恢复
    private func handleColdLaunchRecovery() {
        for urlString in downloadProgress.keys where localBookmarks[urlString] == nil {
            isPaused[urlString]      = true
            isQueued[urlString]      = false
            downloadSpeed[urlString] = 0
        }
        savePersistedProgress()

        downloadSession.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            self.onMain {
                var aliveUrls = Set<String>()
                for task in tasks {
                    guard let dlTask = task as? AVAssetDownloadTask,
                          let urlString = dlTask.taskDescription else {
                        task.cancel(); continue
                    }
                    if self.downloadProgress[urlString] == nil &&
                       self.localBookmarks[urlString]   == nil {
                        dlTask.cancel(); continue
                    }
                    if dlTask.state == .completed || dlTask.state == .canceling { continue }

                    self.activeTasks[urlString] = dlTask
                    aliveUrls.insert(urlString)
                    if dlTask.state == .running { dlTask.suspend() }
                }

                // 副防线：有局部包但 session 已无对应任务 → 清磁盘 + 进度归零
                let orphanUrls = self.pendingBookmarks.keys.filter { !aliveUrls.contains($0) }
                for urlString in orphanUrls {
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

    // MARK: - 启动下载
    func startDownload(urlString: String, title: String, coverImage: String? = nil,
                       seriesTitle: String? = nil, episodeName: String? = nil,
                       episodeKey: String? = nil, sourceURL: String? = nil) {
        onMain {
            guard self.localBookmarks[urlString] == nil else { return }   // 已完成
            self.userPausedUrls.remove(urlString)
            self.retryCounts[urlString] = 0

            if self.cacheMetadata[urlString] == nil {
                self.cacheMetadata[urlString] = VideoCacheMetadata(
                    title: title, coverImage: coverImage, savedAt: Date(),
                    seriesTitle: seriesTitle, episodeName: episodeName,
                    originalEpisodeURL: episodeKey, sourceURL: sourceURL
                )
                self.saveMetadata()
            }
            if self.downloadProgress[urlString] == nil {
                self.downloadProgress[urlString] = 0.0
            }
            self.downloadSpeed[urlString] = 0
            self.isPaused[urlString] = false

            if self.activeTasks[urlString] != nil {   // 已经在跑
                self.savePersistedProgress(); return
            }
            self.enqueueOrStart(urlString)
            self.savePersistedProgress()
        }
    }

    // MARK: - 并发闸门
    private var runningCount: Int {
        activeTasks.filter { isPaused[$0.key] != true }.count
    }

    private func enqueueOrStart(_ urlString: String) {
        if runningCount >= maxConcurrent {
            if !waitingQueue.contains(urlString) { waitingQueue.append(urlString) }
            isQueued[urlString] = true
            isPaused[urlString] = false
            return
        }
        waitingQueue.removeAll { $0 == urlString }
        isQueued[urlString] = false
        beginTask(for: urlString)
    }

    private func beginTask(for urlString: String) {
        guard let remote = URL(string: urlString) else { return }
        let title = cacheMetadata[urlString]?.title ?? urlString
        let asset = AVURLAsset(url: remote)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else {
            // 创建失败 → 排队稍后重试
            isPaused[urlString] = true
            isQueued[urlString] = false
            scheduleAutoRetry(urlString, force: true)
            return
        }
        task.taskDescription = urlString
        activeTasks[urlString] = task
        isPaused[urlString] = false
        isQueued[urlString] = false
        lastSampleTime[urlString] = Date()
        lastTaskBytes[urlString]  = 0
        lastDiskBytes.removeValue(forKey: urlString)
        speedEMA[urlString] = 0
        task.resume()
        savePersistedProgress()
    }

    private func pumpQueue() {
        while runningCount < maxConcurrent, !waitingQueue.isEmpty {
            let next = waitingQueue.removeFirst()
            guard downloadProgress[next] != nil,
                  localBookmarks[next] == nil,
                  activeTasks[next] == nil,
                  !userPausedUrls.contains(next) else {
                isQueued[next] = false
                continue
            }
            beginTask(for: next)
        }
    }

    // MARK: - 暂停 / 继续
    func pauseDownload(urlString: String, byUser: Bool = true) {
        onMain {
            if byUser { self.userPausedUrls.insert(urlString) }
            self.waitingQueue.removeAll { $0 == urlString }
            self.isQueued[urlString] = false
            if let task = self.activeTasks[urlString] { task.suspend() }
            self.isPaused[urlString]      = true
            self.downloadSpeed[urlString] = 0
            self.speedEMA[urlString]      = 0
            self.lastDiskBytes.removeValue(forKey: urlString)
            self.lastTaskBytes.removeValue(forKey: urlString)
            self.lastSampleTime.removeValue(forKey: urlString)
            self.savePersistedProgress()
            self.pumpQueue()
        }
    }

    func resumeDownload(urlString: String) {
        onMain {
            self.userPausedUrls.remove(urlString)
            self.retryCounts[urlString] = 0

            if let task = self.activeTasks[urlString],
               task.state != .completed, task.state != .canceling {
                if self.runningCount >= self.maxConcurrent {
                    if !self.waitingQueue.contains(urlString) { self.waitingQueue.append(urlString) }
                    self.isQueued[urlString] = true
                    self.isPaused[urlString] = false
                    self.savePersistedProgress()
                    return
                }
                task.resume()
                self.isPaused[urlString]       = false
                self.isQueued[urlString]       = false
                self.lastSampleTime[urlString] = Date()
                self.lastTaskBytes[urlString]  = task.countOfBytesReceived
                self.lastDiskBytes.removeValue(forKey: urlString)
                self.savePersistedProgress()
            } else {
                self.recreateAndResume(urlString: urlString)
            }
        }
    }

    private func recreateAndResume(urlString: String) {
        // 先摘掉旧任务身份，后续旧回调一律判为「陈旧」
        if let old = activeTasks.removeValue(forKey: urlString) { old.cancel() }
        purgeStalePartial(for: urlString)

        downloadProgress[urlString] = 0
        lastDiskBytes.removeValue(forKey: urlString)
        lastTaskBytes.removeValue(forKey: urlString)
        speedEMA[urlString] = 0
        zeroSpeedTicks[urlString] = 0
        savePersistedProgress()

        enqueueOrStart(urlString)
        savePersistedProgress()
    }

    /// 把已无法续传的本地局部包从磁盘干净抹掉
    private func purgeStalePartial(for urlString: String) {
        if let bookmark = pendingBookmarks[urlString] {
            var isStale = false
            if let oldPartialURL = try? URL(resolvingBookmarkData: bookmark,
                                            bookmarkDataIsStale: &isStale) {
                do { try FileManager.default.removeItem(at: oldPartialURL) }
                catch {
                    let ns = error as NSError
                    if !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError) {
                        print("⚠️ 清理旧局部包失败: \(error)")
                    }
                }
            }
        }
        pendingBookmarks.removeValue(forKey: urlString)
        savePendingBookmarks()
    }

    // MARK: - 取消 / 删除
    func cancelDownload(urlString: String) { deleteDownload(urlString: urlString) }

    func deleteDownload(urlString: String) {
        onMain {
            self.userPausedUrls.remove(urlString)
            self.waitingQueue.removeAll { $0 == urlString }
            self.retryCounts.removeValue(forKey: urlString)

            // ⭐ 关键：同步摘除任务身份（原来的异步移除正是「取消后重下就乱套」的竞态窗口）
            let task = self.activeTasks.removeValue(forKey: urlString)
            task?.cancel()

            // 保险：session 中同名任务全部取消
            self.downloadSession.getAllTasks { tasks in
                for t in tasks {
                    if let dl = t as? AVAssetDownloadTask, dl.taskDescription == urlString {
                        dl.cancel()
                    }
                }
            }

            if let localURL = self.getLocalURL(for: urlString) {
                try? FileManager.default.removeItem(at: localURL)
            }
            if let pendingURL = self.getPendingLocalURL(for: urlString) {
                try? FileManager.default.removeItem(at: pendingURL)
            }

            self.localBookmarks.removeValue(forKey: urlString)
            self.pendingBookmarks.removeValue(forKey: urlString)
            self.cacheMetadata.removeValue(forKey: urlString)
            self.downloadProgress.removeValue(forKey: urlString)
            self.downloadSpeed.removeValue(forKey: urlString)
            self.isPaused.removeValue(forKey: urlString)
            self.isQueued.removeValue(forKey: urlString)
            self.speedEMA.removeValue(forKey: urlString)
            self.zeroSpeedTicks.removeValue(forKey: urlString)
            self.lastDiskBytes.removeValue(forKey: urlString)
            self.lastTaskBytes.removeValue(forKey: urlString)
            self.lastSampleTime.removeValue(forKey: urlString)

            self.saveBookmarks()
            self.savePendingBookmarks()
            self.saveMetadata()
            self.savePersistedProgress()
            self.pumpQueue()
        }
    }

    // MARK: - 本地路径
    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmark = localBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    func getPendingLocalURL(for urlString: String) -> URL? {
        guard let bookmark = pendingBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    func displayedProgress(for urlString: String) -> Double { downloadProgress[urlString] ?? 0 }
    func displaySpeed(for urlString: String) -> Double { downloadSpeed[urlString] ?? 0 }

    // =================================================================
    // MARK: - ⭐ 测速：以磁盘真实写入量为准（HLS 父任务字节数不可靠）
    // =================================================================
    private func startSpeedTimer() {
        speedTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleSpeed()
        }
        // ⭐ common 模式：列表滚动时也继续采样，避免速度「时有时无」
        RunLoop.main.add(t, forMode: .common)
        speedTimer = t
    }

    private func sampleSpeed() {
        guard !isSampling else { return }

        var taskBytes: [String: Int64] = [:]
        var diskPaths: [String: URL]   = [:]

        for url in downloadProgress.keys {
            guard localBookmarks[url] == nil else { continue }
            if isPaused[url] == true || isQueued[url] == true {
                if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
                speedEMA[url] = 0
                continue
            }
            if let t = activeTasks[url] { taskBytes[url] = t.countOfBytesReceived }
            if let p = getPendingLocalURL(for: url) { diskPaths[url] = p }
        }
        guard !taskBytes.isEmpty || !diskPaths.isEmpty else { return }

        isSampling = true
        let now = Date()
        sizeQueue.async { [weak self] in
            guard let self = self else { return }
            var sizes: [String: Int64] = [:]
            for (u, p) in diskPaths { sizes[u] = Self.allocatedSize(of: p) }
            DispatchQueue.main.async {
                self.applySpeedSamples(diskSizes: sizes, taskBytes: taskBytes, now: now)
                self.isSampling = false
            }
        }
    }

    private func applySpeedSamples(diskSizes: [String: Int64],
                                   taskBytes: [String: Int64],
                                   now: Date) {
        let keys = Set(diskSizes.keys).union(taskBytes.keys)
        for u in keys {
            guard isPaused[u] != true, isQueued[u] != true,
                  localBookmarks[u] == nil else { continue }

            let lastTime = lastSampleTime[u]
            var inst: Double? = nil

            if let d = diskSizes[u] {
                if let prev = lastDiskBytes[u], let lt = lastTime {
                    let dt = now.timeIntervalSince(lt)
                    if dt > 0.25 { inst = max(0, Double(d - prev) / dt) }
                }
                lastDiskBytes[u] = d
            }
            if let b = taskBytes[u] {
                if inst == nil, let prev = lastTaskBytes[u], let lt = lastTime {
                    let dt = now.timeIntervalSince(lt)
                    if dt > 0.25 { inst = max(0, Double(b - prev) / dt) }
                }
                lastTaskBytes[u] = b
            }
            lastSampleTime[u] = now

            guard let v = inst else { continue }

            // EMA 平滑，数值不再乱跳
            let prevEMA = speedEMA[u] ?? 0
            let ema = prevEMA <= 0 ? v : (prevEMA * 0.65 + v * 0.35)
            speedEMA[u] = ema

            if v <= 0 { zeroSpeedTicks[u] = (zeroSpeedTicks[u] ?? 0) + 1 }
            else       { zeroSpeedTicks[u] = 0 }

            // 连续 6 秒没有新增字节才判定为「停滞」，避免闪断
            if (zeroSpeedTicks[u] ?? 0) >= 6 {
                speedEMA[u] = 0
                downloadSpeed[u] = 0
            } else {
                downloadSpeed[u] = ema
            }
        }
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return Int64(v?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url,
                                 includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                              .isRegularFileKey],
                                 options: []) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                              .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private func savePersistedProgressIfNeeded() {
        if Date().timeIntervalSince(lastPersistTime) > 1.5 {
            savePersistedProgress()
            lastPersistTime = Date()
        }
    }

    // =================================================================
    // MARK: - AVAssetDownloadDelegate（全部带「任务身份校验」）
    // =================================================================
    private func isCurrent(_ task: URLSessionTask, _ urlString: String) -> Bool {
        guard let cur = activeTasks[urlString] else { return false }
        return cur === task
    }

    /// ⭐ 下载一开始就拿到最终落盘位置：既用于测速，也用于清理僵尸局部包
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        guard isCurrent(assetDownloadTask, urlString) else { return }
        if let bm = try? location.bookmarkData(options: .minimalBookmark,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            pendingBookmarks[urlString] = bm
            savePendingBookmarks()
        }
        lastDiskBytes.removeValue(forKey: urlString)
        lastSampleTime[urlString] = Date()
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        guard isCurrent(assetDownloadTask, urlString) else { return }   // ⭐ 陈旧回调直接丢弃

        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite, expected > 0 else { return }
        var percent = 0.0
        for value in loadedTimeRanges {
            percent += value.timeRangeValue.duration.seconds / expected
        }
        let cur = downloadProgress[urlString] ?? 0
        downloadProgress[urlString] = min(1.0, max(cur, percent))
        savePersistedProgressIfNeeded()
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else {
            try? FileManager.default.removeItem(at: location); return
        }
        // ⭐ 陈旧任务（已取消/已被新任务替换）：只抹残留，绝不动当前状态
        guard isCurrent(assetDownloadTask, urlString) else {
            let curPending = getPendingLocalURL(for: urlString)?.standardizedFileURL
            if curPending != location.standardizedFileURL {
                try? FileManager.default.removeItem(at: location)
            }
            return
        }
        if let bm = try? location.bookmarkData(options: .minimalBookmark,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            pendingBookmarks[urlString] = bm
            savePendingBookmarks()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { return }

        // ⭐ 陈旧任务的死亡回调：什么都不要动，否则会污染刚重建的新任务
        guard isCurrent(task, urlString) else {
            pumpQueue()
            return
        }

        activeTasks.removeValue(forKey: urlString)
        lastTaskBytes.removeValue(forKey: urlString)
        lastSampleTime.removeValue(forKey: urlString)
        downloadSpeed[urlString] = 0
        speedEMA[urlString] = 0

        let progress = downloadProgress[urlString] ?? 0
        let didTrulyFinish = (error == nil) && (progress >= 0.999)

        if didTrulyFinish {
            if let bookmark = pendingBookmarks[urlString] {
                localBookmarks[urlString] = bookmark
                saveBookmarks()
            }

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
            let title = cacheMetadata[urlString]?.title ?? "Unknown Video"
            TrackingManager.shared.track(event: .downloadComplete,
                                         userId: finalUserId, userType: finalUserType,
                                         videoURL: urlString, videoTitle: title)

            pendingBookmarks.removeValue(forKey: urlString)
            savePendingBookmarks()
            downloadProgress.removeValue(forKey: urlString)
            isPaused.removeValue(forKey: urlString)
            isQueued.removeValue(forKey: urlString)
            retryCounts.removeValue(forKey: urlString)
            lastDiskBytes.removeValue(forKey: urlString)
        } else {
            // 中断：保留进度，标记暂停
            isPaused[urlString] = true
            isQueued[urlString] = false
            savePendingBookmarks()
            if let nsErr = error as NSError? {
                print("⚠️ 下载中断 [\(urlString)]: domain=\(nsErr.domain) code=\(nsErr.code) progress=\(progress)")
            }
            // ⭐ 批量下载「启动阶段就挂掉」的自动重试（progress 极低 且 非用户暂停）
            if error != nil, !userPausedUrls.contains(urlString), progress < 0.02 {
                scheduleAutoRetry(urlString)
            }
        }

        savePersistedProgress()
        pumpQueue()
    }

    private func scheduleAutoRetry(_ urlString: String, force: Bool = false) {
        let retry = retryCounts[urlString] ?? 0
        guard retry < 3 else { return }
        retryCounts[urlString] = retry + 1
        let delay = Double(retry + 1) * 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard self.localBookmarks[urlString] == nil,
                  self.downloadProgress[urlString] != nil,
                  self.activeTasks[urlString] == nil,
                  !self.userPausedUrls.contains(urlString) else { return }
            if !force, self.isPaused[urlString] != true { return }
            print("🔁 自动重试下载: \(urlString) (第 \(retry + 1) 次)")
            self.userPausedUrls.remove(urlString)
            self.recreateAndResume(urlString: urlString)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onMain {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
            print("✨ 后台 Session 事件全部处理完毕")
        }
    }

    // MARK: - 持久化
    private func savePendingBookmarks() {
        UserDefaults.standard.set(pendingBookmarks, forKey: pendingKey)
    }
    private func loadPendingBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Data] {
            pendingBookmarks = saved
        }
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
    private func savePersistedProgress() {
        UserDefaults.standard.set(downloadProgress, forKey: progressKey)
        UserDefaults.standard.set(isPaused,         forKey: pausedKey)
        updateIdleTimer()
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
            guard let self = self else { return }
            let urls = Array(self.activeTasks.keys) + self.waitingQueue
            for url in Set(urls) { self.pauseDownload(urlString: url, byUser: false) }
            print("⚠️ 检测到 Wi-Fi → 蜂窝，已暂停所有下载")
        }
    }

    // MARK: 前台下载防灭屏
    private func updateIdleTimer() {
        let hasActiveDownload = downloadProgress.keys.contains { url in
            localBookmarks[url] == nil && (isPaused[url] != true)
        }
        let isForeground = UIApplication.shared.applicationState != .background
        UIApplication.shared.isIdleTimerDisabled = hasActiveDownload && isForeground
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.savePersistedProgress() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.savePersistedProgress() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateIdleTimer() }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateIdleTimer() }
    }
}

extension HLSDownloadManager {
    func activeTasksContains(_ url: String) -> Bool { downloadProgress[url] != nil }

    /// 一键继续所有处于暂停状态的下载
    func resumeAllPausedDownloads() {
        let paused = downloadProgress.keys
            .filter { isPaused[$0] == true && localBookmarks[$0] == nil }
            .sorted()
        for url in paused { resumeDownload(urlString: url) }
    }

    /// ⭐ UI 分组用：同一部剧的下载归到一起（纯字符串派生，不改数据结构）
    func downloadGroupKey(for url: String) -> String {
        if let meta = cacheMetadata[url] {
            if let s = meta.seriesTitle, !s.isEmpty { return "s:" + s }
            let comps = meta.title.components(separatedBy: " · ")
            if comps.count > 1, let first = comps.first, !first.isEmpty { return "s:" + first }
        }
        return "u:" + url
    }
}

// MARK: - 速度文本
func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec <= 0 { return "—" }
    if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
    let kb = bytesPerSec / 1024.0
    if kb < 1024 { return String(format: "%.1f KB/s", kb) }
    let mb = kb / 1024
    return String(format: "%.2f MB/s", mb)
}

// MARK: - 下载卡片（播放页内）
struct CacheCard: View {
    let realURL: String
    let videoTitle: String
    let coverImage: String?
    var seriesTitle: String? = nil
    var episodeName: String? = nil
    var episodeKey: String? = nil
    var sourceURL: String? = nil

    @ObservedObject private var downloadManager = HLSDownloadManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @AppStorage("hasAcknowledgedAdWarning") private var hasAcknowledgedAdWarning = false
    @State private var showAdWarningAlert = false

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @State private var showCellularAlert = false
    @State private var showCancelAlert = false

    var body: some View {
        let isDownloaded = downloadManager.localBookmarks[realURL] != nil
        let isDownloading = downloadManager.activeTasksContains(realURL)
        let isPaused = downloadManager.isPaused[realURL] ?? false
        let isQueued = downloadManager.isQueued[realURL] ?? false
        let displayProgress = downloadManager.displayedProgress(for: realURL)

        VStack(alignment: .leading, spacing: 14) {
            if isDownloaded {
                downloadedRow
            } else if isDownloading {
                downloadingRow(progress: displayProgress, isPaused: isPaused, isQueued: isQueued)
            } else {
                idleRow
            }

            Divider().opacity(0.3)
            cacheListNavigationRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Download Anyway" : "允许并下载") {
                downloadManager.startDownload(urlString: realURL, title: videoTitle,
                                              coverImage: coverImage, seriesTitle: seriesTitle,
                                              episodeName: episodeName, episodeKey: episodeKey,
                                              sourceURL: sourceURL)
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are currently on a cellular network. Do you want to continue downloading?"
                 : "当前处于蜂窝移动网络，下载将消耗流量，是否继续？")
        }
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
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }

    private var hasAccess: Bool {
        guard let key = episodeKey, !key.isEmpty else { return authManager.isSubscribed }
        return authManager.isSubscribed || FreeQuotaManager.shared.isUnlocked(key)
    }

    private func startDownloadFlow() {
        if !network.isWiFi {
            showCellularAlert = true
        } else {
            downloadManager.startDownload(urlString: realURL, title: videoTitle,
                                          coverImage: coverImage, seriesTitle: seriesTitle,
                                          episodeName: episodeName, episodeKey: episodeKey,
                                          sourceURL: sourceURL)
        }
    }

    private var downloadedRow: some View {
        HStack {
            Label(isGlobalEnglishMode ? "Cached, available offline" : "已下载，可离线播放",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.green)
            Spacer()
            Button {
                downloadManager.deleteDownload(urlString: realURL)
            } label: {
                Label(isGlobalEnglishMode ? "Delete" : "删除", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
            }
        }
    }

    private func downloadingRow(progress: Double, isPaused: Bool, isQueued: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: [.blue, .accentColor],
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
                if isQueued {
                    Text(isGlobalEnglishMode ? "· Queued" : "· 排队中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                } else if !isPaused {
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

                Button {
                    if isPaused {
                        if !network.isWiFi { showCellularAlert = true }
                        else { downloadManager.resumeDownload(urlString: realURL) }
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
                                colors: isPaused ? [Color.green, Color.green.opacity(0.7)]
                                                 : [Color.orange, Color.orange.opacity(0.7)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .shadow(color: (isPaused ? Color.green : Color.orange).opacity(0.4),
                                radius: 6, y: 2)
                }

                Button { showCancelAlert = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .alert(isGlobalEnglishMode ? "Cancel Download" : "取消下载",
                       isPresented: $showCancelAlert) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Confirm" : "确定", role: .destructive) {
                        downloadManager.deleteDownload(urlString: realURL)
                    }
                } message: {
                    Text(isGlobalEnglishMode
                         ? "Are you sure you want to cancel and clear all downloaded data?"
                         : "确定要取消下载并清除所有已下载的数据吗？")
                }
            }

            if !network.isWiFi {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(isGlobalEnglishMode
                         ? "Switched to cellular, mind your data usage"
                         : "已切换到5G，下载请关注流量")
                        .font(.system(size: 11)).foregroundColor(.orange)
                }
            }
        }
    }

    private var idleRow: some View {
        HStack(spacing: 12) {
            Text(isGlobalEnglishMode ? "Download to your phone for smoother playback"
                                     : "下载到手机，播放更流畅")
                .font(.system(size: 12)).foregroundColor(.secondary)

            Button {
                guard hasAccess else { showSubscriptionSheet = true; return }
                if !hasAcknowledgedAdWarning { showAdWarningAlert = true; return }
                startDownloadFlow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(isGlobalEnglishMode ? "Download" : "下载")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.vertical, 10).padding(.horizontal, 20)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                        startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: Color.accentColor.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var cacheListNavigationRow: some View {
        NavigationLink(destination: VideoCacheView()) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 36, height: 36)
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.accentColor)
                }
                HStack(spacing: 2) {
                    Text(isGlobalEnglishMode ? "Manage Offline Cache" : "下载管理")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.primary)
                    Spacer()

                    let downloadingCount = downloadManager.downloadProgress.keys
                        .filter { downloadManager.localBookmarks[$0] == nil }.count
                    let cachedCount = downloadManager.localBookmarks.keys.count

                    if downloadingCount > 0 {
                        Text(isGlobalEnglishMode ? "\(downloadingCount) tasks downloading"
                                                 : "\(downloadingCount)个任务下载中")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.blue)
                    } else if cachedCount > 0 {
                        Text(isGlobalEnglishMode ? "\(cachedCount) videos cached"
                                                 : "已下载 \(cachedCount) 个视频")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    } else {
                        Text(isGlobalEnglishMode ? "View all cached content" : "查看所有已下载视频")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .contentShape(Rectangle())
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
        let color: Color = !network.isConnected ? .red : network.isWiFi ? .green : .orange
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

// MARK: - 已下载剧集分组模型
struct CachedSeriesGroup: Identifiable {
    let id: String
    let seriesTitle: String
    let coverImage: String?
    let episodes: [(url: String, meta: VideoCacheMetadata)]
    let latestSavedAt: Date
}

// MARK: - ⭐ 下载中分组模型
struct DownloadingItem: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let title: String
    let episodeName: String
}
struct DownloadingGroup: Identifiable {
    let id: String              // groupKey，唯一且稳定
    let seriesTitle: String
    let coverImage: String?
    let items: [DownloadingItem]
}

// MARK: - 下载管理
struct VideoCacheView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @StateObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false
    @State private var showCellularAlert = false

    @State private var cachedPlayTarget: CachedPlayTarget? = nil
    @State private var navigateToCachedPlayer = false

    /// ⭐ 反向记录「被用户折叠的组」，默认全部展开，新组自动展开，绝不会消失
    @State private var collapsedGroups: Set<String> = []

    // ---------- 已下载分组（不变） ----------
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
            if let st = items.first?.meta.seriesTitle, !st.isEmpty { title = st }
            else if let t = items.first?.meta.title { title = t.components(separatedBy: " · ").first ?? t }
            else { title = key }
            let cover = items.compactMap { $0.meta.coverImage }.first
            return CachedSeriesGroup(id: key, seriesTitle: title,
                                     coverImage: cover, episodes: sorted, latestSavedAt: latest)
        }.sorted { $0.latestSavedAt > $1.latestSavedAt }
    }

    private var cachedCount: Int { downloadManager.localBookmarks.count }

    // ---------- ⭐ 下载中分组 ----------
    private var downloadingGroups: [DownloadingGroup] {
        var buckets: [String: [DownloadingItem]] = [:]
        var names:   [String: String] = [:]
        var covers:  [String: String] = [:]

        for url in downloadManager.downloadProgress.keys {
            guard downloadManager.localBookmarks[url] == nil else { continue }
            let meta  = downloadManager.cacheMetadata[url]
            let title = meta?.title ?? url
            let comps = title.components(separatedBy: " · ")

            var series = meta?.seriesTitle ?? ""
            if series.isEmpty, comps.count > 1 { series = comps.first ?? "" }

            let key = downloadManager.downloadGroupKey(for: url)
            let epName = (meta?.episodeName?.isEmpty == false)
                ? meta!.episodeName!
                : (comps.count > 1 ? (comps.last ?? title) : title)

            buckets[key, default: []].append(
                DownloadingItem(url: url, title: title, episodeName: epName))
            if names[key] == nil { names[key] = series.isEmpty ? title : series }
            if covers[key] == nil, let c = meta?.coverImage, !c.isEmpty { covers[key] = c }
        }

        return buckets.map { key, items in
            DownloadingGroup(
                id: key,
                seriesTitle: names[key] ?? key,
                coverImage: covers[key],
                items: items.sorted {
                    $0.episodeName.localizedStandardCompare($1.episodeName) == .orderedAscending
                })
        }
        .sorted { $0.seriesTitle.localizedStandardCompare($1.seriesTitle) == .orderedAscending }
    }

    private var downloadingTaskCount: Int {
        downloadManager.downloadProgress.keys
            .filter { downloadManager.localBookmarks[$0] == nil }.count
    }

    private var pausedCount: Int {
        downloadManager.downloadProgress.keys.filter {
            downloadManager.localBookmarks[$0] == nil && downloadManager.isPaused[$0] == true
        }.count
    }

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
            LinearGradient(colors: [Color(.systemGroupedBackground),
                                    Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            if groupedCachedItems.isEmpty && downloadingGroups.isEmpty {
                emptyState
            } else {
                List {
                    // ============ 下载中（按剧集归拢） ============
                    if !downloadingGroups.isEmpty {
                        Section(header: downloadingHeader) {
                            ForEach(downloadingGroups) { group in
                                if group.items.count <= 1, let only = group.items.first {
                                    DownloadingCard(realURL: only.url, title: only.title)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                withAnimation { downloadManager.deleteDownload(urlString: only.url) }
                                            } label: {
                                                Label(isGlobalEnglishMode ? "Delete" : "删除",
                                                      systemImage: "trash")
                                            }.tint(.red)
                                        }
                                } else {
                                    DownloadingGroupHeaderRow(
                                        group: group,
                                        isExpanded: !collapsedGroups.contains(group.id),
                                        onToggle: { toggleGroup(group.id) }
                                    )
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            withAnimation {
                                                for it in group.items {
                                                    downloadManager.deleteDownload(urlString: it.url)
                                                }
                                            }
                                        } label: {
                                            Label(isGlobalEnglishMode ? "Delete All" : "全部取消",
                                                  systemImage: "trash")
                                        }.tint(.red)
                                    }

                                    if !collapsedGroups.contains(group.id) {
                                        ForEach(group.items) { it in
                                            DownloadingEpisodeRow(url: it.url, name: it.episodeName)
                                                .listRowInsets(EdgeInsets(top: 3, leading: 34, bottom: 3, trailing: 16))
                                                .listRowBackground(Color.clear)
                                                .listRowSeparator(.hidden)
                                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                                    Button(role: .destructive) {
                                                        withAnimation {
                                                            downloadManager.deleteDownload(urlString: it.url)
                                                        }
                                                    } label: {
                                                        Label(isGlobalEnglishMode ? "Delete" : "删除",
                                                              systemImage: "trash")
                                                    }.tint(.red)
                                                }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ============ 已下载 ============
                    if !groupedCachedItems.isEmpty {
                        Section(header: sectionHeader(
                            isGlobalEnglishMode ? "Cached" : "已下载",
                            count: cachedCount, icon: "checkmark.seal.fill", color: .green)) {
                            ForEach(groupedCachedItems) { group in
                                if group.episodes.count == 1 {
                                    let row = group.episodes[0]
                                    let seriesTitle = row.meta.seriesTitle?.isEmpty == false
                                        ? row.meta.seriesTitle!
                                        : row.meta.title.components(separatedBy: " · ").first ?? row.meta.title
                                    let eps = makeEpisodeItems(from: group)

                                    Button {
                                        attemptPlayCached(CachedPlayTarget(
                                            primaryURL: row.url, title: seriesTitle,
                                            episodeName: row.meta.episodeName,
                                            episodes: eps, sourceURL: row.meta.sourceURL))
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
                                        }.tint(.red)
                                    }
                                } else {
                                    ZStack {
                                        CachedSeriesCard(group: group)
                                        NavigationLink(destination: CachedSeriesDetailView(
                                            groupKey: group.id, seriesTitle: group.seriesTitle,
                                            coverImage: group.coverImage)) { EmptyView() }
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
                                            Label(isGlobalEnglishMode ? "Delete All" : "删除整部",
                                                  systemImage: "trash")
                                        }.tint(.red)
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
        .navigationTitle(isGlobalEnglishMode ? "Offline Cache" : "下载管理 ")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToCachedPlayer) {
            if let t = cachedPlayTarget {
                CachedVideoPlayerView(realURL: t.primaryURL, title: t.title,
                                      episodeName: t.episodeName, sourceURL: t.sourceURL,
                                      episodes: t.episodes)
            }
        }
        .toolbar {
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
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Resume Anyway" : "允许并继续") {
                downloadManager.resumeAllPausedDownloads()
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are currently on a cellular network. Resume downloading anyway?"
                 : "当前处于蜂窝移动网络，继续下载将消耗流量，是否继续？")
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }

    private func toggleGroup(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedGroups.contains(id) { collapsedGroups.remove(id) }
            else { collapsedGroups.insert(id) }
        }
    }

    private func attemptPlayCached(_ target: CachedPlayTarget) {
        cachedPlayTarget = target
        navigateToCachedPlayer = true
    }

    private func resumeAllAction() {
        if !network.isWiFi { showCellularAlert = true; return }
        downloadManager.resumeAllPausedDownloads()
    }

    private var downloadingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
            Text(isGlobalEnglishMode ? "Downloading" : "下载中")
                .font(.system(size: 16, weight: .bold))
            Text("\(downloadingTaskCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.blue))
            Spacer()
            if pausedCount >= 1 {
                Button { resumeAllAction() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text(isGlobalEnglishMode ? "Resume All" : "一键继续")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(LinearGradient(
                        colors: [Color.green, Color.green.opacity(0.7)],
                        startPoint: .leading, endPoint: .trailing)))
                    .shadow(color: Color.green.opacity(0.35), radius: 5, y: 2)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .textCase(nil)
    }

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
                Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
            } else { Spacer() }
        }
        .padding(.horizontal, 16)
        .textCase(nil)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.10)).frame(width: 120, height: 120)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 50, weight: .light)).foregroundColor(.accentColor)
            }
            Text(isGlobalEnglishMode ? "No cached videos yet" : "去找一些喜欢的视频下载吧")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
            Text(isGlobalEnglishMode
                 ? "Cached videos can be played offline anytime."
                 : "下载后即可随时离线观看，比如乘坐飞机前...")
                .font(.system(size: 13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ⭐ 下载中：剧集组头
struct DownloadingGroupHeaderRow: View {
    let group: DownloadingGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    @ObservedObject private var dm = HLSDownloadManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var showCellularAlert = false

    private var progresses: [Double] { group.items.map { dm.displayedProgress(for: $0.url) } }
    private var avgProgress: Double {
        guard !progresses.isEmpty else { return 0 }
        return progresses.reduce(0, +) / Double(progresses.count)
    }
    private var totalSpeed: Double {
        group.items.reduce(0.0) { $0 + dm.displaySpeed(for: $1.url) }
    }
    private var pausedCount: Int { group.items.filter { dm.isPaused[$0.url] == true }.count }
    private var queuedCount: Int { group.items.filter { dm.isQueued[$0.url] == true }.count }
    private var allPaused: Bool { pausedCount == group.items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                coverThumb
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.seriesTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(isGlobalEnglishMode ? "\(group.items.count) episodes"
                                                 : "\(group.items.count) 集")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                        if queuedCount > 0 {
                            Text(isGlobalEnglishMode ? "\(queuedCount) queued" : "\(queuedCount) 排队")
                                .font(.system(size: 11)).foregroundColor(.blue)
                        }
                        if pausedCount > 0 {
                            Text(isGlobalEnglishMode ? "\(pausedCount) paused" : "\(pausedCount) 暂停")
                                .font(.system(size: 11)).foregroundColor(.orange)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("\(Int(avgProgress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        if totalSpeed > 0 {
                            Text(formatSpeed(totalSpeed))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.secondary.opacity(0.10)))
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: [Color.blue, Color.accentColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(avgProgress)), height: 6)
                        .animation(.easeOut(duration: 0.4), value: avgProgress)
                }
            }
            .frame(height: 6)

            HStack(spacing: 10) {
                Button {
                    if allPaused {
                        if !network.isWiFi { showCellularAlert = true }
                        else { resumeAll() }
                    } else {
                        for it in group.items { dm.pauseDownload(urlString: it.url) }
                    }
                } label: {
                    Label(allPaused ? (isGlobalEnglishMode ? "Resume All" : "全部继续")
                                    : (isGlobalEnglishMode ? "Pause All" : "全部暂停"),
                          systemImage: allPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(LinearGradient(
                            colors: allPaused ? [Color.green, Color.green.opacity(0.7)]
                                              : [Color.orange, Color.orange.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(BorderlessButtonStyle())
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Resume Anyway" : "允许并继续") { resumeAll() }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Resume downloading anyway?"
                 : "当前处于蜂窝网络，继续下载将消耗流量，是否继续？")
        }
    }

    private func resumeAll() {
        for it in group.items where dm.isPaused[it.url] == true {
            dm.resumeDownload(urlString: it.url)
        }
    }

    @ViewBuilder
    private var coverThumb: some View {
        if let name = group.coverImage, !name.isEmpty,
           let coverURL = OVideoAPI.coverURL(for: name) {
            CachedAsyncImage(url: coverURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 46, height: 64).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.5), .blue.opacity(0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "rectangle.stack.fill").foregroundColor(.white)
            }
            .frame(width: 46, height: 64)
        }
    }
}

// MARK: - ⭐ 下载中：组内单集行
struct DownloadingEpisodeRow: View {
    let url: String
    let name: String

    @ObservedObject private var dm = HLSDownloadManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var showCellularAlert = false
    @State private var showCancelAlert = false

    var body: some View {
        let progress = dm.displayedProgress(for: url)
        let paused   = dm.isPaused[url] ?? false
        let queued   = dm.isQueued[url] ?? false
        let speed    = dm.displaySpeed(for: url)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 4)
                        Capsule()
                            .fill(paused ? Color.orange : (queued ? Color.blue.opacity(0.5) : Color.accentColor))
                            .frame(width: max(4, geo.size.width * CGFloat(progress)), height: 4)
                            .animation(.easeOut(duration: 0.4), value: progress)
                    }
                }
                .frame(height: 4)
                Text(queued ? (isGlobalEnglishMode ? "Queued" : "排队中")
                     : paused ? (isGlobalEnglishMode ? "Paused" : "已暂停")
                     : (speed > 0 ? formatSpeed(speed)
                                  : (isGlobalEnglishMode ? "Caching..." : "数据下载中...")))
                    .font(.system(size: 10, design: speed > 0 ? .monospaced : .default))
                    .foregroundColor(queued ? .blue : (paused ? .orange : .secondary))
            }

            Button {
                if paused {
                    if !network.isWiFi { showCellularAlert = true }
                    else { dm.resumeDownload(urlString: url) }
                } else {
                    dm.pauseDownload(urlString: url)
                }
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(paused ? Color.green : Color.orange))
            }
            .buttonStyle(BorderlessButtonStyle())

            Button { showCancelAlert = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.red.opacity(0.12)))
            }
            .buttonStyle(BorderlessButtonStyle())
            .alert(isGlobalEnglishMode ? "Cancel Download" : "取消下载",
                   isPresented: $showCancelAlert) {
                Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                Button(isGlobalEnglishMode ? "Confirm" : "确定", role: .destructive) {
                    dm.deleteDownload(urlString: url)
                }
            } message: {
                Text(isGlobalEnglishMode
                     ? "Are you sure you want to cancel and clear all downloaded data?"
                     : "确定要取消下载并清除所有已下载的数据吗？")
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.tertiarySystemGroupedBackground))
        )
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Resume Anyway" : "允许并继续") {
                dm.resumeDownload(urlString: url)
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Resume downloading anyway?"
                 : "当前处于蜂窝网络，继续下载将消耗流量，是否继续？")
        }
    }
}

// MARK: - 下载中卡片（单集 / 电影）
struct DownloadingCard: View {
    let realURL: String
    let title: String
    @ObservedObject private var dm = HLSDownloadManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var showCancelAlert = false
    @State private var showCellularAlert = false
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false

    var body: some View {
        let progress = dm.displayedProgress(for: realURL)
        let paused   = dm.isPaused[realURL] ?? false
        let queued   = dm.isQueued[realURL] ?? false

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.blue.opacity(0.8), .accentColor.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: queued ? "hourglass" : (paused ? "pause.fill" : "arrow.down"))
                        .font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Text("·").foregroundColor(.secondary)
                        if queued {
                            Text(isGlobalEnglishMode ? "Queued" : "排队中")
                                .font(.system(size: 12)).foregroundColor(.blue)
                        } else if paused {
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
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }

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

            HStack(spacing: 10) {
                Button {
                    if paused {
                        if !network.isWiFi { showCellularAlert = true }
                        else { dm.resumeDownload(urlString: realURL) }
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
                        .background(Capsule().fill(LinearGradient(
                            colors: paused ? [Color.green, Color.green.opacity(0.7)]
                                           : [Color.orange, Color.orange.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(BorderlessButtonStyle())

                Button { showCancelAlert = true } label: {
                    Label(isGlobalEnglishMode ? "Cancel" : "取消", systemImage: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(BorderlessButtonStyle())
                .alert(isGlobalEnglishMode ? "Cancel Download" : "取消下载",
                       isPresented: $showCancelAlert) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Confirm" : "确定", role: .destructive) {
                        dm.deleteDownload(urlString: realURL)
                    }
                } message: {
                    Text(isGlobalEnglishMode
                         ? "Are you sure you want to cancel and clear all downloaded data?"
                         : "确定要取消下载并清除所有已下载的数据吗？")
                }
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
            Button(isGlobalEnglishMode ? "Resume Anyway" : "允许并继续") {
                dm.resumeDownload(urlString: realURL)
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Resume downloading anyway?"
                 : "当前处于蜂窝网络，继续下载将消耗流量，是否继续？")
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
}

// MARK: - 已下载条目卡片
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
                    .foregroundColor(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundColor(.secondary)
                    Text(formattedDate(meta.savedAt)).foregroundColor(.secondary)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
            .frame(width: 60, height: 84).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.5), .blue.opacity(0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "film").foregroundColor(.white)
            }
            .frame(width: 60, height: 84)
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - 观看记录全屏界面
struct VideoPlayHistoryView: View {
    @StateObject private var recordManager = VideoPlayRecordManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false
    @State private var showLoginAlert = false

    @State private var playRecord: VideoPlayRecord? = nil
    @State private var navigateToPlayer = false
    @State private var pendingRecord: VideoPlayRecord? = nil
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var showQuotaExhausted = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemGroupedBackground), Color.accentColor.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            if recordManager.records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(recordManager.records) { record in
                        Button { attemptPlay(record) } label: { recordRow(record) }
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
                VideoPlayerPageView(episodeURL: r.videoURL,
                                    videoTitle: "\(r.videoTitle) · \(r.episodeName)",
                                    coverImage: r.coverImage, channelName: r.channelName,
                                    episodeName: r.episodeName, sourceURL: r.sourceURL)
            }
        }
        .toolbar {
            if !recordManager.records.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        withAnimation { recordManager.clearAll() }
                    } label: {
                        Text(isGlobalEnglishMode ? "Clear All" : "清空").foregroundColor(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .alert(isGlobalEnglishMode ? "Use Free Pass (\(consumeRemaining) left)"
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
                 ? "You've used all your free passes for today."
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

    private func attemptPlay(_ record: VideoPlayRecord) {
        switch decideVideoAccess(episodeKey: record.videoURL, auth: authManager, quota: quotaManager) {
        case .allowed:
            playRecord = record; navigateToPlayer = true
        case .needLogin:
            showLoginAlert = true
        case .needConsume(let r):
            pendingRecord = record; consumeRemaining = r; showConsumeConfirm = true
        case .exhausted:
            showQuotaExhausted = true
        }
    }

    private func consumeAndPlay() async {
        guard let record = pendingRecord else { return }
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let result = await quotaManager.unlock(userId: uid, episodeKey: record.videoURL,
                                               videoTitle: "\(record.videoTitle) · \(record.episodeName)")
        switch result {
        case .success, .alreadyUnlocked:
            playRecord = record; navigateToPlayer = true
        case .quotaExceeded, .failed:
            showQuotaExhausted = true
        }
        pendingRecord = nil
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.08)).frame(width: 90, height: 90)
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 38, weight: .light)).foregroundColor(.secondary)
            }
            Text(isGlobalEnglishMode ? "No history records" : "暂无观看记录")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary)
        }
    }

    private func recordRow(_ record: VideoPlayRecord) -> some View {
        HStack(spacing: 12) {
            coverThumb(name: record.coverImage)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.videoTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.episodeName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1)).cornerRadius(4)
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(formattedDate(record.playTime))
                }
                .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.system(size: 24)).foregroundColor(.accentColor.opacity(0.8))
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
            .frame(width: 45, height: 63).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
                Image(systemName: "film").foregroundColor(.accentColor).font(.caption)
            }
            .frame(width: 45, height: 63)
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }
}

// MARK: - 已下载剧集分组卡片
struct CachedSeriesCard: View {
    let group: CachedSeriesGroup
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        HStack(spacing: 12) {
            coverThumb(name: group.coverImage)
            VStack(alignment: .leading, spacing: 6) {
                Text(group.seriesTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundColor(.accentColor)
                    Text(isGlobalEnglishMode ? "\(group.episodes.count) episodes cached"
                                             : "已下载 \(group.episodes.count) 集")
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
            .frame(width: 60, height: 84).clipped()
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

// MARK: - 已下载剧集详情
struct CachedSeriesDetailView: View {
    let groupKey: String
    let seriesTitle: String
    let coverImage: String?
    @ObservedObject private var dm = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true

    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false

    @State private var cachedPlayTarget: CachedPlayTarget? = nil
    @State private var navigateToCachedPlayer = false

    @State private var isLoadingMore = false
    @State private var downloadMorePayload: DownloadMorePayload? = nil
    @State private var showNoSourceAlert = false

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

    private func makeEpisodeItems(_ eps: [(url: String, meta: VideoCacheMetadata)]) -> [VideoEpisodeItem] {
        eps.enumerated().map { index, item in
            let name = item.meta.episodeName ?? item.meta.title
            let digits = name.filter { $0.isNumber }
            let number = (!digits.isEmpty && digits.count <= 4 && Int(digits) != nil)
                ? digits : String(index + 1)
            return VideoEpisodeItem(number: number, name: name, url: item.url)
        }
    }

    private var seriesSourceURL: String? { episodes.compactMap { $0.meta.sourceURL }.first }

    var body: some View {
        let eps = episodes
        let epItems = makeEpisodeItems(eps)
        let src = eps.compactMap { $0.meta.sourceURL }.first

        ZStack {
            LinearGradient(colors: [Color(.systemGroupedBackground), Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            List {
                ForEach(Array(eps.enumerated()), id: \.element.url) { index, row in
                    Button {
                        cachedPlayTarget = CachedPlayTarget(
                            primaryURL: row.url, title: seriesTitle,
                            episodeName: row.meta.episodeName,
                            episodes: epItems, sourceURL: src)
                        navigateToCachedPlayer = true
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
                        }.tint(.red)
                    }
                }

                Section {
                    downloadMoreButton
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 20, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(PlainListStyle())
            .background(Color.clear)
        }
        .navigationTitle(seriesTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToCachedPlayer) {
            if let t = cachedPlayTarget {
                CachedVideoPlayerView(realURL: t.primaryURL, title: t.title,
                                      episodeName: t.episodeName, sourceURL: t.sourceURL,
                                      episodes: t.episodes)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .sheet(item: $downloadMorePayload) { payload in
            BatchDownloadView(item: payload.item, channel: payload.channel,
                              channelDisplayName: isGlobalEnglishMode ? "Line 1" : "线路 1",
                              isAscending: isEpisodeAscending, onStartDownloads: {})
                .environmentObject(authManager)
        }
        .alert(isGlobalEnglishMode ? "Unavailable" : "暂不可用", isPresented: $showNoSourceAlert) {
            Button(isGlobalEnglishMode ? "OK" : "好的", role: .cancel) {}
        } message: {
            Text(isGlobalEnglishMode
                 ? "Can't fetch more episodes for this older cache."
                 : "该下载较早，无法获取更多剧集信息。请从视频详情页重新进入以下载更多。")
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }

    private var downloadMoreButton: some View {
        Button { startDownloadMore() } label: {
            HStack(spacing: 10) {
                if isLoadingMore { ProgressView().tint(.white) }
                else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(isGlobalEnglishMode ? "Download More Episodes" : "下载更多")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Capsule().fill(LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                startPoint: .leading, endPoint: .trailing)))
            .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isLoadingMore)
    }

    private func startDownloadMore() {
        guard let src = seriesSourceURL, !src.isEmpty else { showNoSourceAlert = true; return }
        isLoadingMore = true
        Task {
            let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
            let best = optimalSortedChannels(channels).first
            await MainActor.run {
                isLoadingMore = false
                if let best = best {
                    let fakeItem = OVideoItem(seriesName: seriesTitle, sourceURL: src, cover: coverImage)
                    downloadMorePayload = DownloadMorePayload(item: fakeItem, channel: best)
                } else { showNoSourceAlert = true }
            }
        }
    }

    private func episodeRow(index: Int, meta: VideoCacheMetadata) -> some View {
        let displayEpisodeName: String = {
            if let epName = meta.episodeName, !epName.isEmpty { return epName }
            if meta.title.contains(" · ") {
                let comps = meta.title.components(separatedBy: " · ")
                if let last = comps.last, !last.isEmpty { return last }
            }
            return meta.title
        }()

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: "play.fill").foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(displayEpisodeName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary).lineLimit(1)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}