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
                // ★ 恢复"允许提交阅读会话"的权限
                newsViewModel.noteAppBecameActive()
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
                // ★★★ 关键：进后台 **只把已确定的已读刷盘**，
                //     绝不把"正在阅读、尚未读完"的那一篇标记为已读。
                print("App entered background. Flush read records only (reading session preserved).")
                newsViewModel.noteAppLeftForeground()
                Task { @MainActor in
                    ImageLoader.clearCache()
                    print("App entered background. Image cache cleared to save memory.")
                }
            } else if newPhase == .inactive {
                newsViewModel.noteAppLeftForeground()
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

        .background(Color.clear.sheet(isPresented: $pointsCoordinator.showInviteSheet) { NewsInviteView() })
        .background(Color.clear.sheet(isPresented: $pointsCoordinator.showVideoInviteSheet) { VideoInviteView() })
        .background(Color.clear.sheet(isPresented: $authManager.showSubscriptionSheet) { SubscriptionView() })
        .background(Color.clear.sheet(isPresented: $anonPromo.showSheet) { AnonymousSubscribeView() })
        .background(Color.clear.sheet(isPresented: $notifManager.showPreAsk) { NotificationPreAskView() })

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
        .onAppear { Task { await resourceManager.refreshServerConfig(minInterval: 120) } }
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
// MARK: - NewsViewModel
// ★ 已读引擎重写：
//   1) 阅读会话（reading session）纯内存，永不落盘 → 杀进程 / 被系统回收都保持未读
//   2) 已读只由 4 类"显式用户动作"提交：返回列表 / 下一篇 / 音频跳下一篇 / 列表手动标记
//   3) 阅读期间不重写 sources 数组 → 详情页不会被 @Published 风暴刷成 PPT
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

    // MARK: 阅读会话（★纯内存，绝不持久化）
    private var readingArticleID: UUID?
    private var readingArticleTopic: String?
    /// 一旦阅读期间 App 离开前台，本次会话的提交权限就被吊销（回前台恢复）
    private var suspendedDuringReading = false
    /// 阅读期间累积的"内存同步"债务
    private var pendingMemorySync = false

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

    func refreshBadge() { badgeUpdater?(totalUnreadCount) }

    // MARK: - 生命周期钩子（App 层调用）
    /// 离开前台：只把"已确定的已读记录"刷到磁盘；吊销当前阅读会话的提交权限
    func noteAppLeftForeground() {
        if isReadingArticle || readingArticleTopic != nil {
            suspendedDuringReading = true
            print("⏸️ [阅读会话] App 离开前台，本篇保持未读（提交权限已吊销）。")
        }
        UserDefaults.standard.synchronize()   // 立刻刷盘，防止随后被杀导致已读丢失
    }

    func noteAppBecameActive() {
        suspendedDuringReading = false
    }

    // MARK: - 锁定逻辑
    func isTimestampLocked(timestamp: String) -> Bool {
        NewsLockRule.isLocked(timestamp: timestamp,
                              lockedDays: lockedDays,
                              serverDate: resourceManager?.serverDate)
    }

    func toggleTimestampExpansion(for sourceKey: String, timestamp: String) {
        var set = expandedTimestampsBySource[sourceKey, default: Set<String>()]
        if set.contains(timestamp) { set.remove(timestamp) } else { set.insert(timestamp) }
        expandedTimestampsBySource[sourceKey] = set
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
        let hasLegacy = UserDefaults.standard.object(forKey: SubscriptionManager.shared.oldSubscribedSourcesKey) != nil

        if subscribedIDs.isEmpty && !hasLegacy {
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
            var usedKeys = Set<String>()

            for url in newsJSONURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([String: [Article]].self, from: data) else { continue }

                for (_, articles) in decoded {
                    guard let first = articles.first, let sourceId = first.source_id else { continue }
                    if !subscribedIDs.contains(sourceId) { continue }

                    let timestamp = url.lastPathComponent
                        .replacingOccurrences(of: "onews_", with: "")
                        .replacingOccurrences(of: ".json", with: "")

                    let withTs = articles.map { article -> Article in
                        var m = article
                        m.timestamp = timestamp
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
                    allArticlesBySourceID[sourceId, default: []].append(contentsOf: withTs)
                }
            }

            var tempSources = allArticlesBySourceID.map { sourceId, articles -> NewsSource in
                let raw = currentMappings[sourceId] ?? sourceId
                let parts = raw.components(separatedBy: "|")
                let cnName = parts.first ?? raw
                let enName = parts.count > 1 ? parts[1] : cnName

                let sorted = articles.sorted {
                    if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                    let h1 = $0.hot ?? 0, h2 = $1.hot ?? 0
                    if h1 != h2 { return h1 > h2 }
                    return $0.topic < $1.topic
                }
                return NewsSource(sourceId: sourceId, name: cnName, name_en: enName, articles: sorted)
            }
            .sorted { s1, s2 in
                let i1 = preferredOrder.firstIndex(of: s1.sourceId) ?? Int.max
                let i2 = preferredOrder.firstIndex(of: s2.sourceId) ?? Int.max
                if i1 != i2 { return i1 < i2 }
                return s1.name < s2.name
            }

            for i in tempSources.indices {
                for j in tempSources[i].articles.indices {
                    if readRecordsCopy.keys.contains(tempSources[i].articles[j].topic) {
                        tempSources[i].articles[j].isRead = true
                    }
                }
            }

            let finalSources = tempSources
            let flatList = finalSources.flatMap { source in
                source.articles.map { (article: $0, sourceName: source.name, sourceNameEN: source.name_en) }
            }
            let finalAll = flatList.sorted { i1, i2 in
                if i1.article.timestamp != i2.article.timestamp {
                    return i1.article.timestamp > i2.article.timestamp
                }
                let h1 = i1.article.hot ?? 0, h2 = i2.article.hot ?? 0
                if h1 != h2 { return h1 > h2 }
                let k1 = NewsViewModel.djb2Hash(i1.article.topic + i1.sourceName)
                let k2 = NewsViewModel.djb2Hash(i2.article.topic + i2.sourceName)
                return k1 < k2
            }

            await MainActor.run {
                NewsLockRule.noteNewestLocalArticleDate(finalAll.first?.article.timestamp)

                if self.isReadingArticle {
                    self.pendingReload = true
                    return
                }

                let records = self.readRecords
                var srcs = finalSources
                for i in srcs.indices {
                    for j in srcs[i].articles.indices where !srcs[i].articles[j].isRead {
                        if records[srcs[i].articles[j].topic] != nil { srcs[i].articles[j].isRead = true }
                    }
                }
                var flat = finalAll
                for k in flat.indices where !flat[k].article.isRead {
                    if records[flat[k].article.topic] != nil { flat[k].article.isRead = true }
                }

                self.sources = srcs
                self.allArticlesSortedForDisplay = flat
                self.refreshBadge()
                print("新闻数据加载/刷新完成！(后台线程处理)")
            }
        }
    }

    // ========================================================================
    // MARK: - 已读核心
    // ========================================================================

    func article(withID id: UUID) -> Article? {
        for s in sources {
            if let a = s.articles.first(where: { $0.id == id }) { return a }
        }
        return nil
    }

    /// 唯一的状态写入口：**先落盘**（durability），内存同步可延后（performance）
    private func applyReadState(_ targets: [ReadTarget], read: Bool) {
        guard !targets.isEmpty else { return }
        let topics = Set(targets.map { $0.topic })

        var changed = false
        for t in topics {
            if read {
                if readRecords[t] == nil { readRecords[t] = Date(); changed = true }
            } else {
                if readRecords.removeValue(forKey: t) != nil { changed = true }
            }
        }
        if changed { saveReadRecords() }

        if isReadingArticle {
            // ★ 阅读详情页期间不重写 sources / flat 数组：
            //   避免 @Published 广播导致详情页整棵重排（这是"点下一篇卡一下"的根因）。
            //   UI 正确性由 isArticleEffectivelyRead(readRecords) 保证。
            pendingMemorySync = true
            return
        }
        refreshMemoryFromRecords()
    }

    /// 以 readRecords 为唯一真相，把内存数组同步一次（双向）
    private func refreshMemoryFromRecords() {
        pendingMemorySync = false
        let records = readRecords

        var srcs = sources
        var changed = false
        for i in srcs.indices {
            for j in srcs[i].articles.indices {
                let want = records[srcs[i].articles[j].topic] != nil
                if srcs[i].articles[j].isRead != want {
                    srcs[i].articles[j].isRead = want; changed = true
                }
            }
        }
        if changed { sources = srcs }

        var flat = allArticlesSortedForDisplay
        var fChanged = false
        for k in flat.indices {
            let want = records[flat[k].article.topic] != nil
            if flat[k].article.isRead != want {
                flat[k].article.isRead = want; fChanged = true
            }
        }
        if fChanged { allArticlesSortedForDisplay = flat }

        refreshBadge()
    }

    // MARK: 对外 API
    func markArticleAsRead(_ article: Article) {
        applyReadState([ReadTarget(id: article.id, topic: article.topic)], read: true)
    }
    func markAsRead(article: Article) { markArticleAsRead(article) }
    func markAsUnread(article: Article) {
        applyReadState([ReadTarget(id: article.id, topic: article.topic)], read: false)
    }
    func markAsRead(articleID: UUID) {
        if let a = article(withID: articleID) { markArticleAsRead(a) }
    }
    func markAsUnread(articleID: UUID) {
        if let a = article(withID: articleID) { markAsUnread(article: a) }
    }
    func markArticles(_ articles: [Article], asRead: Bool) {
        guard !articles.isEmpty else { return }
        applyReadState(articles.map { ReadTarget(id: $0.id, topic: $0.topic) }, read: asRead)
    }

    // MARK: 遗留"暂存"接口 —— ★已废弃为 no-op
    // 之所以保留签名：避免其它文件编译失败。
    // 之所以改成 no-op：任何"进详情页就暂存已读"的旧路径都必须被彻底掐死，
    // 否则杀进程时 commitPendingReads 会把没读完的文章写成已读。
    @discardableResult
    func stageArticleAsRead(_ article: Article) -> Bool { false }
    @discardableResult
    func stageArticleAsRead(articleID: UUID) -> Bool { false }
    func isArticlePendingRead(articleID: UUID) -> Bool { false }
    func persistPendingReads() { UserDefaults.standard.synchronize() }
    func commitPendingReads() { persistPendingReads() }
    func commitPendingReadsSilently() { persistPendingReads() }

    // MARK: 阅读会话
    func beginReading(_ article: Article) {
        readingArticleID = article.id
        readingArticleTopic = article.topic
        suspendedDuringReading = false
        if !isReadingArticle { isReadingArticle = true }
    }

    /// 退出详情页（用户真的返回 / 明确读完）：先落盘 → 再同步内存 → 最后解冻数据重建
    func finishReading(markCurrentAsRead: Bool = true) {
        let topic = readingArticleTopic
        let id = readingArticleID
        readingArticleID = nil
        readingArticleTopic = nil

        // ★ 若阅读期间进过后台（可能已被系统回收再恢复），本次不允许自动标记已读
        let allowCommit = markCurrentAsRead && !suspendedDuringReading
        if !allowCommit && markCurrentAsRead {
            print("🚫 [阅读会话] 曾离开前台，跳过自动标记已读，保持未读。")
        }

        if allowCommit, let topic = topic {
            // 此时 isReadingArticle 仍为 true → 只落盘，内存同步在下面统一做
            applyReadState([ReadTarget(id: id, topic: topic)], read: true)
        }

        if pendingMemorySync { refreshMemoryFromRecords() }
        UserDefaults.standard.synchronize()

        suspendedDuringReading = false
        isReadingArticle = false      // 必须最后：这一行会触发被延后的 loadNews()
    }

    /// 兜底：列表页出现 / 导航栈回退时调用
    func finishReadingIfNeeded() {
        guard readingArticleID != nil || readingArticleTopic != nil
                || isReadingArticle || pendingMemorySync else { return }
        finishReading(markCurrentAsRead: true)
    }

    // MARK: 已读判定
    func isEffectivelyRead(articleID: UUID) -> Bool {
        if let a = article(withID: articleID) { return isArticleEffectivelyRead(a) }
        return false
    }

    func isArticleEffectivelyRead(_ article: Article) -> Bool {
        if readRecords[article.topic] != nil { return true }
        return article.isRead
    }

    func syncReadStatusFromPersistence() {
        loadReadRecords()
        refreshMemoryFromRecords()
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
            targets = s.articles.filter { !isArticleEffectivelyRead($0) }
        } else {
            targets = sources.flatMap { $0.articles }.filter { !isArticleEffectivelyRead($0) }
        }
        markArticles(targets, asRead: true)
    }

    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !isArticleEffectivelyRead($0) }.count
    }

    // MARK: - 下一篇（★不再每次全量排序）
    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        if let name = sourceName {
            guard let source = sources.first(where: { $0.name == name }),
                  let idx = source.articles.firstIndex(where: { $0.id == id }) else { return nil }
            for a in source.articles[(idx + 1)...] where isSelectableNext(a) {
                return (a, name)
            }
            return nil
        } else {
            // ★ 直接复用已排好序的缓存列表，避免 flatMap + sorted 的主线程尖峰
            let list = allArticlesSortedForDisplay
            guard let idx = list.firstIndex(where: { $0.article.id == id }) else { return nil }
            for item in list[(idx + 1)...] where isSelectableNext(item.article) {
                return (item.article, item.sourceName)
            }
            return nil
        }
    }

    private func isSelectableNext(_ a: Article) -> Bool {
        if isArticleEffectivelyRead(a) { return false }
        if !isLoggedInNow() && isTimestampLocked(timestamp: a.timestamp) { return false }
        return true
    }

    private func isLoggedInNow() -> Bool { return true }

    func getUnreadCountForDateGroup(timestamp: String, inSource sourceName: String?) -> Int {
        var count = 0
        if let name = sourceName {
            if let source = sources.first(where: { $0.name == name }) {
                count = source.articles.lazy
                    .filter { $0.timestamp == timestamp && !self.isArticleEffectivelyRead($0) }.count
            }
        } else {
            for source in sources {
                count += source.articles.lazy
                    .filter { $0.timestamp == timestamp && !self.isArticleEffectivelyRead($0) }.count
            }
        }
        return count
    }

    func getEffectiveUnreadCount(inSource sourceName: String?) -> Int {
        if let name = sourceName, let source = sources.first(where: { $0.name == name }) {
            return source.articles.lazy.filter { !self.isArticleEffectivelyRead($0) }.count
        }
        return sources.reduce(0) { acc, s in
            acc + s.articles.lazy.filter { !self.isArticleEffectivelyRead($0) }.count
        }
    }
}

// ============================================================================
// MARK: - 数据模型
// ============================================================================
struct NewsSource: Identifiable {
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
    var stableKey: String = ""

    enum CodingKeys: String, CodingKey {
        case topic, article, images, source_id, url, topic_eng, article_eng, hot
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Article, rhs: Article) -> Bool { lhs.id == rhs.id }

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
        return bytes.withUnsafeBufferPointer { ptr in NSUUID(uuidBytes: ptr.baseAddress) as UUID }
    }
}

@MainActor
class AppBadgeManager: ObservableObject {
    func requestAuthorizationAsync() async {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, _ in
                Task { @MainActor in
                    print(granted ? "用户已授予角标权限。" : "用户未授予角标权限。")
                    continuation.resume()
                }
            }
        }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, _ in
            DispatchQueue.main.async {
                print(granted ? "用户已授予角标权限。" : "用户未授予角标权限。")
            }
        }
    }

    func updateBadge(count: Int) {
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "updateBadgeCount") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
            }
        }
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { error in
            if let error = error { print("【角标更新失败】: \(error.localizedDescription)") }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
            }
        }
    }
}

extension Notification.Name {
    static let newsDataDidUpdate = Notification.Name("newsDataDidUpdate")
    static let newsConfigDidUpdate = Notification.Name("newsConfigDidUpdate")
}