import SwiftUI
import Combine

@MainActor
final class VideoDataManager: ObservableObject {
    @Published var categoryNames: [String] = ["Featured", "Movie", "Drama", "Show", "Anime"]
    @Published private(set) var pageItems: [String: [VideoItem]] = [:]
    @Published private(set) var hasMore: [String: Bool] = [:]
    @Published private(set) var loadingKeys: Set<String> = []
    @Published var bootstrapping = false
    /// 最近一次网络错误（nil = 正常），供 UI 显示与重试
    @Published var lastError: String?
    /// ⭐ 每次清缓存 +1；视图把它纳入 task(id:)，保证清缓存后一定会重新拉取
    @Published private(set) var cacheEpoch = 0

    private var nextPage: [String: Int] = [:]
    private let pageSize = 40
    private var didBootstrap = false
    private var loadedUserId: String?
    private var lastMaxYear: Int?

    private var maxYear: Int? { AppConfigManager.shared.effectiveMaxYear }

    private func key(_ c: String, _ s: VideoSortOption) -> String {
        "\(c)|\(s.rawValue)|\(maxYear ?? -1)"
    }
    func items(_ c: String, _ s: VideoSortOption) -> [VideoItem] { pageItems[key(c, s)] ?? [] }
    func hasMorePages(_ c: String, _ s: VideoSortOption) -> Bool { hasMore[key(c, s)] ?? true }
    func isLoading(_ c: String, _ s: VideoSortOption) -> Bool { loadingKeys.contains(key(c, s)) }

    private func sanitize(_ arr: [VideoItem]) -> [VideoItem] {
        guard let y = maxYear else { return arr }
        return arr.filter { ($0.releaseYear ?? 0) <= y }
    }

    private func describe(_ e: Error) -> String {
        let ns = e as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return T("无网络连接", "No internet connection")
        case NSURLErrorCannotFindHost:         return T("找不到服务器（DNS）", "Cannot find host")
        case NSURLErrorCannotConnectToHost:    return T("无法连接服务器（端口/防火墙）", "Cannot connect to host")
        case NSURLErrorTimedOut:               return T("请求超时", "Request timed out")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection, -1022:
            return T("被 ATS 拦截：请检查 Info.plist 的 NSAllowsArbitraryLoads",
                     "Blocked by ATS: check Info.plist")
        case 1, 4, 65:
            return T("网络被沙盒拒绝：请勾选 App Sandbox → Outgoing Connections",
                     "Sandbox denied network: enable Outgoing Connections")
        default:
            return "\(ns.localizedDescription)（\(ns.code)）"
        }
    }

    func bootstrap(userId: String?) async {
        // ⭐ 先确保配置到手，避免用错 max_year
        await AppConfigManager.shared.ensureFetched()

        if didBootstrap, loadedUserId == userId, lastMaxYear == maxYear { return }
        if didBootstrap { resetCache() }
        loadedUserId = userId; lastMaxYear = maxYear
        bootstrapping = true; defer { bootstrapping = false }
        do {
            let names = try await VideoAPI.fetchCategories()
            if !names.isEmpty { categoryNames = names }
            lastError = nil
        } catch {
            lastError = describe(error)
            print("❌ [Data] 拉取分类失败: \(error)")
        }
        didBootstrap = true
    }

    func resetCache() {
        pageItems.removeAll(); hasMore.removeAll(); nextPage.removeAll(); loadingKeys.removeAll()
        cacheEpoch += 1
    }

    func loadFirstPageIfNeeded(_ c: String, _ s: VideoSortOption, userId: String?) async {
        await AppConfigManager.shared.ensureFetched()
        let k = key(c, s)
        // 已有内容 → 不重复拉；曾经加载出「空且还有更多」→ 视为失败，重拉
        if let arr = pageItems[k], !arr.isEmpty { return }
        if pageItems[k] != nil, hasMore[k] == false { return }
        await loadNextPage(c, s, userId: userId)
    }

    /// 强制重新拉第一页（重试按钮用）
    func reload(_ c: String, _ s: VideoSortOption, userId: String?) async {
        await AppConfigManager.shared.ensureFetched()
        let k = key(c, s)
        pageItems[k] = nil; hasMore[k] = nil; nextPage[k] = nil
        lastError = nil
        await loadNextPage(c, s, userId: userId)
    }

    func loadNextPage(_ c: String, _ s: VideoSortOption, userId: String?) async {
        await AppConfigManager.shared.ensureFetched()
        let k = key(c, s)
        if loadingKeys.contains(k) { return }
        if hasMore[k] == false { return }
        loadingKeys.insert(k); defer { loadingKeys.remove(k) }

        // ⭐ 若某一页全被去重/过滤掉了，自动继续翻下一页（最多 3 次），避免"卡住不再加载"
        var tries = 0
        var added = 0
        repeat {
            tries += 1
            let page = nextPage[k] ?? 0
            do {
                let resp = try await VideoAPI.fetchList(category: c, sort: s, page: page,
                                pageSize: pageSize, userId: userId, maxYear: maxYear)
                var arr = pageItems[k] ?? []
                let existing = Set(arr.map(\.url))
                let fresh = sanitize(resp.items).filter { !existing.contains($0.url) }
                arr.append(contentsOf: fresh)
                added = fresh.count
                pageItems[k] = arr
                hasMore[k] = resp.has_more
                nextPage[k] = page + 1
                lastError = nil
                print("📦 [Data] \(c)/\(s.rawValue) page=\(page) 服务器 \(resp.items.count) 条 / 新增 \(fresh.count) / 累计 \(arr.count)")
                if resp.items.isEmpty || !resp.has_more { break }
            } catch {
                lastError = describe(error)
                print("❌ [Data] 拉取 \(c) 第 \(page) 页失败: \(error)")
                break
            }
        } while added == 0 && tries < 3
    }

    func search(_ kw: String, userId: String?) async -> [VideoItem] {
        await AppConfigManager.shared.ensureFetched()
        do { return sanitize(try await VideoAPI.search(keyword: kw, userId: userId, maxYear: maxYear)) }
        catch { lastError = describe(error); return [] }
    }
    func filterOptions(userId: String?) async -> FilterOptionsResponse? {
        await AppConfigManager.shared.ensureFetched()
        return try? await VideoAPI.fetchFilterOptions(userId: userId)
    }
    /// 返回 (items, hasMore, errorText)
    func filter(category: String?, type: String?, year: Int?, region: String?,
                sort: VideoSortOption, page: Int, userId: String?) async -> ([VideoItem], Bool, String?) {
        await AppConfigManager.shared.ensureFetched()
        do {
            let r = try await VideoAPI.fetchFilter(category: category, type: type, year: year,
                    region: region, sort: sort, page: page, pageSize: pageSize,
                    userId: userId, maxYear: maxYear)
            return (sanitize(r.items), r.has_more, nil)
        } catch {
            let msg = describe(error)
            lastError = msg
            return ([], true, msg)   // ⭐ 出错不要把 hasMore 写死成 false，否则永远无法继续
        }
    }
    func playlist(_ url: String) async -> [VideoChannel] {
        (try? await VideoAPI.fetchPlaylist(url: url)) ?? []
    }
}

// MARK: - 搜索历史
@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    @Published private(set) var items: [String] = []
    private let key = "GW_SearchHistory"
    private init() { items = UserDefaults.standard.stringArray(forKey: key) ?? [] }

    func add(_ kw: String) {
        let k = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 1 else { return }
        // 同词去重
        items.removeAll { $0.caseInsensitiveCompare(k) == .orderedSame }
        // ⭐ 把「是本次关键词前缀」的旧记录清掉（输入 迷雾 前会先记 迷 ）
        items.removeAll { old in
            old.count < k.count && k.lowercased().hasPrefix(old.lowercased())
        }
        items.insert(k, at: 0)
        if items.count > 25 { items = Array(items.prefix(25)) }
        save()
    }
    func remove(_ kw: String) { items.removeAll { $0 == kw }; save() }
    func clear() { items.removeAll(); save() }
    private func save() { UserDefaults.standard.set(items, forKey: key) }
}

// MARK: - 播放记录
struct PlayRecord: Codable, Identifiable, Hashable {
    var id: String { "\(videoURL)_\(playTime.timeIntervalSince1970)" }
    let videoTitle: String, episodeName: String, videoURL: String
    let coverImage: String?, playTime: Date, channelName: String?, sourceURL: String?
}

@MainActor
final class PlayRecordStore: ObservableObject {
    static let shared = PlayRecordStore()
    @Published private(set) var records: [PlayRecord] = []
    private let key = "GW_PlayRecords"
    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let r = try? JSONDecoder().decode([PlayRecord].self, from: d) { records = r }
    }
    func add(title: String, episode: String, url: String, cover: String?, channel: String?, source: String?) {
        records.removeAll { $0.videoTitle == title && $0.episodeName == episode }
        records.insert(.init(videoTitle: title, episodeName: episode, videoURL: url,
                             coverImage: cover, playTime: Date(),
                             channelName: channel, sourceURL: source), at: 0)
        if records.count > 60 { records = Array(records.prefix(60)) }
        save()
    }
    func remove(_ r: PlayRecord) { records.removeAll { $0.id == r.id }; save() }
    func clear() { records.removeAll(); save() }
    private func save() {
        if let d = try? JSONEncoder().encode(records) { UserDefaults.standard.set(d, forKey: key) }
    }
}