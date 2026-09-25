// API 接口、数据模型、排序枚举、缓存元数据
// 纯数据层（SQLite 分页版）

import SwiftUI

// MARK: - 服务器地址
enum OVideoAPI {
    static let baseURL = "http://106.15.183.158:5001/api/OVideo"

    static func coverURL(for imageName: String) -> URL? {
        guard !imageName.isEmpty,
              let encoded = imageName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(baseURL)/cover/\(encoded)")
    }

    private static func makeURL(_ path: String, _ items: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: "\(baseURL)/\(path)") else { return nil }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    static func fetchCategories() async throws -> [String] {
        guard let url = makeURL("categories", []) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoCategoriesResponse.self, from: data).categories
    }

    static func fetchList(category: String, sort: VideoSortOption,
                        page: Int, pageSize: Int, userId: String?,
                        maxYear: Int? = nil) async throws -> OVideoListResponse {
        var q = [URLQueryItem(name: "category", value: category),
                URLQueryItem(name: "sort", value: sort.rawValue),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize))]
        if let uid = userId, !uid.isEmpty { q.append(URLQueryItem(name: "user_id", value: uid)) }
        if let y = maxYear { q.append(URLQueryItem(name: "max_year", value: String(y))) }
        guard let url = makeURL("list", q) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData   // 【新增】避免拿到 URLCache 旧数据
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoListResponse.self, from: data)
    }

    static func fetchFilter(category: String?, type: String?, year: Int?, region: String?,
                            sort: VideoSortOption, page: Int, pageSize: Int,
                            userId: String?, maxYear: Int? = nil) async throws -> OVideoListResponse {
        var q = [URLQueryItem(name: "sort", value: sort.rawValue),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize))]
        if let c = category { q.append(URLQueryItem(name: "category", value: c)) }
        if let t = type     { q.append(URLQueryItem(name: "type", value: t)) }
        if let y = year     { q.append(URLQueryItem(name: "year", value: String(y))) }
        if let r = region   { q.append(URLQueryItem(name: "region", value: r)) }
        if let uid = userId, !uid.isEmpty { q.append(URLQueryItem(name: "user_id", value: uid)) }
        if let my = maxYear { q.append(URLQueryItem(name: "max_year", value: String(my))) }
        guard let url = makeURL("filter", q) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoListResponse.self, from: data)
    }

    static func fetchFilterOptions(userId: String?) async throws -> OVideoFilterOptionsResponse {
        var q: [URLQueryItem] = []
        if let uid = userId, !uid.isEmpty { q.append(URLQueryItem(name: "user_id", value: uid)) }
        guard let url = makeURL("filter_options", q) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoFilterOptionsResponse.self, from: data)
    }

    static func search(keyword: String, userId: String?, maxYear: Int? = nil) async throws -> [OVideoItem] {
        var q = [URLQueryItem(name: "q", value: keyword)]
        if let uid = userId, !uid.isEmpty { q.append(URLQueryItem(name: "user_id", value: uid)) }
        if let y = maxYear { q.append(URLQueryItem(name: "max_year", value: String(y))) }
        guard let url = makeURL("search2", q) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoListResponse.self, from: data).items
    }

    static func fetchPlaylist(url itemURL: String) async throws -> [OVideoChannel] {
        guard let encoded = itemURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/playlist?url=\(encoded)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData   // 【新增】剧集列表必须最新
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoPlaylistResponse.self, from: data).playlist
    }

    static func resolveRealURL(episodeURL: String) async throws -> String {
        if episodeURL.lowercased().contains(".m3u8") { return episodeURL }
        guard let url = URL(string: "\(baseURL)/resolve") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": episodeURL])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 {
                throw NSError(domain: "OVideo", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "该视频暂不可用"])
            }
            if http.statusCode == 404 {
                throw NSError(domain: "OVideo", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "未找到可播放的资源"])
            }
            if http.statusCode >= 400 {
                throw NSError(domain: "OVideo", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "解析失败 (\(http.statusCode))"])
            }
        }
        let result = try JSONDecoder().decode(OVideoResolveResponse.self, from: data)
        return result.real_url
    }

    static func submitWish(content: String, keyword: String?,
                           userId: String?, userType: String) async throws {
        guard let url = URL(string: "\(baseURL)/wish") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        var body: [String: Any] = ["wish_content": content, "user_type": userType]
        if let k = keyword, !k.isEmpty { body["keyword"] = k }
        if let uid = userId, !uid.isEmpty { body["user_id"] = uid }
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        body["app_version"] = appVer
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw NSError(domain: "OVideo", code: 429,
                              userInfo: [NSLocalizedDescriptionKey: "提交太频繁，请稍后再试"])
            }
            if http.statusCode >= 400 {
                throw NSError(domain: "OVideo", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "提交失败 (\(http.statusCode))"])
            }
        }
    }

    static func fetchMyWishReplies(userId: String) async throws -> [WishReply] {
        guard let url = makeURL("wish/my_replies",
                                [URLQueryItem(name: "user_id", value: userId)]) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(WishRepliesResponse.self, from: data).replies
    }

    static func ackWishReply(id: Int, userId: String) async {
        guard let url = URL(string: "\(baseURL)/wish/ack_reply") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "user_id": userId])
        _ = try? await URLSession.shared.data(for: req)
    }

    static func fetchMyReportReplies(userId: String) async throws -> [ReportReply] {
        guard let url = makeURL("report/my_replies",
                                [URLQueryItem(name: "user_id", value: userId)]) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ReportRepliesResponse.self, from: data).replies
    }

    static func ackReportReply(id: Int, userId: String) async {
        guard let url = URL(string: "\(baseURL)/report/ack_reply") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "user_id": userId])
        _ = try? await URLSession.shared.data(for: req)
    }
}

func cleanName(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let hasChinese = trimmed.range(of: "[\u{4e00}-\u{9fa5}]", options: .regularExpression) != nil
    if hasChinese,
       let range = trimmed.range(of: "[\u{4e00}-\u{9fa5}·]+", options: .regularExpression) {
        let extracted = String(trimmed[range])
            .trimmingCharacters(in: CharacterSet(charactersIn: "·").union(.whitespaces))
        if !extracted.isEmpty { return extracted }
    }
    return trimmed
}

// MARK: - 模型（未改动）
struct WishRepliesResponse: Codable { let replies: [WishReply] }
struct WishReply: Codable, Identifiable, Hashable {
    let id: Int
    let wish_content: String
    let admin_reply: String?
    let replied_at: String?
}

struct ReportRepliesResponse: Codable { let replies: [ReportReply] }
struct ReportReply: Codable, Identifiable, Hashable {
    let id: Int
    let video_title: String?
    let episode_name: String?
    let admin_reply: String?
    let replied_at: String?
}

struct OVideoCategoriesResponse: Codable { let categories: [String] }
struct OVideoListResponse: Codable {
    let items: [OVideoItem]
    let has_more: Bool
    let page: Int
}
struct OVideoFilterOptionsResponse: Codable {
    let types: [String]
    let years: [Int]
    let regions: [String]
}
struct OVideoPlaylistResponse: Codable { let playlist: [OVideoChannel] }

struct OVideoResponse: Codable { let categories: [OVideoCategory] }
struct OVideoCategory: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let items: [OVideoItem]
}

struct OVideoItem: Codable, Identifiable, Hashable {
    var id: String { url }
    let time: String?
    let name: String
    let url: String
    let info: String?
    let image: String?
    let director: String?
    let writers: [String]?
    let cast: [String]?
    let types: [String]?
    let region: String?
    let date: String?
    let alias: String?
    let intro: String?
    let ratings: [String: String]?
    let playlist: [OVideoChannel]?
    let update: String?

    enum CodingKeys: String, CodingKey {
        case time, name, url, info, image, date, alias, intro, playlist, update
        case director = "导演"
        case writers  = "编剧"
        case cast     = "主演"
        case types    = "类型"
        case region   = "地区"
        case ratings  = "评分"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: OVideoItem, rhs: OVideoItem) -> Bool { lhs.url == rhs.url }
}

struct OVideoChannel: Codable, Hashable {
    let name: String
    let episodes: [String: String]
    let episodeOrder: [String]?

    enum CodingKeys: String, CodingKey {
        case name, episodes
        case episodeOrder = "episode_order"
    }

    var sortedEpisodes: [(name: String, url: String)] { sortedEpisodes(ascending: true) }

    func sortedEpisodes(ascending: Bool) -> [(name: String, url: String)] {
        if let order = episodeOrder, !order.isEmpty {
            let ordered = order.compactMap { key -> (name: String, url: String)? in
                guard let url = episodes[key] else { return nil }
                return (name: key, url: url)
            }
            if ordered.count == episodes.count {
                return ascending ? ordered : ordered.reversed()
            }
        }
        return episodes.sorted { (kv1, kv2) -> Bool in
            if let num1 = Int(kv1.key), let num2 = Int(kv2.key) {
                return ascending ? (num1 < num2) : (num1 > num2)
            }
            let comparison = kv1.key.localizedStandardCompare(kv2.key)
            return ascending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }.map { (name: $0.key, url: $0.value) }
    }
}

struct OVideoResolveResponse: Codable {
    let real_url: String
    let title: String?
}

extension OVideoItem {
    var updateSortKey: String { update ?? "" }
    var releaseSortKey: String {
        guard let raw = date, !raw.isEmpty else { return "" }
        return raw.split(separator: "(").first.map(String.init) ?? raw
    }
    var releaseYear: Int? {
        guard let raw = date, !raw.isEmpty else { return nil }
        let cleaned = raw.split(separator: "(").first.map(String.init) ?? raw
        if let first = cleaned.split(separator: "-").first, let y = Int(first) { return y }
        return nil
    }
    var bestRating: Double {
        guard let r = ratings else { return 0 }
        return r.values.compactMap { Double($0) }.max() ?? 0
    }
    var starringCast: [String] {
        guard let cast = cast else { return [] }
        return Array(cast.prefix(2))
    }
    var otherCast: [String] {
        guard let cast = cast, cast.count > 3 else { return [] }
        return Array(cast.dropFirst(2))
    }
}

extension OVideoItem {
    /// ⭐ 内容级比较（`==` 只比 url，用于集合去重；UI 是否需要重绘必须用这个）
    func hasSameContent(as o: OVideoItem) -> Bool {
        url == o.url && name == o.name && info == o.info && image == o.image
            && update == o.update && date == o.date && time == o.time
            && ratings == o.ratings && region == o.region && intro == o.intro
    }
}

enum VideoSortOption: String, CaseIterable {
    case update, date, rating
    func displayName(_ en: Bool) -> String {
        switch self {
        case .date:   return en ? "By Release Date" : "按上映日期"
        case .update: return en ? "By Last Updated" : "按更新日期"
        case .rating: return en ? "By Rating" : "按评分"
        }
    }
    func shortName(_ en: Bool) -> String {
        switch self {
        case .date:   return en ? "Release" : "上映"
        case .update: return en ? "Updated" : "更新"
        case .rating: return en ? "Rating" : "评分"
        }
    }
    var icon: String {
        switch self {
        case .date:   return "calendar"
        case .update: return "clock"
        case .rating: return "star.fill"
        }
    }
}

struct VideoCacheMetadata: Codable {
    let title: String
    let coverImage: String?
    let savedAt: Date
    var seriesTitle: String?
    var episodeName: String?
    var originalEpisodeURL: String?
    var sourceURL: String?
}
extension VideoCacheMetadata {
    var groupKey: String {
        if let s = seriesTitle, !s.isEmpty { return "title:" + s }
        if let c = coverImage, !c.isEmpty { return "cover:" + c }
        return "single:" + title
    }
}

// MARK: - ⭐ 单个「分类 + 排序」的独立数据源
// 每个分类页只监听自己的 feed：A 分类翻页不会让 B/C/D/E 分类页、底部栏、详情页重绘
@MainActor
final class OVideoCategoryFeed: ObservableObject {
    let key: String
    @Published fileprivate(set) var items: [OVideoItem] = []
    @Published fileprivate(set) var hasMore = true
    @Published fileprivate(set) var isLoading = false
    @Published fileprivate(set) var loadFailed = false
    fileprivate(set) var didLoadFirstPage = false
    fileprivate var nextPage = 0
    fileprivate var lastRefreshAt: Date?
    fileprivate var knownURLs = Set<String>()

    init(key: String) { self.key = key }
}

// MARK: - 数据管理器（分页 / 按需 / 静默刷新 · 性能版）
@MainActor
class OVideoDataManager: ObservableObject {
    @Published var categoryNames: [String] = ["Featured", "Movie", "Drama", "Show", "Anime"]
    @Published var reviewMaxYear: Int? = nil {
        didSet { if oldValue != reviewMaxYear { feeds.removeAll() } }
    }
    @Published var isBootstrapping = false
    @Published var bootstrapError: String? = nil

    /// ⭐ 不发布：feed 自己发布，避免全局广播
    private var feeds: [String: OVideoCategoryFeed] = [:]
    private var lastCategoryRefreshAt: Date?

    private let pageSize = 24
    private var didBootstrap = false
    private var loadedUserId: String? = nil
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskKey: String?

    var isLoading: Bool { isBootstrapping }

    func cacheKey(_ cat: String, _ sort: VideoSortOption) -> String {
        if let y = reviewMaxYear { return "\(cat)|\(sort.rawValue)|ry\(y)" }
        return "\(cat)|\(sort.rawValue)"
    }

    /// 取得（必要时创建）某分类 + 排序的数据源
    func feed(category: String, sort: VideoSortOption) -> OVideoCategoryFeed {
        let k = cacheKey(category, sort)
        if let f = feeds[k] { return f }
        let f = OVideoCategoryFeed(key: k)
        feeds[k] = f
        return f
    }

    // 兼容旧 API（注意：这三个是非响应式快照，UI 请监听 feed）
    func items(category: String, sort: VideoSortOption) -> [OVideoItem] {
        feeds[cacheKey(category, sort)]?.items ?? []
    }
    func hasMorePages(category: String, sort: VideoSortOption) -> Bool {
        feeds[cacheKey(category, sort)]?.hasMore ?? true
    }
    func isLoadingPage(category: String, sort: VideoSortOption) -> Bool {
        feeds[cacheKey(category, sort)]?.isLoading ?? false
    }

    // MARK: 启动（⭐ 并发调用去重：AppDelegate 预热 + VideoModuleView.task 不再重复请求）
    func bootstrap(userId: String?) async {
        if didBootstrap && loadedUserId == userId { return }
        let key = userId ?? "∅"
        if let t = bootstrapTask, bootstrapTaskKey == key { await t.value; return }
        let t = Task { await self.performBootstrap(userId: userId) }
        bootstrapTask = t
        bootstrapTaskKey = key
        await t.value
        if bootstrapTaskKey == key { bootstrapTask = nil; bootstrapTaskKey = nil }
    }

    private func performBootstrap(userId: String?) async {
        if didBootstrap && loadedUserId != userId {
            feeds.removeAll()
            objectWillChange.send()          // 让分类页重新取新 feed
        }
        loadedUserId = userId
        if !isBootstrapping { isBootstrapping = true }
        defer { isBootstrapping = false }
        do {
            let names = try await OVideoAPI.fetchCategories()
            if !names.isEmpty, names != categoryNames { categoryNames = names }
            lastCategoryRefreshAt = Date()
            if bootstrapError != nil { bootstrapError = nil }
        } catch {
            bootstrapError = error.localizedDescription
        }
        didBootstrap = true
    }

    // MARK: 分页
    func loadFirstPageIfNeeded(category: String, sort: VideoSortOption, userId: String?) async {
        let f = feed(category: category, sort: sort)
        if f.didLoadFirstPage || f.isLoading { return }
        await loadNextPage(category: category, sort: sort, userId: userId)
    }

    func loadNextPage(category: String, sort: VideoSortOption, userId: String?) async {
        let f = feed(category: category, sort: sort)
        guard !f.isLoading, f.hasMore else { return }
        let page = f.nextPage
        let year = reviewMaxYear
        f.isLoading = true
        if f.loadFailed { f.loadFailed = false }
        do {
            let resp = try await OVideoAPI.fetchList(category: category, sort: sort,
                                                     page: page, pageSize: pageSize,
                                                     userId: userId, maxYear: year)
            f.isLoading = false
            // ⭐ 过期结果丢弃：审核年份 / 用户切换后旧 feed 已被移除；或静默刷新已抢先填充
            guard feeds[f.key] === f, f.nextPage == page else { return }
            var fresh: [OVideoItem] = []
            for it in resp.items where f.knownURLs.insert(it.url).inserted { fresh.append(it) }
            if !fresh.isEmpty { f.items.append(contentsOf: fresh) }
            if f.hasMore != resp.has_more { f.hasMore = resp.has_more }
            f.nextPage = page + 1
            if page == 0 { f.didLoadFirstPage = true; f.lastRefreshAt = Date() }
        } catch {
            f.isLoading = false
            let cancelled = (error is CancellationError) || (error as? URLError)?.code == .cancelled
            if !cancelled { f.loadFailed = true }   // 页面切走导致的取消不算失败，回来会自动重载
        }
    }

    // MARK: 静默刷新第一页（新增前插 + 同 URL 就地更新；⭐ 内容无变化时不发布）
    func silentRefreshFirstPage(category: String, sort: VideoSortOption,
                                userId: String?, minInterval: TimeInterval = 60) async {
        let f = feed(category: category, sort: sort)
        if f.isLoading { return }
        if let last = f.lastRefreshAt, Date().timeIntervalSince(last) < minInterval { return }
        f.lastRefreshAt = Date()
        let year = reviewMaxYear

        do {
            let resp = try await OVideoAPI.fetchList(category: category, sort: sort,
                                                     page: 0, pageSize: pageSize,
                                                     userId: userId, maxYear: year)
            guard feeds[f.key] === f else { return }

            if f.items.isEmpty {
                guard !f.isLoading else { return }   // 正常分页已在进行，交给它
                var seen = Set<String>()
                let list = resp.items.filter { seen.insert($0.url).inserted }
                f.knownURLs = seen
                f.items = list
                f.hasMore = resp.has_more
                f.nextPage = 1
                f.didLoadFirstPage = true
                if f.loadFailed { f.loadFailed = false }
                return
            }

            var arr = f.items
            var changed = false
            let freshMap = Dictionary(resp.items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            for i in arr.indices {
                if let newer = freshMap[arr[i].url], !newer.hasSameContent(as: arr[i]) {
                    arr[i] = newer; changed = true
                }
            }
            var brandNew: [OVideoItem] = []
            for it in resp.items where !f.knownURLs.contains(it.url) {
                f.knownURLs.insert(it.url)
                brandNew.append(it)
            }
            if !brandNew.isEmpty {
                arr.insert(contentsOf: brandNew, at: 0)
                changed = true
                print("📺 [静默刷新] \(f.key) 新增 \(brandNew.count) 条")
            }
            if changed { f.items = arr }
        } catch {
            f.lastRefreshAt = Date().addingTimeInterval(-(max(0, minInterval - 20)))
        }
    }

    func silentRefreshCurrentSelection(userId: String?, minInterval: TimeInterval = 60) async {
        await refreshCategoryNames()
        let idx = UserDefaults.standard.integer(forKey: "OVideo_SelectedCategoryIndex")
        let sortRaw = UserDefaults.standard.string(forKey: "OVideo_SortOption")
            ?? VideoSortOption.date.rawValue
        let sort = VideoSortOption(rawValue: sortRaw) ?? .date
        guard idx >= 0, idx < categoryNames.count else { return }
        await silentRefreshFirstPage(category: categoryNames[idx], sort: sort,
                                     userId: userId, minInterval: minInterval)
    }

    func refreshCategoryNames(minInterval: TimeInterval = 600) async {
        if let last = lastCategoryRefreshAt, Date().timeIntervalSince(last) < minInterval { return }
        lastCategoryRefreshAt = Date()
        if let names = try? await OVideoAPI.fetchCategories(), !names.isEmpty, names != categoryNames {
            categoryNames = names
        }
    }

    func search(keyword: String, userId: String?) async -> [OVideoItem] {
        (try? await OVideoAPI.search(keyword: keyword, userId: userId, maxYear: reviewMaxYear)) ?? []
    }

    func fetchFilterOptions(userId: String?) async -> OVideoFilterOptionsResponse? {
        try? await OVideoAPI.fetchFilterOptions(userId: userId)
    }

    func fetchFilter(category: String?, type: String?, year: Int?, region: String?,
                     sort: VideoSortOption, page: Int, userId: String?)
    async -> (items: [OVideoItem], hasMore: Bool) {
        do {
            let resp = try await OVideoAPI.fetchFilter(category: category, type: type, year: year,
                                                       region: region, sort: sort, page: page,
                                                       pageSize: pageSize, userId: userId,
                                                       maxYear: reviewMaxYear)
            return (resp.items, resp.has_more)
        } catch {
            return ([], false)
        }
    }

    func fetchPlaylist(url: String) async -> [OVideoChannel] {
        (try? await OVideoAPI.fetchPlaylist(url: url)) ?? []
    }
}

// MARK: - 搜索历史 / 播放记录 / 回复管理器（未改动）
@MainActor
final class SearchHistoryManager: ObservableObject {
    @Published private(set) var histories: [String] = []
    private let storageKey = "ONews_VideoSearchHistory"
    private let maxCount = 20
    init() { load() }
    func add(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        histories.removeAll { $0.caseInsensitiveCompare(kw) == .orderedSame }
        histories.insert(kw, at: 0)
        if histories.count > maxCount { histories = Array(histories.prefix(maxCount)) }
        save()
    }
    func remove(_ keyword: String) { histories.removeAll { $0 == keyword }; save() }
    func clearAll() { histories.removeAll(); save() }
    private func save() { UserDefaults.standard.set(histories, forKey: storageKey) }
    private func load() { histories = UserDefaults.standard.stringArray(forKey: storageKey) ?? [] }
}

struct VideoPlayRecord: Codable, Identifiable, Hashable {
    var id: String { "\(videoURL)_\(playTime.timeIntervalSince1970)" }
    let videoTitle: String
    let episodeName: String
    let videoURL: String
    let coverImage: String?
    let playTime: Date
    let channelName: String?
    let sourceURL: String?
}

@MainActor
final class VideoPlayRecordManager: ObservableObject {
    static let shared = VideoPlayRecordManager()
    @Published private(set) var records: [VideoPlayRecord] = []
    private let storageKey = "ONews_VideoPlayRecords"
    private let maxCount = 20
    private init() { load() }
    func addRecord(videoTitle: String, episodeName: String, videoURL: String,
                   coverImage: String?, channelName: String?, sourceURL: String?) {
        let newRecord = VideoPlayRecord(videoTitle: videoTitle, episodeName: episodeName,
                                        videoURL: videoURL, coverImage: coverImage,
                                        playTime: Date(), channelName: channelName, sourceURL: sourceURL)
        records.removeAll { $0.videoTitle == videoTitle && $0.episodeName == episodeName }
        records.insert(newRecord, at: 0)
        if records.count > maxCount { records = Array(records.prefix(maxCount)) }
        save()
    }
    func removeRecord(_ record: VideoPlayRecord) { records.removeAll { $0.id == record.id }; save() }
    func clearAll() { records.removeAll(); save() }
    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([VideoPlayRecord].self, from: data) {
            self.records = decoded
        }
    }
}

@MainActor
final class WishReplyManager: ObservableObject {
    static let shared = WishReplyManager()
    @Published var pendingReplies: [WishReply] = []
    private init() {}
    func refresh(userId: String?) async {
        guard let uid = userId, !uid.isEmpty else { return }
        if let replies = try? await OVideoAPI.fetchMyWishReplies(userId: uid) {
            self.pendingReplies = replies
        }
    }
    func acknowledge(_ reply: WishReply, userId: String?) async {
        guard let uid = userId, !uid.isEmpty else { return }
        await OVideoAPI.ackWishReply(id: reply.id, userId: uid)
        pendingReplies.removeAll { $0.id == reply.id }
    }
}

@MainActor
final class ReportReplyManager: ObservableObject {
    static let shared = ReportReplyManager()
    @Published var pendingReplies: [ReportReply] = []
    private init() {}
    func refresh(userId: String?) async {
        guard let uid = userId, !uid.isEmpty else { return }
        if let replies = try? await OVideoAPI.fetchMyReportReplies(userId: uid) {
            self.pendingReplies = replies
        }
    }
    func acknowledge(_ reply: ReportReply, userId: String?) async {
        guard let uid = userId, !uid.isEmpty else { return }
        await OVideoAPI.ackReportReply(id: reply.id, userId: uid)
        pendingReplies.removeAll { $0.id == reply.id }
    }
}