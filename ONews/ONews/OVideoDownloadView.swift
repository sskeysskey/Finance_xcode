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

import Foundation
import AVFoundation
import UIKit

// =====================================================================
// MARK: - 下载管理器（v4：热身闸门 + 龟速看门狗 + 自动"删包重建" + delegate 离开主线程）
//   相比 v3 的关键变化：
//   1. 任何时刻只允许 1 个任务处于"冷启动热身期" → 不再出现 3 个任务同时抢连接池
//   2. 新增「龟速看门狗」：字节在动但长期爬不动 → 判定连接/CDN 边缘坏了 → 自动重建
//   3. 热身超时(40s) → 丢弃局部包、用远端 URL 全新重建（= 自动执行"删除再下载"）
//   4. 局部包续传设 8% 门槛：太小的局部包没有续传价值，反而拖慢启动
//   5. delegateQueue 改为专用串行队列；didLoad 只写 inbox，主线程每秒合并发布
//   6. 全网都慢 → 判定为网络问题，绝不重建（避免网差时无限重启）
// =====================================================================
final class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {

    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!

    // MARK: - 对外发布状态（签名与旧版完全一致，UI 无需修改）
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadSpeed:    [String: Double] = [:]
    @Published var isPaused:         [String: Bool]   = [:]
    @Published var isQueued:         [String: Bool]   = [:]
    @Published var localBookmarks:   [String: Data]   = [:]
    @Published var cacheMetadata:    [String: VideoCacheMetadata] = [:]

    // =============================================================
    // MARK: - 可调参数（想调行为只改这里）
    // =============================================================
    /// HLS 单任务内部已经是多连接并行，2 个并发的总吞吐通常优于 3 个
    private let maxConcurrent = 2
    /// 两个任务启动之间的最小间隔
    private let minStartGap: TimeInterval = 3.0

    // —— 热身闸门 ——
    private let warmupProgressTarget: Double  = 0.02            // 进度到 2% 视为起速
    private let warmupBytesTarget: Int64      = 3 * 1024 * 1024 // 或者收到 3MB
    private let warmupSpeedTarget: Double     = 250 * 1024      // 或者速度到 250KB/s
    private let warmupTimeout: TimeInterval   = 40              // 40s 还没起速 → 全新重建
    private let maxWarmupRestarts             = 3

    // —— 龟速看门狗 ——
    private let slowWindow: TimeInterval      = 60              // 评估窗口
    private let slowProgressGain: Double      = 0.02            // 一分钟涨不到 2%
    private let slowSpeedFloor: Double        = 120 * 1024       // 且平均速度 < 120KB/s
    private let maxSlowRestarts               = 3
    private let slowRestartCooldown: TimeInterval = 90

    // —— 完全停滞看门狗 ——
    private let stallTimeout: TimeInterval    = 90
    private let maxStallRestarts              = 3

    // —— 续传策略 ——
    /// 进度低于该值时，局部包没有续传价值，直接丢弃从零开始（这才是"删除重下就飞"的原理）
    private let partialResumeMinProgress: Double = 0.08
    /// suspend 超过这么久，resume 大概率残废，直接重建
    private let suspendRebuildThreshold: TimeInterval = 120

    // =============================================================
    // MARK: - 调度状态
    // =============================================================
    private var activeTasks:  [String: AVAssetDownloadTask] = [:]
    private var runningUrls:  Set<String> = []
    private var waitingQueue: [String] = []
    private var userPausedUrls: Set<String> = []
    private var orderSeq: [String: Int] = [:]
    private var seqCounter = 0
    private var cooldownUntil: [String: Date] = [:]

    // 热身闸门
    private var warmingUp: String?
    private var warmupStartedAt: [String: Date] = [:]
    private var warmupRestarts:  [String: Int]  = [:]
    private var nextStartAllowedAt = Date.distantPast
    private var gateRetryScheduled = false

    // 龟速统计
    private var slowWindowStart: [String: (at: Date, progress: Double, bytes: Int64)] = [:]
    private var slowRestarts: [String: Int] = [:]
    private var lastSlowRestartAt: [String: Date] = [:]

    // 续传 / 重试
    private var pendingBookmarks: [String: Data] = [:]
    private var resumedFromPartial: Set<String> = []
    private var partialResumeFailures: [String: Int] = [:]
    private var forceFreshStart: Set<String> = []      // 下次建任务强制从零
    private var retryCounts:   [String: Int] = [:]
    private var stallRestarts: [String: Int] = [:]
    private var suspendedAt:   [String: Date] = [:]

    // 进度
    private var accurateProgress: [String: Double] = [:]

    // 测速
    private var lastBytes:     [String: Int64]  = [:]
    private var lastSampleAt:  [String: Date]   = [:]
    private var speedEMA:      [String: Double] = [:]
    private var lastNonZeroAt: [String: Date]   = [:]
    private var lastAdvanceAt: [String: Date]   = [:]

    // MARK: - delegate 线程 ↔ 主线程 之间的进度信箱（加锁）
    private let inboxLock = NSLock()
    private var inboxProgress:  [String: Double] = [:]
    private var currentTaskIDs: [String: Int]    = [:]   // url -> 当前有效 taskIdentifier

    // MARK: - 持久化 key（与旧版一致，老数据无缝读取）
    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    private let metadataKey  = "ONews_VideoCacheMetadata"
    private let progressKey  = "ONews_DownloadProgress"
    private let pausedKey    = "ONews_DownloadPaused"
    private let pendingKey   = "ONews_PendingHLSBookmarks"

    private var speedTimer: Timer?
    private var tickCount = 0
    private var lastPersistAt = Date.distantPast
    private var reconcileScheduled = false

    var backgroundCompletionHandler: (() -> Void)?

    // =================================================================
    // MARK: - init
    // =================================================================
    override init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false                 // 别让系统"择机"慢慢下
        config.shouldUseExtendedBackgroundIdleMode = true  // 后台/锁屏时尽量保持 socket
        config.timeoutIntervalForRequest  = 30        // ⭐ 分片请求 30s 无数据 → 踢掉重连（治"挂死连接"）
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 6      // 给分片取回留足并发（AVFoundation 可能忽略，无害）
        config.networkServiceType = .responsiveData   // 后台 session 上标成"数据优先"，避免被当低优先级流量
        config.allowsCellularAccess = true            // 蜂窝由 NetworkMonitor 在上层控制

        // ⭐ delegate 不再放主线程：serial queue，避免主线程忙时反压下载流水线
        let dq = OperationQueue()
        dq.maxConcurrentOperationCount = 1
        dq.qualityOfService = .utility
        dq.name = "com.miniplayer.hlsdownload.delegate"

        downloadSession = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: dq
        )

        loadBookmarks()
        loadMetadata()
        loadPendingBookmarks()
        loadPersistedProgress()
        purgeOrphanPendingPackages()
        handleColdLaunchRecovery()
        startTimer()
        observeNetwork()
        observeAppLifecycle()
    }

    // =================================================================
    // MARK: - 小工具
    // =================================================================
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
    private func nextSeq() -> Int { seqCounter += 1; return seqCounter }

    private func setCurrentTaskID(_ url: String, _ id: Int) {
        inboxLock.lock(); currentTaskIDs[url] = id; inboxLock.unlock()
    }
    private func clearCurrentTaskID(_ url: String) {
        inboxLock.lock()
        currentTaskIDs.removeValue(forKey: url)
        inboxProgress.removeValue(forKey: url)
        inboxLock.unlock()
    }

    private func markAdvance(_ url: String, bytes: Int64) {
        let now = Date()
        lastBytes[url]     = bytes
        lastSampleAt[url]  = now
        lastAdvanceAt[url] = now
        lastNonZeroAt.removeValue(forKey: url)
        speedEMA[url] = 0
        slowWindowStart[url] = (now, accurateProgress[url] ?? 0, bytes)
        if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
    }

    private func clearSpeedState(_ url: String) {
        lastBytes.removeValue(forKey: url)
        lastSampleAt.removeValue(forKey: url)
        lastNonZeroAt.removeValue(forKey: url)
        lastAdvanceAt.removeValue(forKey: url)
        slowWindowStart.removeValue(forKey: url)
        speedEMA[url] = 0
        if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
    }

    // =================================================================
    // MARK: - 热身闸门
    // =================================================================
    private func beginWarmup(_ url: String) {
        warmingUp = url
        warmupStartedAt[url] = Date()
        nextStartAllowedAt = Date().addingTimeInterval(minStartGap)
    }

    private func clearWarmup(_ url: String) {
        if warmingUp == url { warmingUp = nil }
        warmupStartedAt.removeValue(forKey: url)
    }

    private func markWarmedUp(_ url: String) {
        guard warmingUp == url else { return }
        clearWarmup(url)
        print("🔥 已起速，放行下一个任务: \(cacheMetadata[url]?.title ?? url)")
        scheduleReconcile()
    }

    /// 热身超时 → 认定这条连接/边缘节点没救了，丢局部包全新重建
    private func checkWarmupTimeout() {
        guard let url = warmingUp else { return }
        guard let startedAt = warmupStartedAt[url] else { clearWarmup(url); return }

        guard let task = activeTasks[url],
              isPaused[url] != true,
              localBookmarks[url] == nil,
              downloadProgress[url] != nil,
              task.state == .running else {
            clearWarmup(url); return
        }
        guard Date().timeIntervalSince(startedAt) >= warmupTimeout else { return }

        let n = warmupRestarts[url] ?? 0
        guard n < maxWarmupRestarts else {
            print("⚠️ 热身重建已达上限，放行闸门让它慢慢下: \(url)")
            clearWarmup(url)
            scheduleReconcile()
            return
        }
        warmupRestarts[url] = n + 1
        print("🐌 冷启动 \(Int(warmupTimeout))s 未起速 → 丢弃局部包全新重建（第 \(n + 1) 次）: \(url)")
        restartTask(url, fresh: true, cooldown: 2.5)
    }

    // =================================================================
    // MARK: - 统一的"重建任务"入口
    // =================================================================
    /// - Parameter fresh: true = 丢弃局部包从零；false = 走局部包续传
    private func restartTask(_ url: String, fresh: Bool, cooldown: TimeInterval) {
        if let task = activeTasks.removeValue(forKey: url) {
            clearCurrentTaskID(url)
            task.cancel()
        }
        runningUrls.remove(url)
        clearSpeedState(url)
        clearWarmup(url)
        suspendedAt.removeValue(forKey: url)
        if fresh { forceFreshStart.insert(url) }

        lastAdvanceAt[url] = Date()
        isPaused[url] = false
        isQueued[url] = true
        waitingQueue.removeAll { $0 == url }
        waitingQueue.insert(url, at: 0)                       // 优先级最高
        cooldownUntil[url] = Date().addingTimeInterval(cooldown) // 等旧任务彻底释放局部包

        DispatchQueue.main.asyncAfter(deadline: .now() + cooldown + 0.3) { [weak self] in
            self?.scheduleReconcile()
        }
    }

    // =================================================================
    // MARK: - 调度：对账 + 补位
    // =================================================================
    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    private func scheduleGateRetry() {
        guard !gateRetryScheduled else { return }
        gateRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.gateRetryScheduled = false
            self.reconcile()
        }
    }

    private func reconcile() {
        // 0) 热身闸门自检：别被死任务卡住
        if let w = warmingUp {
            let valid = activeTasks[w] != nil
                && downloadProgress[w] != nil
                && localBookmarks[w] == nil
                && isPaused[w] != true
                && runningUrls.contains(w)
            if !valid { clearWarmup(w) }
        }

        // 1) 清理无效 / 已死任务
        for url in Array(activeTasks.keys) {
            guard let task = activeTasks[url] else { continue }
            let stillNeeded = (downloadProgress[url] != nil) && (localBookmarks[url] == nil)
            if !stillNeeded {
                activeTasks.removeValue(forKey: url)
                runningUrls.remove(url)
                clearCurrentTaskID(url)
                clearWarmup(url)
                task.cancel()
                continue
            }
            if task.state == .completed || task.state == .canceling {
                activeTasks.removeValue(forKey: url)
                runningUrls.remove(url)
                clearCurrentTaskID(url)
                clearWarmup(url)
            }
        }

        // 2) 已暂停的：挂起并让出名额
        for url in Array(activeTasks.keys) where isPaused[url] == true {
            if let t = activeTasks[url], t.state == .running {
                t.suspend()
                suspendedAt[url] = Date()
            }
            runningUrls.remove(url)
            clearWarmup(url)
            if isQueued[url] == true { isQueued[url] = false }
            if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
        }

        // 3) runningUrls 只保留仍然有效的
        runningUrls = runningUrls.filter { url in
            guard let t = activeTasks[url],
                  localBookmarks[url] == nil,
                  isPaused[url] != true,
                  t.state != .completed, t.state != .canceling else { return false }
            if t.state == .suspended { t.resume(); suspendedAt.removeValue(forKey: url) }
            return true
        }
        for (url, t) in activeTasks
        where t.state == .running && isPaused[url] != true && localBookmarks[url] == nil {
            runningUrls.insert(url)
        }

        // 4) 重建等待队列
        let desired = Set(downloadProgress.keys.filter {
            localBookmarks[$0] == nil && isPaused[$0] != true
        })
        var seen = Set<String>()
        waitingQueue = waitingQueue.filter { url in
            guard desired.contains(url), !runningUrls.contains(url) else { return false }
            return seen.insert(url).inserted
        }
        let missing = desired.subtracting(runningUrls).subtracting(waitingQueue)
        if !missing.isEmpty {
            waitingQueue.append(contentsOf: missing.sorted {
                (orderSeq[$0] ?? Int.max, $0) < (orderSeq[$1] ?? Int.max, $1)
            })
        }

        // 5) ⭐ 补位：一次只放行一个 + 热身闸门 + 最小间隔（核心修复）
        var deferred: [String] = []
        let now = Date()
        var startedOne = false
        var safety = 0
        while runningUrls.count < maxConcurrent, !waitingQueue.isEmpty, !startedOne, safety < 128 {
            safety += 1
            if warmingUp != nil { scheduleGateRetry(); break }        // 上一个还没起速，先别添乱
            if now < nextStartAllowedAt { scheduleGateRetry(); break } // 启动间隔
            let next = waitingQueue.removeFirst()
            if let until = cooldownUntil[next], until > now {
                deferred.append(next)
                continue
            }
            cooldownUntil.removeValue(forKey: next)
            startOrResume(next)
            startedOne = true
        }
        if !deferred.isEmpty {
            waitingQueue.insert(contentsOf: deferred, at: 0)
            scheduleGateRetry()
        }

        // 6) 同步 UI 标记
        let queuedSet = Set(waitingQueue)
        for url in downloadProgress.keys where localBookmarks[url] == nil {
            let q = queuedSet.contains(url)
            if (isQueued[url] ?? false) != q { isQueued[url] = q }
            if runningUrls.contains(url), isPaused[url] == true { isPaused[url] = false }
            if !runningUrls.contains(url), (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
        }
        for url in Array(isQueued.keys)
        where downloadProgress[url] == nil || localBookmarks[url] != nil {
            isQueued.removeValue(forKey: url)
        }

        updateIdleTimer()
    }

    private func startOrResume(_ url: String) {
        guard downloadProgress[url] != nil,
              localBookmarks[url] == nil,
              isPaused[url] != true else {
            isQueued[url] = false
            return
        }

        if let task = activeTasks[url] {
            switch task.state {
            case .suspended:
                // ⭐ 挂起太久的任务 resume 出来大概率残废/龟速，直接重建
                if let s = suspendedAt[url], Date().timeIntervalSince(s) > suspendRebuildThreshold {
                    let fresh = (accurateProgress[url] ?? 0) < partialResumeMinProgress
                    print("♻️ 挂起超过 \(Int(suspendRebuildThreshold))s，重建任务（fresh=\(fresh)）: \(url)")
                    restartTask(url, fresh: fresh, cooldown: 1.5)
                    return
                }
                task.resume()
                suspendedAt.removeValue(forKey: url)
                runningUrls.insert(url)
                isPaused[url] = false
                isQueued[url] = false
                markAdvance(url, bytes: task.countOfBytesReceived)
                beginWarmup(url)                    // resume 也要重新起速
                return
            case .running:
                runningUrls.insert(url)
                isQueued[url] = false
                return
            default:
                activeTasks.removeValue(forKey: url)
                clearCurrentTaskID(url)
                task.cancel()
            }
        }
        beginTask(for: url)
    }

    private func beginTask(for urlString: String) {
        guard downloadProgress[urlString] != nil,
              localBookmarks[urlString] == nil,
              isPaused[urlString] != true else { return }

        guard let task = makeTask(for: urlString) else {
            runningUrls.remove(urlString)
            clearWarmup(urlString)
            scheduleAutoRetry(urlString)
            return
        }

        task.taskDescription = urlString
        activeTasks[urlString] = task
        setCurrentTaskID(urlString, task.taskIdentifier)   // 必须在 resume 之前
        runningUrls.insert(urlString)
        isPaused[urlString] = false
        isQueued[urlString] = false
        suspendedAt.removeValue(forKey: urlString)
        markAdvance(urlString, bytes: 0)
        beginWarmup(urlString)
        task.resume()
        savePersistedProgressIfNeeded()
    }

    /// HLS 断点续传：**只有局部包够大才值得续传**，否则从零（这才是"删掉重下就飞"的原理）
    private func makeTask(for urlString: String) -> AVAssetDownloadTask? {
        let title = cacheMetadata[urlString]?.title ?? urlString
        let progress = accurateProgress[urlString] ?? downloadProgress[urlString] ?? 0

        let wantFresh = forceFreshStart.contains(urlString) || progress < partialResumeMinProgress
        forceFreshStart.remove(urlString)

        // ① 值得续传：用本地局部包
        if !wantFresh,
           (partialResumeFailures[urlString] ?? 0) < 2,
           let partial = getPendingLocalURL(for: urlString),
           FileManager.default.fileExists(atPath: partial.path) {
            let localAsset = AVURLAsset(url: partial)
            if let t = downloadSession.makeAssetDownloadTask(
                asset: localAsset, assetTitle: title, assetArtworkData: nil, options: nil
            ) {
                resumedFromPartial.insert(urlString)
                print("♻️ 从本地局部包续传: \(title) \(Int(progress * 100))%")
                return t
            }
        }

        // ② 从零：清掉垃圾局部包，进度诚实归零
        resumedFromPartial.remove(urlString)
        if pendingBookmarks[urlString] != nil { purgeStalePartial(for: urlString) }
        accurateProgress[urlString] = 0
        if (downloadProgress[urlString] ?? 0) != 0 { downloadProgress[urlString] = 0 }

        guard let remote = URL(string: urlString) else { return nil }
        print("🆕 全新任务（新连接/新 CDN 边缘）: \(title)")
        // 想强制画质可在此加 options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: NSNumber(value: 2_000_000)]
        return downloadSession.makeAssetDownloadTask(
            asset: AVURLAsset(url: remote), assetTitle: title,
            assetArtworkData: nil, options: nil
        )
    }

    // =================================================================
    // MARK: - 冷启动恢复
    // =================================================================
    private func handleColdLaunchRecovery() {
        for url in downloadProgress.keys.sorted() where localBookmarks[url] == nil {
            if orderSeq[url] == nil { orderSeq[url] = nextSeq() }
            if isPaused[url] == true { userPausedUrls.insert(url) }
            if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
            isQueued[url] = false
        }

        downloadSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.onMain {
                for task in tasks {
                    guard let dl = task as? AVAssetDownloadTask,
                          let url = dl.taskDescription else {
                        task.cancel(); continue
                    }
                    if dl.state == .completed || dl.state == .canceling { continue }
                    guard self.downloadProgress[url] != nil,
                          self.localBookmarks[url] == nil else {
                        dl.cancel(); continue
                    }
                    if let cur = self.activeTasks[url], cur !== dl { dl.cancel(); continue }

                    self.activeTasks[url] = dl
                    self.setCurrentTaskID(url, dl.taskIdentifier)
                    self.markAdvance(url, bytes: dl.countOfBytesReceived)
                    if dl.state == .running, self.userPausedUrls.contains(url) {
                        dl.suspend()
                        self.suspendedAt[url] = Date()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.autoResumeAfterColdLaunch()
                }
                self.reconcile()
            }
        }
    }

    private func autoResumeAfterColdLaunch() {
        let onCellular = NetworkMonitor.shared.isConnected && !NetworkMonitor.shared.isWiFi
        let candidates = downloadProgress.keys
            .filter { localBookmarks[$0] == nil && !userPausedUrls.contains($0) }
            .sorted { (orderSeq[$0] ?? Int.max, $0) < (orderSeq[$1] ?? Int.max, $1) }

        for url in candidates {
            if onCellular {
                isPaused[url] = true
                isQueued[url] = false
            } else {
                isPaused[url] = false
                if !runningUrls.contains(url), !waitingQueue.contains(url) {
                    waitingQueue.append(url)
                    isQueued[url] = true
                }
            }
        }
        savePersistedProgress()
        reconcile()
    }

    private func purgeOrphanPendingPackages() {
        for url in pendingBookmarks.keys
        where downloadProgress[url] == nil && localBookmarks[url] == nil {
            purgeStalePartial(for: url)
        }
    }

    // =================================================================
    // MARK: - 对外 API
    // =================================================================
    func startDownload(urlString: String, title: String, coverImage: String? = nil,
                       seriesTitle: String? = nil, episodeName: String? = nil,
                       episodeKey: String? = nil, sourceURL: String? = nil) {
        onMain {
            guard self.localBookmarks[urlString] == nil else { return }
            self.userPausedUrls.remove(urlString)
            self.retryCounts[urlString]    = 0
            self.stallRestarts[urlString]  = 0
            self.warmupRestarts[urlString] = 0
            self.slowRestarts[urlString]   = 0
            self.cooldownUntil.removeValue(forKey: urlString)

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
                self.accurateProgress[urlString] = 0.0
            }
            if self.orderSeq[urlString] == nil { self.orderSeq[urlString] = self.nextSeq() }

            self.isPaused[urlString]      = false
            self.downloadSpeed[urlString] = 0
            if !self.runningUrls.contains(urlString), !self.waitingQueue.contains(urlString) {
                self.waitingQueue.append(urlString)
                self.isQueued[urlString] = true
            }
            self.savePersistedProgress()
            self.scheduleReconcile()
        }
    }

    func pauseDownload(urlString: String, byUser: Bool = true) {
        onMain {
            if byUser { self.userPausedUrls.insert(urlString) }
            self.isPaused[urlString] = true
            self.isQueued[urlString] = false
            self.waitingQueue.removeAll { $0 == urlString }
            self.runningUrls.remove(urlString)
            self.clearWarmup(urlString)
            if let t = self.activeTasks[urlString], t.state == .running {
                t.suspend()
                self.suspendedAt[urlString] = Date()
            }
            self.clearSpeedState(urlString)
            self.savePersistedProgress()
            self.scheduleReconcile()
        }
    }

    func resumeDownload(urlString: String) {
        onMain {
            guard self.localBookmarks[urlString] == nil,
                  self.downloadProgress[urlString] != nil else { return }
            self.userPausedUrls.remove(urlString)
            self.retryCounts[urlString]    = 0
            self.stallRestarts[urlString]  = 0
            self.warmupRestarts[urlString] = 0
            self.slowRestarts[urlString]   = 0
            self.cooldownUntil.removeValue(forKey: urlString)
            self.isPaused[urlString] = false
            if self.orderSeq[urlString] == nil { self.orderSeq[urlString] = self.nextSeq() }
            if !self.runningUrls.contains(urlString), !self.waitingQueue.contains(urlString) {
                self.waitingQueue.append(urlString)
                self.isQueued[urlString] = true
            }
            self.savePersistedProgress()
            self.scheduleReconcile()
        }
    }

    func cancelDownload(urlString: String) { deleteDownload(urlString: urlString) }

    func deleteDownload(urlString: String) {
        onMain {
            self.userPausedUrls.remove(urlString)
            self.waitingQueue.removeAll { $0 == urlString }
            self.runningUrls.remove(urlString)
            self.clearWarmup(urlString)
            self.retryCounts.removeValue(forKey: urlString)
            self.stallRestarts.removeValue(forKey: urlString)
            self.warmupRestarts.removeValue(forKey: urlString)
            self.slowRestarts.removeValue(forKey: urlString)
            self.lastSlowRestartAt.removeValue(forKey: urlString)
            self.partialResumeFailures.removeValue(forKey: urlString)
            self.resumedFromPartial.remove(urlString)
            self.forceFreshStart.remove(urlString)
            self.cooldownUntil.removeValue(forKey: urlString)
            self.suspendedAt.removeValue(forKey: urlString)
            self.orderSeq.removeValue(forKey: urlString)

            let task = self.activeTasks.removeValue(forKey: urlString)
            self.clearCurrentTaskID(urlString)
            task?.cancel()

            self.downloadSession.getAllTasks { tasks in
                DispatchQueue.main.async {
                    for t in tasks {
                        guard let dl = t as? AVAssetDownloadTask,
                              dl.taskDescription == urlString else { continue }
                        if let cur = self.activeTasks[urlString], cur === dl { continue }
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
            self.accurateProgress.removeValue(forKey: urlString)
            self.downloadSpeed.removeValue(forKey: urlString)
            self.isPaused.removeValue(forKey: urlString)
            self.isQueued.removeValue(forKey: urlString)
            self.clearSpeedState(urlString)

            self.saveBookmarks()
            self.savePendingBookmarks()
            self.saveMetadata()
            self.savePersistedProgress()
            self.scheduleReconcile()
        }
    }

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
    // MARK: - 定时器
    // =================================================================
    private func startTimer() {
        speedTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(t, forMode: .common)
        speedTimer = t
    }

    private func onTick() {
        tickCount &+= 1
        drainProgressInbox()                              // 合并发布进度（每秒一次）
        sampleSpeed()                                     // 只读 countOfBytesReceived
        checkWarmupTimeout()                              // 冷启动起不来 → 全新重建
        checkStalls()                                     // 完全停滞 → 续传重建
        if tickCount % 5  == 0 { checkSlowCrawl() }        // 龟速判定
        if tickCount % 2  == 0 { reconcile() }            // 补位（配合热身闸门要更勤）
        if tickCount % 30 == 0 { auditSessionTasks() }
    }

    /// ⭐ 把 delegate 线程写进 inbox 的进度合并后发布（把主线程负担降一两个数量级）
    private func drainProgressInbox() {
        inboxLock.lock()
        let snapshot = inboxProgress
        inboxProgress.removeAll()
        inboxLock.unlock()
        guard !snapshot.isEmpty else { return }

        let now = Date()
        for (url, raw) in snapshot {
            guard downloadProgress[url] != nil, localBookmarks[url] == nil else { continue }
            let prev = accurateProgress[url] ?? 0
            let newP = max(prev, min(1.0, max(0.0, raw)))
            accurateProgress[url] = newP

            if newP > prev + 0.00001 {
                lastAdvanceAt[url]   = now
                retryCounts[url]     = 0
                stallRestarts[url]   = 0
            }

            let published = downloadProgress[url] ?? 0
            if Int(newP * 100) != Int(published * 100) || (newP >= 1.0 && published < 1.0) {
                downloadProgress[url] = newP
            }

            // 收编：任务确实在跑但没登记
            if let t = activeTasks[url], t.state == .running,
               isPaused[url] != true, !runningUrls.contains(url) {
                runningUrls.insert(url)
                waitingQueue.removeAll { $0 == url }
                if isQueued[url] == true { isQueued[url] = false }
            }
            if warmingUp == url, newP >= warmupProgressTarget { markWarmedUp(url) }
        }
        savePersistedProgressIfNeeded()
    }

    private func sampleSpeed() {
        let now = Date()
        for url in runningUrls {
            guard let task = activeTasks[url],
                  isPaused[url] != true,
                  localBookmarks[url] == nil else { continue }

            let bytesNow  = task.countOfBytesReceived
            let prevBytes = lastBytes[url] ?? bytesNow
            let prevAt    = lastSampleAt[url] ?? now
            let dt = now.timeIntervalSince(prevAt)
            guard dt >= 0.5 else { continue }

            let delta = max(0, bytesNow - prevBytes)
            let inst  = Double(delta) / dt
            let prevEMA = speedEMA[url] ?? 0
            let ema = prevEMA <= 0 ? inst : (prevEMA * 0.6 + inst * 0.4)
            speedEMA[url] = ema

            if delta > 0 {
                lastAdvanceAt[url] = now
                lastNonZeroAt[url] = now
                downloadSpeed[url] = ema
            } else if let last = lastNonZeroAt[url], now.timeIntervalSince(last) < 4 {
                downloadSpeed[url] = ema
            } else {
                speedEMA[url] = 0
                if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
            }

            lastBytes[url]    = bytesNow
            lastSampleAt[url] = now

            // 热身达标判定（字节量 / 瞬时速度）
            if warmingUp == url, bytesNow >= warmupBytesTarget || ema >= warmupSpeedTarget {
                markWarmedUp(url)
            }
        }
        for url in downloadProgress.keys where !runningUrls.contains(url) {
            if (downloadSpeed[url] ?? 0) != 0 { downloadSpeed[url] = 0 }
        }
    }

    /// ⭐⭐ 龟速看门狗：字节在动但爬不动 → 大概率连接/CDN 边缘坏了 → 重建（自动做"删除重下"）
    private func checkSlowCrawl() {
        let now = Date()
        var slowCandidates: [String] = []
        var eligibleCount = 0

        for url in Array(runningUrls) {
            guard let task = activeTasks[url],
                  task.state == .running,
                  isPaused[url] != true,
                  localBookmarks[url] == nil,
                  warmingUp != url else { continue }
            let prog = accurateProgress[url] ?? 0
            guard prog < 0.95 else { continue }
            eligibleCount += 1

            guard let w = slowWindowStart[url] else {
                slowWindowStart[url] = (now, prog, task.countOfBytesReceived)
                continue
            }
            let dt = now.timeIntervalSince(w.at)
            guard dt >= slowWindow else { continue }

            let gain     = prog - w.progress
            let avgSpeed = Double(max(0, task.countOfBytesReceived - w.bytes)) / dt
            slowWindowStart[url] = (now, prog, task.countOfBytesReceived)   // 滚动窗口

            if gain < slowProgressGain && avgSpeed < slowSpeedFloor {
                slowCandidates.append(url)
                print("🐌 龟速样本: \(cacheMetadata[url]?.title ?? url) 一分钟涨 \(String(format: "%.2f", gain * 100))%，均速 \(Int(avgSpeed / 1024))KB/s")
            }
        }

        guard !slowCandidates.isEmpty else { return }
        guard NetworkMonitor.shared.isConnected else { return }

        // 所有在跑的任务都慢 → 是网络/服务器整体慢，重建也没用，别折腾
        if eligibleCount >= 2, slowCandidates.count >= eligibleCount {
            print("🌐 全部任务都慢，判定为网络整体问题，不做重建")
            return
        }

        for url in slowCandidates {
            let n = slowRestarts[url] ?? 0
            guard n < maxSlowRestarts else { continue }
            if let last = lastSlowRestartAt[url], now.timeIntervalSince(last) < slowRestartCooldown { continue }
            slowRestarts[url] = n + 1
            lastSlowRestartAt[url] = now

            let prog  = accurateProgress[url] ?? 0
            let fresh = prog < partialResumeMinProgress
            print("♻️ 长期龟速，重建任务（\(fresh ? "丢弃局部包从零" : "局部包续传")，第 \(n + 1) 次）: \(url)")
            restartTask(url, fresh: fresh, cooldown: 2.5)
        }
    }

    /// 完全停滞看门狗
    private func checkStalls() {
        let now = Date()
        for url in Array(runningUrls) {
            guard let task = activeTasks[url],
                  isPaused[url] != true,
                  localBookmarks[url] == nil,
                  task.state == .running else { continue }

            guard let last = lastAdvanceAt[url] else {
                lastAdvanceAt[url] = now
                continue
            }
            guard now.timeIntervalSince(last) >= stallTimeout else { continue }

            let restarts = stallRestarts[url] ?? 0
            guard restarts < maxStallRestarts else {
                print("⛔️ 反复停滞，已暂停等待用户处理: \(url)")
                pauseDownload(urlString: url, byUser: false)
                continue
            }
            stallRestarts[url] = restarts + 1
            let prog  = accurateProgress[url] ?? 0
            let fresh = prog < partialResumeMinProgress
            print("🕒 停滞 \(Int(stallTimeout))s，重建任务（fresh=\(fresh)）: \(url)")
            restartTask(url, fresh: fresh, cooldown: 2.0)
        }
    }

    private func auditSessionTasks() {
        guard !activeTasks.isEmpty || !waitingQueue.isEmpty || !downloadProgress.isEmpty else { return }

        downloadSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.onMain {
                for task in tasks {
                    guard let dl = task as? AVAssetDownloadTask,
                          let url = dl.taskDescription else { continue }
                    if dl.state == .completed || dl.state == .canceling { continue }
                    guard self.downloadProgress[url] != nil,
                          self.localBookmarks[url] == nil else {
                        dl.cancel(); continue
                    }
                    if let cur = self.activeTasks[url] {
                        if cur !== dl { dl.cancel() }
                    } else {
                        self.activeTasks[url] = dl
                        self.setCurrentTaskID(url, dl.taskIdentifier)
                        self.markAdvance(url, bytes: dl.countOfBytesReceived)
                    }
                }
                for url in Array(self.activeTasks.keys) {
                    guard let t = self.activeTasks[url] else { continue }
                    if t.state == .completed || t.state == .canceling {
                        self.activeTasks.removeValue(forKey: url)
                        self.runningUrls.remove(url)
                        self.clearCurrentTaskID(url)
                        self.clearWarmup(url)
                    }
                }
                self.reconcile()
            }
        }
    }

    private func savePersistedProgressIfNeeded() {
        if Date().timeIntervalSince(lastPersistAt) > 3.0 {
            savePersistedProgress()
            lastPersistAt = Date()
        }
    }

    // =================================================================
    // MARK: - AVAssetDownloadDelegate（运行在专用串行队列，一律 hop 回主线程改状态）
    // =================================================================
    private func isCurrent(_ task: URLSessionTask, _ urlString: String) -> Bool {
        guard let cur = activeTasks[urlString] else { return false }
        return cur === task
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        onMain {
            guard self.isCurrent(assetDownloadTask, urlString) else { return }

            let oldPending = self.getPendingLocalURL(for: urlString)?.standardizedFileURL
            if let old = oldPending, old != location.standardizedFileURL {
                try? FileManager.default.removeItem(at: old)
                if self.resumedFromPartial.contains(urlString) {
                    self.partialResumeFailures[urlString] = (self.partialResumeFailures[urlString] ?? 0) + 1
                    print("⚠️ 局部包未被复用，本次从零开始: \(urlString)")
                }
                self.accurateProgress[urlString] = 0
                if (self.downloadProgress[urlString] ?? 0) != 0 { self.downloadProgress[urlString] = 0 }
            } else if oldPending != nil, self.resumedFromPartial.contains(urlString) {
                self.partialResumeFailures[urlString] = 0
            }

            if let bm = try? location.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) {
                self.pendingBookmarks[urlString] = bm
                self.savePendingBookmarks()
            }
            self.markAdvance(urlString, bytes: assetDownloadTask.countOfBytesReceived)
        }
    }

    /// ⭐ 高频回调：只做浮点计算 + 写加锁 inbox，不碰 @Published、不 dispatch 主线程
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite, expected > 0 else { return }

        var loaded = 0.0
        for value in loadedTimeRanges {
            let d = value.timeRangeValue.duration.seconds
            if d.isFinite, d > 0 { loaded += d }
        }
        let calculated = min(1.0, max(0.0, loaded / expected))
        let id = assetDownloadTask.taskIdentifier

        inboxLock.lock()
        if currentTaskIDs[urlString] == id {
            inboxProgress[urlString] = max(inboxProgress[urlString] ?? 0, calculated)
        }
        inboxLock.unlock()
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else {
            try? FileManager.default.removeItem(at: location); return
        }
        onMain {
            guard self.isCurrent(assetDownloadTask, urlString) else {
                let curPending = self.getPendingLocalURL(for: urlString)?.standardizedFileURL
                if curPending != location.standardizedFileURL,
                   self.downloadProgress[urlString] == nil || self.localBookmarks[urlString] != nil {
                    try? FileManager.default.removeItem(at: location)
                }
                return
            }
            if let bm = try? location.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) {
                self.pendingBookmarks[urlString] = bm
                self.savePendingBookmarks()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { onMain { self.scheduleReconcile() }; return }
        onMain {
            guard self.isCurrent(task, urlString) else { self.scheduleReconcile(); return }

            self.activeTasks.removeValue(forKey: urlString)
            self.runningUrls.remove(urlString)
            self.clearCurrentTaskID(urlString)
            self.clearWarmup(urlString)
            self.clearSpeedState(urlString)
            self.suspendedAt.removeValue(forKey: urlString)

            let progress = self.accurateProgress[urlString] ?? self.downloadProgress[urlString] ?? 0
            let pendingURL = self.getPendingLocalURL(for: urlString)
            let pendingExists = pendingURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let didTrulyFinish = (error == nil) && pendingExists && (progress >= 0.6)

            if didTrulyFinish {
                if let bookmark = self.pendingBookmarks[urlString] {
                    self.localBookmarks[urlString] = bookmark
                    self.saveBookmarks()
                }

                let storedUserId = UserDefaults.standard.string(forKey: "current_user_id")
                let identity: (userId: String, userType: String) = {
                    if let storedUserId, !storedUserId.isEmpty {
                        return (storedUserId, storedUserId.hasPrefix("dev_") ? "device" : "apple")
                    }
                    if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                        return ("dev_" + idfv, "device")
                    }
                    return ("guest_user", "device")
                }()
                let title = self.cacheMetadata[urlString]?.title ?? "Unknown Video"
                TrackingManager.shared.track(event: .downloadComplete,
                                             userId: identity.userId, userType: identity.userType,
                                             videoURL: urlString, videoTitle: title)

                self.pendingBookmarks.removeValue(forKey: urlString)
                self.savePendingBookmarks()

                self.downloadProgress.removeValue(forKey: urlString)
                self.accurateProgress.removeValue(forKey: urlString)
                self.downloadSpeed.removeValue(forKey: urlString)
                self.isPaused.removeValue(forKey: urlString)
                self.isQueued.removeValue(forKey: urlString)
                self.retryCounts.removeValue(forKey: urlString)
                self.stallRestarts.removeValue(forKey: urlString)
                self.warmupRestarts.removeValue(forKey: urlString)
                self.slowRestarts.removeValue(forKey: urlString)
                self.lastSlowRestartAt.removeValue(forKey: urlString)
                self.partialResumeFailures.removeValue(forKey: urlString)
                self.resumedFromPartial.remove(urlString)
                self.forceFreshStart.remove(urlString)
                self.cooldownUntil.removeValue(forKey: urlString)
                self.orderSeq.removeValue(forKey: urlString)
                self.waitingQueue.removeAll { $0 == urlString }
                print("✅ 下载完成: \(title)")

            } else {
                self.savePendingBookmarks()

                if error == nil, pendingExists {
                    self.partialResumeFailures[urlString] = (self.partialResumeFailures[urlString] ?? 0) + 1
                    print("⚠️ 任务无错误结束但进度仅 \(Int(progress * 100))%，将重试: \(urlString)")
                }
                if let error {
                    let ns = error as NSError
                    print("""
                    ⚠️ 下载中断: \(urlString)
                    domain=\(ns.domain) code=\(ns.code) progress=\(progress)
                    \(ns.localizedDescription)
                    """)
                }

                if self.userPausedUrls.contains(urlString) {
                    self.isPaused[urlString] = true
                    self.isQueued[urlString] = false
                } else {
                    self.scheduleAutoRetry(urlString)
                }
            }

            self.savePersistedProgress()
            self.scheduleReconcile()
        }
    }

    private func scheduleAutoRetry(_ urlString: String) {
        guard localBookmarks[urlString] == nil,
              downloadProgress[urlString] != nil,
              !userPausedUrls.contains(urlString) else { return }

        let retry = retryCounts[urlString] ?? 0
        guard retry < 5 else {
            print("⛔️ 自动重试已达上限，保持暂停: \(urlString)")
            isPaused[urlString] = true
            isQueued[urlString] = false
            savePersistedProgress()
            return
        }
        retryCounts[urlString] = retry + 1
        let delay = min(30.0, Double(retry + 1) * 3.0)

        // 连续失败 2 次以上 → 这个局部包大概率有问题，下次从零来
        if retry >= 1 { forceFreshStart.insert(urlString) }

        isPaused[urlString] = false
        isQueued[urlString] = true
        cooldownUntil[urlString] = Date().addingTimeInterval(delay)
        if !waitingQueue.contains(urlString) { waitingQueue.append(urlString) }

        print("🔁 \(Int(delay))s 后自动重试（第 \(retry + 1) 次）: \(urlString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { [weak self] in
            self?.scheduleReconcile()
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

    // =================================================================
    // MARK: - 持久化
    // =================================================================
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
        var snapshot = downloadProgress
        for (k, v) in accurateProgress where snapshot[k] != nil { snapshot[k] = v }
        UserDefaults.standard.set(snapshot, forKey: progressKey)
        UserDefaults.standard.set(isPaused, forKey: pausedKey)
        updateIdleTimer()
    }
    private func loadPersistedProgress() {
        if let p = UserDefaults.standard.dictionary(forKey: progressKey) as? [String: Double] {
            downloadProgress = p
            accurateProgress = p
        }
        if let pa = UserDefaults.standard.dictionary(forKey: pausedKey) as? [String: Bool] {
            isPaused = pa
        }
    }

    private func observeNetwork() {
        NetworkMonitor.shared.onSwitchedToCellular = { [weak self] in
            guard let self = self else { return }
            let urls = Set(self.runningUrls)
                .union(self.waitingQueue)
                .union(self.activeTasks.keys)
            for url in urls { self.pauseDownload(urlString: url, byUser: false) }
            print("⚠️ 检测到 Wi-Fi → 蜂窝，已暂停所有下载")
        }
    }

    private func updateIdleTimer() {
        let hasActive = !runningUrls.isEmpty
        let isForeground = UIApplication.shared.applicationState != .background
        let shouldDisable = hasActive && isForeground
        if UIApplication.shared.isIdleTimerDisabled != shouldDisable {
            UIApplication.shared.isIdleTimerDisabled = shouldDisable
        }
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
        ) { [weak self] _ in
            self?.updateIdleTimer()
            self?.auditSessionTasks()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateIdleTimer()
            self?.scheduleReconcile()
        }
    }
}

extension HLSDownloadManager {
    func activeTasksContains(_ url: String) -> Bool { downloadProgress[url] != nil }

    /// 一键继续所有暂停中的下载（按加入顺序，reconcile + 热身闸门会自动限流）
    func resumeAllPausedDownloads() {
        let paused = downloadProgress.keys
            .filter { isPaused[$0] == true && localBookmarks[$0] == nil }
            .sorted { (orderSeq[$0] ?? Int.max, $0) < (orderSeq[$1] ?? Int.max, $1) }
        for url in paused { resumeDownload(urlString: url) }
    }

    /// 一键全部暂停
    func pauseAllDownloads() {
        let urls = downloadProgress.keys.filter { localBookmarks[$0] == nil && isPaused[$0] != true }
        for url in urls { pauseDownload(urlString: url, byUser: true) }
    }

    /// UI 分组用：同一部剧的下载归到一起
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
            Button(isGlobalEnglishMode ? "Got it" : "我知道了，请继续下载") {
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
