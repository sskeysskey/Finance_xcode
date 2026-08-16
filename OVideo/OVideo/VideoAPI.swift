import Foundation

enum VideoAPI {
    static let baseURL = "http://106.15.183.158:5001/api/OVideo"
    static let ua = "OVideo-macOS/\(DeviceIdentity.appVersion)"

    /// 排查空白页时打开，会打印每条请求的 URL / 字节数 / 错误
    static var verboseLog = true

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        return URLSession(configuration: c)
    }()

    static func coverURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty,
              let e = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(baseURL)/cover/\(e)")
    }

    private static func req(_ path: String, _ items: [URLQueryItem], timeout: TimeInterval = 15) -> URLRequest? {
        guard var c = URLComponents(string: "\(baseURL)/\(path)") else { return nil }
        c.queryItems = items.isEmpty ? nil : items
        guard let u = c.url else { return nil }
        var r = URLRequest(url: u); r.timeoutInterval = timeout
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        return r
    }

    // MARK: - 统一 GET + 日志
    private static func rawData(_ path: String, _ items: [URLQueryItem],
                               timeout: TimeInterval) async throws -> Data {
        guard let r = req(path, items, timeout: timeout) else { throw URLError(.badURL) }
        do {
            let (d, resp) = try await session.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                if verboseLog {
                    print("❌ [API] \(path) HTTP \(h.statusCode) body=\(String(data: d.prefix(200), encoding: .utf8) ?? "-")")
                }
                throw NSError(domain: "GW", code: h.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(h.statusCode)"])
            }
            if verboseLog { print("✅ [API] \(r.url?.absoluteString ?? path) → \(d.count) bytes") }
            return d
        } catch {
            let ns = error as NSError
            if verboseLog {
                print("❌ [API] \(r.url?.absoluteString ?? path) 失败: code=\(ns.code) \(ns.localizedDescription)")
            }
            throw error
        }
    }

    private static func fetch<T: Decodable>(_ type: T.Type, _ path: String,
                                            _ items: [URLQueryItem] = [],
                                            timeout: TimeInterval = 15) async throws -> T {
        let d = try await rawData(path, items, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: d) }
        catch {
            if verboseLog {
                print("❌ [API] \(path) JSON 解码失败: \(error)")
                print("   原始前 400 字: \(String(data: d.prefix(400), encoding: .utf8) ?? "-")")
            }
            throw error
        }
    }

    // MARK: - 业务接口
    static func fetchCategories() async throws -> [String] {
        try await fetch(CategoriesResponse.self, "categories").categories
    }

    static func fetchList(category: String, sort: VideoSortOption, page: Int, pageSize: Int,
                          userId: String?, maxYear: Int?) async throws -> ListResponse {
        var q = [URLQueryItem(name: "category", value: category),
                 URLQueryItem(name: "sort", value: sort.rawValue),
                 URLQueryItem(name: "page", value: String(page)),
                 URLQueryItem(name: "page_size", value: String(pageSize))]
        if let u = userId, !u.isEmpty { q.append(.init(name: "user_id", value: u)) }
        if let y = maxYear { q.append(.init(name: "max_year", value: String(y))) }
        return try await fetch(ListResponse.self, "list", q)
    }

    static func fetchFilter(category: String?, type: String?, year: Int?, region: String?,
                            sort: VideoSortOption, page: Int, pageSize: Int,
                            userId: String?, maxYear: Int?) async throws -> ListResponse {
        var q = [URLQueryItem(name: "sort", value: sort.rawValue),
                 URLQueryItem(name: "page", value: String(page)),
                 URLQueryItem(name: "page_size", value: String(pageSize))]
        if let c = category { q.append(.init(name: "category", value: c)) }
        if let t = type     { q.append(.init(name: "type", value: t)) }
        if let y = year     { q.append(.init(name: "year", value: String(y))) }
        if let g = region   { q.append(.init(name: "region", value: g)) }
        if let u = userId, !u.isEmpty { q.append(.init(name: "user_id", value: u)) }
        if let m = maxYear { q.append(.init(name: "max_year", value: String(m))) }
        return try await fetch(ListResponse.self, "filter", q)
    }

    static func fetchFilterOptions(userId: String?) async throws -> FilterOptionsResponse {
        var q: [URLQueryItem] = []
        if let u = userId, !u.isEmpty { q.append(.init(name: "user_id", value: u)) }
        return try await fetch(FilterOptionsResponse.self, "filter_options", q)
    }

    static func search(keyword: String, userId: String?, maxYear: Int?) async throws -> [VideoItem] {
        var q = [URLQueryItem(name: "q", value: keyword)]
        if let u = userId, !u.isEmpty { q.append(.init(name: "user_id", value: u)) }
        if let y = maxYear { q.append(.init(name: "max_year", value: String(y))) }
        return try await fetch(ListResponse.self, "search2", q).items
    }

    static func fetchPlaylist(url itemURL: String) async throws -> [VideoChannel] {
        try await fetch(PlaylistResponse.self, "playlist",
                        [.init(name: "url", value: itemURL)]).playlist
    }

    static func fetchDetail(url itemURL: String) async -> VideoItem? {
        struct R: Codable { let item: VideoItem }
        return try? await fetch(R.self, "detail", [.init(name: "url", value: itemURL)]).item
    }

    static func resolveRealURL(episodeURL: String) async throws -> String {
        if episodeURL.lowercased().contains(".m3u8") { return episodeURL }
        guard let u = URL(string: "\(baseURL)/resolve") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["url": episodeURL])
        let (d, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg: String
            switch h.statusCode {
            case 403: msg = T("该视频暂不可用", "This video is unavailable")
            case 404: msg = T("未找到可播放资源", "No playable source found")
            default:  msg = T("解析失败 (\(h.statusCode))", "Resolve failed (\(h.statusCode))")
            }
            throw NSError(domain: "GW", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        struct R: Codable { let real_url: String }
        return try JSONDecoder().decode(R.self, from: d).real_url
    }

    // 追剧
    static func fetchSeriesStatus(urls: [String]) async -> [SeriesStatus] {
        guard !urls.isEmpty, let u = URL(string: "\(baseURL)/track_series/status") else { return [] }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["urls": urls])
        guard let (d, _) = try? await session.data(for: r) else { return [] }
        struct R: Codable { let items: [SeriesStatus] }
        return (try? JSONDecoder().decode(R.self, from: d))?.items ?? []
    }

    // 寻片 / 举报回复
    static func submitWish(content: String, keyword: String?, userId: String?, userType: String) async throws {
        guard let u = URL(string: "\(baseURL)/wish") else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["wish_content": content, "user_type": userType,
                                   "app_version": DeviceIdentity.appVersion]
        if let k = keyword, !k.isEmpty { body["keyword"] = k }
        if let i = userId, !i.isEmpty { body["user_id"] = i }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            throw NSError(domain: "GW", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey:
                h.statusCode == 429 ? T("提交太频繁，请稍后再试", "Too frequent, try later")
                                    : T("提交失败", "Submit failed")])
        }
    }

    static func fetchWishReplies(userId: String) async -> [WishReply] {
        struct R: Codable { let replies: [WishReply] }
        return (try? await fetch(R.self, "wish/my_replies",
                                 [.init(name: "user_id", value: userId)], timeout: 12).replies) ?? []
    }
    static func ackWishReply(id: Int, userId: String) async {
        await ack(path: "wish/ack_reply", id: id, userId: userId)
    }
    static func fetchReportReplies(userId: String) async -> [ReportReply] {
        struct R: Codable { let replies: [ReportReply] }
        return (try? await fetch(R.self, "report/my_replies",
                                 [.init(name: "user_id", value: userId)], timeout: 12).replies) ?? []
    }
    static func ackReportReply(id: Int, userId: String) async {
        await ack(path: "report/ack_reply", id: id, userId: userId)
    }
    private static func ack(path: String, id: Int, userId: String) async {
        guard let u = URL(string: "\(baseURL)/\(path)") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "user_id": userId])
        _ = try? await session.data(for: r)
    }
}

// MARK: - Models
struct CategoriesResponse: Codable { let categories: [String] }

/// 容错版：单条 item 解码失败不会让整页数据丢光（droppedItems 记录被跳过的条数）
struct ListResponse: Codable {
    let items: [VideoItem]
    let has_more: Bool
    let page: Int
    var droppedItems: Int = 0

    enum CodingKeys: String, CodingKey { case items, has_more, page }

    private struct Lenient: Decodable {
        let value: VideoItem?
        init(from decoder: Decoder) throws { value = try? VideoItem(from: decoder) }
    }

    init(items: [VideoItem], has_more: Bool, page: Int) {
        self.items = items; self.has_more = has_more; self.page = page
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([Lenient].self, forKey: .items) ?? []
        let good = raw.compactMap(\.value)
        items = good
        droppedItems = raw.count - good.count
        has_more = (try? c.decode(Bool.self, forKey: .has_more)) ?? false
        page = (try? c.decode(Int.self, forKey: .page)) ?? 0
    }
}

struct FilterOptionsResponse: Codable { let types: [String]; let years: [Int]; let regions: [String] }
struct PlaylistResponse: Codable { let playlist: [VideoChannel] }
struct SeriesStatus: Codable {
    let url: String; let category: String?; let name: String?; let image: String?
    let info: String?; let update: String?; let episode_count: Int; let unavailable: Bool?
}
struct WishReply: Codable, Identifiable, Hashable {
    let id: Int; let wish_content: String; let admin_reply: String?; let replied_at: String?
}
struct ReportReply: Codable, Identifiable, Hashable {
    let id: Int; let video_title: String?; let episode_name: String?
    let admin_reply: String?; let replied_at: String?
}

struct VideoItem: Codable, Identifiable, Hashable {
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
    let update: String?

    enum CodingKeys: String, CodingKey {
        case time, name, url, info, image, date, alias, intro, update
        case director = "导演", writers = "编剧", cast = "主演"
        case types = "类型", region = "地区", ratings = "评分"
    }
    func hash(into h: inout Hasher) { h.combine(url) }
    static func == (l: VideoItem, r: VideoItem) -> Bool { l.url == r.url }

    var releaseYear: Int? {
        guard let raw = date, !raw.isEmpty else { return nil }
        let c = raw.split(separator: "(").first.map(String.init) ?? raw
        if let f = c.split(separator: "-").first, let y = Int(f) { return y }
        return nil
    }
    var bestRating: Double { (ratings?.values.compactMap { Double($0) }.max()) ?? 0 }
    var starringCast: [String] { Array((cast ?? []).prefix(2)) }
    var otherCast: [String] { (cast ?? []).count > 3 ? Array((cast ?? []).dropFirst(2)) : [] }
}

struct VideoChannel: Codable, Hashable {
    let name: String
    let episodes: [String: String]
    let episodeOrder: [String]?
    enum CodingKeys: String, CodingKey { case name, episodes, episodeOrder = "episode_order" }

    func sortedEpisodes(ascending: Bool = true) -> [(name: String, url: String)] {
        if let order = episodeOrder, !order.isEmpty {
            let ordered = order.compactMap { k -> (name: String, url: String)? in
                guard let u = episodes[k] else { return nil }; return (k, u)
            }
            if ordered.count == episodes.count { return ascending ? ordered : ordered.reversed() }
        }
        return episodes.sorted { a, b in
            if let x = Int(a.key), let y = Int(b.key) { return ascending ? x < y : x > y }
            let c = a.key.localizedStandardCompare(b.key)
            return ascending ? c == .orderedAscending : c == .orderedDescending
        }.map { ($0.key, $0.value) }
    }

    func episodeItems(ascending: Bool = true) -> [EpisodeItem] {
        sortedEpisodes(ascending: ascending).enumerated().map { i, kv in
            EpisodeItem(number: Self.shortNumber(kv.name, i), name: kv.name, url: kv.url)
        }
    }
    private static func shortNumber(_ name: String, _ idx: Int) -> String {
        let d = name.filter { $0.isNumber }
        if !d.isEmpty, d.count <= 4, let n = Int(d) { return String(n) }
        return String(idx + 1)
    }
    var distinctCount: Int {
        var s = Set<String>()
        for k in episodes.keys {
            let d = k.filter { $0.isNumber }
            if d.isEmpty { s.insert(k) } else if let n = Int(d) { s.insert("n\(n)") } else { s.insert(d) }
        }
        return s.count
    }
}

struct EpisodeItem: Codable, Identifiable, Hashable {
    var id: String { url }
    let number: String
    let name: String
    let url: String
}

enum VideoSortOption: String, CaseIterable, Codable {
    case update, date, rating
    func name(_ en: Bool) -> String {
        switch self {
        case .date:   return en ? "Release Date" : "上映日期"
        case .update: return en ? "Last Updated" : "更新日期"
        case .rating: return en ? "Rating" : "评分"
        }
    }
    var icon: String {
        switch self { case .date: return "calendar"; case .update: return "clock"; case .rating: return "star.fill" }
    }
}

/// 线路排序：实际集数 > 总链接数 > 画质 > 原顺序（与 iOS 版一致）
func optimalChannels(_ chs: [VideoChannel]) -> [VideoChannel] {
    chs.enumerated().map { (i, c) -> (Int, VideoChannel, Int, Int, Int) in
        var q = 1
        let keys = c.episodes.keys.map { $0.uppercased() }
        if keys.contains(where: { $0.contains("TC") || $0.contains("TS") || $0.contains("HC") || $0.contains("抢先") }) { q = 0 }
        else if keys.contains(where: { $0.contains("HD") || $0.contains("正片") }) { q = 2 }
        return (i, c, c.distinctCount, c.episodes.count, q)
    }
    .sorted { a, b in
        if a.2 != b.2 { return a.2 > b.2 }
        if a.3 != b.3 { return a.3 > b.3 }
        if a.4 != b.4 { return a.4 > b.4 }
        return a.0 < b.0
    }
    .map { $0.1 }
}

func cleanName(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return "" }
    let hasCN = t.range(of: "[\u{4e00}-\u{9fa5}]", options: .regularExpression) != nil
    if hasCN, let r = t.range(of: "[\u{4e00}-\u{9fa5}·]+", options: .regularExpression) {
        let e = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: "·").union(.whitespaces))
        if !e.isEmpty { return e }
    }
    return t
}

extension VideoItem {
    /// 供「下载更多」等场景构造轻量 item
    init(seriesName: String, sourceURL: String, cover: String?) {
        self.init(time: nil, name: seriesName, url: sourceURL, info: nil, image: cover,
                  director: nil, writers: nil, cast: nil, types: nil, region: nil,
                  date: nil, alias: nil, intro: nil, ratings: nil, update: nil)
    }
}