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

    /// 带重试的配置拉取；失败会写入 lastError（不再静默）
    func refresh(retries: Int = 2) async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for attempt in 0...max(0, retries) {
            if await fetchOnce() { return }
            if attempt < retries { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        }
    }

    private func fetchOnce() async -> Bool {
        guard let url = URL(string: "\(base)/check_version") else {
            lastError = "配置地址无效"; return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
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
            print("✅ [Config] 已获取配置：reviewMode=\(reviewMode) maxYear=\(String(describing: effectiveMaxYear)) moduleEnabled=\(moduleEnabled)")
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