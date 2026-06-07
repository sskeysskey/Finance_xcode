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
    
    // 【修改】增加 userId 参数
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
    
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: OVideoItem, rhs: OVideoItem) -> Bool { lhs.url == rhs.url }
}

struct OVideoChannel: Codable, Hashable {
    let name: String
    // 【修改】从 [String] 改为 [String: String] 字典
    let episodes: [String: String]
    
    // 【新增】辅助属性：对字典进行智能排序，返回有序的 (集数名, 播放URL) 数组
    var sortedEpisodes: [(name: String, url: String)] {
        sortedEpisodes(ascending: true)
    }
    
    // 【新增】支持正序/倒序的智能排序方法
    func sortedEpisodes(ascending: Bool) -> [(name: String, url: String)] {
        episodes.sorted { (kv1, kv2) -> Bool in
            // 尝试将 Key 转为数字进行排序（例如 "1", "2", "10"）
            if let num1 = Int(kv1.key), let num2 = Int(kv2.key) {
                return ascending ? (num1 < num2) : (num1 > num2)
            }
            // 如果不是纯数字，则按标准字典序排序（例如 "第1集" 与 "第2集"）
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
            "日剧": "剧情", "国产": "剧情", "大陆": "剧情", 
            "美国": "剧情", "欧美": "剧情", "美国剧": "剧情", "欧美剧": "剧情",
            "日本剧": "剧情", "日本": "剧情", 
            "韩国剧": "剧情", "韩国": "剧情", "日韩": "剧情", "日韩剧": "剧情",
            "香港": "剧情", "台湾": "剧情", "港台": "剧情", "邵氏电影": "剧情",

            "泰国": "泰剧", "海外剧": "泰剧", "海外": "泰剧",
            
            "喜剧片": "喜剧", "搞笑": "喜剧",

            "爱情片": "爱情", "恋爱": "爱情", "情": "爱情", "浪漫": "爱情",

            "丧尸": "恐怖", "惊栗": "惊悚",
            
            "犯罪片": "犯罪", 

            "记录": "纪录片", "其他": "纪录片", "纪录": "纪录片",
            "记录片": "纪录片",
            
            "选秀": "综艺", "大陆综艺": "综艺", "晚会": "综艺", "日韩综艺": "综艺", "欧美综艺": "综艺",
            "相声": "综艺", "访谈": "综艺", "戏曲": "综艺", "港台综艺": "综艺", "国产综艺": "综艺",

            "动画": "动漫", "海外动漫": "动漫", "鬼怪": "动漫", "日本动漫": "动漫",
            "有声动漫": "动漫", "机战": "动漫", "日韩动漫": "动漫", "欧美动漫": "动漫",
            "游戏": "动漫", "热血": "动漫", "致郁": "动漫", "动漫片": "动漫",
            "动漫电影": "动漫", "动画电影": "动漫", "国产动漫": "动漫",
        ]
        
        // 映射并去重
        let normalized = types.map { typeMapping[$0] ?? $0 }
        return Array(Set(normalized)) // 返回去重后的数组
    }
}

// 【修改】增加 update 选项，并修改 date 的显示文本
enum VideoSortOption: String, CaseIterable {
    case date, update, rating
    
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
}

// 【新增】统一的分组 key 计算逻辑
extension VideoCacheMetadata {
    var groupKey: String {
        if let s = seriesTitle, !s.isEmpty { return "title:" + s }
        if let c = coverImage, !c.isEmpty { return "cover:" + c } // 兜底：同剧封面一致
        return "single:" + title
    }
}

// MARK: - 数据管理器
@MainActor
class OVideoDataManager: ObservableObject {
    @Published var categories: [OVideoCategory] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    private var hasLoaded = false
    
    // 【新增】记录上一次加载所用的 userId，用于判断是否需要重新加载
    private var loadedUserId: String? = nil
    // ⭐ 新增：排序结果缓存。key = "categoryName|sortOption"
    private var sortCache: [String: [OVideoItem]] = [:]
    // ⭐ 新增：搜索索引
    private var searchIndex: [SearchIndexEntry] = []
    
    func loadVideosIfNeeded(userId: String? = nil) async {
        // 【修改】已加载，且用户身份与上次一致，才跳过；
        // 否则（例如预加载时是 nil，进入页面时变成真实 userId）需要重新拉取，
        // 这样邀请码用户才能拿到未过滤的数据
        if hasLoaded && loadedUserId == userId { return }
        await loadVideos(userId: userId)
    }
    
    // 【修改】增加 userId 参数
    func loadVideos(userId: String? = nil) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // 【修改】传入 userId
            let cats = try await OVideoAPI.fetchVideos(userId: userId)
            self.categories = cats
            self.sortCache.removeAll()
            
            // 构建搜索索引
            let index = await Task.detached(priority: .utility) {
                Self.buildIndex(from: cats)
            }.value
            self.searchIndex = index
            
            self.loadedUserId = userId   // 【新增】
            self.hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // ⭐ 修改：构建索引时捕获 categoryName，并对导演、演员进行中英文清洗
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
    
    var allItems: [OVideoItem] { categories.flatMap { $0.items } }
    
    // ⭐ 新版：sortKey 做字符串比较 + 结果缓存
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
    
    // ⭐ 核心修改：多级严格分层搜索算法
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