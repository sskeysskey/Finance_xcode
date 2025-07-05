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
    
    // 获取 Documents 目录的便捷属性
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    init() {
        loadReadRecords()
//        loadNews()
    }

    private func loadReadRecords() {
            self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
        }

        private func saveReadRecords() {
            UserDefaults.standard.set(self.readRecords, forKey: readKey)
        }
        
        // ==================== 核心修改: 重写 loadNews 方法 ====================
        func loadNews() {
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
                        return $0.timestamp > $1.timestamp
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
    
    // ==================== 新增功能: 批量标记为已读 ====================
    
    /// 将指定文章（包含）以上的全部未读文章标记为已读
    /// - Parameters:
    ///   - articleID: 起始文章的 ID
    ///   - sourceName: 如果为 nil，则在所有来源中查找；否则在指定来源中查找
    func markAllAboveAsRead(articleID: UUID, inSource sourceName: String?) {
        DispatchQueue.main.async {
            let articlesToProcess = self.getArticleList(for: sourceName)
            
            guard let pivotIndex = articlesToProcess.firstIndex(where: { $0.id == articleID }) else { return }
            
            let articlesAbove = articlesToProcess[0...pivotIndex]
            
            for article in articlesAbove where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }
    
    /// 将指定文章（包含）以下的全部未读文章标记为已读
    /// - Parameters:
    ///   - articleID: 起始文章的 ID
    ///   - sourceName: 如果为 nil，则在所有来源中查找；否则在指定来源中查找
    func markAllBelowAsRead(articleID: UUID, inSource sourceName: String?) {
        DispatchQueue.main.async {
            let articlesToProcess = self.getArticleList(for: sourceName)
            
            guard let pivotIndex = articlesToProcess.firstIndex(where: { $0.id == articleID }) else { return }
            
            let articlesBelow = articlesToProcess[pivotIndex...]
            
            for article in articlesBelow where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }
    
    /// 辅助函数：根据 sourceName 获取排序好的文章列表
    private func getArticleList(for sourceName: String?) -> [Article] {
        let list: [Article]
        if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
            // 单个来源，直接用它的文章列表
            list = source.articles
        } else {
            // 所有来源，合并并重新排序
            list = self.sources.flatMap { $0.articles }.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp > $1.timestamp
                }
                return $0.topic < $1.topic
            }
        }
        return list
    }
    
    // ====================================================================

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
