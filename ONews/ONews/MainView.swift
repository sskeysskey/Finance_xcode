import SwiftUI
import UserNotifications
import Combine
import UIKit

// 【新增】第 1 步：创建一个 AppDelegate 类
// 这个类将负责处理所有 App 级别的一次性启动任务。
class AppDelegate: NSObject, UIApplicationDelegate {
    // 【修改】将所有共享的 Manager 移动到 AppDelegate 中，由它来“拥有”这些实例。
    let newsViewModel = NewsViewModel()
    let resourceManager = ResourceManager()
    let badgeManager = AppBadgeManager()
    
    // 这是 App 启动后会调用的方法，是执行一次性设置的完美位置。
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        print("AppDelegate: didFinishLaunchingWithOptions - App 启动完成，开始进行一次性设置。")
        
        // 1. 在这里进行“接线”操作，不会再有编译错误。
        // 因为此时 AppDelegate 实例已经完全创建好了。
        newsViewModel.badgeUpdater = { [weak self] count in
            self?.badgeManager.updateBadge(count: count)
        }
        
        // 2. 在 App 启动时就请求角标权限
        badgeManager.requestAuthorization()
        
        // 3. 配置全局 UI 外观
        let tv = UITableView.appearance()
        tv.backgroundColor = .clear
        tv.separatorStyle = .none
        
        return true
    }
}


@main
struct NewsReaderAppApp: App {
    // 【新增】第 2 步：使用 @UIApplicationDelegateAdaptor 将 AppDelegate 连接到 SwiftUI App 生命周期。
    // SwiftUI 会自动创建 AppDelegate 的实例，并调用其生命周期方法。
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 【移除】不再需要在 App struct 中直接创建这些 manager。
    // @StateObject private var newsViewModel = NewsViewModel()
    // @StateObject private var resourceManager = ResourceManager()
    // @StateObject private var badgeManager = AppBadgeManager()

    @Environment(\.scenePhase) private var scenePhase

    // 【移除】移除整个 init() 方法，因为它的所有逻辑都已移至 AppDelegate。
    /*
    init() {
        // ... 所有代码都已移动 ...
    }
    */

    var body: some Scene {
        WindowGroup {
            MainAppView()
                // 【修改】第 3 步：从 appDelegate 实例中获取共享对象并注入环境。
                .environmentObject(appDelegate.newsViewModel)
                .environmentObject(appDelegate.resourceManager)
                // badgeManager 不需要注入，因为它只在内部工作
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // 【修改】从 appDelegate 获取 newsViewModel 来调用方法
            let newsViewModel = appDelegate.newsViewModel
            
            if newPhase == .active {
                print("App is active. Syncing read status.")
                newsViewModel.syncReadStatusFromPersistence()
            } else if newPhase == .background {
                print("App entered background. Committing pending reads silently.")
                newsViewModel.commitPendingReadsSilently()
            } else if newPhase == .inactive {
                print("App is inactive. Committing pending reads silently as a precaution.")
                newsViewModel.commitPendingReadsSilently()
            }
        }
    }
}

// 这是你的 MainAppView.swift 文件中的 body 部分
// 【无需改动】这部分代码已经是正确的了。
struct MainAppView: View {
    @AppStorage("hasCompletedInitialSetup") private var hasCompletedInitialSetup = false
    
    // 这些 EnvironmentObject 会从 NewsReaderAppApp 的 body 中正确接收到值
    @EnvironmentObject var resourceManager: ResourceManager
    @EnvironmentObject var newsViewModel: NewsViewModel

    var body: some View {
        if hasCompletedInitialSetup {
            SourceListView()
        } else {
            WelcomeView(hasCompletedInitialSetup: $hasCompletedInitialSetup)
        }
    }
}


// ==================== 共享颜色扩展 ====================
// 将此扩展移至共享文件，以便所有共享视图都能访问
extension Color {
    static let viewBackground = Color(red: 28/255, green: 28/255, blue: 30/255)
}


// ==================== 共享视图组件 ====================

/// 公共：搜索输入视图（在导航栏下方显示）
/// 已从各个视图文件中提取至此，以供全局复用。
struct SearchBarInline: View {
    @Binding var text: String
    var placeholder: String = "搜索标题关键字" // 【新增】允许自定义 placeholder
    var onCommit: () -> Void
    var onCancel: () -> Void

    // 焦点绑定
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(placeholder, text: $text, onCommit: onCommit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .focused($isFocused)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)

            if !text.isEmpty {
                Button("搜索") { onCommit() }
                    .buttonStyle(.bordered)
            }

            Button("取消") {
                onCancel()
                // 取消时顺便收起键盘
                isFocused = false
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial) // 使用材质背景以适应不同上下文
        .onAppear {
            // 出现时自动聚焦
            DispatchQueue.main.async {
                self.isFocused = true
            }
        }
    }
}

/// 公共：文章卡片视图
/// 已从各个视图文件中提取至此，以供全局复用。
struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String?
    let isReadEffective: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = sourceName {
                Text(name.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(article.topic)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isReadEffective ? .secondary : .primary)
                .lineLimit(3)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.viewBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}


class NewsViewModel: ObservableObject {
    @Published var sources: [NewsSource] = []

    // MARK: - 新增: UI状态管理
    @Published var expandedTimestampsBySource: [String: Set<String>] = [:]
    @Published var lastTappedArticleIDBySource: [String: UUID?] = [:]
    let allArticlesKey = "__ALL_ARTICLES__" // 用于 "All Articles" 列表的特殊键

    private let subscriptionManager = SubscriptionManager.shared

    private let readKey = "readTopics"
    private var readRecords: [String: Date] = [:]

    var badgeUpdater: ((Int) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    // ✅ 会话中暂存的“已读但未提交”的文章ID
    private var pendingReadArticleIDs: Set<UUID> = []
    // ✅ 兜底集合：最近一次静默提交到持久化但未刷新 UI 的文章 IDs
    private var lastSilentCommittedIDs: Set<UUID> = []

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

    // MARK: - 新增: UI状态管理方法
    func toggleTimestampExpansion(for sourceKey: String, timestamp: String) {
        var currentSet = expandedTimestampsBySource[sourceKey, default: Set<String>()]
        if currentSet.contains(timestamp) {
            currentSet.remove(timestamp)
        } else {
            currentSet.insert(timestamp)
        }
        expandedTimestampsBySource[sourceKey] = currentSet
    }

    func setLastTappedArticleID(for sourceKey: String, id: UUID?) {
        lastTappedArticleIDBySource[sourceKey] = id
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

    func isArticlePendingRead(articleID: UUID) -> Bool {
        return pendingReadArticleIDs.contains(articleID)
    }

    func isEffectivelyRead(articleID: UUID) -> Bool {
        if isArticlePendingRead(articleID: articleID) { return true }
        if let (i, j) = indexPathOfArticle(id: articleID) {
            return sources[i].articles[j].isRead
        }
        return false
    }

    func isArticleEffectivelyRead(_ article: Article) -> Bool {
        return isEffectivelyRead(articleID: article.id)
    }

    /// 提交所有暂存的已读文章并刷新 UI。
    /// 另外：兜底处理最近一次静默提交过但 UI 未刷新的 IDs。
    func commitPendingReads() {
        var idsToCommit = pendingReadArticleIDs
        // 将 pending 清空，防止重复
        pendingReadArticleIDs.removeAll()
        
        // 把 lastSilentCommittedIDs 也并入（兜底刷新 UI）
        if !lastSilentCommittedIDs.isEmpty {
            idsToCommit.formUnion(lastSilentCommittedIDs)
            lastSilentCommittedIDs.removeAll()
        }
        
        guard !idsToCommit.isEmpty else { return }

        print("【完整提交】正在提交 \(idsToCommit.count) 篇已读文章（将刷新 UI）...")
        DispatchQueue.main.async {
            for articleID in idsToCommit {
                self.markAsRead(articleID: articleID)
            }
            print("【完整提交】完成。")
        }
    }

    /// 应用退到后台时调用：处理暂存项，并总是重新计算和设置角标。
    func commitPendingReadsSilently() {
        let idsToCommit = pendingReadArticleIDs

        // 步骤 1: 如果有暂存的已读文章，则进行静默提交处理。
        if !idsToCommit.isEmpty {
            print("【静默提交】正在提交 \(idsToCommit.count) 篇暂存的已读文章（不刷新 UI）...")
            
            // 记录这批被静默提交的 ID，供稍后 UI 刷新兜底
            lastSilentCommittedIDs.formUnion(idsToCommit)
            // 清空 pending 队列
            pendingReadArticleIDs.removeAll()

            // 更新持久化存储
            for articleID in idsToCommit {
                if let (sourceIndex, articleIndex) = indexPathOfArticle(id: articleID) {
                    let topic = sources[sourceIndex].articles[articleIndex].topic
                    if readRecords[topic] == nil {
                        readRecords[topic] = Date()
                    }
                }
            }
            saveReadRecords()
            print("【静默提交】持久化存储已更新。")

        } else {
            // 即使没有要提交的，也打印日志，便于调试
            print("【静默提交】没有暂存的已读文章需要提交。")
        }

        // 步骤 2: 无论有无暂存项，都根据当前的持久化状态重新计算总未读数并更新角标。
        // 这是解决角标消失问题的关键：确保每次退到后台都设置一次正确的角标值。
        let currentUnreadCount = calculateUnreadCountAfterSilentCommit()
        
        DispatchQueue.main.async { [weak self] in
            self?.badgeUpdater?(currentUnreadCount)
        }

        print("【静幕提交】完成。应用角标已(重新)设置为: \(currentUnreadCount)。")
    }

    // MARK: - 新增的同步方法
    /// 将持久化存储的已读状态同步到内存中的 `sources` 数组。
    /// 这个方法比 `loadNews()` 更轻量，只更新 `isRead` 状态。
    func syncReadStatusFromPersistence() {
        DispatchQueue.main.async {
            var didChange = false
            for i in self.sources.indices {
                for j in self.sources[i].articles.indices {
                    let article = self.sources[i].articles[j]
                    // 如果文章在内存中是未读，但在持久化记录中是已读
                    if !article.isRead && self.readRecords.keys.contains(article.topic) {
                        self.sources[i].articles[j].isRead = true
                        didChange = true
                    }
                }
            }
            if didChange {
                print("状态同步：已将持久化的已读状态同步到内存中的 `sources`。")
            }
        }
    }

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

    private func indexPathOfArticle(id: UUID) -> (Int, Int)? {
        for i in sources.indices {
            if let j = sources[i].articles.firstIndex(where: { $0.id == id }) {
                return (i, j)
            }
        }
        return nil
    }

    // MARK: - 底层标记函数：会刷新内存 sources，从而刷新 UI
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

    // MARK: - 动态计数函数

    /// 计算指定日期分组内的有效未读文章数
    func getUnreadCountForDateGroup(timestamp: String, inSource sourceName: String?) -> Int {
        var count = 0
        
        if let name = sourceName {
            if let source = sources.first(where: { $0.name == name }) {
                let articlesForDate = source.articles.filter { $0.timestamp == timestamp }
                count = articlesForDate.filter { !isArticleEffectivelyRead($0) }.count
            }
        } else {
            for source in sources {
                let articlesForDate = source.articles.filter { $0.timestamp == timestamp }
                count += articlesForDate.filter { !isArticleEffectivelyRead($0) }.count
            }
        }
        
        return count
    }

    /// (新增) 计算指定上下文（单个源或全部）中的有效总未读数
    func getEffectiveUnreadCount(inSource sourceName: String?) -> Int {
        let articlesToScan: [Article]
        if let name = sourceName, let source = sources.first(where: { $0.name == name }) {
            // 情况一：从特定新闻源进入，扫描该源的所有文章
            articlesToScan = source.articles
        } else {
            // 情况二：从 "ALL" 进入，扫描所有来源的所有文章
            articlesToScan = sources.flatMap { $0.articles }
        }
        
        // 使用 isArticleEffectivelyRead 进行过滤，以获得实时准确的未读数
        return articlesToScan.filter { !isArticleEffectivelyRead($0) }.count
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
class AppBadgeManager: ObservableObject {
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("用户已授予角标权限。")
                } else {
                    print("用户未授予角标权限。")
                }
            }
        }
    }

    func updateBadge(count: Int) {
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "updateBadgeCount") {
            print("后台任务时间耗尽，强制结束角标更新任务。")
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        
        let badgeCount = max(0, count)

        UNUserNotificationCenter.current().setBadgeCount(badgeCount) { error in
            if let error = error {
                print("【角标更新失败】: \(error.localizedDescription)")
            } else {
                print("【角标更新成功】应用角标已(重新)设置为: \(badgeCount)")
            }
            
            if backgroundTask != .invalid {
                print("角标更新操作完成，结束后台任务。")
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }
}
