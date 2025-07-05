import SwiftUI

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
    
    init() {
        loadReadRecords()
        loadNews()
    }

    private func loadReadRecords() {
        self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }
    
    // ==================== 核心修改: 重写 loadNews 方法 ====================
    func loadNews() {
        // 1. 扫描 Bundle 中的所有资源 URL
        guard let resourceURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else {
            print("无法在 Bundle 中找到任何 JSON 文件。")
            return
        }
        
        // 2. 筛选出符合 "onews_*.json" 格式的文件
        let newsJSONURLs = resourceURLs.filter {
            $0.lastPathComponent.starts(with: "onews_")
        }
        
        guard !newsJSONURLs.isEmpty else {
            fatalError("错误：在项目包中没有找到任何 'onews_YYMMDD.json' 格式的文件。请确保文件已添加并设置为 'Copy Bundle Resources'。")
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
                    mutableArticle.timestamp = timestamp // 关键步骤：注入时间戳
                    return mutableArticle
                }
                
                // 将带有时间戳的文章添加到聚合字典中
                allArticlesBySource[sourceName, default: []].append(contentsOf: articlesWithTimestamp)
            }
        }
        
        // 5. 创建 NewsSource 数组，并对每个来源的文章按时间倒序排序
        var tempSources = allArticlesBySource.map { sourceName, articles -> NewsSource in
            // 按时间戳字符串倒序排序 (e.g., "250705" > "250704")
            let sortedArticles = articles.sorted { $0.timestamp > $1.timestamp }
            return NewsSource(name: sourceName, articles: sortedArticles)
        }
        // 对来源本身按名称排序
        .sorted { $0.name < $1.name }

        // 6. 根据已读记录，标记文章的 isRead 状态
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
        }
    }
    // ====================================================================

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

    /// 计算总未读数
    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
    
    // findNext/Previous 系列方法不需要修改，因为它们是基于已经加载和排序好的 `sources` 数组工作的。
    // ... findNextUnread, findPreviousUnread, findNextArticle, findPreviousArticle 等方法保持不变 ...
    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        let relevantSources: [NewsSource]
        if let name = sourceName {
            relevantSources = self.sources.filter { $0.name == name }
        } else {
            relevantSources = self.sources
        }
        let unreadArticles = relevantSources.flatMap { source -> [(article: Article, sourceName: String)] in
            source.articles.filter { !$0.isRead }.map { article in (article: article, sourceName: source.name) }
        }
        guard !unreadArticles.isEmpty else { return nil }
        guard let currentIndex = unreadArticles.firstIndex(where: { $0.article.id == id }) else {
            return unreadArticles.first
        }
        let nextIndex = (currentIndex + 1) % unreadArticles.count
        return unreadArticles[nextIndex]
    }
    func findPreviousUnread(before id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        let list: [(Article, String)]
        if let sourceName = sourceName, let source = sources.first(where: { $0.name == sourceName }) {
            list = source.articles.filter { !$0.isRead }.map { ($0, source.name) }
        } else {
            list = sources.flatMap { src in
                src.articles.filter { !$0.isRead }.map { ($0, src.name) }
            }
        }
        if let idx = list.firstIndex(where: { $0.0.id == id }), idx > 0 {
            return list[idx-1]
        }
        return nil
    }
}

struct NewsSource: Identifiable {
    let id = UUID()
    let name: String
    var articles: [Article]
    
    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }
}

// ==================== 修改: Article 模型增加 timestamp 属性 ====================
struct Article: Identifiable, Codable {
    var id = UUID()
    let topic: String
    let article: String
    let images: [String]
    
    var isRead: Bool = false
    var timestamp: String = "" // 新增属性，用于存储日期戳，例如 "250704"

    // CodingKeys 保持不变，因为 timestamp 不是从 JSON 直接解码的
    enum CodingKeys: String, CodingKey {
        case topic, article, images
    }
}
// =========================================================================
