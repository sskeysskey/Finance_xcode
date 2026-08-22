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
    let authManager = AuthManager.shared   // ✅

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

        // 【需求3 修改】不再在启动时请求通知权限（避免用户一上来就点"不允许"）。
        // 只查询当前授权状态，真正的请求交给 NotificationPermissionManager 在"成功时刻"发起。
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

                // ★★★【需求1】回前台：静默刷新新闻 + 视频（无任何弹窗/遮罩）★★★
                Task {
                    await NotificationPermissionManager.shared.refreshStatus()
                    // 新闻：拉 version.json + 增量下载 JSON（有变更才会触发 UI 刷新）
                    await resourceManager.silentRefresh(minInterval: 30, reason: "foreground")
                    // 视频：刷新当前选中分类的第一页 + 分类名
                    await videoDataManager.silentRefreshCurrentSelection(
                        userId: authManager.userIdentifier, minInterval: 30)
                }

            } else if newPhase == .background {
                print("App entered background. Committing pending reads silently.")
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

    // 【需求2】首启不再主动弹登录窗，相关触发逻辑已整体移除。
    // 登录引导只在用户"点击受限新闻/视频"时由 NewsPointsCoordinator 触发。

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

            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .sheet(isPresented: $notifManager.showPreAsk) { NotificationPreAskView() }
        }
        .animation(.easeInOut, value: resourceManager.showForceUpdate)
        .animation(.easeInOut, value: resourceManager.showMigrationSheet)
        .sheet(isPresented: $pointsCoordinator.showInviteSheet) { NewsInviteView() }
        .sheet(isPresented: $pointsCoordinator.showLoginSheet) { LoginView() }
        .sheet(isPresented: $pointsCoordinator.showSubscriptionSheet) { SubscriptionView() }
        .sheet(isPresented: $pointsCoordinator.showVideoInviteSheet) { VideoInviteView() }
        // 【需求3】通知授权预弹窗（Soft-Ask）
        .sheet(isPresented: $notifManager.showPreAsk) { NotificationPreAskView() }
        .onReceive(NotificationCenter.default.publisher(for: .notificationPermissionGranted)) { _ in
            // 拿到权限后立刻把角标补上
            newsViewModel.refreshBadge()
        }
        .onAppear {
            syncGlobalBlock()
            // 【需求2】此处原来的 triggerInviteIfNeeded(...) 已删除
        }
        .onChange(of: hasCompletedInitialSetup) { _ in
            syncGlobalBlock()
            // 【需求2】此处原来的 triggerInviteIfNeeded(...) 已删除
        }
        .onChange(of: resourceManager.showForceUpdate) { _ in syncGlobalBlock() }
        .onChange(of: resourceManager.showMigrationSheet) { _ in syncGlobalBlock() }
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
        // ★【需求1】视频首页只拉 version.json（省流量），不下载新闻 JSON
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

struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String?
    let sourceNameEN: String?
    let isReadEffective: Bool
    let isContentMatch: Bool
    let isLocked: Bool
    let showEnglish: Bool

    init(article: Article, sourceName: String?, sourceNameEN: String? = nil, isReadEffective: Bool,
         isContentMatch: Bool = false, isLocked: Bool = false, showEnglish: Bool = false) {
        self.article = article
        self.sourceName = sourceName
        self.sourceNameEN = sourceNameEN
        self.isReadEffective = isReadEffective
        self.isContentMatch = isContentMatch
        self.isLocked = isLocked
        self.showEnglish = showEnglish
    }

    var displayTopic: String {
        if showEnglish, let engTitle = article.topic_eng, !engTitle.isEmpty { return engTitle }
        return article.topic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let name = sourceName {
                    let finalName = (showEnglish && sourceNameEN != nil && !sourceNameEN!.isEmpty) ? sourceNameEN! : name
                    Text(finalName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 11, weight: .bold, design: .default))
                        .tracking(0.5)
                        .foregroundColor(isReadEffective ? .secondary.opacity(0.7) : .blue.opacity(0.8))
                        .animation(.none, value: showEnglish)
                }
                Spacer()
                if isLocked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 14))
                        Text(Localized.needSubscription).font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
                }
            }

            HStack(alignment: .top) {
                Text(displayTopic)
                    .font(.system(size: 19, weight: isReadEffective ? .regular : .bold, design: .serif))
                    .foregroundColor(isReadEffective ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .opacity(isReadEffective ? 0.8 : 1.0)
                    .animation(.none, value: showEnglish)
                Spacer(minLength: 0)
            }

            if isContentMatch {
                HStack {
                    Label(Localized.contentMatch, systemImage: "text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color.black.opacity(isReadEffective ? 0.02 : 0.06), radius: 8, x: 0, y: 4)
        )
        .opacity(isLocked ? 0.7 : 1.0)
    }
}

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

    private var pendingReadArticleIDs: Set<UUID> = []
    private var lastSilentCommittedIDs: Set<UUID> = []

    // ★★★【需求1 关键】阅读详情页期间禁止重建 sources（因为 Article.id 是解码时新建的 UUID，
    // 一旦重建，详情页的 currentArticle.id 会在新数组里找不到 → 点"下一篇"直接失效）★★★
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

        // 数据下载完成 → 若正在阅读则延后落地
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

        // 【新增】只更新配置（锁天数等），不重建列表，成本极低
        NotificationCenter.default.publisher(for: .newsConfigDidUpdate)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let d = self.resourceManager?.serverLockedDays ?? 0
                if self.lockedDays != d { self.lockedDays = d }
            }
            .store(in: &cancellables)
    }

    /// 【新增】拿到通知权限后主动补角标
    func refreshBadge() {
        badgeUpdater?(totalUnreadCount)
    }

    // MARK: - 锁定逻辑（★需求2 修复：统一走 NewsLockRule，全程 UTC 日历）
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

    func loadNews() {
        // 双保险：阅读详情页时绝不重建（避免 id 失效）
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

            for url in newsJSONURLs {
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
                        var mutableArticle = article
                        mutableArticle.timestamp = timestamp
                        return mutableArticle
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
                // ★★★【需求2】把"本地已下载新闻的最新一天"存下来，作为锁定判定的设备无关基准，
                // 彻底消除 iPad/iPhone 时区差异 & server_date 缓存过期导致的误锁。
                NewsLockRule.noteNewestLocalArticleDate(finalAllArticles.first?.article.timestamp)

                // 再次确认：万一刚好进了详情页，就放弃这次替换，交给退出时重来
                if self.isReadingArticle {
                    self.pendingReload = true
                    return
                }
                self.sources = finalSources
                self.allArticlesSortedForDisplay = finalAllArticles
                print("新闻数据加载/刷新完成！(后台线程处理)")

                #if DEBUG
                if let newest = finalAllArticles.first?.article.timestamp {
                    print(NewsLockRule.debugDescribe(timestamp: newest,
                                                    lockedDays: self.lockedDays,
                                                    serverDate: self.resourceManager?.serverDate))
                }
                #endif
            }
        }
    }

    // MARK: - 暂存与提交逻辑
    func stageArticleAsRead(articleID: UUID) -> Bool {
        if let article = sources.flatMap({ $0.articles }).first(where: { $0.id == articleID }), article.isRead {
            return false
        }
        if pendingReadArticleIDs.contains(articleID) { return false }
        pendingReadArticleIDs.insert(articleID)
        return true
    }

    func isArticlePendingRead(articleID: UUID) -> Bool { pendingReadArticleIDs.contains(articleID) }

    func isEffectivelyRead(articleID: UUID) -> Bool {
        if isArticlePendingRead(articleID: articleID) { return true }
        if let (i, j) = indexPathOfArticle(id: articleID) { return sources[i].articles[j].isRead }
        return false
    }

    func isArticleEffectivelyRead(_ article: Article) -> Bool {
        if isArticlePendingRead(articleID: article.id) { return true }
        if readRecords[article.topic] != nil { return true }
        return article.isRead
    }

    func commitPendingReads() {
        var idsToCommit = pendingReadArticleIDs
        pendingReadArticleIDs.removeAll()
        if !lastSilentCommittedIDs.isEmpty {
            idsToCommit.formUnion(lastSilentCommittedIDs)
            lastSilentCommittedIDs.removeAll()
        }
        guard !idsToCommit.isEmpty else { return }
        DispatchQueue.main.async {
            for articleID in idsToCommit { self.markAsRead(articleID: articleID) }
            print("【完整提交】完成。")
        }
    }

    func commitPendingReadsSilently() {
        let idsToCommit = pendingReadArticleIDs
        if !idsToCommit.isEmpty {
            lastSilentCommittedIDs.formUnion(idsToCommit)
            pendingReadArticleIDs.removeAll()
            for articleID in idsToCommit {
                if let (sourceIndex, articleIndex) = indexPathOfArticle(id: articleID) {
                    let topic = sources[sourceIndex].articles[articleIndex].topic
                    if readRecords[topic] == nil { readRecords[topic] = Date() }
                }
            }
            saveReadRecords()
        }
        let currentUnreadCount = calculateUnreadCountAfterSilentCommit()
        DispatchQueue.main.async { [weak self] in self?.badgeUpdater?(currentUnreadCount) }
    }

    func syncReadStatusFromPersistence() {
        DispatchQueue.main.async {
            var didChange = false
            for i in self.sources.indices {
                for j in self.sources[i].articles.indices {
                    let article = self.sources[i].articles[j]
                    if !article.isRead && self.readRecords.keys.contains(article.topic) {
                        self.sources[i].articles[j].isRead = true
                        didChange = true
                    }
                }
            }
            if didChange { print("状态同步：已将持久化的已读状态同步到内存中的 `sources`。") }
        }
    }

    private func calculateUnreadCountAfterSilentCommit() -> Int {
        var count = 0
        for source in sources {
            for article in source.articles where readRecords[article.topic] == nil { count += 1 }
        }
        return count
    }

    private func indexPathOfArticle(id: UUID) -> (Int, Int)? {
        for i in sources.indices {
            if let j = sources[i].articles.firstIndex(where: { $0.id == id }) { return (i, j) }
        }
        return nil
    }

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
            for article in visibleArticles[0..<pivotIndex] where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }

    func markAllBelowAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        DispatchQueue.main.async {
            guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
            guard pivotIndex < visibleArticles.count - 1 else { return }
            for article in visibleArticles[(pivotIndex + 1)...] where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }

    func markAllAsReadInSource(_ sourceName: String?) {
        var changed = false
        if let name = sourceName {
            if let sourceIndex = sources.firstIndex(where: { $0.name == name }) {
                for j in sources[sourceIndex].articles.indices where !sources[sourceIndex].articles[j].isRead {
                    sources[sourceIndex].articles[j].isRead = true
                    readRecords[sources[sourceIndex].articles[j].topic] = Date()
                    changed = true
                }
            }
        } else {
            for i in sources.indices {
                for j in sources[i].articles.indices where !sources[i].articles[j].isRead {
                    sources[i].articles[j].isRead = true
                    readRecords[sources[i].articles[j].topic] = Date()
                    changed = true
                }
            }
        }
        if changed { saveReadRecords() }
    }

    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }

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
        let nextUnreadItem = subsequentItems.first { item in
            let isRead = isArticleEffectivelyRead(item.article)
            let isLocked = !isLoggedInNow() && isTimestampLocked(timestamp: item.article.timestamp)
            return !isRead && !isLocked
        }
        return nextUnreadItem
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

struct NewsSource: Identifiable {
    let id = UUID()
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

    enum CodingKeys: String, CodingKey {
        case topic, article, images, source_id, url, topic_eng, article_eng, hot
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Article, rhs: Article) -> Bool { lhs.id == rhs.id }
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
            } else {
                print("【角标更新成功】应用角标已设置为: \(badgeCount)")
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
    // 【新增】仅配置更新（lockedDays / 开关 / 通知），不重建列表
    static let newsConfigDidUpdate = Notification.Name("newsConfigDidUpdate")
}