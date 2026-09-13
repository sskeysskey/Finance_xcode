import SwiftUI
import UserNotifications
import Combine
import UIKit

extension Color {
    static let viewBackground = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
}

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return Self.orientationLock
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        print("✨ [AppDelegate] 收到后台下载 URLSession 事件，Identifier: \(identifier)")
        HLSDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    let newsViewModel = NewsViewModel()
    let resourceManager = ResourceManager()
    let badgeManager = AppBadgeManager()
    let authManager = AuthManager.shared

    let predictionSyncManager = PredictionSyncManager()
    let preferenceManager = PreferenceManager()
    let translationManager = TranslationManager()

    let videoDataManager = OVideoDataManager()

    var hasRequestedPermissions = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        print("AppDelegate: didFinishLaunchingWithOptions - App 启动完成，开始进行一次性设置。")

        initializeLanguagePreference()

        newsViewModel.badgeUpdater = { [weak self] count in
            self?.badgeManager.updateBadge(count: count)
        }
        newsViewModel.resourceManager = resourceManager

        Task {
            await NotificationPermissionManager.shared.refreshStatus()
            await MainActor.run { self.hasRequestedPermissions = true }
        }

        // 视频模块预加载
        Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard let self = self else { return }
            let uid = self.authManager.userIdentifier
            await self.videoDataManager.bootstrap(userId: uid)

            let idx = UserDefaults.standard.integer(forKey: "OVideo_SelectedCategoryIndex")
            let sortRaw = UserDefaults.standard.string(forKey: "OVideo_SortOption")
                ?? VideoSortOption.date.rawValue
            let sort = VideoSortOption(rawValue: sortRaw) ?? .date
            let names = self.videoDataManager.categoryNames
            if idx >= 0, idx < names.count {
                await self.videoDataManager.loadFirstPageIfNeeded(
                    category: names[idx], sort: sort, userId: uid)
            }
            await SeriesTrackManager.shared.refresh(force: true)
            print("📺 [预加载] 视频首页第一页已预热。")
        }

        let tv = UITableView.appearance()
        tv.backgroundColor = .clear
        tv.separatorStyle = .none

        return true
    }

    private func initializeLanguagePreference() {
        let defaults = UserDefaults.standard
        let initKey = "hasInitializedLanguage"
        if defaults.bool(forKey: initKey) { return }
        let preferredLang = Locale.preferredLanguages.first ?? "en"
        print("【国际化】检测到系统首选语言: \(preferredLang)")
        let isChinese = preferredLang.hasPrefix("zh")
        let shouldBeEnglish = !isChinese
        defaults.set(shouldBeEnglish, forKey: "isGlobalEnglishMode")
        defaults.set(true, forKey: initKey)
        print("【国际化】首次启动初始化完成。设置英文模式: \(shouldBeEnglish)")
    }
}


@main
struct NewsReaderAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainAppView()
                .environmentObject(appDelegate.newsViewModel)
                .environmentObject(appDelegate.resourceManager)
                .environmentObject(appDelegate.authManager)
                .environmentObject(appDelegate.predictionSyncManager)
                .environmentObject(appDelegate.preferenceManager)
                .environmentObject(appDelegate.translationManager)
                .environmentObject(appDelegate.videoDataManager)
        }
        .onChange(of: scenePhase) { newPhase in
            let newsViewModel = appDelegate.newsViewModel
            let authManager = appDelegate.authManager
            let resourceManager = appDelegate.resourceManager
            let videoDataManager = appDelegate.videoDataManager

            if newPhase == .active {
                print("App is active. Syncing status...")
                newsViewModel.syncReadStatusFromPersistence()
                authManager.handleAppDidBecomeActive()

                Task {
                    await FreeQuotaManager.shared.refresh(
                        userId: FreeQuotaManager.currentUserId(auth: authManager))
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager))
                    await SeriesTrackManager.shared.refresh(force: true)
                }

                Task {
                    await NotificationPermissionManager.shared.refreshStatus()
                    await resourceManager.silentRefresh(minInterval: 30, reason: "foreground")
                    await videoDataManager.silentRefreshCurrentSelection(
                        userId: authManager.userIdentifier, minInterval: 30)
                }

            } else if newPhase == .background {
                // ★ 现在这里是同步落盘（按 topic），不再依赖 UUID 反查
                print("App entered background. Committing pending reads.")
                newsViewModel.commitPendingReadsSilently()
                Task { @MainActor in
                    ImageLoader.clearCache()
                    print("App entered background. Image cache cleared to save memory.")
                }
            } else if newPhase == .inactive {
                newsViewModel.commitPendingReadsSilently()
            }
        }
    }
}

struct MainAppView: View {
    @AppStorage("hasCompletedInitialSetup") private var hasCompletedInitialSetup = false
    @AppStorage("prefersVideoHome") private var prefersVideoHome = false

    @EnvironmentObject var resourceManager: ResourceManager
    @EnvironmentObject var newsViewModel: NewsViewModel
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var pointsCoordinator = NewsPointsCoordinator.shared
    @ObservedObject private var notifManager = NotificationPermissionManager.shared
    @ObservedObject private var anonPromo = AnonymousSubscribePromptManager.shared
    @ObservedObject private var purchaseFlow = PurchaseFlowManager.shared

    private func syncGlobalBlock() {
        notifManager.setGlobalBlocked(
            !hasCompletedInitialSetup
            || resourceManager.showForceUpdate
            || resourceManager.showMigrationSheet
        )
    }

    var body: some View {
        ZStack {
            if hasCompletedInitialSetup {
                if prefersVideoHome { VideoOnlyHomeView() } else { SourceListView() }
            } else {
                WelcomeView(hasCompletedInitialSetup: $hasCompletedInitialSetup)
            }

            if resourceManager.showForceUpdate {
                ForceUpdateView(storeURL: resourceManager.appStoreURL)
                    .transition(.opacity).zIndex(998)
            }
            if resourceManager.showMigrationSheet, let config = resourceManager.activeMigration {
                MigrationView(config: config,
                              onDismiss: config.isForced ? nil : { resourceManager.dismissMigration() })
                    .transition(.opacity.combined(with: .move(edge: .bottom))).zIndex(999)
            }

            NewsPointsOverlayView().zIndex(1000)
            AppFlowOverlay().zIndex(1001)
        }
        .animation(.easeInOut, value: resourceManager.showForceUpdate)
        .animation(.easeInOut, value: resourceManager.showMigrationSheet)

        .background(
            Color.clear
                .sheet(isPresented: $pointsCoordinator.showInviteSheet) { NewsInviteView() }
        )
        .background(
            Color.clear
                .sheet(isPresented: $pointsCoordinator.showVideoInviteSheet) { VideoInviteView() }
        )
        .background(
            Color.clear
                .sheet(isPresented: $authManager.showSubscriptionSheet) { SubscriptionView() }
        )
        .background(
            Color.clear
                .sheet(isPresented: $anonPromo.showSheet) { AnonymousSubscribeView() }
        )
        .background(
            Color.clear
                .sheet(isPresented: $notifManager.showPreAsk) { NotificationPreAskView() }
        )

        .onReceive(NotificationCenter.default.publisher(for: .notificationPermissionGranted)) { _ in
            newsViewModel.refreshBadge()
        }
        .onChange(of: pointsCoordinator.showSubscriptionSheet) { show in
            guard show, PurchaseFlowManager.useDirectPurchase else { return }
            pointsCoordinator.showSubscriptionSheet = false
            PurchaseFlowManager.shared.startPurchase(auth: authManager, reason: "points-coordinator")
        }
        .onAppear { syncGlobalBlock() }
        .onChange(of: hasCompletedInitialSetup) { _ in syncGlobalBlock() }
        .onChange(of: resourceManager.showForceUpdate) { _ in syncGlobalBlock() }
        .onChange(of: resourceManager.showMigrationSheet) { _ in syncGlobalBlock() }
        .onChange(of: authManager.isSubscribed) { subscribed in
            if subscribed { AnonymousSubscribePromptManager.shared.markPurchased() }
        }
        .onChange(of: authManager.isLoggedIn) { newVal in
            if newVal {
                Task {
                    await FreeQuotaManager.shared.refresh(
                        userId: FreeQuotaManager.currentUserId(auth: authManager))
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager))
                }
            }
        }
    }
}

struct VideoOnlyHomeView: View {
    @EnvironmentObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var supportManager = SupportChatManager.shared

    var body: some View {
        NavigationStack {
            if resourceManager.showVideoModule {
                VideoModuleView(showBackButton: false)
            } else {
                VideoModuleClosedView()
            }
        }
        .onAppear {
            Task { await resourceManager.refreshServerConfig(minInterval: 120) }
        }
        .sheet(isPresented: $supportManager.showChat) {
            SupportChatView(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        }
    }
}

struct SearchBarInline: View {
    @Binding var text: String
    var placeholder: String = Localized.searchPlaceholder
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(placeholder, text: $text, onCommit: onCommit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .focused($isFocused)
                if !text.isEmpty {
                    Button(action: { text = ""; isFocused = true }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary.opacity(0.6))
                            .padding(.trailing, 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)

            if !text.isEmpty {
                Button(Localized.search) { onCommit() }.buttonStyle(.bordered)
            }
            Button(Localized.cancel) { onCancel(); isFocused = false }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
        .onAppear { DispatchQueue.main.async { self.isFocused = true } }
    }
}

// ============================================================================
// MARK: - NewsViewModel（★已读引擎重写：同步落盘 + topic 稳定键 + 稳定 UUID）
// ============================================================================
@MainActor
class NewsViewModel: ObservableObject {
    nonisolated static let preferredSourceOrder: [String] = [
        "ft", "wsjcn", "nytimes", "bloomberg", "rfi", "nikkei", "dw",
        "wsj", "economist", "reuters", "washpost", "mittr", "bbc",
    ]

    @Published var sources: [NewsSource] = []
    @Published var expandedTimestampsBySource: [String: Set<String>] = [:]
    let allArticlesKey = "__ALL_ARTICLES__"

    @Published var lockedDays: Int = 0
    weak var resourceManager: ResourceManager?

    private let subscriptionManager = SubscriptionManager.shared
    private let readKey = "readTopics"
    private var readRecords: [String: Date] = [:]

    var badgeUpdater: ((Int) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    /// 暂存已读（id -> topic）。现在只作为兼容通道，主流程都是"写入即落盘"
    private var pendingReadTopics: [UUID: String] = [:]

    /// 当前详情页正在阅读的文章（兜底提交用）
    private var readingArticleID: UUID?
    private var readingArticleTopic: String?

    /// 阅读详情页期间禁止重建 sources
    @Published var isReadingArticle: Bool = false {
        didSet {
            guard oldValue != isReadingArticle else { return }
            if !isReadingArticle && pendingReload {
                pendingReload = false
                print("📥 [延后刷新] 退出详情页，开始落地新数据。")
                loadNews()
            }
        }
    }
    private var pendingReload = false

    private struct ReadTarget {
        let id: UUID?
        let topic: String
    }

    nonisolated private static func djb2Hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = (hash &<< 5) &+ hash &+ UInt64(byte) }
        return hash
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @Published var allArticlesSortedForDisplay: [(article: Article, sourceName: String, sourceNameEN: String)] = []

    init() {
        loadReadRecords()

        $sources
            .map { sources in sources.flatMap { $0.articles }.filter { !$0.isRead }.count }
            .removeDuplicates()
            .sink { [weak self] unreadCount in
                self?.badgeUpdater?(unreadCount)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .newsDataDidUpdate)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isReadingArticle {
                    self.pendingReload = true
                    print("📥 [延后刷新] 用户正在阅读，新数据稍后落地。")
                    return
                }
                print("收到数据更新通知，重新加载本地新闻数据...")
                self.loadNews()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .newsConfigDidUpdate)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let d = self.resourceManager?.serverLockedDays ?? 0
                if self.lockedDays != d { self.lockedDays = d }
            }
            .store(in: &cancellables)
    }

    func refreshBadge() {
        badgeUpdater?(totalUnreadCount)
    }

    // MARK: - 锁定逻辑
    func isTimestampLocked(timestamp: String) -> Bool {
        NewsLockRule.isLocked(timestamp: timestamp,
                              lockedDays: lockedDays,
                              serverDate: resourceManager?.serverDate)
    }

    func toggleTimestampExpansion(for sourceKey: String, timestamp: String) {
        var currentSet = expandedTimestampsBySource[sourceKey, default: Set<String>()]
        if currentSet.contains(timestamp) { currentSet.remove(timestamp) } else { currentSet.insert(timestamp) }
        expandedTimestampsBySource[sourceKey] = currentSet
    }

    private func loadReadRecords() {
        self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }

    // MARK: - 数据加载
    func loadNews() {
        if isReadingArticle {
            pendingReload = true
            return
        }

        self.lockedDays = resourceManager?.serverLockedDays ?? 0
        let currentMappings = resourceManager?.sourceMappings ?? [:]
        let subscribedIDs = SubscriptionManager.shared.subscribedSourceIDs
        let hasLegacySubscriptions = UserDefaults.standard.object(forKey: SubscriptionManager.shared.oldSubscribedSourcesKey) != nil

        if subscribedIDs.isEmpty && !hasLegacySubscriptions {
            self.sources = []
            self.allArticlesSortedForDisplay = []
            return
        }

        let preferredOrder = Self.preferredSourceOrder
        let docDir = self.documentsDirectory
        let readRecordsCopy = self.readRecords

        Task.detached(priority: .userInitiated) {
            guard let allFileURLs = try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else { return }
            let newsJSONURLs = allFileURLs.filter {
                $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json"
            }
            guard !newsJSONURLs.isEmpty else { return }

            var allArticlesBySourceID = [String: [Article]]()
            let decoder = JSONDecoder()
            // ★ 稳定 ID 去重集合
            var usedKeys = Set<String>()

            for url in newsJSONURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([String: [Article]].self, from: data) else { continue }

                for (_, articles) in decoded {
                    guard let firstArticle = articles.first,
                          let sourceId = firstArticle.source_id else { continue }
                    if !subscribedIDs.contains(sourceId) { continue }

                    let timestamp = url.lastPathComponent
                        .replacingOccurrences(of: "onews_", with: "")
                        .replacingOccurrences(of: ".json", with: "")

                    let articlesWithTimestamp = articles.map { article -> Article in
                        var m = article
                        m.timestamp = timestamp
                        // ★★★ 确定性稳定标识：数据重建后 id 不变
                        var key = "\(sourceId)|\(timestamp)|\(article.topic)"
                        if usedKeys.contains(key) {
                            var n = 2
                            while usedKeys.contains("\(key)#\(n)") { n += 1 }
                            key = "\(key)#\(n)"
                        }
                        usedKeys.insert(key)
                        m.stableKey = key
                        m.id = Article.stableUUID(from: key)
                        return m
                    }
                    allArticlesBySourceID[sourceId, default: []].append(contentsOf: articlesWithTimestamp)
                }
            }

            var tempSources = allArticlesBySourceID.map { sourceId, articles -> NewsSource in
                let rawMappingName = currentMappings[sourceId] ?? sourceId
                let nameParts = rawMappingName.components(separatedBy: "|")
                let cnName = nameParts.first ?? rawMappingName
                let enName = nameParts.count > 1 ? nameParts[1] : cnName

                let sortedArticles = articles.sorted {
                    if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                    let h1 = $0.hot ?? 0, h2 = $1.hot ?? 0
                    if h1 != h2 { return h1 > h2 }
                    return $0.topic < $1.topic
                }
                return NewsSource(sourceId: sourceId, name: cnName, name_en: enName, articles: sortedArticles)
            }
            .sorted { source1, source2 in
                let index1 = preferredOrder.firstIndex(of: source1.sourceId) ?? Int.max
                let index2 = preferredOrder.firstIndex(of: source2.sourceId) ?? Int.max
                if index1 != index2 { return index1 < index2 }
                return source1.name < source2.name
            }

            for i in tempSources.indices {
                for j in tempSources[i].articles.indices {
                    let topic = tempSources[i].articles[j].topic
                    if readRecordsCopy.keys.contains(topic) {
                        tempSources[i].articles[j].isRead = true
                    }
                }
            }

            let finalSources = tempSources
            let flatList = finalSources.flatMap { source in
                source.articles.map { (article: $0, sourceName: source.name, sourceNameEN: source.name_en) }
            }
            let finalAllArticles = flatList.sorted { item1, item2 in
                if item1.article.timestamp != item2.article.timestamp {
                    return item1.article.timestamp > item2.article.timestamp
                }
                let h1 = item1.article.hot ?? 0, h2 = item2.article.hot ?? 0
                if h1 != h2 { return h1 > h2 }
                let key1 = NewsViewModel.djb2Hash(item1.article.topic + item1.sourceName)
                let key2 = NewsViewModel.djb2Hash(item2.article.topic + item2.sourceName)
                return key1 < key2
            }

            await MainActor.run {
                NewsLockRule.noteNewestLocalArticleDate(finalAllArticles.first?.article.timestamp)

                if self.isReadingArticle {
                    self.pendingReload = true
                    return
                }

                // ★★★ 关键修复：用"当前"的 readRecords 再刷一遍，消除后台快照竞态
                let records = self.readRecords
                var srcs = finalSources
                for i in srcs.indices {
                    for j in srcs[i].articles.indices where !srcs[i].articles[j].isRead {
                        if records[srcs[i].articles[j].topic] != nil {
                            srcs[i].articles[j].isRead = true
                        }
                    }
                }
                var flat = finalAllArticles
                for k in flat.indices where !flat[k].article.isRead {
                    if records[flat[k].article.topic] != nil {
                        flat[k].article.isRead = true
                    }
                }

                self.sources = srcs
                self.allArticlesSortedForDisplay = flat
                print("新闻数据加载/刷新完成！(后台线程处理)")

                #if DEBUG
                if let newest = flat.first?.article.timestamp {
                    print(NewsLockRule.debugDescribe(timestamp: newest,
                                                    lockedDays: self.lockedDays,
                                                    serverDate: self.resourceManager?.serverDate))
                }
                #endif
            }
        }
    }

    // ========================================================================
    // MARK: - ★已读核心：同步、幂等、立即持久化
    // ========================================================================

    func article(withID id: UUID) -> Article? {
        for s in sources {
            if let a = s.articles.first(where: { $0.id == id }) { return a }
        }
        return nil
    }

    private func indexPathOfArticle(id: UUID) -> (Int, Int)? {
        for i in sources.indices {
            if let j = sources[i].articles.firstIndex(where: { $0.id == id }) { return (i, j) }
        }
        return nil
    }

    /// 唯一的状态写入口：以 topic 为稳定键，先落盘再同步内存（一次性替换，只发一次通知）
    private func applyReadState(_ targets: [ReadTarget], read: Bool) {
        guard !targets.isEmpty else { return }
        let topics = Set(targets.map { $0.topic })
        let ids = Set(targets.compactMap { $0.id })

        // 1. 持久化（同步、立即）
        var recordsChanged = false
        for t in topics {
            if read {
                if readRecords[t] == nil { readRecords[t] = Date(); recordsChanged = true }
            } else {
                if readRecords.removeValue(forKey: t) != nil { recordsChanged = true }
            }
        }
        if recordsChanged { saveReadRecords() }

        // 2. 清理暂存
        for id in ids { pendingReadTopics.removeValue(forKey: id) }
        if !read {
            let snap = pendingReadTopics
            for (k, v) in snap where topics.contains(v) { pendingReadTopics.removeValue(forKey: k) }
        }

        // 3. 同步内存（sources）
        var srcs = sources
        var srcChanged = false
        for i in srcs.indices {
            for j in srcs[i].articles.indices {
                let a = srcs[i].articles[j]
                guard topics.contains(a.topic) || ids.contains(a.id) else { continue }
                if a.isRead != read { srcs[i].articles[j].isRead = read; srcChanged = true }
            }
        }
        if srcChanged { sources = srcs }

        // 4. 同步内存（全部文章扁平列表）
        var flat = allArticlesSortedForDisplay
        var flatChanged = false
        for k in flat.indices {
            let a = flat[k].article
            guard topics.contains(a.topic) || ids.contains(a.id) else { continue }
            if a.isRead != read { flat[k].article.isRead = read; flatChanged = true }
        }
        if flatChanged { allArticlesSortedForDisplay = flat }

        badgeUpdater?(totalUnreadCount)
    }

    // MARK: 对外 API

    /// ★推荐：读完立刻落盘
    func markArticleAsRead(_ article: Article) {
        applyReadState([ReadTarget(id: article.id, topic: article.topic)], read: true)
    }

    func markAsRead(article: Article) { markArticleAsRead(article) }

    func markAsUnread(article: Article) {
        applyReadState([ReadTarget(id: article.id, topic: article.topic)], read: false)
    }

    func markAsRead(articleID: UUID) {
        if let a = article(withID: articleID) {
            markArticleAsRead(a)
        } else if let t = pendingReadTopics[articleID] {
            applyReadState([ReadTarget(id: articleID, topic: t)], read: true)
        }
    }

    func markAsUnread(articleID: UUID) {
        if let a = article(withID: articleID) {
            markAsUnread(article: a)
        } else if let t = pendingReadTopics[articleID] {
            applyReadState([ReadTarget(id: articleID, topic: t)], read: false)
        }
    }

    /// 批量（多选 / 撤销 / 以上以下全部已读）
    func markArticles(_ articles: [Article], asRead: Bool) {
        guard !articles.isEmpty else { return }
        applyReadState(articles.map { ReadTarget(id: $0.id, topic: $0.topic) }, read: asRead)
    }

    // MARK: 暂存（兼容保留）
    @discardableResult
    func stageArticleAsRead(_ article: Article) -> Bool {
        if readRecords[article.topic] != nil { return false }
        if pendingReadTopics[article.id] != nil { return false }
        pendingReadTopics[article.id] = article.topic
        return true
    }

    @discardableResult
    func stageArticleAsRead(articleID: UUID) -> Bool {
        guard let a = article(withID: articleID) else { return false }
        return stageArticleAsRead(a)
    }

    func isArticlePendingRead(articleID: UUID) -> Bool { pendingReadTopics[articleID] != nil }

    /// 把暂存的全部落盘（同步）
    func persistPendingReads() {
        guard !pendingReadTopics.isEmpty else { return }
        let snap = pendingReadTopics
        pendingReadTopics.removeAll()
        applyReadState(snap.map { ReadTarget(id: $0.key, topic: $0.value) }, read: true)
    }

    func commitPendingReads() { persistPendingReads() }
    func commitPendingReadsSilently() { persistPendingReads() }

    // MARK: 阅读会话（★核心修复点）
    func beginReading(_ article: Article) {
        readingArticleID = article.id
        readingArticleTopic = article.topic
        if !isReadingArticle { isReadingArticle = true }
    }

    /// 退出详情页：**先同步落盘，最后才解冻数据重建**
    func finishReading(markCurrentAsRead: Bool = true) {
        let id = readingArticleID
        let topic = readingArticleTopic
        readingArticleID = nil
        readingArticleTopic = nil

        if markCurrentAsRead, let topic = topic {
            applyReadState([ReadTarget(id: id, topic: topic)], read: true)
        }
        persistPendingReads()

        // ★ 必须放最后：这一行会触发被延后的 loadNews()
        isReadingArticle = false
    }

    /// 兜底：列表页出现 / 导航栈回退时调用，防 onDisappear 偶发不触发
    func finishReadingIfNeeded() {
        guard readingArticleID != nil || readingArticleTopic != nil
                || isReadingArticle || !pendingReadTopics.isEmpty else { return }
        finishReading(markCurrentAsRead: true)
    }

    // MARK: 已读判定
    func isEffectivelyRead(articleID: UUID) -> Bool {
        if isArticlePendingRead(articleID: articleID) { return true }
        if let a = article(withID: articleID) { return isArticleEffectivelyRead(a) }
        return false
    }

    func isArticleEffectivelyRead(_ article: Article) -> Bool {
        if pendingReadTopics[article.id] != nil { return true }
        if readRecords[article.topic] != nil { return true }
        return article.isRead
    }

    func syncReadStatusFromPersistence() {
        loadReadRecords()
        let topics = Set(readRecords.keys)
        guard !topics.isEmpty else { return }

        var srcs = sources
        var changed = false
        for i in srcs.indices {
            for j in srcs[i].articles.indices where !srcs[i].articles[j].isRead {
                if topics.contains(srcs[i].articles[j].topic) {
                    srcs[i].articles[j].isRead = true; changed = true
                }
            }
        }
        if changed { sources = srcs }

        var flat = allArticlesSortedForDisplay
        var fChanged = false
        for k in flat.indices where !flat[k].article.isRead {
            if topics.contains(flat[k].article.topic) {
                flat[k].article.isRead = true; fChanged = true
            }
        }
        if fChanged { allArticlesSortedForDisplay = flat }

        if changed || fChanged { print("状态同步：已把持久化的已读同步到内存。") }
    }

    // MARK: 批量操作
    func markAllAboveAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        guard let pivot = visibleArticles.firstIndex(where: { $0.id == articleID }), pivot > 0 else { return }
        markArticles(Array(visibleArticles[0..<pivot]), asRead: true)
    }

    func markAllBelowAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        guard let pivot = visibleArticles.firstIndex(where: { $0.id == articleID }),
              pivot < visibleArticles.count - 1 else { return }
        markArticles(Array(visibleArticles[(pivot + 1)...]), asRead: true)
    }

    func markAllAsReadInSource(_ sourceName: String?) {
        let targets: [Article]
        if let name = sourceName, let s = sources.first(where: { $0.name == name }) {
            targets = s.articles.filter { !$0.isRead }
        } else {
            targets = sources.flatMap { $0.articles }.filter { !$0.isRead }
        }
        markArticles(targets, asRead: true)
    }

    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }

    // MARK: - 下一篇
    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        let candidates: [(article: Article, sourceName: String)]
        if let name = sourceName {
            if let source = self.sources.first(where: { $0.name == name }) {
                candidates = source.articles.map { (article: $0, sourceName: name) }
            } else { return nil }
        } else {
            candidates = self.sources.flatMap { source in
                source.articles.map { (article: $0, sourceName: source.name) }
            }.sorted { item1, item2 in
                if item1.article.timestamp != item2.article.timestamp {
                    return item1.article.timestamp > item2.article.timestamp
                }
                let h1 = item1.article.hot ?? 0, h2 = item2.article.hot ?? 0
                if h1 != h2 { return h1 > h2 }
                let key1 = NewsViewModel.djb2Hash(item1.article.topic + item1.sourceName)
                let key2 = NewsViewModel.djb2Hash(item2.article.topic + item2.sourceName)
                return key1 < key2
            }
        }

        guard let currentIndex = candidates.firstIndex(where: { $0.article.id == id }) else { return nil }
        let subsequentItems = candidates.suffix(from: currentIndex + 1)
        return subsequentItems.first { item in
            let isRead = isArticleEffectivelyRead(item.article)
            let isLocked = !isLoggedInNow() && isTimestampLocked(timestamp: item.article.timestamp)
            return !isRead && !isLocked
        }
    }

    private func isLoggedInNow() -> Bool { return true }

    func getUnreadCountForDateGroup(timestamp: String, inSource sourceName: String?) -> Int {
        var count = 0
        if let name = sourceName {
            if let source = sources.first(where: { $0.name == name }) {
                count = source.articles.filter { $0.timestamp == timestamp }
                    .filter { !isArticleEffectivelyRead($0) }.count
            }
        } else {
            for source in sources {
                count += source.articles.filter { $0.timestamp == timestamp }
                    .filter { !isArticleEffectivelyRead($0) }.count
            }
        }
        return count
    }

    func getEffectiveUnreadCount(inSource sourceName: String?) -> Int {
        let articlesToScan: [Article]
        if let name = sourceName, let source = sources.first(where: { $0.name == name }) {
            articlesToScan = source.articles
        } else {
            articlesToScan = sources.flatMap { $0.articles }
        }
        return articlesToScan.filter { !isArticleEffectivelyRead($0) }.count
    }
}

// ============================================================================
// MARK: - 数据模型
// ============================================================================
struct NewsSource: Identifiable {
    // ★ 稳定 id：避免每次重建触发 List 全量 diff
    var id: String { sourceId }
    let sourceId: String
    let name: String
    let name_en: String
    var articles: [Article]
    var unreadCount: Int { articles.filter { !$0.isRead }.count }
}

struct Article: Identifiable, Codable, Hashable {
    var id = UUID()
    let topic: String
    let article: String
    let topic_eng: String?
    let article_eng: String?
    let images: [String]
    let source_id: String?
    let url: String?
    let hot: Int?
    var isRead: Bool = false
    var timestamp: String = ""
    /// ★ 稳定标识（source_id|timestamp|topic[#n]），不参与编解码
    var stableKey: String = ""

    enum CodingKeys: String, CodingKey {
        case topic, article, images, source_id, url, topic_eng, article_eng, hot
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Article, rhs: Article) -> Bool { lhs.id == rhs.id }

    /// 由字符串派生确定性 UUID（FNV-1a + djb2 各取 8 字节）
    static func stableUUID(from key: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 5381
        for b in key.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = ((h2 &<< 5) &+ h2) &+ UInt64(b)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i]     = UInt8(truncatingIfNeeded: h1 >> (8 * UInt64(i)))
            bytes[8 + i] = UInt8(truncatingIfNeeded: h2 >> (8 * UInt64(i)))
        }
        return bytes.withUnsafeBufferPointer { ptr in
            NSUUID(uuidBytes: ptr.baseAddress) as UUID
        }
    }
}

@MainActor
class AppBadgeManager: ObservableObject {

    func requestAuthorizationAsync() async {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
                Task { @MainActor in
                    print(granted ? "用户已授予角标权限。" : "用户未授予角标权限。")
                    continuation.resume()
                }
            }
        }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            DispatchQueue.main.async {
                print(granted ? "用户已授予角标权限。" : "用户未授予角标权限。")
            }
        }
    }

    func updateBadge(count: Int) {
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "updateBadgeCount") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        let badgeCount = max(0, count)
        UNUserNotificationCenter.current().setBadgeCount(badgeCount) { error in
            if let error = error {
                print("【角标更新失败】: \(error.localizedDescription)")
            }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }
}

extension Notification.Name {
    static let newsDataDidUpdate = Notification.Name("newsDataDidUpdate")
    static let newsConfigDidUpdate = Notification.Name("newsConfigDidUpdate")
}