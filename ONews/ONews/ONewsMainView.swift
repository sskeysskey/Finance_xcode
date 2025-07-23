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
    
    init() {
        loadReadRecords()
//        loadNews()
        
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
    
    private func getArticleList(for sourceName: String?) -> [Article] {
        let list: [Article]
        if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
            list = source.articles
        } else {
            list = self.sources.flatMap { $0.articles }.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp > $1.timestamp
                }
                return $0.topic < $1.topic
            }
        }
        return list
    }

    /// 计算总未读数
    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
    
    // findNext/Previous 系列方法保持不变...
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
