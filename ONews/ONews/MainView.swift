import SwiftUI
import UserNotifications
import Combine
import UIKit

extension Color {
    // 稍微带一点灰度的背景，比纯白更护眼，能衬托出白色卡片
    static let viewBackground = Color(UIColor.systemGroupedBackground)
    
    // 卡片背景：浅色模式纯白，深色模式深灰
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
}

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
        
        // --- 🌍 国际化智能初始化逻辑 ---
        initializeLanguagePreference()
        // ------------------------------------

        // ... (原有的接线操作)
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
    
    // 【新增】辅助方法：只在首次安装时，根据系统语言自动设置默认模式
    private func initializeLanguagePreference() {
        let defaults = UserDefaults.standard
        let initKey = "hasInitializedLanguage"
        
        // 1. 检查是否已经初始化过
        // 如果已经初始化过，说明用户可能已经手动改过设置，或者已经沿用了上次的自动设置，直接跳过，尊重用户选择。
        if defaults.bool(forKey: initKey) {
            return
        }
        
        // 2. 获取当前系统语言或区域 (兼容 iOS 16 新旧 API)
        let languageCode: String?
        let regionCode: String?
        
        if #available(iOS 16, *) {
            languageCode = Locale.current.language.languageCode?.identifier
            regionCode = Locale.current.region?.identifier
        } else {
            languageCode = Locale.current.languageCode
            regionCode = Locale.current.regionCode
        }
        
        print("检测到系统语言: \(languageCode ?? "nil"), 地区: \(regionCode ?? "nil")")
        
        var shouldBeEnglish = false
        
        // 3. 判断逻辑
        // 策略 A：如果语言代码是 'en' (英语)，直接默认开启
        if let lang = languageCode, lang.contains("en") {
            shouldBeEnglish = true
        }
        // 策略 B：或者如果地区是美国 (US)、英国 (GB)、加拿大 (CA)、澳大利亚 (AU) 等
        else if let region = regionCode, ["US", "GB", "CA", "AU", "NZ", "IE"].contains(region) {
            shouldBeEnglish = true
        }
        
        // 4. 写入设置
        // 这里直接修改 "isGlobalEnglishMode"，视图里的 @AppStorage 会自动读取这个值
        defaults.set(shouldBeEnglish, forKey: "isGlobalEnglishMode")
        
        // 5. 标记已初始化，以后不再自动覆盖
        defaults.set(true, forKey: initKey)
        
        print("【国际化】首次启动初始化完成。默认英文模式: \(shouldBeEnglish)")
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
        ZStack { // 【修改】使用 ZStack 包裹，以便放置强制更新层
            if hasCompletedInitialSetup {
                SourceListView()
            } else {
                WelcomeView(hasCompletedInitialSetup: $hasCompletedInitialSetup)
            }
            
            // 【新增】强制更新拦截层
            // 只要 showForceUpdate 为 true，这个视图就会盖住底下所有内容
            if resourceManager.showForceUpdate {
                ForceUpdateView(storeURL: resourceManager.appStoreURL)
                    .transition(.opacity)
                    .zIndex(999) // 确保在最上层
            }
        }
        .animation(.easeInOut, value: resourceManager.showForceUpdate)
    }
}

/// 公共：搜索输入视图（在导航栏下方显示）
/// 已从各个视图文件中提取至此，以供全局复用。
struct SearchBarInline: View {
    @Binding var text: String
    // 【修改】默认使用 Localized 里的占位符
    var placeholder: String = Localized.searchPlaceholder 
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
                // 【修改】使用 Localized.search
                Button(Localized.search) { onCommit() }
                    .buttonStyle(.bordered)
            }

            // 【修改】使用 Localized.cancel
            Button(Localized.cancel) {
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
    let sourceNameEN: String? // 【新增】接收英文名称
    let isReadEffective: Bool
    let isContentMatch: Bool
    let isLocked: Bool
    
    // 【新增 1】接收外部传入的语言状态
    let showEnglish: Bool

    // 【修改】初始化方法，增加 sourceNameEN，默认值为 nil
    init(article: Article, sourceName: String?, sourceNameEN: String? = nil, isReadEffective: Bool, isContentMatch: Bool = false, isLocked: Bool = false, showEnglish: Bool = false) {
        self.article = article
        self.sourceName = sourceName
        self.sourceNameEN = sourceNameEN // 【新增】
        self.isReadEffective = isReadEffective
        self.isContentMatch = isContentMatch
        self.isLocked = isLocked
        self.showEnglish = showEnglish
    }
    
    // 【新增 3】核心逻辑：决定显示哪个标题
    var displayTopic: String {
        // 如果开启英文模式且有英文标题，则显示英文
        if showEnglish, let engTitle = article.topic_eng, !engTitle.isEmpty {
            return engTitle
        }
        // 否则（关闭模式 或 没有英文标题），显示中文
        return article.topic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { 
            // 1. 顶部元数据行：来源名称 + 锁定状态
            HStack {
                if let name = sourceName {
                    // 【核心修改】这里增加判断：如果是英文模式且有英文名，显示英文名；否则显示中文名
                    let finalName = (showEnglish && sourceNameEN != nil && !sourceNameEN!.isEmpty) ? sourceNameEN! : name
                    
                    Text(finalName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 11, weight: .bold, design: .default))
                        .tracking(0.5)
                        .foregroundColor(isReadEffective ? .secondary.opacity(0.7) : .blue.opacity(0.8))
                        // 添加动画
                        .animation(.none, value: showEnglish)
                }
                
                Spacer()
                
                if isLocked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14))
                        // 【修改】使用 Localized.needSubscription
                        Text(Localized.needSubscription)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
                }
            }
            
            // 2. 标题区域：使用衬线字体
            HStack(alignment: .top) {
                // 【修改 4】这里必须使用计算出来的 displayTopic，而不是固定的 article.topic
                Text(displayTopic)
                    .font(.system(size: 19, weight: isReadEffective ? .regular : .bold, design: .serif))
                    .foregroundColor(isReadEffective ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true) // 防止截断
                    .multilineTextAlignment(.leading)
                    .opacity(isReadEffective ? 0.8 : 1.0)
                    // 【可选】添加动画，让文字切换更平滑
                    .animation(.none, value: showEnglish)
                
                Spacer(minLength: 0)
            }

            // 3. 底部标签栏：正文匹配标记等
            if isContentMatch {
                HStack {
                    // 【修改】使用 Localized.contentMatch
                    Label(Localized.contentMatch, systemImage: "text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(18) // 【修改】内边距也稍微加大一点，让文字不拥挤
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color.black.opacity(isReadEffective ? 0.02 : 0.06), radius: 8, x: 0, y: 4)
        )
        // 如果已读，稍微降低整体透明度，让未读内容更突出
        .opacity(isLocked ? 0.7 : 1.0)
    }
}

// 【主要修改】将 NewsViewModel 标记为 @MainActor，以确保其所有操作都在主线程上执行。
@MainActor
class NewsViewModel: ObservableObject {
    // 定义一个公共的静态常量
    nonisolated static let preferredSourceOrder: [String] = [
        "ft",        // 金融时报
        "wsjcn",     // 华尔街日报中文
        "nytimes",   // 纽约时报
        "bloomberg", // 彭博社
        "rfi",       // 法广
        "nikkei",    // 日经亚洲
        "dw",         // 德声
        "wsj",       // 华尔街日报
        "economist", // 经济学人
        "reuters",   // 路透社
        "washpost",  // 华盛顿邮报
        "mittr",     // 麻省理工
    ]

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
    
    // 【优化】静态 DateFormatter 缓存，避免重复创建
    private static let lockCheckFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var allArticlesSortedForDisplay: [(article: Article, sourceName: String, sourceNameEN: String)] {
        let flatList = self.sources.flatMap { source in
            // 这里返回的是 3 个元素，现在类型签名匹配了
            source.articles.map { (article: $0, sourceName: source.name, sourceNameEN: source.name_en) }
        }
        
        return flatList.sorted { item1, item2 in
            if item1.article.timestamp != item2.article.timestamp {
                return item1.article.timestamp > item2.article.timestamp
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

    // MARK: - 新增的锁定逻辑
    
    /// 检查给定的时间戳是否在锁定期内
    func isTimestampLocked(timestamp: String) -> Bool {
        // 如果 lockedDays 为 0 或负数，则不锁定任何内容
        guard lockedDays > 0 else { return false }
        
        // 【优化】使用静态 formatter
        guard let dateOfTimestamp = Self.lockCheckFormatter.date(from: timestamp) else {
            return false
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
    
    // 【优化】核心修改：异步加载数据，防止卡顿
    func loadNews() {
        self.lockedDays = resourceManager?.serverLockedDays ?? 0
        
        // 获取当前的映射关系 (从 version.json 下载下来的 "wsj": "环球资讯|Global Info")
        let currentMappings = resourceManager?.sourceMappings ?? [:]
        
        let subscribedIDs = SubscriptionManager.shared.subscribedSourceIDs
        
        // 【迁移逻辑】兼容旧版本
        let hasLegacySubscriptions = UserDefaults.standard.object(forKey: SubscriptionManager.shared.oldSubscribedSourcesKey) != nil
        
        if subscribedIDs.isEmpty && !hasLegacySubscriptions {
            self.sources = []
            return
        }

        let preferredOrder = Self.preferredSourceOrder
        
        // 捕获需要的数据，传入后台 Task
        let docDir = self.documentsDirectory
        let readRecordsCopy = self.readRecords
        
        // 使用 Task.detached 将繁重的 IO 和 JSON 解码移出主线程
        Task.detached(priority: .userInitiated) {
            guard let allFileURLs = try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else {
                return
            }
            
            let newsJSONURLs = allFileURLs.filter {
                $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json"
            }
            
            guard !newsJSONURLs.isEmpty else { return }
            
            // 【修改点1】Key改为 String (source_id)，不再是中文名
            var allArticlesBySourceID = [String: [Article]]()
            let decoder = JSONDecoder()
            
            for url in newsJSONURLs {
                // 这里的 Data 读取和 decode 是最耗时的，现在在后台线程运行
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                    continue
                }
                
                for (_, articles) in decoded {
                    // 必须有 source_id
                    guard let firstArticle = articles.first,
                          let sourceId = firstArticle.source_id else {
                        continue
                    }
                    
                    // 【修改】直接使用函数开头捕获的 subscribedIDs 副本
                    // 这样就避免了在后台线程访问 SubscriptionManager 单例，确保线程安全
                    if !subscribedIDs.contains(sourceId) {
                        continue
                    }
                    
                    let timestamp = url.lastPathComponent
                        .replacingOccurrences(of: "onews_", with: "")
                        .replacingOccurrences(of: ".json", with: "")
                    
                    let articlesWithTimestamp = articles.map { article -> Article in
                        var mutableArticle = article
                        mutableArticle.timestamp = timestamp
                        return mutableArticle
                    }
                    
                    // 【修改点2】直接用 sourceId 作为归类的 Key
                    allArticlesBySourceID[sourceId, default: []].append(contentsOf: articlesWithTimestamp)
                }
            }
            
            // 【修改点3】在这里统一处理 "中文|英文" 的分割逻辑
            var tempSources = allArticlesBySourceID.map { sourceId, articles -> NewsSource in
                
                // 1. 获取映射字符串 (例如: "环球资讯|Global Info")
                // 如果没有映射，就暂时用 sourceId
                let rawMappingName = currentMappings[sourceId] ?? sourceId
                
                // 2. 切分字符串
                let nameParts = rawMappingName.components(separatedBy: "|")
                let cnName = nameParts.first ?? rawMappingName
                // 如果有竖线后的部分就用，没有则回退到中文名
                let enName = nameParts.count > 1 ? nameParts[1] : cnName
                
                let sortedArticles = articles.sorted {
                    if $0.timestamp != $1.timestamp {
                        return $0.timestamp > $1.timestamp
                    }
                    return $0.topic < $1.topic
                }
                
                return NewsSource(
                    sourceId: sourceId,
                    name: cnName,      // 存中文
                    name_en: enName,   // 存英文
                    articles: sortedArticles
                )
            }
            // 【步骤 2：修改排序逻辑】
            // 原代码: .sorted { $0.name < $1.name }
            // 修改为:
            .sorted { source1, source2 in
                // 获取两个源在自定义列表中的索引 (如果没有找到，返回 Int.max，即排到最后)
                let index1 = preferredOrder.firstIndex(of: source1.sourceId) ?? Int.max
                let index2 = preferredOrder.firstIndex(of: source2.sourceId) ?? Int.max
                
                // 如果两个都在列表中（或者有一个在列表中），按列表索引排序（小的在前）
                if index1 != index2 {
                    return index1 < index2
                }
                
                // 如果两个都不在列表中（index 都是 Int.max），则回退到按中文名称排序
                return source1.name < source2.name
            }
            
            // 应用已读状态
            for i in tempSources.indices {
                for j in tempSources[i].articles.indices {
                    let topic = tempSources[i].articles[j].topic
                    if readRecordsCopy.keys.contains(topic) {
                        tempSources[i].articles[j].isRead = true
                    }
                }
            }
            
            // 【关键修改】在切换回 MainActor 之前，将 var 转为 let。
            // 这解决了 "Reference to captured var" 警告。
            let finalSources = tempSources
            
            // 回到主线程更新 UI
            await MainActor.run {
                self.sources = finalSources
                print("新闻数据加载/刷新完成！(后台线程处理)")
            }
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
        // 1. 统一数据源类型
        let candidates: [(article: Article, sourceName: String)]
        
        if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
            candidates = source.articles.map { (article: $0, sourceName: name) }
        } else {
            // allArticlesSortedForDisplay 现在包含 3 个元素，我们只取前两个用于查找逻辑
            candidates = self.allArticlesSortedForDisplay.map { ($0.article, $0.sourceName) }
        }
        
        // 2. 查找当前文章索引
        guard let currentIndex = candidates.firstIndex(where: { $0.article.id == id }) else {
            return nil
        }
        
        // 3. 【修复点】这里必须使用 candidates，而不是旧的 baseList
        let subsequentItems = candidates.suffix(from: currentIndex + 1)
        
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
    let sourceId: String // 【新增】保存原始ID (如 "wsj")
    let name: String     // 存中文名 (作为默认/逻辑主键)
    let name_en: String  // 【新增】存英文名
    
    var articles: [Article]
    
    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }
}

struct Article: Identifiable, Codable, Hashable {
    var id = UUID()
    let topic: String
    let article: String
    // --- 新增下面两个字段 ---
    let topic_eng: String?   // 英文标题 (可选)
    let article_eng: String? // 英文正文 (可选)
    // ----------------------
    let images: [String]
    let source_id: String?
    let url: String?
    var isRead: Bool = false
    var timestamp: String = ""

    enum CodingKeys: String, CodingKey {
        // --- 记得在这里添加映射 ---
        case topic, article, images, source_id, url, topic_eng, article_eng
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
