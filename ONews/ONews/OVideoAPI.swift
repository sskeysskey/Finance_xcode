// API 接口、数据模型、排序枚举、缓存元数据
// 纯数据层，所有模块都依赖

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
    
    // 【保留】老的全量接口，作为兜底，新客户端不再使用
    static func fetchVideos(userId: String? = nil) async throws -> [OVideoCategory] {
        var urlString = "\(baseURL)/videos"
        if let uid = userId, !uid.isEmpty,
           let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "?user_id=\(encoded)"
        }
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OVideoResponse.self, from: data)
        return response.categories
    }
    
    // 【新增】只取分类名（极轻量）
    static func fetchCategories(userId: String? = nil) async throws -> [String] {
        var urlString = "\(baseURL)/categories"
        if let uid = userId, !uid.isEmpty,
           let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "?user_id=\(encoded)"
        }
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(OVideoCategoriesResponse.self, from: data).categories
    }
    
    // 【新增】分页拉取某分类（已按 sort 在服务端排好序）
    static func fetchVideoPage(category: String,
                               sort: VideoSortOption,
                               page: Int,
                               pageSize: Int,
                               userId: String?) async throws -> OVideoListResponse {
        guard var comp = URLComponents(string: "\(baseURL)/list") else { throw URLError(.badURL) }
        var q = [
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        if let uid = userId, !uid.isEmpty {
            q.append(URLQueryItem(name: "user_id", value: uid))
        }
        comp.queryItems = q
        guard let url = comp.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(OVideoListResponse.self, from: data)
    }

    // 放到 OVideoAPI 内（fetchVideoPage 后面）
    static func fetchDetail(url: String, userId: String? = nil) async throws -> [OVideoChannel] {
        guard var comp = URLComponents(string: "\(baseURL)/detail") else { throw URLError(.badURL) }
        var q = [URLQueryItem(name: "url", value: url)]
        if let uid = userId, !uid.isEmpty {
            q.append(URLQueryItem(name: "user_id", value: uid))
        }
        comp.queryItems = q
        guard let u = comp.url else { throw URLError(.badURL) }
        var request = URLRequest(url: u)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(OVideoDetailResponse.self, from: data).playlist
    }
    
    static func resolveRealURL(episodeURL: String) async throws -> String {
        // 【核心修改】：如果本身就是 m3u8 链接，直接返回，跳过网络请求
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
}

// MARK: - 搜索索引条目（预处理小写）
struct SearchIndexEntry {
    let item: OVideoItem
    let categoryName: String
    let nameLower: String
    let aliasLower: String
    let typesLower: String
    let directorLower: String
    let castLower: String
    let introLower: String
    // 新增：归一化版本（移除 · 和空格，用于模糊匹配）
    let nameNormalized: String
    let aliasNormalized: String
    let directorNormalized: String
    let castNormalized: String
}

// 新增：搜索归一化辅助函数（文件顶层全局函数，不能加 static）
private func normalizeSearchText(_ text: String) -> String {
    text.lowercased()
        .replacingOccurrences(of: "·", with: "")
        .replacingOccurrences(of: " ", with: "")
}

// ⭐ 新增：中英文混合人名清洗提取函数（文件顶层全局函数）
// 如果包含中文，则只提取中文部分；如果只有英文，则保留英文。
func cleanName(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    
    // 正则表达式匹配中文字符
    let chineseRegex = "[\u{4e00}-\u{9fa5}·]+"
    if let range = trimmed.range(of: chineseRegex, options: .regularExpression) {
        // 提取匹配到的中文部分（例如 "安东尼·麦凯"）并去除首尾空格
        return String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // 如果没有中文，则返回原始去除首尾空格的名字（如纯英文 "Omar Al-Atawi"）
    return trimmed
}

// MARK: - 数据模型
struct OVideoResponse: Codable {
    let categories: [OVideoCategory]
}

// 【新增】分类名响应
struct OVideoCategoriesResponse: Codable {
    let categories: [String]
}

// 【新增】分页响应
struct OVideoListResponse: Codable {
    let items: [OVideoItem]
    let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

// 放到 OVideoListResponse 附近
struct OVideoDetailResponse: Codable {
    let playlist: [OVideoChannel]
}

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
    let playlist: [OVideoChannel]
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

    // ⭐ 新增：列表接口不下发 playlist，缺省给空数组
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time     = try c.decodeIfPresent(String.self, forKey: .time)
        name     = try c.decode(String.self, forKey: .name)
        url      = try c.decode(String.self, forKey: .url)
        info     = try c.decodeIfPresent(String.self, forKey: .info)
        image    = try c.decodeIfPresent(String.self, forKey: .image)
        director = try c.decodeIfPresent(String.self, forKey: .director)
        writers  = try c.decodeIfPresent([String].self, forKey: .writers)
        cast     = try c.decodeIfPresent([String].self, forKey: .cast)
        types    = try c.decodeIfPresent([String].self, forKey: .types)
        region   = try c.decodeIfPresent(String.self, forKey: .region)
        date     = try c.decodeIfPresent(String.self, forKey: .date)
        alias    = try c.decodeIfPresent(String.self, forKey: .alias)
        intro    = try c.decodeIfPresent(String.self, forKey: .intro)
        ratings  = try c.decodeIfPresent([String: String].self, forKey: .ratings)
        playlist = try c.decodeIfPresent([OVideoChannel].self, forKey: .playlist) ?? []
        update   = try c.decodeIfPresent(String.self, forKey: .update)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: OVideoItem, rhs: OVideoItem) -> Bool { lhs.url == rhs.url }
}

struct OVideoChannel: Codable, Hashable {
    let name: String
    let episodes: [String: String]
    // 【新增】服务器下发的原始集数顺序（与 JSON 中的书写顺序完全一致）
    let episodeOrder: [String]?
    
    enum CodingKeys: String, CodingKey {
        case name, episodes
        case episodeOrder = "episode_order"
    }
    
    var sortedEpisodes: [(name: String, url: String)] {
        sortedEpisodes(ascending: true)
    }
    
    func sortedEpisodes(ascending: Bool) -> [(name: String, url: String)] {
        // 【核心】优先使用服务器下发的原始顺序：
        // JSON 本身就是正确的时间顺序，正序直接用，倒序则 reversed
        if let order = episodeOrder, !order.isEmpty {
            let ordered = order.compactMap { key -> (name: String, url: String)? in
                guard let url = episodes[key] else { return nil }
                return (name: key, url: url)
            }
            // 数量一致才信任（防止 order 与 episodes 不匹配时漏集）
            if ordered.count == episodes.count {
                return ascending ? ordered : ordered.reversed()
            }
        }
        
        // 兜底（旧缓存数据 / 缺少 episode_order 时）：沿用原有智能排序
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

// MARK: - 排序 / 筛选辅助
extension OVideoItem {
    // ⭐ 性能优化：用字符串作为排序 key，避免 DateFormatter 调用
    // "yyyy-MM-dd HH:mm:ss" 的字典序与时间序一致
    var updateSortKey: String { update ?? "" }
    
    // 上映日期清洗后字典序也等同时间序（年-月-日 定长前缀）
    var releaseSortKey: String {
        guard let raw = date, !raw.isEmpty else { return "" }
        return raw.split(separator: "(").first.map(String.init) ?? raw
    }
    
    // 下面这两个 Date 计算属性保留用于详情页等"展示用途"，不再用于排序
    var updateDate: Date {
        guard let raw = update, !raw.isEmpty else { return .distantPast }
        return OVideoItem.updateDateFormatter.date(from: raw) ?? .distantPast
    }
    
    var releaseDate: Date {
        guard let raw = date, !raw.isEmpty else { return .distantPast }
        let cleaned = raw.split(separator: "(").first.map(String.init) ?? raw
        let parts = cleaned.split(separator: "-")
        var comp = DateComponents()
        comp.year = 1970; comp.month = 1; comp.day = 1
        if parts.count >= 1, let y = Int(parts[0]) { comp.year = y }
        if parts.count >= 2, let m = Int(parts[1]) { comp.month = m }
        if parts.count >= 3, let d = Int(parts[2]) { comp.day = d }
        return Calendar.current.date(from: comp) ?? .distantPast
    }
    
    private static let updateDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    
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

    // 新增：演员拆分逻辑
    var starringCast: [String] {
        guard let cast = cast else { return [] }
        return Array(cast.prefix(2))
    }
    
    var otherCast: [String] {
        guard let cast = cast, cast.count > 3 else { return [] }
        return Array(cast.dropFirst(2))
    }

    // 这里定义你的归类逻辑
    var normalizedRegion: String {
        guard let r = region, !r.isEmpty else { return "其它" }
        
        // 【新增修改】：提取第一个斜杠 "/" 前面的国家/地区，并去除首尾空格
        let firstRegion = r.split(separator: "/")
                           .first?
                           .trimmingCharacters(in: .whitespacesAndNewlines) ?? r
        
        // 归类映射 (使用提取后的 firstRegion 进行匹配)
        let chinaRegions = ["中国大陆", "内地", "澳门", "大陆", "大陆国语", "中国"]
        let chinataiwanRegions = ["台湾", "港台", "中国台湾"]
        let chinahongkongRegions = ["香港", "中国香港", "中国澳门"]
        let europeRegions = [
            "英国", "西班牙", "挪威", "瑞典", "丹麦", "乌克兰", "南斯拉夫", "塞浦路斯", "奥地利", "UK", "United Kingdom", 
            "保加利亚", "克罗地亚", "塞尔维亚", "德国", "意大利", "捷克", "捷克斯洛伐克", "法国", "波黑", "玻利维亚", 
            "突尼斯", "罗马尼亚", "西德", "马耳他", "澳大利亚", "爱尔兰", "瑞士", "立陶宛", "芬兰", "荷兰", "匈牙利", 
            "希腊", "拉脱维亚", "马其顿", "新西兰", "比利时", "波兰", "NZ", "冰岛", "北马其顿", "卢森堡", "斯洛伐克", 
            "斯洛文尼亚", "澳大利亚Australia", "爱沙尼亚", "英语", "葡萄牙"
        ]
        let asiaRegions = ["乌兹别克斯坦", "俄罗斯", "印度尼西亚", "土耳其", "新加坡", "格鲁吉亚", "泰国", "苏联", "菲律宾", "巴基斯坦", "不丹", "哈萨克斯坦", "塔吉克斯坦", "尼泊尔", "柬埔寨", "蒙古", "越南", "马来西亚"]
        let middleastRegions = ["伊拉克", "伊朗", "以色列", "埃及", "巴勒斯坦", "叙利亚", "巴勒斯坦被占领区", "沙特阿拉伯", "约旦", "苏丹", "阿富汗", "黎巴嫩"]
        let americaRegions = ["加拿大", "墨西哥", "哥伦比亚", "巴西", "智利", "厄瓜多尔", "阿根廷", "秘鲁", "Aruba", "Canada", "Jamaica", "USA", "乌拉圭", "古巴", "委内瑞拉", "牙买加", "特立尼达和多巴哥"]
        let africaRegions = ["南非", "乍得", "埃塞俄比亚", "塞内加尔", "摩洛哥", "阿尔及利亚", "阿尔巴尼亚"]
        
        if chinaRegions.contains(firstRegion) { return "中国" }
        if chinataiwanRegions.contains(firstRegion) { return "中国台湾" }
        if chinahongkongRegions.contains(firstRegion) { return "香港澳门" }
        if europeRegions.contains(firstRegion) { return "欧洲" }
        if asiaRegions.contains(firstRegion) { return "亚洲" }
        if middleastRegions.contains(firstRegion) { return "中东" }
        if americaRegions.contains(firstRegion) { return "北美洲/南美洲" }
        if africaRegions.contains(firstRegion) { return "非洲" }
        
        return firstRegion // 如果不在列表中，返回提取后的第一个国家名称
    }

    // 新增：类型映射逻辑
    var normalizedTypes: [String] {
        guard let types = types else { return [] }
        
        // 定义映射字典：key 是原始名称，value 是归一化后的名称
        let typeMapping: [String: String] = [
            "科幻片": "科幻", "奇幻": "科幻", "异世界": "科幻", "玄幻": "科幻",
            "运动": "体育片",
            "动作片": "动作",
            "武侠": "古装",
            "战争片": "战争", "战斗": "战争",
            "同性": "基腐", "同杏": "基腐",
            
            "人性": "剧情", "剧情片": "剧情", "日常": "剧情", "黑色电影": "剧情",
            "韩剧": "剧情", "美剧": "剧情", "国产剧": "剧情", "港台剧": "剧情",
            "日剧": "剧情", "国产": "剧情", "大陆": "剧情", "泰剧": "剧情",
            "美国": "剧情", "欧美": "剧情", "美国剧": "剧情", "欧美剧": "剧情",
            "日本剧": "剧情", "日本": "剧情", 
            "韩国剧": "剧情", "韩国": "剧情", "日韩": "剧情", "日韩剧": "剧情",
            "香港": "剧情", "台湾": "剧情", "港台": "剧情", "邵氏电影": "剧情",
            "泰国": "剧情", "海外剧": "剧情", "海外": "剧情",
            
            "喜剧片": "喜剧", "搞笑": "喜剧",

            "爱情片": "爱情", "恋爱": "爱情", "情": "爱情", "浪漫": "爱情",

            "丧尸": "恐怖", "恐怖片": "恐怖", "惊栗": "惊悚",
            
            "犯罪片": "犯罪", 

            "记录": "纪录片", "其他": "纪录片", "纪录": "纪录片", "记录片": "纪录片",
            
            // "选秀": "综艺", "大陆综艺": "综艺", "晚会": "综艺", "日韩综艺": "综艺", "欧美综艺": "综艺",
            // "相声": "综艺", "访谈": "综艺", "戏曲": "综艺", "港台综艺": "综艺", "国产综艺": "综艺",

            // "动画": "动漫", "海外动漫": "动漫", "鬼怪": "动漫", "日本动漫": "动漫",
            // "有声动漫": "动漫", "机战": "动漫", "日韩动漫": "动漫", "欧美动漫": "动漫",
            // "游戏": "动漫", "热血": "动漫", "致郁": "动漫", "动漫片": "动漫",
            // "动漫电影": "动漫", "动画电影": "动漫", "国产动漫": "动漫",
        ]
        
        // 映射并去重
        let normalized = types.map { typeMapping[$0] ?? $0 }
        return Array(Set(normalized)) // 返回去重后的数组
    }
}

// 【修改】增加 update 选项，并修改 date 的显示文本
enum VideoSortOption: String, CaseIterable {
    case update, date, rating
    
    func displayName(_ en: Bool) -> String {
        switch self {
        case .date:   return en ? "By Release Date" : "按上映日期"
        case .update: return en ? "By Last Updated" : "按更新日期"
        case .rating: return en ? "By Rating" : "按评分"
        }
    }
    /// 简短名，用于 Toolbar 上的状态指示
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

// MARK: - 缓存元数据
struct VideoCacheMetadata: Codable {
    let title: String
    let coverImage: String?
    let savedAt: Date
    // 【新增】剧集归类用字段（可选，旧缓存数据缺失时自动为 nil）
    var seriesTitle: String?   // 剧名（去掉集数），如「权力的游戏」
    var episodeName: String?   // 集数名，如「第3集」「HD国语」
    var originalEpisodeURL: String?   // 【新增】原始 episodeURL，用于免费次数绑定

}

// 【新增】统一的分组 key 计算逻辑
extension VideoCacheMetadata {
    var groupKey: String {
        if let s = seriesTitle, !s.isEmpty { return "title:" + s }
        if let c = coverImage, !c.isEmpty { return "cover:" + c } // 兜底：同剧封面一致
        return "single:" + title
    }
}

// MARK: - 数据管理器（分页渐进加载）
@MainActor
class OVideoDataManager: ObservableObject {
    @Published var categories: [OVideoCategory] = []
    @Published var isLoading = false          // 仅「首屏」（首个分类第一页）
    @Published var isFullyLoaded = false      // 全部数据后台加载完毕
    @Published var errorMessage: String? = nil
    @Published private(set) var currentSort: VideoSortOption = .date
    
    private var hasLoaded = false
    
    // 【新增】记录上一次加载所用的 userId，用于判断是否需要重新加载
    private var loadedUserId: String? = nil
    private var loadedSort: VideoSortOption? = nil
    
    // 每个分类的分页状态
    private struct PageState {
        var nextPage = 0
        var hasMore = true
        var isLoading = false
        var started = false
    }
    private var pageStates: [String: PageState] = [:]
    
    private let firstPageSize = 20      // 首屏小一点，秒进
    private let backgroundPageSize = 80 // 后台批量大一点，减少刷新次数
    
    private var backgroundTask: Task<Void, Never>? = nil
    private var searchIndex: [SearchIndexEntry] = []
    private var sortCache: [String: [OVideoItem]] = [:]
    
    var allItems: [OVideoItem] { categories.flatMap { $0.items } }
    
    func items(for name: String) -> [OVideoItem] {
        categories.first(where: { $0.name == name })?.items ?? []
    }
    
    func hasMore(for name: String) -> Bool {
        pageStates[name]?.hasMore ?? false
    }
    
    // MARK: 对外入口
    
    func loadVideosIfNeeded(userId: String? = nil,
                            sort: VideoSortOption = .date,
                            initialCategoryIndex: Int = 0) async {
        // 用户身份或排序变了都要重新拉
        if hasLoaded && loadedUserId == userId && loadedSort == sort { return }
        await reloadAll(userId: userId, sort: sort, priorityCategoryIndex: initialCategoryIndex)
    }
    
    // 重试用
    func loadVideos(userId: String? = nil) async {
        await reloadAll(userId: userId, sort: currentSort, priorityCategoryIndex: 0)
    }
    
    // 切换排序：服务端重新排序，重置后从优先分类第一页拉
    func changeSort(to newSort: VideoSortOption, priorityCategoryIndex: Int) async {
        guard newSort != currentSort else { return }
        await reloadAll(userId: loadedUserId, sort: newSort, priorityCategoryIndex: priorityCategoryIndex)
    }
    
    // 用户切到某个尚未开始加载的分类时，立刻拉它的第一页
    func ensureCategoryStarted(_ name: String) {
        guard let st = pageStates[name], !st.started, st.hasMore else { return }
        Task { await loadPage(categoryName: name, pageSize: firstPageSize) }
    }
    
    // 上拉加载更多（兜底，后台通常已自动补齐）
    func loadMore(category name: String) {
        guard let st = pageStates[name], st.hasMore, !st.isLoading else { return }
        Task { await loadPage(categoryName: name, pageSize: backgroundPageSize) }
    }
    
    // MARK: 核心加载流程
    
    private func reloadAll(userId: String?,
                           sort: VideoSortOption,
                           priorityCategoryIndex: Int) async {
        backgroundTask?.cancel()
        backgroundTask = nil
        
        isLoading = true
        errorMessage = nil
        currentSort = sort
        loadedUserId = userId
        loadedSort = sort
        searchIndex = []
        sortCache.removeAll()
        isFullyLoaded = false
        hasLoaded = true
        
        // 1. 分类列表（极轻量）
        let names: [String]
        do {
            let fetched = try await OVideoAPI.fetchCategories(userId: userId)
            names = fetched
        } catch {
            // 兜底固定顺序
            names = ["Movie", "Drama", "Show", "Anime"]
        }
        
        categories = names.map { OVideoCategory(name: $0, items: []) }
        pageStates = Dictionary(uniqueKeysWithValues: names.map { ($0, PageState()) })
        
        guard !names.isEmpty else {
            isLoading = false
            isFullyLoaded = true
            return
        }
        
        // 2. 首屏：优先分类第一页
        let pIdx = min(max(0, priorityCategoryIndex), names.count - 1)
        await loadPage(categoryName: names[pIdx], pageSize: firstPageSize)
        isLoading = false
        
        // 3. 后台补齐剩余页与其他分类
        startBackgroundLoading(priorityIndex: pIdx)
    }
    
    private func loadPage(categoryName: String, pageSize: Int) async {
        guard var st = pageStates[categoryName], st.hasMore, !st.isLoading else { return }
        st.isLoading = true
        st.started = true
        pageStates[categoryName] = st
        
        do {
            let resp = try await OVideoAPI.fetchVideoPage(
                category: categoryName,
                sort: currentSort,
                page: st.nextPage,
                pageSize: pageSize,
                userId: loadedUserId
            )
            appendItems(resp.items, to: categoryName)
            st.nextPage += 1
            st.hasMore = resp.hasMore
            st.isLoading = false
            pageStates[categoryName] = st
        } catch {
            st.isLoading = false
            pageStates[categoryName] = st
            // 仅当这一分类还一条都没有时，才把错误暴露给 UI
            if (categories.first(where: { $0.name == categoryName })?.items.isEmpty ?? true) {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func appendItems(_ items: [OVideoItem], to name: String) {
        guard let idx = categories.firstIndex(where: { $0.name == name }) else { return }
        let merged = categories[idx].items + items
        categories[idx] = OVideoCategory(name: name, items: merged)
        // 排序缓存失效（filter 视图可能仍会用到 sortItems）
        for opt in VideoSortOption.allCases { sortCache["\(name)|\(opt.rawValue)"] = nil }
        // 增量补搜索索引
        if !items.isEmpty {
            let cat = OVideoCategory(name: name, items: items)
            searchIndex.append(contentsOf: Self.buildIndex(from: [cat]))
        }
    }
    
    private func startBackgroundLoading(priorityIndex: Int) {
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            let names = self.orderedNames(priorityIndex: priorityIndex)
            for name in names {
                while !Task.isCancelled {
                    let cont = await self.loadNextBackgroundPage(name)
                    if !cont { break }
                }
                if Task.isCancelled { return }
            }
            if !Task.isCancelled {
                await MainActor.run { self.isFullyLoaded = true }
            }
        }
    }
    
    @MainActor
    private func loadNextBackgroundPage(_ name: String) async -> Bool {
        guard let st = pageStates[name], st.hasMore else { return false }
        if st.isLoading {
            // 正被前台（ensureCategoryStarted / loadMore）加载，稍等再判断
            try? await Task.sleep(nanoseconds: 200_000_000)
            return pageStates[name]?.hasMore ?? false
        }
        let before = st.nextPage
        await loadPage(categoryName: name, pageSize: backgroundPageSize)
        let after = pageStates[name]?.nextPage ?? before
        if after == before { return false } // 没前进（出错）就停
        return pageStates[name]?.hasMore ?? false
    }
    
    @MainActor
    private func orderedNames(priorityIndex: Int) -> [String] {
        let names = categories.map { $0.name }
        guard !names.isEmpty else { return [] }
        let p = min(max(0, priorityIndex), names.count - 1)
        return [names[p]] + names.enumerated().filter { $0.offset != p }.map { $0.element }
    }
    
    // MARK: 搜索索引构建
    nonisolated private static func buildIndex(from categories: [OVideoCategory]) -> [SearchIndexEntry] {
        var entries: [SearchIndexEntry] = []
        for category in categories {
            for item in category.items {
                let nameLower = item.name.lowercased()
                let aliasLower = item.alias?.lowercased() ?? ""
                let typesLower = (item.types ?? []).joined(separator: "\u{1F}").lowercased()
                
                // ⭐ 对导演和演员先进行中英文清洗提取
                let cleanedDirector = item.director.map { cleanName($0) } ?? ""
                let cleanedCast = (item.cast ?? []).map { cleanName($0) }
                
                let directorLower = cleanedDirector.lowercased()
                let castLower = cleanedCast.joined(separator: "\u{1F}").lowercased()
                let introLower = item.intro?.lowercased() ?? ""
                
                entries.append(
                    SearchIndexEntry(
                        item: item,
                        categoryName: category.name,
                        nameLower: nameLower,
                        aliasLower: aliasLower,
                        typesLower: typesLower,
                        directorLower: directorLower,
                        castLower: castLower,
                        introLower: introLower,
                        nameNormalized: normalizeSearchText(item.name),
                        aliasNormalized: normalizeSearchText(item.alias ?? ""),
                        directorNormalized: normalizeSearchText(cleanedDirector),
                        castNormalized: normalizeSearchText(cleanedCast.joined(separator: "\u{1F}"))
                    )
                )
            }
        }
        return entries
    }
    
    // MARK: 排序（保留给 Filter 视图使用）
    func sortItems(_ items: [OVideoItem],
                   by option: VideoSortOption,
                   cacheKey: String? = nil) -> [OVideoItem] {
        if let key = cacheKey {
            let fullKey = "\(key)|\(option.rawValue)"
            if let cached = sortCache[fullKey] { return cached }
            let sorted = performSort(items, by: option)
            sortCache[fullKey] = sorted
            return sorted
        }
        return performSort(items, by: option)
    }

    private func performSort(_ items: [OVideoItem],
                             by option: VideoSortOption) -> [OVideoItem] {
        switch option {
        case .update:
            return items.sorted { $0.updateSortKey > $1.updateSortKey }
        case .date:
            return items.sorted { $0.releaseSortKey > $1.releaseSortKey }
        case .rating:
            return items.sorted { a, b in
                if a.bestRating == b.bestRating {
                    return a.releaseSortKey > b.releaseSortKey
                }
                return a.bestRating > b.bestRating
            }
        }
    }
    
    // MARK: 搜索（在已加载到的索引上做；后台补齐后即为全量）
    func searchAsync(keyword: String, limit: Int = 200) async -> [OVideoItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        
        // 新增：归一化关键词（移除 · 和空格）
        let kwNormalized = kw.replacingOccurrences(of: "·", with: "")
                             .replacingOccurrences(of: " ", with: "")
        
        let index = self.searchIndex
        
        return await Task.detached(priority: .userInitiated) {
            // 定义分类的原本顺序权重（越小越靠前）
            let categoryOrder = ["Movie": 0, "Drama": 1, "Show": 2, "Anime": 3]
            
            // 临时存储匹配到的条目及其排序权重
            // matchPriority: 0=名字匹配, 1=别名/类型匹配, 2=导演/演员匹配, 3=简介匹配
            // categoryPriority: 0=Movie, 1=Drama, 2=Show, 3=Anime, 4=其它
            var matchedResults: [(item: OVideoItem, matchPriority: Int, categoryPriority: Int)] = []
            matchedResults.reserveCapacity(128)
            
            for entry in index {
                // 周期性检查取消
                if Task.isCancelled { return [] }
                
                var matchPriority: Int? = nil
                
                // 修改：同时匹配原始 lowercase 和归一化版本
                if entry.nameLower.contains(kw) || entry.nameNormalized.contains(kwNormalized) {
                    matchPriority = 0
                } else if entry.aliasLower.contains(kw) || entry.aliasNormalized.contains(kwNormalized) || entry.typesLower.contains(kw) {
                    matchPriority = 1
                } else if entry.directorLower.contains(kw) || entry.directorNormalized.contains(kwNormalized) ||
                          entry.castLower.contains(kw) || entry.castNormalized.contains(kwNormalized) {
                    matchPriority = 2
                } else if entry.introLower.contains(kw) {
                    matchPriority = 3
                }
                
                // 2. 如果匹配成功，计算分类优先级并加入结果集
                if let priority = matchPriority {
                    let catPriority = categoryOrder[entry.categoryName] ?? 4
                    matchedResults.append((entry.item, priority, catPriority))
                }
            }
            
            if Task.isCancelled { return [] }
            
            // 3. 执行多级维度排序
            let sorted = matchedResults.sorted { a, b in
                // 第一层：首先比较匹配优先级（名字匹配 > 别名类型 > 导演演员 > 简介）
                if a.matchPriority != b.matchPriority {
                    return a.matchPriority < b.matchPriority
                }
                
                // 第二层：匹配优先级相同时，优先按照上映日期（releaseSortKey）降序排列（越新越靠前）
                let releaseA = a.item.releaseSortKey
                let releaseB = b.item.releaseSortKey
                if releaseA != releaseB {
                    return releaseA > releaseB // 降序：晚的（大值）在前面
                }
                
                // 第三层：上映日期也一致时，按照分类原本顺序（Movie > Drama > Show > Anime）
                if a.categoryPriority != b.categoryPriority {
                    return a.categoryPriority < b.categoryPriority
                }
                
                // 第四层：前三者都相同时，按照更新时间（updateSortKey）降序
                return a.item.updateSortKey > b.item.updateSortKey
            }
            
            // 4. 截断并返回
            return Array(sorted.prefix(limit).map { $0.item })
        }.value
    }
}

// 旧的 search(keyword:) 可以保留作为兜底，但不再被搜索 UI 使用
// MARK: - 搜索历史管理器
@MainActor
final class SearchHistoryManager: ObservableObject {
    @Published private(set) var histories: [String] = []
    
    private let storageKey = "ONews_VideoSearchHistory"
    private let maxCount = 20
    
    init() { load() }
    
    /// 添加一条记录（已存在则置顶；空字符串忽略）
    func add(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        histories.removeAll { $0.caseInsensitiveCompare(kw) == .orderedSame }
        histories.insert(kw, at: 0)
        if histories.count > maxCount {
            histories = Array(histories.prefix(maxCount))
        }
        save()
    }
    
    func remove(_ keyword: String) {
        histories.removeAll { $0 == keyword }
        save()
    }
    
    func clearAll() {
        histories.removeAll()
        save()
    }
    
    private func save() {
        UserDefaults.standard.set(histories, forKey: storageKey)
    }
    
    private func load() {
        histories = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }
}

// MARK: - 视频播放/浏览记录模型
struct VideoPlayRecord: Codable, Identifiable, Hashable {
    var id: String { "\(videoURL)_\(playTime.timeIntervalSince1970)" }
    let videoTitle: String      // 影片主标题，如 "肖申克的救赎"
    let episodeName: String     // 剧集/线路名，如 "HD国语" 或 "第1集"
    let videoURL: String        // 原始播放/解析 URL (episodeURL)
    let coverImage: String?     // 封面图片名
    let playTime: Date          // 播放时间
    let channelName: String?    // 线路名，如 "线路 1"
    let sourceURL: String?      // 影片详情页唯一键，用于重新进入详情
}

// MARK: - 视频播放/浏览记录管理器
@MainActor
final class VideoPlayRecordManager: ObservableObject {
    static let shared = VideoPlayRecordManager()
    
    @Published private(set) var records: [VideoPlayRecord] = []
    
    private let storageKey = "ONews_VideoPlayRecords"
    private let maxCount = 20
    
    private init() {
        load()
    }
    
    /// 添加一条播放记录（如果已存在相同视频相同集数，则更新时间并置顶）
    func addRecord(videoTitle: String, episodeName: String, videoURL: String, coverImage: String?, channelName: String?, sourceURL: String?) {
        let newRecord = VideoPlayRecord(
            videoTitle: videoTitle,
            episodeName: episodeName,
            videoURL: videoURL,
            coverImage: coverImage,
            playTime: Date(),
            channelName: channelName,
            sourceURL: sourceURL
        )
        
        // 过滤掉相同视频和相同集数的旧记录
        records.removeAll { $0.videoTitle == videoTitle && $0.episodeName == episodeName }
        
        // 插入到最前面
        records.insert(newRecord, at: 0)
        
        // 限制最多 20 条
        if records.count > maxCount {
            records = Array(records.prefix(maxCount))
        }
        
        save()
    }
    
    func removeRecord(_ record: VideoPlayRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }
    
    func clearAll() {
        records.removeAll()
        save()
    }
    
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