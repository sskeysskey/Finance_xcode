import SwiftUI
import UserNotifications
import Combine

extension Color {
    static let viewBackground = Color(red: 28/255, green: 28/255, blue: 30/255)
}

@main
struct NewsReaderAppApp: App {
    var body: some Scene {
        WindowGroup {
            MainAppView()
        }
    }
}

struct MainAppView: View {
    @AppStorage("hasCompletedInitialSetup") private var hasCompletedInitialSetup = false

    var body: some View {
        if hasCompletedInitialSetup {
            SourceListView()
        } else {
            WelcomeView {
                self.hasCompletedInitialSetup = true
            }
        }
    }
}


class NewsViewModel: ObservableObject {
    @Published var sources: [NewsSource] = []

    private let subscriptionManager = SubscriptionManager.shared
    
    private let readKey = "readTopics"
    private var readRecords: [String: Date] = [:]

    var badgeUpdater: ((Int) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    // ✅ 会话中暂存的“已读但未提交”的文章ID
    private var pendingReadArticleIDs: Set<UUID> = []

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var allArticlesSortedForDisplay: [(article: Article, sourceName: String)] {
        let flatList = self.sources.flatMap { source in
            source.articles.map { (article: $0, sourceName: source.name) }
        }
        
        return flatList.sorted { item1, item2 in
            if item1.article.timestamp != item2.article.timestamp {
                return item1.article.timestamp < item2.article.timestamp
            }
            return item1.article.topic < item2.article.topic
        }
    }

    init() {
        loadReadRecords()
        $sources
            .map { sources in
                sources.flatMap { $0.articles }.filter { !$0.isRead }.count
            }
            .removeDuplicates()
            .sink { [weak self] unreadCount in
                print("检测到未读数变化，准备更新角标: \(unreadCount)")
                self?.badgeUpdater?(unreadCount)
            }
            .store(in: &cancellables)
    }

    private func loadReadRecords() {
        self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }

    func loadNews() {
        let subscribed = subscriptionManager.subscribedSources
        if subscribed.isEmpty {
            print("没有订阅任何新闻源。列表将为空。")
            DispatchQueue.main.async {
                self.sources = []
            }
            return
        }
        print("开始加载新闻，订阅源为: \(subscribed)")
        
        guard let allFileURLs = try? FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil) else {
            print("无法读取 Documents 目录。")
            return
        }
        
        let newsJSONURLs = allFileURLs.filter {
            $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json"
        }
        
        guard !newsJSONURLs.isEmpty else {
            print("错误：在 Documents 目录中没有找到任何 'onews_*.json' 文件。请先同步资源。")
            return
        }

        var allArticlesBySource = [String: [Article]]()
        let decoder = JSONDecoder()

        for url in newsJSONURLs {
            let fileName = url.deletingPathExtension().lastPathComponent
            guard let timestamp = fileName.components(separatedBy: "_").last, !timestamp.isEmpty else {
                continue
            }
            
            guard let data = try? Data(contentsOf: url) else {
                continue
            }
            
            guard let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                continue
            }
            
            for (sourceName, articles) in decoded {
                guard subscribed.contains(sourceName) else { continue }
                
                let articlesWithTimestamp = articles.map { article -> Article in
                    var mutableArticle = article
                    mutableArticle.timestamp = timestamp
                    return mutableArticle
                }
                allArticlesBySource[sourceName, default: []].append(contentsOf: articlesWithTimestamp)
            }
        }
        
        var tempSources = allArticlesBySource.map { sourceName, articles -> NewsSource in
            let sortedArticles = articles.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.topic < $1.topic
            }
            return NewsSource(name: sourceName, articles: sortedArticles)
        }
        .sorted { $0.name < $1.name }

        for i in tempSources.indices {
            for j in tempSources[i].articles.indices {
                let article = tempSources[i].articles[j]
                if readRecords.keys.contains(article.topic) {
                    tempSources[i].articles[j].isRead = true
                }
            }
        }

        DispatchQueue.main.async {
            self.sources = tempSources
            print("新闻数据加载/刷新完成！共 \(self.sources.count) 个已订阅来源。")
        }
    }

    // MARK: - 暂存与提交逻辑

    /// 将文章ID暂存到待提交列表。如果该文章是首次在本会话中被标记，则返回 true。
    func stageArticleAsRead(articleID: UUID) -> Bool {
        if let article = sources.flatMap({ $0.articles }).first(where: { $0.id == articleID }), article.isRead {
            return false
        }
        if pendingReadArticleIDs.contains(articleID) {
            return false
        }
        
        pendingReadArticleIDs.insert(articleID)
        return true
    }

    /// 检查一篇文章是否在“待提交”列表中。
    func isArticlePendingRead(articleID: UUID) -> Bool {
        return pendingReadArticleIDs.contains(articleID)
    }

    /// 统一判断：这篇文章是否“有效地”被视作已读（已持久 isRead 或在本会话暂存 pending）
    func isEffectivelyRead(articleID: UUID) -> Bool {
        if isArticlePendingRead(articleID: articleID) { return true }
        if let (i, j) = indexPathOfArticle(id: articleID) {
            return sources[i].articles[j].isRead
        }
        return false
    }
    
    /// View 侧便捷方法
    func isArticleEffectivelyRead(_ article: Article) -> Bool {
        return isEffectivelyRead(articleID: article.id)
    }

    /// ✅ 场景1: 返回列表页时调用。
    /// 提交所有暂存的已读文章，并清空列表。此操作会修改 `sources`，从而刷新UI。
    func commitPendingReads() {
        let idsToCommit = pendingReadArticleIDs
        guard !idsToCommit.isEmpty else { return }

        print("【完整提交】正在提交 \(idsToCommit.count) 篇暂存的已读文章（将刷新 UI）...")
        pendingReadArticleIDs.removeAll()

        DispatchQueue.main.async {
            for articleID in idsToCommit {
                self.markAsRead(articleID: articleID) // markAsRead 会修改 self.sources
            }
            print("【完整提交】完成。")
        }
    }

    /// ✅ 场景2: 应用退到后台时调用。
    /// 静默提交已读文章，仅更新持久化记录和角标，不改变 `sources`。
    func commitPendingReadsSilently() {
        let idsToCommit = pendingReadArticleIDs
        guard !idsToCommit.isEmpty else { return }

        print("【静默提交】正在提交 \(idsToCommit.count) 篇暂存的已读文章（不刷新 UI）...")
        pendingReadArticleIDs.removeAll()

        for articleID in idsToCommit {
            if let (sourceIndex, articleIndex) = indexPathOfArticle(id: articleID) {
                let topic = sources[sourceIndex].articles[articleIndex].topic
                if readRecords[topic] == nil {
                     readRecords[topic] = Date()
                }
            }
        }
        saveReadRecords()

        let newUnread = calculateUnreadCountAfterSilentCommit()
        DispatchQueue.main.async { [weak self] in
            self?.badgeUpdater?(newUnread)
        }

        print("【静默提交】完成。角标将更新为 \(newUnread)。")
    }

    /// 用于静默提交后计算最新的未读数。
    private func calculateUnreadCountAfterSilentCommit() -> Int {
        var count = 0
        for source in sources {
            for article in source.articles {
                if readRecords[article.topic] == nil {
                    count += 1
                }
            }
        }
        return count
    }

    /// 找到文章在内存 sources 中的位置
    private func indexPathOfArticle(id: UUID) -> (Int, Int)? {
        for i in sources.indices {
            if let j = sources[i].articles.firstIndex(where: { $0.id == id }) {
                return (i, j)
            }
        }
        return nil
    }

    // MARK: - 底层标记函数

    func markAsRead(articleID: UUID) {
        DispatchQueue.main.async {
            if let (i, j) = self.indexPathOfArticle(id: articleID) {
                if !self.sources[i].articles[j].isRead {
                    self.sources[i].articles[j].isRead = true
                    let topic = self.sources[i].articles[j].topic
                    self.readRecords[topic] = Date()
                    self.saveReadRecords()
                }
            }
        }
    }
    
    func markAsUnread(articleID: UUID) {
        DispatchQueue.main.async {
            if let (i, j) = self.indexPathOfArticle(id: articleID) {
                if self.sources[i].articles[j].isRead {
                    self.sources[i].articles[j].isRead = false
                    let topic = self.sources[i].articles[j].topic
                    self.readRecords.removeValue(forKey: topic)
                    self.saveReadRecords()
                }
            }
        }
    }

    func markAllAboveAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        DispatchQueue.main.async {
            guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
            guard pivotIndex > 0 else { return }
            let articlesAbove = visibleArticles[0..<pivotIndex]
            for article in articlesAbove where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }

    func markAllBelowAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        DispatchQueue.main.async {
            guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
            guard pivotIndex < visibleArticles.count - 1 else { return }
            let articlesBelow = visibleArticles[(pivotIndex + 1)...]
            for article in articlesBelow where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }

    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }

    /// 按显示顺序寻找下一篇未读：跳过已读和“已暂存为已读”的文章
    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        let baseList: [(article: Article, sourceName: String)]
        if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
            baseList = source.articles.map { (article: $0, sourceName: name) }
        } else {
            baseList = self.allArticlesSortedForDisplay
        }

        guard let currentIndex = baseList.firstIndex(where: { $0.article.id == id }) else {
            return nil
        }

        let subsequentItems = baseList.suffix(from: currentIndex + 1)

        let nextUnreadItem = subsequentItems.first { item in
            let isPending = isArticlePendingRead(articleID: item.article.id)
            return !item.article.isRead && !isPending
        }

        return nextUnreadItem
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

struct Article: Identifiable, Codable, Hashable {
    var id = UUID()
    let topic: String
    let article: String
    let images: [String]

    var isRead: Bool = false
    var timestamp: String = ""

    enum CodingKeys: String, CodingKey {
        case topic, article, images
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Article, rhs: Article) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class AppBadgeManager {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            if granted {
                print("用户已授予角标权限。")
            } else {
                print("用户未授予角标权限。")
            }
        }
    }

    func updateBadge(count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error = error {
                print("更新角标失败: \(error.localizedDescription)")
            } else {
                print("应用角标已更新为: \(count)")
            }
        }
    }
}
