import SwiftUI
import UserNotifications
import Combine // 1. 导入 Combine 框架

// ==================== 核心修改 1: 定义全局背景色 ====================
extension Color {
    // 主视图的背景色 (深灰色)
    static let viewBackground = Color(red: 28/255, green: 28/255, blue: 30/255) // 对应 Hex: #1C1C1E
}
// ====================================================================

@main
struct NewsReaderAppApp: App {
    var body: some Scene {
        WindowGroup {
            MainAppView()
        }
    }
}

struct MainAppView: View {
    @State private var isAuthenticated = false

    var body: some View {
        if isAuthenticated {
            SourceListView(isAuthenticated: $isAuthenticated)
        } else {
            // 为了方便调试，我们直接进入主界面
            SourceListView(isAuthenticated: $isAuthenticated)
        }
    }
}

// ObservableObject 使得 SwiftUI 视图可以订阅它的变化
class NewsViewModel: ObservableObject {

    @Published var sources: [NewsSource] = []
    
    private let readKey = "readTopics"
    private var readRecords: [String: Date] = [:]
    
    // ==================== 新增修改 1: 添加角标更新器和 Combine 订阅 ====================
    /// 一个闭包，用于在未读数变化时调用外部更新逻辑（例如更新App角标）
    var badgeUpdater: ((Int) -> Void)?
    
    /// 用于存储 Combine 订阅的集合
    private var cancellables = Set<AnyCancellable>()
    // ==========================================================================
    
    // 获取 Documents 目录的便捷属性
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // ==================== 核心修改 1: 创建一个权威的、排序后的一维文章列表 ====================
        /// 提供一个按显示逻辑排序（日期降序 -> 来源名升序 -> 标题升序）的扁平化文章列表。
        /// 这是“All Articles”视图和相关导航逻辑的唯一数据源。
    // ==================== 核心修改点: 调整此处的排序逻辑 ====================
        /// 提供一个按显示逻辑排序（日期降序 -> 标题升序）的扁平化文章列表。
        /// 这是“All Articles”视图和相关导航逻辑的唯一数据源。
        var allArticlesSortedForDisplay: [(article: Article, sourceName: String)] {
            let flatList = self.sources.flatMap { source in
                source.articles.map { (article: $0, sourceName: source.name) }
            }
            
            return flatList.sorted { item1, item2 in
                // 主要排序条件：按时间戳降序 (新日期在前)
                if item1.article.timestamp != item2.article.timestamp {
//                    return item1.article.timestamp > item2.article.timestamp
                    return item1.article.timestamp < item2.article.timestamp
                }
                
                // 次要排序条件：如果日期相同，直接按文章标题升序 (字母顺序)
                // (已移除按来源排序的逻辑，以实现混杂阅读)
                return item1.article.topic < item2.article.topic
            }
        }
        // ===============
    
    init() {
        loadReadRecords()
        
        // ==================== 新增修改 2: 设置 Combine 管道 ====================
        // 监听 @Published var sources 的任何变化
        $sources
            // 当 sources 数组变化时，计算新的未读总数
            .map { sources in
                sources.flatMap { $0.articles }.filter { !$0.isRead }.count
            }
            // 只有当未读总数真的发生变化时，才继续传递事件（性能优化）
            .removeDuplicates()
            // 接收到新的未读总数
            .sink { [weak self] unreadCount in
                // 调用我们设置的外部更新器
                print("检测到未读数变化，准备更新角标: \(unreadCount)")
                self?.badgeUpdater?(unreadCount)
            }
            // 将这个订阅存储起来，以便在 viewModel 销毁时自动取消
            .store(in: &cancellables)
        // ====================================================================
    }

    private func loadReadRecords() {
            self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }
    
    // loadNews 方法保持不变...
    func loadNews() {
        // ... 此方法内部逻辑保持不变 ...
        // 1. 扫描 Documents 目录中的所有内容
        guard let allFileURLs = try? FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil) else {
            print("无法读取 Documents 目录。")
            return
        }
        
        // 2. 筛选出符合 "onews_*.json" 格式的文件
        let newsJSONURLs = allFileURLs.filter {
            $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json"
        }
        
        guard !newsJSONURLs.isEmpty else {
            print("错误：在 Documents 目录中没有找到任何 'onews_*.json' 文件。请先同步资源。")
            // 在实际应用中，这里可能需要提示用户
            return
        }

        var allArticlesBySource = [String: [Article]]()
        let decoder = JSONDecoder()

        // 3. 遍历所有找到的 JSON 文件
        for url in newsJSONURLs {
            // 从文件名中提取时间戳 (e.g., "250704")
            let fileName = url.deletingPathExtension().lastPathComponent
            guard let timestamp = fileName.components(separatedBy: "_").last, !timestamp.isEmpty else {
                print("警告：跳过文件 \(url.lastPathComponent)，因为它不符合 'onews_TIMESTAMP.json' 格式。")
                continue
            }
            
            // 加载和解析 JSON 数据
            guard let data = try? Data(contentsOf: url) else {
                print("警告：无法加载文件 \(url.lastPathComponent)。")
                continue
            }
            
            guard let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                print("警告：解析文件 \(url.lastPathComponent) 失败。")
                continue
            }
            
            // 4. 为每篇文章设置时间戳，并按来源聚合
            for (sourceName, articles) in decoded {
                let articlesWithTimestamp = articles.map { article -> Article in
                    var mutableArticle = article
                    mutableArticle.timestamp = timestamp
                    return mutableArticle
                }
                allArticlesBySource[sourceName, default: []].append(contentsOf: articlesWithTimestamp)
            }
        }
        
        // 5. 创建 NewsSource 数组，并排序
        var tempSources = allArticlesBySource.map { sourceName, articles -> NewsSource in
            // 修改排序规则：首先按时间戳倒序，然后按主题排序，确保每次加载顺序一致
            let sortedArticles = articles.sorted {
                if $0.timestamp != $1.timestamp {
//                    return $0.timestamp > $1.timestamp
                    return $0.timestamp < $1.timestamp
                }
                return $0.topic < $1.topic
            }
            return NewsSource(name: sourceName, articles: sortedArticles)
        }
        .sorted { $0.name < $1.name }

        // 6. 标记已读状态
        for i in tempSources.indices {
            for j in tempSources[i].articles.indices {
                let article = tempSources[i].articles[j]
                if readRecords.keys.contains(article.topic) {
                   tempSources[i].articles[j].isRead = true
               }
            }
        }

        // 7. 在主线程上发布最终结果
        DispatchQueue.main.async {
            self.sources = tempSources
            print("新闻数据加载/刷新完成！共 \(self.sources.count) 个来源。")
        }
    }

    // markAsRead, markAsUnread, markAllAboveAsRead, markAllBelowAsRead 等方法保持不变
    // 因为我们使用了 Combine，这些方法在修改 `sources` 数组后，会自动触发角标更新，无需在每个函数里单独调用。
    
    /// 用户阅读完文章后调用
    func markAsRead(articleID: UUID) {
        DispatchQueue.main.async {
            for i in self.sources.indices {
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    if !self.sources[i].articles[j].isRead {
                        self.sources[i].articles[j].isRead = true
                        let topic = self.sources[i].articles[j].topic
                        self.readRecords[topic] = Date()
                        self.saveReadRecords()
                    }
                    return
                }
            }
        }
    }

    /// 将指定文章标记为未读
    func markAsUnread(articleID: UUID) {
        DispatchQueue.main.async {
            for i in self.sources.indices {
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    if self.sources[i].articles[j].isRead {
                        self.sources[i].articles[j].isRead = false
                        let topic = self.sources[i].articles[j].topic
                        self.readRecords.removeValue(forKey: topic)
                        self.saveReadRecords()
                    }
                    return
                }
            }
        }
    }
    
    /// **修正后的方法: 直接操作传入的可见文章列表**
    /// 修正后的方法: 将指定文章以上的所有文章标记为已读（不包括该文章本身）
        func markAllAboveAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
            DispatchQueue.main.async {
                // 1. 在可见列表中找到触发操作的文章的索引
                guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
                
                // 如果 pivotIndex 是 0（即第一篇文章），那么它上面没有文章，直接返回。
                guard pivotIndex > 0 else { return }

                // 2. 【核心修改】使用半开区间 [0..<pivotIndex] 来获取上方所有文章，排除自身。
                let articlesAbove = visibleArticles[0..<pivotIndex]
                
                // 3. 遍历这个精确的子集，并将其中未读的文章标记为已读
                for article in articlesAbove where !article.isRead {
                    self.markAsRead(articleID: article.id)
                }
            }
        }

        /// 修正后的方法: 将指定文章以下的所有文章标记为已读（不包括该文章本身）
        func markAllBelowAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
            DispatchQueue.main.async {
                // 1. 在可见列表中找到触发操作的文章的索引
                guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
                
                // 如果 pivotIndex 是最后一篇文章，那么它下面没有文章，直接返回。
                guard pivotIndex < visibleArticles.count - 1 else { return }

                // 2. 【核心修改】从 pivotIndex + 1 开始切片，以获取下方所有文章，排除自身。
                let articlesBelow = visibleArticles[(pivotIndex + 1)...]
                
                // 3. 遍历这个精确的子集，并将其中未读的文章标记为已读
                for article in articlesBelow where !article.isRead {
                    self.markAsRead(articleID: article.id)
                }
            }
        }
    
    // ==================== 核心修改 2: 更新 getArticleList 以使用新排序 ====================
        private func getArticleList(for sourceName: String?) -> [Article] {
            if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
                // 如果是单个来源，其内部文章已在 loadNews 中排序，直接返回
                return source.articles
            } else {
                // 如果是“所有文章”，使用我们新的权威排序列表
                return self.allArticlesSortedForDisplay.map { $0.article }
            }
        }
        // ==============================================

    /// 计算总未读数
    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
    
    // ==================== 核心修改: findNextUnread 函数 ====================
        /// 寻找下一篇未读文章。如果到达列表末尾，则循环回到第一篇。
        func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
            let list: [(article: Article, sourceName: String)]
            
            // 1. 获取正确的未读文章列表 (此逻辑保持不变)
            if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
                list = source.articles
                    .filter { !$0.isRead }
                    .map { (article: $0, sourceName: name) }
            } else {
                list = self.allArticlesSortedForDisplay.filter { !$0.article.isRead }
            }
            
            // 2. 如果根本没有未读文章，则直接返回 nil (此逻辑保持不变)
            guard !list.isEmpty else { return nil }
            
            // 3. 寻找当前文章在未读列表中的索引 (此逻辑保持不变)
            guard let currentIndex = list.firstIndex(where: { $0.article.id == id }) else {
                // 如果当前文章不在未读列表中（可能刚被标记为已读），则从第一篇未读文章开始
                return list.first
            }
            
            // 4. 【核心修改】计算下一篇文章的索引，使用模运算实现循环
            // (currentIndex + 1) 会得到常规的下一个索引
            // % list.count (对列表总数取模) 能确保结果永远不会越界。
            // 例如，如果列表有5篇文章 (索引0-4)，当前在最后一篇 (索引4):
            // (4 + 1) % 5  ->  5 % 5  ->  结果是 0。完美地回到了列表开头。
            let nextIndex = (currentIndex + 1) % list.count
            
            // 5. 返回计算出的下一篇文章
            return list[nextIndex]
        }
        // ======================================================================

        // ==================== 核心修改 4: 更新 findPreviousUnread 以使用新排序 ====================
        func findPreviousUnread(before id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
            let list: [(article: Article, sourceName: String)]
            
            if let name = sourceName, let source = sources.first(where: { $0.name == name }) {
                list = source.articles
                    .filter { !$0.isRead }
                    .map { (article: $0, sourceName: name) }
            } else {
                list = self.allArticlesSortedForDisplay.filter { !$0.article.isRead }
            }
            
            guard !list.isEmpty else { return nil }
            
            if let currentIndex = list.firstIndex(where: { $0.article.id == id }), currentIndex > 0 {
                return list[currentIndex - 1]
            }
            
            return nil
        }
        // =========
}

// NewsSource 和 Article 结构体保持不变
struct NewsSource: Identifiable {
    let id = UUID()
    let name: String
    var articles: [Article]
    
    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }
}

struct Article: Identifiable, Codable {
    var id = UUID()
    let topic: String
    let article: String
    let images: [String]
    
    var isRead: Bool = false
    var timestamp: String = ""

    enum CodingKeys: String, CodingKey {
        case topic, article, images
    }
}

/// 一个专门用于管理应用图标角标的类
@MainActor
class AppBadgeManager {
    
    /// 请求显示角标所需的权限
    /// 应该在应用启动时或者合适的时机调用一次
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            if let error = error {
                print("请求角标权限时出错: \(error.localizedDescription)")
            }
            if granted {
                print("用户已授予角标权限。")
            } else {
                print("用户未授予角标权限。")
            }
        }
    }
    
    /// 更新应用图标上的角标数字
    /// - Parameter count: 要显示的未读数量。传入 0 会清除角标。
    func updateBadge(count: Int) {
        // 使用 UNUserNotificationCenter.current().setBadgeCount 是目前推荐的方式
        // 它能更好地处理权限问题
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error = error {
                print("更新角标失败: \(error.localizedDescription)")
            } else {
                print("应用角标已更新为: \(count)")
            }
        }
    }
}
