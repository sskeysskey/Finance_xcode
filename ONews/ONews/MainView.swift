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

    // ★ 前台刷新节流：只有"从后台回来"或"距上次超过阈值"才做重量级刷新
    var cameFromBackground = true
    var lastForegroundRefreshAt: Date = .distantPast
    static let foregroundRefreshMinInterval: TimeInterval = 20

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
        .onChange(of: scenePhase) { _, newPhase in
            let newsViewModel = appDelegate.newsViewModel
            let authManager = appDelegate.authManager
            let resourceManager = appDelegate.resourceManager
            let videoDataManager = appDelegate.videoDataManager

            if newPhase == .active {
                print("App is active. Syncing status...")
                // ★ 恢复"允许提交阅读会话"的权限
                newsViewModel.noteAppBecameActive()
                newsViewModel.syncReadStatusFromPersistence()   // ★ 内部已做"无变化跳过"
                authManager.handleAppDidBecomeActive()

                // ★ 重量级刷新节流：控制中心/通知横幅导致的 inactive→active 不重复打网络
                let now = Date()
                let shouldHeavyRefresh = appDelegate.cameFromBackground
                    || now.timeIntervalSince(appDelegate.lastForegroundRefreshAt)
                        > AppDelegate.foregroundRefreshMinInterval
                appDelegate.cameFromBackground = false

                if shouldHeavyRefresh {
                    appDelegate.lastForegroundRefreshAt = now
                    // ★ 三者互不依赖 → 并行
                    Task {
                        await FreeQuotaManager.shared.refresh(
                            userId: FreeQuotaManager.currentUserId(auth: authManager))
                    }
                    Task {
                        await NewsQuotaManager.shared.refresh(
                            userId: NewsQuotaManager.currentUserId(auth: authManager))
                    }
                    Task { await SeriesTrackManager.shared.refresh(force: true) }
                }

                // 通知权限状态每次都刷新（系统权限弹窗关闭后正是 inactive→active）
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
                appDelegate.cameFromBackground = true
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
    // ★ 已移除 @EnvironmentObject newsViewModel：
    //   根视图只用它刷新角标，却会因 sources 的每次变化整棵重算。
    //   角标刷新已移到 NewsViewModel 内部监听 .notificationPermissionGranted。
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

        .onChange(of: pointsCoordinator.showSubscriptionSheet) { _, show in
            guard show, PurchaseFlowManager.useDirectPurchase else { return }
            pointsCoordinator.showSubscriptionSheet = false
            PurchaseFlowManager.shared.startPurchase(auth: authManager, reason: "points-coordinator")
        }
        .onAppear { syncGlobalBlock() }
        .onChange(of: hasCompletedInitialSetup) { syncGlobalBlock() }
        .onChange(of: resourceManager.showForceUpdate) { syncGlobalBlock() }
        .onChange(of: resourceManager.showMigrationSheet) { syncGlobalBlock() }
        .onChange(of: authManager.isSubscribed) { _, subscribed in
            if subscribed { AnonymousSubscribePromptManager.shared.markPurchased() }
        }
        .onChange(of: authManager.isLoggedIn) { _, newVal in
            if newVal {
                Task {
                    await FreeQuotaManager.shared.refresh(
                        userId: FreeQuotaManager.currentUserId(auth: authManager))
                }
                Task {
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
// MARK: - 加载辅助类型（文件级，不继承 MainActor 隔离，可在后台安全使用）
// ============================================================================
fileprivate struct NewsArticleLocation {
    let source: Int
    let article: Int
}

fileprivate struct NewsSnapshot {
    let sources: [NewsSource]
    let flat: [(article: Article, sourceName: String, sourceNameEN: String)]
    let locationByID: [UUID: NewsArticleLocation]
    let sourceIndexByName: [String: Int]
    let flatIndexByID: [UUID: Int]
}

fileprivate struct NewsFileStamp: Equatable {
    let modified: Date
    let size: Int
}

/// ★ JSON 解码缓存：按 文件名 + 修改时间 + 大小 命中，文件没变就不再解析
fileprivate actor NewsFileCache {
    static let shared = NewsFileCache()
    private var entries: [String: (stamp: NewsFileStamp, payload: [String: [Article]])] = [:]

    func payload(for name: String, stamp: NewsFileStamp) -> [String: [Article]]? {
        guard let e = entries[name], e.stamp == stamp else { return nil }
        return e.payload
    }

    func store(_ payload: [String: [Article]], for name: String, stamp: NewsFileStamp) {
        entries[name] = (stamp, payload)
    }

    /// 已被删除的文件从缓存中剔除
    func retainOnly(_ names: Set<String>) {
        if entries.keys.contains(where: { !names.contains($0) }) {
            entries = entries.filter { names.contains($0.key) }
        }
    }

    func removeAll() { entries.removeAll() }
}

// ============================================================================
// MARK: - NewsViewModel
// ★ 已读引擎：
//   1) 阅读会话（reading session）纯内存，永不落盘 → 杀进程 / 被系统回收都保持未读
//   2) 已读只由 4 类"显式用户动作"提交：返回列表 / 下一篇 / 音频跳下一篇 / 列表手动标记
//   3) 阅读期间不重写 sources 数组 → 详情页不会被 @Published 风暴刷成 PPT
// ★ 性能层：
//   4) 未读计数按 (dataVersion, readVersion) 缓存，O(1) 读取
//   5) UUID → 位置索引，查找 / 下一篇 O(1)
//   6) JSON 解码缓存 + 并行解码 + 过期加载丢弃
// ============================================================================
@MainActor
class NewsViewModel: ObservableObject {
    nonisolated static let preferredSourceOrder: [String] = [
        "ft", "wsjcn", "nytimes", "bloomberg", "rfi", "nikkei", "dw",
        "wsj", "economist", "reuters", "washpost", "mittr", "bbc",
    ]

    @Published var sources: [NewsSource] = [] {
        didSet { dataVersion &+= 1 }
    }
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

    // MARK: 版本号（驱动缓存失效）
    private var dataVersion = 0
    private var readVersion = 0

    // MARK: 未读计数缓存
    private var unreadCacheDataVersion = -1
    private var unreadCacheReadVersion = -1
    private var unreadTotalCache = 0
    private var unreadBySource: [Int] = []
    private var unreadBySourceDate: [[String: Int]] = []
    private var unreadByDateAll: [String: Int] = [:]

    // MARK: 查找索引（加载时后台构建；使用时校验，失配则回退线性查找）
    private var locationByID: [UUID: NewsArticleLocation] = [:]
    private var sourceIndexByName: [String: Int] = [:]
    private var flatIndexByID: [UUID: Int] = [:]

    // MARK: 加载控制
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var hasLoadedOnce = false

    // MARK: 角标去重
    private var lastBadgeCount: Int?

    // MARK: 已读记录清理
    private var didPruneThisSession = false
    private static let pruneThreshold = 3000
    private static let pruneMaxAge: TimeInterval = 90 * 24 * 3600

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
            .receive(on: DispatchQueue.main)
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let d = self.resourceManager?.serverLockedDays ?? 0
                if self.lockedDays != d { self.lockedDays = d }
            }
            .store(in: &cancellables)

        // ★ 原先在 MainAppView 里监听，导致根视图订阅整个 ViewModel；现移到这里
        NotificationCenter.default.publisher(for: .notificationPermissionGranted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)

        // ★ 内存警告：释放 JSON 解码缓存
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { _ in Task { await NewsFileCache.shared.removeAll() } }
            .store(in: &cancellables)
    }

    // MARK: - 角标
    /// 强制刷新（外部调用 / 权限刚授予）
    func refreshBadge() {
        guard hasLoadedOnce else { return }   // 数据未就绪前不写角标，避免闪成 0
        let c = totalUnreadCount
        lastBadgeCount = c
        badgeUpdater?(c)
    }

    /// 内部使用：数值不变则不打系统 API
    private func updateBadgeIfChanged() {
        guard hasLoadedOnce else { return }
        let c = totalUnreadCount
        guard c != lastBadgeCount else { return }
        lastBadgeCount = c
        badgeUpdater?(c)
    }

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
        readVersion &+= 1
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }

    private func clearIndexes() {
        locationByID = [:]
        sourceIndexByName = [:]
        flatIndexByID = [:]
    }

    // MARK: - 数据加载
    func loadNews() {
        if isReadingArticle {
            pendingReload = true
            return
        }

        let d = resourceManager?.serverLockedDays ?? 0
        if lockedDays != d { lockedDays = d }

        let currentMappings = resourceManager?.sourceMappings ?? [:]
        let subscribedIDs = SubscriptionManager.shared.subscribedSourceIDs
        let hasLegacy = UserDefaults.standard.object(forKey: SubscriptionManager.shared.oldSubscribedSourcesKey) != nil

        if subscribedIDs.isEmpty && !hasLegacy {
            loadTask?.cancel()
            loadGeneration &+= 1
            clearIndexes()
            self.sources = []
            self.allArticlesSortedForDisplay = []
            hasLoadedOnce = true
            updateBadgeIfChanged()
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        let readVersionAtStart = readVersion
        let readRecordsCopy = self.readRecords
        let preferredOrder = Self.preferredSourceOrder
        let docDir = self.documentsDirectory

        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let snapshot = await NewsViewModel.buildSnapshot(
                docDir: docDir,
                subscribedIDs: Set(subscribedIDs),
                mappings: currentMappings,
                readRecords: readRecordsCopy,
                preferredOrder: preferredOrder
            ) else { return }
            guard !Task.isCancelled else { return }
            await self?.applySnapshot(snapshot, generation: generation, readVersionAtStart: readVersionAtStart)
        }
    }

    /// 后台构建：读目录 → 命中缓存 / 并行解码 → 组装 → 排序 → 建索引
    nonisolated private static func buildSnapshot(
        docDir: URL,
        subscribedIDs: Set<String>,
        mappings: [String: String],
        readRecords: [String: Date],
        preferredOrder: [String]
    ) async -> NewsSnapshot? {
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let allFileURLs = try? FileManager.default.contentsOfDirectory(
            at: docDir, includingPropertiesForKeys: resourceKeys) else { return nil }

        let newsJSONURLs = allFileURLs
            .filter { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !newsJSONURLs.isEmpty else { return nil }

        let cache = NewsFileCache.shared
        await cache.retainOnly(Set(newsJSONURLs.map { $0.lastPathComponent }))

        // 1) 查缓存
        var payloads: [String: [String: [Article]]] = [:]
        var misses: [(url: URL, stamp: NewsFileStamp?)] = []
        for url in newsJSONURLs {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            var stamp: NewsFileStamp?
            if let m = values?.contentModificationDate, let s = values?.fileSize {
                stamp = NewsFileStamp(modified: m, size: s)
            }
            if let stamp, let hit = await cache.payload(for: name, stamp: stamp) {
                payloads[name] = hit
            } else {
                misses.append((url, stamp))
            }
        }

        // 2) 未命中的并行解码
        if !misses.isEmpty {
            await withTaskGroup(of: (String, NewsFileStamp?, [String: [Article]]?).self) { group in
                for miss in misses {
                    let url = miss.url
                    let stamp = miss.stamp
                    group.addTask {
                        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                            return (url.lastPathComponent, stamp, nil)
                        }
                        let decoded = try? JSONDecoder().decode([String: [Article]].self, from: data)
                        return (url.lastPathComponent, stamp, decoded)
                    }
                }
                for await (name, stamp, decoded) in group {
                    guard let decoded else { continue }
                    payloads[name] = decoded
                    if let stamp { await cache.store(decoded, for: name, stamp: stamp) }
                }
            }
        }

        if Task.isCancelled { return nil }

        // 3) 组装（按文件名顺序 + 排序后的 key 遍历 → 稳定 ID 分配确定化）
        var allArticlesBySourceID = [String: [Article]]()
        var usedKeys = Set<String>()

        for url in newsJSONURLs {
            let name = url.lastPathComponent
            guard let decoded = payloads[name] else { continue }
            let timestamp = name
                .replacingOccurrences(of: "onews_", with: "")
                .replacingOccurrences(of: ".json", with: "")

            for groupKey in decoded.keys.sorted() {
                guard let articles = decoded[groupKey],
                      let first = articles.first,
                      let sourceId = first.source_id,
                      subscribedIDs.contains(sourceId) else { continue }

                var withTs: [Article] = []
                withTs.reserveCapacity(articles.count)
                for article in articles {
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
                    m.isRead = readRecords[article.topic] != nil
                    withTs.append(m)
                }
                allArticlesBySourceID[sourceId, default: []].append(contentsOf: withTs)
            }
        }

        if Task.isCancelled { return nil }

        // 4) 每源排序 + 源排序
        let tempSources = allArticlesBySourceID.map { sourceId, articles -> NewsSource in
            let raw = mappings[sourceId] ?? sourceId
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

        // 5) 扁平列表（★排序键预计算，避免比较器里反复拼串算哈希）
        struct FlatItem {
            let article: Article
            let sourceName: String
            let sourceNameEN: String
            let hot: Int
            let tie: UInt64
        }
        var items: [FlatItem] = []
        items.reserveCapacity(tempSources.reduce(0) { $0 + $1.articles.count })
        for s in tempSources {
            for a in s.articles {
                items.append(FlatItem(article: a,
                                      sourceName: s.name,
                                      sourceNameEN: s.name_en,
                                      hot: a.hot ?? 0,
                                      tie: djb2Hash(a.topic + s.name)))
            }
        }
        items.sort { i1, i2 in
            if i1.article.timestamp != i2.article.timestamp {
                return i1.article.timestamp > i2.article.timestamp
            }
            if i1.hot != i2.hot { return i1.hot > i2.hot }
            return i1.tie < i2.tie
        }
        let flat = items.map { (article: $0.article, sourceName: $0.sourceName, sourceNameEN: $0.sourceNameEN) }

        // 6) 索引（首次出现优先，与原 first(where:) 语义一致）
        var locationByID = [UUID: NewsArticleLocation]()
        var sourceIndexByName = [String: Int]()
        for (si, s) in tempSources.enumerated() {
            if sourceIndexByName[s.name] == nil { sourceIndexByName[s.name] = si }
            for (ai, a) in s.articles.enumerated() where locationByID[a.id] == nil {
                locationByID[a.id] = NewsArticleLocation(source: si, article: ai)
            }
        }
        var flatIndexByID = [UUID: Int]()
        flatIndexByID.reserveCapacity(flat.count)
        for (k, item) in flat.enumerated() where flatIndexByID[item.article.id] == nil {
            flatIndexByID[item.article.id] = k
        }

        return NewsSnapshot(sources: tempSources,
                            flat: flat,
                            locationByID: locationByID,
                            sourceIndexByName: sourceIndexByName,
                            flatIndexByID: flatIndexByID)
    }

    /// 主线程落地
    private func applySnapshot(_ snap: NewsSnapshot, generation: Int, readVersionAtStart: Int) {
        guard generation == loadGeneration else {
            print("⏭️ [加载] 丢弃过期结果 (gen \(generation) != \(loadGeneration))")
            return
        }

        NewsLockRule.noteNewestLocalArticleDate(snap.flat.first?.article.timestamp)

        if isReadingArticle {
            pendingReload = true
            return
        }

        var srcs = snap.sources
        var flat = snap.flat

        // 仅当加载期间已读记录发生过变化才重新套用（双向）
        if readVersion != readVersionAtStart {
            let records = readRecords
            for i in srcs.indices {
                for j in srcs[i].articles.indices {
                    let want = records[srcs[i].articles[j].topic] != nil
                    if srcs[i].articles[j].isRead != want { srcs[i].articles[j].isRead = want }
                }
            }
            for k in flat.indices {
                let want = records[flat[k].article.topic] != nil
                if flat[k].article.isRead != want { flat[k].article.isRead = want }
            }
        }

        locationByID = snap.locationByID
        sourceIndexByName = snap.sourceIndexByName
        flatIndexByID = snap.flatIndexByID

        self.sources = srcs
        self.allArticlesSortedForDisplay = flat
        pendingMemorySync = false
        hasLoadedOnce = true
        updateBadgeIfChanged()
        pruneReadRecordsIfNeeded()
        print("新闻数据加载/刷新完成！(后台线程处理)")
    }

    /// 已读记录瘦身：仅在记录过多时、每次启动最多一次；
    /// 只删"读过超过 90 天 且 当前本地数据中已不存在"的记录 → 对 UI 零影响
    private func pruneReadRecordsIfNeeded() {
        guard !didPruneThisSession, readRecords.count > Self.pruneThreshold else { return }
        didPruneThisSession = true

        var liveTopics = Set<String>()
        for s in sources { for a in s.articles { liveTopics.insert(a.topic) } }

        let cutoff = Date().addingTimeInterval(-Self.pruneMaxAge)
        let before = readRecords.count
        readRecords = readRecords.filter { topic, date in date >= cutoff || liveTopics.contains(topic) }
        let removed = before - readRecords.count
        if removed > 0 {
            saveReadRecords()
            readVersion &+= 1
            print("🧹 [已读记录] 清理 \(removed) 条过期记录，剩余 \(readRecords.count)。")
        }
    }

    // ========================================================================
    // MARK: - 查找
    // ========================================================================

    private func sourceIndex(named name: String) -> Int? {
        if let i = sourceIndexByName[name], i < sources.count, sources[i].name == name { return i }
        return sources.firstIndex { $0.name == name }
    }

    func article(withID id: UUID) -> Article? {
        if let loc = locationByID[id],
           loc.source < sources.count,
           loc.article < sources[loc.source].articles.count {
            let a = sources[loc.source].articles[loc.article]
            if a.id == id { return a }
        }
        for s in sources {
            if let a = s.articles.first(where: { $0.id == id }) { return a }
        }
        return nil
    }

    // ========================================================================
    // MARK: - 已读核心
    // ========================================================================

    /// 唯一的状态写入口：**先落盘**（durability），内存同步可延后（performance）
    private func applyReadState(_ targets: [ReadTarget], read: Bool) {
        guard !targets.isEmpty else { return }
        let topics = Set(targets.map { $0.topic })

        var changed = false
        let now = Date()
        for t in topics {
            if read {
                if readRecords[t] == nil { readRecords[t] = now; changed = true }
            } else {
                if readRecords.removeValue(forKey: t) != nil { changed = true }
            }
        }
        guard changed else { return }
        saveReadRecords()
        readVersion &+= 1

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

        updateBadgeIfChanged()
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

    /// 回前台时调用：持久化没变就什么都不做；阅读中只记债务，不重写数组
    func syncReadStatusFromPersistence() {
        let fresh = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
        let changed = fresh != readRecords
        if changed {
            readRecords = fresh
            readVersion &+= 1
        }
        guard changed || pendingMemorySync else { return }
        if isReadingArticle {
            pendingMemorySync = true
            return
        }
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
        if let name = sourceName, let i = sourceIndex(named: name) {
            targets = sources[i].articles.filter { !isArticleEffectivelyRead($0) }
        } else {
            targets = sources.flatMap { $0.articles }.filter { !isArticleEffectivelyRead($0) }
        }
        markArticles(targets, asRead: true)
    }

    // ========================================================================
    // MARK: - 未读计数（★缓存，O(1) 读取；数据或已读变化后首次访问时 O(N) 重建一次）
    // ========================================================================
    private func ensureUnreadCache() {
        if unreadCacheDataVersion == dataVersion && unreadCacheReadVersion == readVersion { return }

        let records = readRecords
        var total = 0
        var perSource = [Int](repeating: 0, count: sources.count)
        var perSourceDate = [[String: Int]](repeating: [:], count: sources.count)
        var perDateAll = [String: Int]()

        for (i, s) in sources.enumerated() {
            var c = 0
            var byDate = [String: Int]()
            for a in s.articles where !(records[a.topic] != nil || a.isRead) {
                c += 1
                byDate[a.timestamp, default: 0] += 1
            }
            perSource[i] = c
            perSourceDate[i] = byDate
            total += c
            for (ts, n) in byDate { perDateAll[ts, default: 0] += n }
        }

        unreadTotalCache = total
        unreadBySource = perSource
        unreadBySourceDate = perSourceDate
        unreadByDateAll = perDateAll
        unreadCacheDataVersion = dataVersion
        unreadCacheReadVersion = readVersion
    }

    var totalUnreadCount: Int {
        ensureUnreadCache()
        return unreadTotalCache
    }

    func getUnreadCountForDateGroup(timestamp: String, inSource sourceName: String?) -> Int {
        ensureUnreadCache()
        if let name = sourceName {
            guard let i = sourceIndex(named: name), i < unreadBySourceDate.count else { return 0 }
            return unreadBySourceDate[i][timestamp] ?? 0
        }
        return unreadByDateAll[timestamp] ?? 0
    }

    func getEffectiveUnreadCount(inSource sourceName: String?) -> Int {
        ensureUnreadCache()
        if let name = sourceName, let i = sourceIndex(named: name), i < unreadBySource.count {
            return unreadBySource[i]
        }
        return unreadTotalCache
    }

    // MARK: - 下一篇（★索引定位，O(1) 起点）
    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        if let name = sourceName {
            guard let sIdx = sourceIndex(named: name) else { return nil }
            let arts = sources[sIdx].articles
            let idx: Int
            if let loc = locationByID[id], loc.source == sIdx,
               loc.article < arts.count, arts[loc.article].id == id {
                idx = loc.article
            } else if let f = arts.firstIndex(where: { $0.id == id }) {
                idx = f
            } else {
                return nil
            }
            for a in arts[(idx + 1)...] where isSelectableNext(a) {
                return (a, name)
            }
            return nil
        } else {
            let list = allArticlesSortedForDisplay
            let idx: Int
            if let i = flatIndexByID[id], i < list.count, list[i].article.id == id {
                idx = i
            } else if let f = list.firstIndex(where: { $0.article.id == id }) {
                idx = f
            } else {
                return nil
            }
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