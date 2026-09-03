import Foundation
import SwiftUI
import Combine

struct MacVideoConfig: Codable {
    var review_mode: Bool?
    var review_max_year: Int?
    var module_enabled: Bool?
    var min_app_version: String?
    var store_url: String?
    var notification: String?
    var update_time: String?
    var category_mappings_review: [String: String]?
}

struct ServerVersionPayload: Codable {
    var version: String?
    var update_time: String?
    var notification: String?
    var is_free_access_day: Bool?
    var mac_video: MacVideoConfig?
}

@MainActor
final class AppConfigManager: ObservableObject {
    static let shared = AppConfigManager()

    @Published var moduleEnabled = true
    @Published var reviewMode = false
    @Published var reviewMaxYear = 1974
    @Published var updateTime = ""
    @Published var notification: String?
    @Published var showForceUpdate = false
    @Published var storeURL = ""
    @Published var reviewCategoryMap: [String: String] = [:]
    @Published private(set) var didFetch = false
    /// 最近一次拉取配置的错误（nil = 正常），供 UI 显示
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let kFirstRunReview  = "GW_FirstRunWasReviewMode"
    private let kDismissedNotice = "GW_DismissedNotice"
    private let kEverFetched     = "GW_EverFetchedConfig"
    private let kCachedReview    = "GW_CachedReviewMode"
    private let kCachedMaxYear   = "GW_CachedReviewMaxYear"
    private let base = "http://106.15.183.158:5001/api/ONews"

    /// ⭐ 正在进行的拉取任务：保证「同时只有一次网络请求」，且所有调用者都能 await 到结果
    private var inflight: Task<Void, Never>?

    private init() {
        let d = UserDefaults.standard
        // 之前成功拿过配置 → 先用缓存值，避免离线时误进「1974 老片馆」
        if d.bool(forKey: kEverFetched) {
            reviewMode    = d.bool(forKey: kCachedReview)
            reviewMaxYear = (d.object(forKey: kCachedMaxYear) as? Int) ?? 1974
        }
    }

    /// 是否对当前用户使用「1974 老片伪装」
    /// 规则：服务器 review_mode=true 且 本机首次安装时服务器就处于审核态
    /// 尚未拿到配置时：只有「全新安装且从未成功联网」才保守判定为审核态
    var useReviewDisguise: Bool {
        let d = UserDefaults.standard
        if !didFetch {
            if d.bool(forKey: kEverFetched) {
                // 有历史配置缓存 → 按缓存判断，不再无脑伪装
                return d.bool(forKey: kCachedReview) && d.bool(forKey: kFirstRunReview)
            }
            return d.object(forKey: kFirstRunReview) == nil
        }
        guard reviewMode else { return false }
        return d.bool(forKey: kFirstRunReview)
    }
    var effectiveMaxYear: Int? { useReviewDisguise ? reviewMaxYear : nil }

    func categoryDisplayName(_ key: String, english: Bool) -> String {
        if useReviewDisguise, let raw = reviewCategoryMap[key] {
            let parts = raw.components(separatedBy: "|")
            return english ? (parts.count > 1 ? parts[1] : parts[0]) : parts[0]
        }
        if english { return key }
        switch key {
        case "Featured": return "最新"
        case "Movie":    return "电影"
        case "Drama":    return "剧集"
        case "Show":     return "综艺"
        case "Anime":    return "动漫"
        default:         return key
        }
    }

    /// 带重试的配置拉取（并发安全：重复调用会复用同一个任务）
    func refresh(retries: Int = 2) async {
        if let t = inflight { await t.value; return }
        let t = Task { @MainActor in
            self.isRefreshing = true
            for attempt in 0...max(0, retries) {
                if await self.fetchOnce() { break }
                if attempt < retries { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            self.isRefreshing = false
        }
        inflight = t
        await t.value
        inflight = nil
    }

    /// ⭐ 所有「依赖 max_year 的列表请求」都必须先 await 这个，避免冷启动误用 1974 老片模式
    func ensureFetched() async {
        if didFetch { return }
        await refresh(retries: 1)
    }

    private func fetchOnce() async -> Bool {
        guard let url = URL(string: "\(base)/check_version") else {
            lastError = "配置地址无效"; return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(VideoAPI.ua, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                lastError = "配置接口返回 \(h.statusCode)"
                print("❌ [Config] check_version HTTP \(h.statusCode)")
                return false
            }
            let payload = try JSONDecoder().decode(ServerVersionPayload.self, from: data)
            apply(payload)
            lastError = nil
            print("✅ [Config] reviewMode=\(reviewMode) maxYear=\(String(describing: effectiveMaxYear)) moduleEnabled=\(moduleEnabled)")
            return true
        } catch {
            let ns = error as NSError
            lastError = "\(ns.localizedDescription)（\(ns.code)）"
            print("❌ [Config] check_version 失败: \(ns.code) \(ns.localizedDescription)")
            return false
        }
    }

    private func apply(_ payload: ServerVersionPayload) {
        let c = payload.mac_video ?? MacVideoConfig()
        moduleEnabled  = c.module_enabled ?? true
        reviewMode     = c.review_mode ?? false
        reviewMaxYear  = c.review_max_year ?? 1974
        updateTime     = c.update_time ?? payload.update_time ?? ""
        storeURL       = c.store_url ?? ""
        reviewCategoryMap = c.category_mappings_review ?? [:]

        let d = UserDefaults.standard
        // 首次拿到配置时，固化「本机安装时刻服务器是否在审核态」
        if d.object(forKey: kFirstRunReview) == nil { d.set(reviewMode, forKey: kFirstRunReview) }
        d.set(true, forKey: kEverFetched)
        d.set(reviewMode, forKey: kCachedReview)
        d.set(reviewMaxYear, forKey: kCachedMaxYear)

        let note = (c.notification ?? payload.notification ?? "").trimmingCharacters(in: .whitespaces)
        notification = (note.isEmpty || note == d.string(forKey: kDismissedNotice)) ? nil : note

        if let minV = c.min_app_version, isVersion(DeviceIdentity.appVersion, lessThan: minV) {
            showForceUpdate = true
        }
        didFetch = true
    }

    func dismissNotification() {
        if let n = notification { UserDefaults.standard.set(n, forKey: kDismissedNotice) }
        notification = nil
    }

    /// 调试用：清掉「首次安装处于审核态」的标记
    func resetReviewFlagForDebug() {
        UserDefaults.standard.removeObject(forKey: kFirstRunReview)
    }

    private func isVersion(_ a: String, lessThan b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }
        let y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

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
