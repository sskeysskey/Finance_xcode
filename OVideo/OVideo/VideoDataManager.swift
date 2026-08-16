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
    }

    func loadFirstPageIfNeeded(_ c: String, _ s: VideoSortOption, userId: String?) async {
        if pageItems[key(c, s)] != nil { return }
        await loadNextPage(c, s, userId: userId)
    }

    /// 强制重新拉第一页（重试按钮用）
    func reload(_ c: String, _ s: VideoSortOption, userId: String?) async {
        let k = key(c, s)
        pageItems[k] = nil; hasMore[k] = nil; nextPage[k] = nil
        await loadNextPage(c, s, userId: userId)
    }

    func loadNextPage(_ c: String, _ s: VideoSortOption, userId: String?) async {
        let k = key(c, s)
        if loadingKeys.contains(k) { return }
        if hasMore[k] == false { return }
        let page = nextPage[k] ?? 0
        loadingKeys.insert(k); defer { loadingKeys.remove(k) }
        do {
            let resp = try await VideoAPI.fetchList(category: c, sort: s, page: page,
                            pageSize: pageSize, userId: userId, maxYear: maxYear)
            if resp.droppedItems > 0 {
                print("⚠️ [Data] \(c) 第 \(page) 页有 \(resp.droppedItems) 条解码失败被跳过")
            }
            var arr = pageItems[k] ?? []
            let existing = Set(arr.map(\.url))
            arr.append(contentsOf: sanitize(resp.items).filter { !existing.contains($0.url) })
            pageItems[k] = arr; hasMore[k] = resp.has_more; nextPage[k] = page + 1
            lastError = nil
            print("📦 [Data] \(c)/\(s.rawValue) page=\(page) 服务器返回 \(resp.items.count) 条，过滤后累计 \(arr.count) 条，maxYear=\(String(describing: maxYear))")
        } catch {
            lastError = describe(error)
            print("❌ [Data] 拉取 \(c) 第 \(page) 页失败: \(error)")
        }
    }

    func search(_ kw: String, userId: String?) async -> [VideoItem] {
        do { return sanitize(try await VideoAPI.search(keyword: kw, userId: userId, maxYear: maxYear)) }
        catch { lastError = describe(error); return [] }
    }
    func filterOptions(userId: String?) async -> FilterOptionsResponse? {
        try? await VideoAPI.fetchFilterOptions(userId: userId)
    }
    func filter(category: String?, type: String?, year: Int?, region: String?,
                sort: VideoSortOption, page: Int, userId: String?) async -> ([VideoItem], Bool) {
        do {
            let r = try await VideoAPI.fetchFilter(category: category, type: type, year: year,
                    region: region, sort: sort, page: page, pageSize: pageSize,
                    userId: userId, maxYear: maxYear)
            return (sanitize(r.items), r.has_more)
        } catch {
            lastError = describe(error); return ([], false)
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
        let k = kw.trimmingCharacters(in: .whitespacesAndNewlines); guard !k.isEmpty else { return }
        items.removeAll { $0.caseInsensitiveCompare(k) == .orderedSame }
        items.insert(k, at: 0); if items.count > 25 { items = Array(items.prefix(25)) }; save()
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