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

    // 公共：构造带 query 的 URL
    private static func makeURL(_ path: String, _ items: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: "\(baseURL)/\(path)") else { return nil }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    // 分类名列表
    static func fetchCategories() async throws -> [String] {
        guard let url = makeURL("categories", []) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoCategoriesResponse.self, from: data).categories
    }

    // 首页分页列表
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
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoListResponse.self, from: data)
    }

    // 筛选分页列表
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

    // 筛选可选项
    static func fetchFilterOptions(userId: String?) async throws -> OVideoFilterOptionsResponse {
        var q: [URLQueryItem] = []
        if let uid = userId, !uid.isEmpty { q.append(URLQueryItem(name: "user_id", value: uid)) }
        guard let url = makeURL("filter_options", q) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoFilterOptionsResponse.self, from: data)
    }

    // 搜索
    static func search(keyword: String, userId: String?, maxYear: Int? = nil) async throws -> [OVideoItem] {
        var q = [URLQueryItem(name: "q", value: keyword)]
        if let uid = userId, !uid.isEmpty { q.append(URLQueryItem(name: "user_id", value: uid)) }
        if let y = maxYear { q.append(URLQueryItem(name: "max_year", value: String(y))) }
        guard let url = makeURL("search2", q) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoListResponse.self, from: data).items
    }

    // 详情播放列表（仅有效链接）
    static func fetchPlaylist(url itemURL: String) async throws -> [OVideoChannel] {
        guard let encoded = itemURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/playlist?url=\(encoded)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OVideoPlaylistResponse.self, from: data).playlist
    }

    static func resolveRealURL(episodeURL: String) async throws -> String {
        if episodeURL.lowercased().contains(".m3u8") {
            return episodeURL
        }
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

    // 提交寻片/许愿请求
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

    // 【第二阶段】拉取我的未读回复
    static func fetchMyWishReplies(userId: String) async throws -> [WishReply] {
        guard let url = makeURL("wish/my_replies",
                                [URLQueryItem(name: "user_id", value: userId)]) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(WishRepliesResponse.self, from: data).replies
    }

    // 【第二阶段】标记回复已读
    static func ackWishReply(id: Int, userId: String) async {
        guard let url = URL(string: "\(baseURL)/wish/ack_reply") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "user_id": userId])
        _ = try? await URLSession.shared.data(for: req)
    }

    // 【举报回复】拉取我的未读回复
    static func fetchMyReportReplies(userId: String) async throws -> [ReportReply] {
        guard let url = makeURL("report/my_replies",
                                [URLQueryItem(name: "user_id", value: userId)]) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ReportRepliesResponse.self, from: data).replies
    }

    // 【举报回复】标记回复已读
    static func ackReportReply(id: Int, userId: String) async {
        guard let url = URL(string: "\(baseURL)/report/ack_reply") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "user_id": userId])
        _ = try? await URLSession.shared.data(for: req)
    }
}

// ⭐ 中英文混合人名清洗（详情页仍要用）
func cleanName(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let chineseRegex = "[\u{4e00}-\u{9fa5}·]+"
    if let range = trimmed.range(of: chineseRegex, options: .regularExpression) {
        return String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

// MARK: - 寻片回复模型（第二阶段）
struct WishRepliesResponse: Codable { let replies: [WishReply] }
struct WishReply: Codable, Identifiable, Hashable {
    let id: Int
    let wish_content: String
    let admin_reply: String?
    let replied_at: String?
}

// MARK: - 举报回复模型
struct ReportRepliesResponse: Codable { let replies: [ReportReply] }
struct ReportReply: Codable, Identifiable, Hashable {
    let id: Int
    let video_title: String?
    let episode_name: String?
    let admin_reply: String?
    let replied_at: String?
}

// MARK: - 响应模型
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

// 旧结构保留（向后兼容，不再使用）
struct OVideoResponse: Codable { let categories: [OVideoCategory] }
struct OVideoCategory: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let items: [OVideoItem]
}

// MARK: - 数据模型
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
    let playlist: [OVideoChannel]?   // ⭐ 列表接口不返回 playlist
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

// MARK: - 排序 / 展示辅助
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

// 排序枚举
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

// MARK: - 缓存元数据（不变）
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

// MARK: - 数据管理器（分页 / 按需）
@MainActor
class OVideoDataManager: ObservableObject {
    // ⭐ 默认含 Featured（兜底用，正常会被服务器返回覆盖）
    @Published var categoryNames: [String] = ["Featured", "Movie", "Drama", "Show", "Anime"]
    // 【新增】审核员模式：只看 <= 此年份的老片（nil 表示不限制）
    @Published var reviewMaxYear: Int? = nil {
        didSet {
            // 限定条件变化时，把已经加载的旧片单清掉，强制按新 key 重新拉
            if oldValue != reviewMaxYear {
                pageItems.removeAll(); hasMore.removeAll()
                nextPage.removeAll(); loadingKeys.removeAll()
            }
        }
    }
    @Published var isBootstrapping = false
    @Published var bootstrapError: String? = nil

    // 每个 "category|sort" 的分页缓存
    @Published private(set) var pageItems: [String: [OVideoItem]] = [:]
    @Published private(set) var hasMore: [String: Bool] = [:]
    @Published private(set) var loadingKeys: Set<String> = []
    private var nextPage: [String: Int] = [:]

    private let pageSize = 24
    private var didBootstrap = false
    private var loadedUserId: String? = nil

    // 兼容旧 UI（底部栏不再依赖加载状态）
    var isLoading: Bool { isBootstrapping }

    func cacheKey(_ cat: String, _ sort: VideoSortOption) -> String {
        if let y = reviewMaxYear { return "\(cat)|\(sort.rawValue)|ry\(y)" }
        return "\(cat)|\(sort.rawValue)"
    }

    func items(category: String, sort: VideoSortOption) -> [OVideoItem] {
        pageItems[cacheKey(category, sort)] ?? []
    }
    func hasMorePages(category: String, sort: VideoSortOption) -> Bool {
        hasMore[cacheKey(category, sort)] ?? true
    }
    func isLoadingPage(category: String, sort: VideoSortOption) -> Bool {
        loadingKeys.contains(cacheKey(category, sort))
    }

    // 引导：拉分类名；用户身份变化时清缓存
    func bootstrap(userId: String?) async {
        if didBootstrap && loadedUserId == userId { return }
        if didBootstrap && loadedUserId != userId {
            pageItems.removeAll(); hasMore.removeAll()
            nextPage.removeAll(); loadingKeys.removeAll()
        }
        loadedUserId = userId
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            let names = try await OVideoAPI.fetchCategories()
            if !names.isEmpty { categoryNames = names }
            bootstrapError = nil
        } catch {
            bootstrapError = error.localizedDescription
        }
        didBootstrap = true
    }

    func loadFirstPageIfNeeded(category: String, sort: VideoSortOption, userId: String?) async {
        if pageItems[cacheKey(category, sort)] != nil { return }
        await loadNextPage(category: category, sort: sort, userId: userId)
    }

    func loadNextPage(category: String, sort: VideoSortOption, userId: String?) async {
        let key = cacheKey(category, sort)
        if loadingKeys.contains(key) { return }
        if let hm = hasMore[key], hm == false { return }
        let page = nextPage[key] ?? 0
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }
        do {
            let resp = try await OVideoAPI.fetchList(category: category, sort: sort,
                                         page: page, pageSize: pageSize,
                                         userId: userId, maxYear: reviewMaxYear)
            var arr = pageItems[key] ?? []
            let existing = Set(arr.map { $0.url })
            arr.append(contentsOf: resp.items.filter { !existing.contains($0.url) })
            pageItems[key] = arr
            hasMore[key] = resp.has_more
            nextPage[key] = page + 1
        } catch {
            // 失败保留 hasMore=true，允许下次重试
        }
    }

    // 搜索
    func search(keyword: String, userId: String?) async -> [OVideoItem] {
        (try? await OVideoAPI.search(keyword: keyword, userId: userId, maxYear: reviewMaxYear)) ?? []
    }

    // 筛选选项
    func fetchFilterOptions(userId: String?) async -> OVideoFilterOptionsResponse? {
        try? await OVideoAPI.fetchFilterOptions(userId: userId)
    }

    // 筛选分页
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

    // 详情播放列表
    func fetchPlaylist(url: String) async -> [OVideoChannel] {
        (try? await OVideoAPI.fetchPlaylist(url: url)) ?? []
    }
}

// MARK: - 搜索历史管理器（不变）
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

// MARK: - 播放记录模型 / 管理器（不变）
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

// MARK: - 寻片回复管理器（第二阶段）
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

// MARK: - 举报回复管理器
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