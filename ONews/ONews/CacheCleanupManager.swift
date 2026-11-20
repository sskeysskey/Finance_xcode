import Foundation

enum CacheKind: String, CaseIterable, Identifiable, Sendable {
    case newsImages, coverCache, networkCache, audioChunks, tmpDownloads, orphanHLS
    var id: String { rawValue }

    func title(en: Bool) -> String {
        switch self {
        case .newsImages:   return en ? "Article Images" : "文章配图"
        case .coverCache:   return en ? "Cover Cache" : "视频封面缓存"
        case .networkCache: return en ? "Network Cache" : "网络响应缓存"
        case .audioChunks:  return en ? "Audio Temp Files" : "音频播报临时文件"
        case .tmpDownloads: return en ? "Interrupted Downloads" : "中断的下载残留"
        case .orphanHLS:    return en ? "Orphaned Offline Videos" : "离线视频孤儿文件"
        }
    }

    func hint(en: Bool) -> String {
        switch self {
        case .newsImages:   return en ? "Includes offline images; re-downloaded when needed"
                                      : "会一并删除离线图片，阅读时会按需重新下载"
        case .coverCache:   return en ? "Covers reload automatically" : "封面会自动重新加载"
        case .networkCache: return en ? "Network responses only" : "仅网络响应缓存"
        case .audioChunks:  return en ? "Stops playback first" : "清理前会先停止播报"
        case .tmpDownloads: return en ? "Skipped while syncing" : "同步进行中时不会清理"
        case .orphanHLS:    return en ? "Only files with no download record" : "仅清理已无下载记录引用的文件"
        }
    }
}

struct CleanupPlan: Sendable {
    var urls: [CacheKind: [URL]] = [:]
}

@MainActor
final class CacheCleanupManager {
    static let shared = CacheCleanupManager()
    private let fm = FileManager.default

    private var docsDir: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var libDir: URL { fm.urls(for: .libraryDirectory, in: .userDomainMask)[0] }
    private var tmpDir: URL { fm.temporaryDirectory }

    // MARK: - 计划（主线程：需要读取下载记录 / 同步状态）
    func makePlan(resourceManager rm: ResourceManager) -> CleanupPlan {
        var plan = CleanupPlan()
        plan.urls[.newsImages] = children(of: docsDir, prefix: "news_images_")
        plan.urls[.audioChunks] = children(of: tmpDir, prefix: "chunk_", suffix: ".caf")

        // 正在同步/下载时，CFNetworkDownload_*.tmp 可能是正在写入的文件，不能删
        if !rm.isSyncing && !rm.isSilentSyncing {
            plan.urls[.tmpDownloads] = children(of: tmpDir, prefix: "CFNetworkDownload_", suffix: ".tmp")
                .filter { isOlderThan($0, seconds: 600) }
        }
        plan.urls[.orphanHLS] = HLSDownloadManager.shared.orphanAssetURLs()
        return plan
    }

    // MARK: - 扫描大小
    func scan(resourceManager rm: ResourceManager) async -> [CacheKind: Int64] {
        let urls = makePlan(resourceManager: rm).urls
        var sizes = await Task.detached(priority: .utility) {
            urls.mapValues { CacheCleanupManager.size(of: $0) }
        }.value
        // 这两项由 URLCache 统计，不走文件遍历
        sizes[.coverCache] = Int64(OImageLoader.shared.diskUsage)
        sizes[.networkCache] = Int64(URLCache.shared.currentDiskUsage)
        return sizes
    }

    // MARK: - 清理（返回实际释放字节数）
    func clean(_ kinds: Set<CacheKind>, resourceManager rm: ResourceManager) async -> Int64 {
        // 1. 音频：先停播，否则正在播放的分段文件会被删
        if kinds.contains(.audioChunks) {
            NotificationCenter.default.post(name: .stopAllReaderAudio, object: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // 2. 图片：先停止后台图片队列，避免边删边下
        if kinds.contains(.newsImages) {
            rm.cancelImageQueue()
            ImageLoader.clearCache()
        }
        // 3. 内存/URLCache 类
        if kinds.contains(.coverCache) {
            OImageCache.shared.clearMemory()
            OImageLoader.shared.clearDiskCache()
        }
        if kinds.contains(.networkCache) {
            URLCache.shared.removeAllCachedResponses()
        }

        // 4. 文件类：在清理时重新生成计划，保证孤儿判断是最新的
        let plan = makePlan(resourceManager: rm)
        let targets = kinds.flatMap { plan.urls[$0] ?? [] }
        return await Task.detached(priority: .utility) {
            CacheCleanupManager.removeAndMeasure(targets)
        }.value
    }

    // MARK: - 工具
    private func children(of dir: URL, prefix: String, suffix: String = "") -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
    }

    private func isOlderThan(_ url: URL, seconds: TimeInterval) -> Bool {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return Date().timeIntervalSince(date) > seconds
    }

    nonisolated static func size(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { $0 + allocatedSize($1) }
    }

    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        // 目录（含 .movpkg 包）：递归累加
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    nonisolated static func removeAndMeasure(_ urls: [URL]) -> Int64 {
        var freed: Int64 = 0
        for u in urls {
            let s = allocatedSize(u)
            do {
                try FileManager.default.removeItem(at: u)
                freed += s
            } catch {
                print("⚠️ [清理] 删除失败 \(u.lastPathComponent): \(error)")
            }
        }
        return freed
    }
}

extension Notification.Name {
    static let stopAllReaderAudio = Notification.Name("stopAllReaderAudio")
}
