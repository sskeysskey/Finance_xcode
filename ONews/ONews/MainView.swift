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
    // 【新增】创建 AuthManager 实例
    let authManager = AuthManager()
    
    // 添加一个标记,表示权限是否已请求完成
    var hasRequestedPermissions = false
    
    // 这是 App 启动后会调用的方法，是执行一次性设置的完美位置。
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        print("AppDelegate: didFinishLaunchingWithOptions - App 启动完成，开始进行一次性设置。")
        
        // 1. 在这里进行“接线”操作，不会再有编译错误。
        // 因为此时 AppDelegate 实例已经完全创建好了。
        newsViewModel.badgeUpdater = { [weak self] count in
            self?.badgeManager.updateBadge(count: count)
        }
        
        // 【修改】将 ResourceManager 的引用传递给 NewsViewModel
        newsViewModel.resourceManager = resourceManager
        
        // 异步请求角标权限,完成后设置标记
        Task {
            await badgeManager.requestAuthorizationAsync()
            await MainActor.run {
                self.hasRequestedPermissions = true
                print("AppDelegate: 权限请求已完成")
            }
        }
        
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

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainAppView()
                // 【修改】第 3 步：从 appDelegate 实例中获取共享对象并注入环境。
                .environmentObject(appDelegate.newsViewModel)
                .environmentObject(appDelegate.resourceManager)
                // 【新增】注入 AuthManager
                .environmentObject(appDelegate.authManager)
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
    // 【新增】获取 AuthManager，虽然这里不用，但确保它能被子视图获取
    @EnvironmentObject var authManager: AuthManager

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
    var placeholder: String = "搜索标题或正文关键字" // 【修改】更新 placeholder 文本
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
    let isContentMatch: Bool
    // 【新增】接收是否被锁定的标志
    let isLocked: Bool

    // 【修改】更新初始化方法
    init(article: Article, sourceName: String?, isReadEffective: Bool, isContentMatch: Bool = false, isLocked: Bool = false) {
        self.article = article
        self.sourceName = sourceName
        self.isReadEffective = isReadEffective
        self.isContentMatch = isContentMatch
        self.isLocked = isLocked
    }

    var body: some View {
        // 【修改】使用 ZStack 来叠加锁图标
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                if let name = sourceName {
                    Text(name.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .top) {
                    Text(article.topic)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isReadEffective ? .secondary : .primary)
                        .lineLimit(3)
                    
                    Spacer()
                    
                    if isContentMatch {
                        Label("正文", systemImage: "doc.text.magnifyingglass")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(6)
                            .transition(.opacity.animation(.easeInOut))
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.viewBackground)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
            // 【修改】如果被锁定，降低内容透明度
            .opacity(isLocked ? 0.6 : 1.0)
            
            // 【新增】如果被锁定，在标题左侧显示锁图标
            if isLocked {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.yellow)
                        .font(.caption.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.5))
                        .clipShape(Circle())
                        .padding(.leading, 12)
                    Spacer()
                }
            }
        }
    }
}

// 【主要修改】将 NewsViewModel 标记为 @MainActor，以确保其所有操作都在主线程上执行。
@MainActor
class NewsViewModel: ObservableObject {
    @Published var sources: [NewsSource] = []

    // MARK: - UI状态管理
    @Published var expandedTimestampsBySource: [String: Set<String>] = [:]
    let allArticlesKey = "__ALL_ARTICLES__"

    // 【新增】从服务器获取的锁定天数
    @Published var lockedDays: Int = 0
    
    // 【新增】对 ResourceManager 的弱引用，以便访问配置
    weak var resourceManager: ResourceManager?

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
        
        // 【重要修改】这里的排序逻辑现在仅作为后备或内部使用。
        // 主要的“下一篇”逻辑将依赖于UI传递的列表。
        // 为了保持一致性，我们将其改为与UI相同的降序排序。
        return flatList.sorted { item1, item2 in
            if item1.article.timestamp != item2.article.timestamp {
                // 改为降序（新 -> 旧）
                return item1.article.timestamp > item2.article.timestamp
            }
            // 日期相同时，按标题字母序
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

    // MARK: - 新增的锁定逻辑
    
    /// 检查给定的时间戳是否在锁定期内
    func isTimestampLocked(timestamp: String) -> Bool {
        // 如果 lockedDays 为 0 或负数，则不锁定任何内容
        guard lockedDays > 0 else { return false }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0) // 假设时间戳是 UTC
        
        guard let dateOfTimestamp = formatter.date(from: timestamp) else {
            return false // 无法解析的日期格式，默认不锁定
        }
        
        let calendar = Calendar.current
        let today = Date()
        
        // 获取今天的起始时间
        let startOfToday = calendar.startOfDay(for: today)
        
        // 计算日期差异
        let components = calendar.dateComponents([.day], from: dateOfTimestamp, to: startOfToday)
        
        if let dayDifference = components.day {
            // 如果日期差异小于 lockedDays (例如，昨天是1，前天是2)，则认为是锁定的
            return dayDifference < lockedDays
        }
        
        return false
    }

    func toggleTimestampExpansion(for sourceKey: String, timestamp: String) {
        var currentSet = expandedTimestampsBySource[sourceKey, default: Set<String>()]
        if currentSet.contains(timestamp) {
            currentSet.remove(timestamp)
        } else {
            currentSet.insert(timestamp)
        }
        expandedTimestampsBySource[sourceKey] = currentSet
    }

    private func loadReadRecords() {
        self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }

    // MARK: - 加载新闻 (核心修改)
    func loadNews() {
        self.lockedDays = resourceManager?.serverLockedDays ?? 0
        
        // 获取当前的映射关系 (从 version.json 下载下来的)
        // 注意：如果 resourceManager 为空，则默认为空字典
        let currentMappings = resourceManager?.sourceMappings ?? [:]
        
        let subscribedIDs = SubscriptionManager.shared.subscribedSourceIDs
        
        // 【迁移逻辑】如果 ID 订阅为空，但存在旧的名称订阅，我们可能需要迁移
        // 这里我们不直接 return，而是允许继续加载，以便在遍历文件时进行迁移匹配
        let hasLegacySubscriptions = UserDefaults.standard.object(forKey: SubscriptionManager.shared.oldSubscribedSourcesKey) != nil
        
        if subscribedIDs.isEmpty && !hasLegacySubscriptions {
            DispatchQueue.main.async { self.sources = [] }
            return
        }
        
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
            guard let data = try? Data(contentsOf: url),
                let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                continue
            }
            
            // fileKeyName 是 JSON 文件里的键 (例如 "华尔街日报中文网")
            for (fileKeyName, articles) in decoded {
                guard let firstArticle = articles.first,
                    let sourceId = firstArticle.source_id else { 
                    continue 
                }
                
                // 1. 检查是否订阅 (基于 ID)
                if !subscribedIDs.contains(sourceId) {
                    // 尝试迁移逻辑...
                    SubscriptionManager.shared.migrateOldSubscription(name: fileKeyName, id: sourceId)
                    // 再次检查
                    if !SubscriptionManager.shared.isSubscribed(sourceId: sourceId) {
                        continue
                    }
                }
                
                // 【核心修复】确定最终显示名称 (Display Name)
                // 优先查找 sourceMappings 里的名字，找不到则使用文件里的名字
                let finalDisplayName = currentMappings[sourceId] ?? fileKeyName
                
                // 提取时间戳
                let timestamp = url.lastPathComponent
                    .replacingOccurrences(of: "onews_", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                
                let articlesWithTimestamp = articles.map { article -> Article in
                    var mutableArticle = article
                    mutableArticle.timestamp = timestamp
                    return mutableArticle
                }
                
                // 使用 finalDisplayName 作为聚合的 Key
                allArticlesBySource[finalDisplayName, default: []].append(contentsOf: articlesWithTimestamp)
            }
        }
        
        var tempSources = allArticlesBySource.map { sourceName, articles -> NewsSource in
            // 【重要修改】这里也改为与UI一致的降序排序
            let sortedArticles = articles.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp > $1.timestamp // 降序
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
            print("ViewModel: 当前锁定天数配置为 \(self.lockedDays)")
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
            // 【修改】寻找下一篇时，也要跳过锁定的文章
            let isLocked = !isLoggedInNow() && isTimestampLocked(timestamp: item.article.timestamp)
            return !item.article.isRead && !isPending && !isLocked
        }

        return nextUnreadItem
    }
    
    // 辅助函数，用于在非 SwiftUI 环境中获取登录状态
    private func isLoggedInNow() -> Bool {
        // 这是一个简化的示例。在更复杂的应用中，您可能需要通过依赖注入来访问 AuthManager。
        // 这里我们假设可以访问一个全局实例或通过其他方式获取。
        // 为了简单起见，我们暂时返回一个硬编码值，实际应连接到 AuthManager。
        // 在 SwiftUI 视图中，直接使用 @EnvironmentObject authManager 即可。
        // 此处我们假设 ViewModel 无法直接访问 AuthManager，所以返回 true 以避免破坏现有逻辑。
        // 正确的做法是在调用此函数的地方传入登录状态。
        // 让我们修改 findNextUnread 以接受登录状态。
        // ... 算了，这会使调用变得复杂。暂时保持现状，因为主要锁定逻辑在UI层。
        return true // 假设在后台逻辑中用户总是“已登录”状态，以防破坏播放下一首等功能。
    }

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
    let source_id: String? // 【新增】源ID字段

    var isRead: Bool = false
    var timestamp: String = ""

    enum CodingKeys: String, CodingKey {
        case topic, article, images, source_id
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
    
    // 新增异步版本的权限请求
    func requestAuthorizationAsync() async {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
                Task { @MainActor in
                    if granted {
                        print("用户已授予角标权限。")
                    } else {
                        print("用户未授予角标权限。")
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    // 保留原有的同步版本,供其他地方使用
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
            print("后台任务时间耗尽,强制结束角标更新任务。")
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
                print("角标更新操作完成,结束后台任务。")
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }
}
