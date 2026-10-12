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

/// 组装阶段的中间结构：携带"发布时间排序键"与"原始出现顺序"（稳定排序用）
fileprivate struct NewsStagedArticle {
    let article: Article
    let timeKey: String   // 14 位数字 yyyyMMddHHmmss；缺失为 ""（排在当天最后）
    let seq: Int          // 全局出现顺序（文件名 → 分组 key → 数组下标）

    /// 基础顺序：日期降序 → 发布时间降序 → 原始顺序
    static func precedes(_ a: NewsStagedArticle, _ b: NewsStagedArticle) -> Bool {
        if a.article.timestamp != b.article.timestamp { return a.article.timestamp > b.article.timestamp }
        if a.timeKey != b.timeKey { return a.timeKey > b.timeKey }
        return a.seq < b.seq
    }
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
//   1) 阅读会话纯内存，永不落盘 → 杀进程 / 被系统回收都保持未读
//   2) 已读只由"显式用户动作"提交：返回列表 / 下一篇 / 音频跳下一篇 / 列表手动标记
//   3) 阅读期间不重写 sources 数组 → 详情页不会被 @Published 风暴刷成 PPT
//   4) ★ 角标在任何已读变化时立即同步（不触碰 @Published）
// ★ 排序：
//   5) 基础顺序 = 日期降序 + 发布时间降序；显示顺序再按用户偏好重排（带缓存）
//   6) 新闻源顺序支持用户拖拽，持久化在本地
// ============================================================================
@MainActor
class NewsViewModel: ObservableObject {
    nonisolated static let preferredSourceOrder: [String] = [
        "ft", "wsjcn", "nytimes", "bloomberg", "rfi", "nikkei", "dw",
        "wsj", "economist", "reuters", "washpost", "mittr", "bbc",
    ]
    /// 用户在首页拖拽后的新闻源顺序（sourceId 数组，纯本地，无需服务器）
    nonisolated static let customSourceOrderKey = "customSourceOrder"

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
    private var suspendedDuringReading = false
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

    // MARK: 查找索引
    private var locationByID: [UUID: NewsArticleLocation] = [:]
    private var sourceIndexByName: [String: Int] = [:]
    private var flatIndexByID: [UUID: Int] = [:]

    // MARK: 显示顺序缓存（下一篇 / 连续播放 按"用户看到的顺序"走）
    private struct DisplayOrder {
        let dataVersion: Int
        let prefs: Int
        let order: [Int]          // 显示顺序 → 原数组下标
        let pos: [UUID: Int]      // 文章 ID → 在 order 中的位置
    }
    private var displayOrderCache: [String: DisplayOrder] = [:]

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

        NotificationCenter.default.publisher(for: .notificationPermissionGranted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)

        // ★ 个人中心"恢复默认新闻源顺序"
        NotificationCenter.default.publisher(for: .newsSourceOrderDidReset)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resetSourceOrder() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { _ in Task { await NewsFileCache.shared.removeAll() } }
            .store(in: &cancellables)
    }

    // MARK: - 角标
    /// 强制刷新（权限刚授予 / 离开前台）
    func refreshBadge() {
        guard hasLoadedOnce else { return }
        let c = totalUnreadCount
        lastBadgeCount = c
        badgeUpdater?(c)
    }

    /// 数值不变则不打系统 API
    private func updateBadgeIfChanged() {
        guard hasLoadedOnce else { return }
        let c = totalUnreadCount
        guard c != lastBadgeCount else { return }
        lastBadgeCount = c
        badgeUpdater?(c)
    }

    // MARK: - 生命周期钩子
    func noteAppLeftForeground() {
        if isReadingArticle || readingArticleTopic != nil {
            suspendedDuringReading = true
            print("⏸️ [阅读会话] App 离开前台，本篇保持未读（提交权限已吊销）。")
        }
        UserDefaults.standard.synchronize()
        // ★ 用户马上就会在桌面看到角标 → 强制对齐一次（兜底之前任何一次失败的写入）
        refreshBadge()
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
        displayOrderCache = [:]
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
        let customOrder = UserDefaults.standard.stringArray(forKey: Self.customSourceOrderKey) ?? []
        let docDir = self.documentsDirectory

        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let snapshot = await NewsViewModel.buildSnapshot(
                docDir: docDir,
                subscribedIDs: Set(subscribedIDs),
                mappings: currentMappings,
                readRecords: readRecordsCopy,
                preferredOrder: preferredOrder,
                customOrder: customOrder
            ) else { return }
            guard !Task.isCancelled else { return }
            await self?.applySnapshot(snapshot, generation: generation, readVersionAtStart: readVersionAtStart)
        }
    }

    // MARK: - 排序工具（nonisolated：后台构建与主线程共用）

    /// 把 "2026-10-12 03:32:50" / "2026-10-12T03:32:50Z" 等统一成 14 位数字键；无效返回 ""
    nonisolated static func timeSortKey(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var digits = String(raw.filter { $0.isASCII && $0.isNumber })
        guard digits.count >= 8 else { return "" }
        if digits.count < 14 {
            digits += String(repeating: "0", count: 14 - digits.count)
        } else if digits.count > 14 {
            digits = String(digits.prefix(14))
        }
        return digits
    }

    /// 源排序：用户自定义顺序优先；未出现在自定义顺序里的（新订阅）排在后面，按默认顺序
    nonisolated static func sortSources(_ list: [NewsSource],
                                        customOrder: [String],
                                        preferredOrder: [String]) -> [NewsSource] {
        var customRank: [String: Int] = [:]
        for (i, id) in customOrder.enumerated() where customRank[id] == nil { customRank[id] = i }
        var prefRank: [String: Int] = [:]
        for (i, id) in preferredOrder.enumerated() where prefRank[id] == nil { prefRank[id] = i }
        let base = customOrder.count

        func rank(_ s: NewsSource) -> Int {
            if let c = customRank[s.sourceId] { return c }
            return base + (prefRank[s.sourceId] ?? 100_000)
        }
        return list.sorted { a, b in
            let r1 = rank(a), r2 = rank(b)
            if r1 != r2 { return r1 < r2 }
            return a.name < b.name
        }
    }

    /// 源 / 文章位置索引（首次出现优先）
    nonisolated fileprivate static func buildSourceIndexes(_ list: [NewsSource])
        -> (locations: [UUID: NewsArticleLocation], names: [String: Int]) {
        var locations = [UUID: NewsArticleLocation]()
        var names = [String: Int]()
        for (si, s) in list.enumerated() {
            if names[s.name] == nil { names[s.name] = si }
            for (ai, a) in s.articles.enumerated() where locations[a.id] == nil {
                locations[a.id] = NewsArticleLocation(source: si, article: ai)
            }
        }
        return (locations, names)
    }

    /// 后台构建：读目录 → 命中缓存 / 并行解码 → 组装 → 排序 → 建索引
    nonisolated private static func buildSnapshot(
        docDir: URL,
        subscribedIDs: Set<String>,
        mappings: [String: String],
        readRecords: [String: Date],
        preferredOrder: [String],
        customOrder: [String]
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
                        if decoded == nil { print("⚠️ [加载] 解码失败: \(url.lastPathComponent)") }
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

        // 3) 组装（按文件名顺序 + 排序后的 key 遍历 → 稳定 ID / 稳定 seq）
        var stagedBySourceID = [String: [NewsStagedArticle]]()
        var usedKeys = Set<String>()
        var seq = 0

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
                    stagedBySourceID[sourceId, default: []].append(
                        NewsStagedArticle(article: m, timeKey: timeSortKey(article.publishedAt), seq: seq))
                    seq += 1
                }
            }
        }

        if Task.isCancelled { return nil }

        // 4) 每源排序（★ 日期降序 → 发布时间降序 → 原始顺序；hot 已不参与）
        var tempSources: [NewsSource] = []
        var flatStaged: [(staged: NewsStagedArticle, name: String, nameEN: String)] = []
        flatStaged.reserveCapacity(seq)

        for (sourceId, staged) in stagedBySourceID {
            let raw = mappings[sourceId] ?? sourceId
            let parts = raw.components(separatedBy: "|")
            let cnName = parts.first ?? raw
            let enName = parts.count > 1 ? parts[1] : cnName

            let sorted = staged.sorted(by: NewsStagedArticle.precedes)
            tempSources.append(NewsSource(sourceId: sourceId, name: cnName, name_en: enName,
                                          articles: sorted.map(\.article)))
            for st in sorted { flatStaged.append((st, cnName, enName)) }
        }
        tempSources = sortSources(tempSources, customOrder: customOrder, preferredOrder: preferredOrder)

        // 5) 扁平列表：同一规则（seq 全局唯一 → 全序、可复现，与源顺序无关）
        flatStaged.sort { NewsStagedArticle.precedes($0.staged, $1.staged) }
        let flat = flatStaged.map {
            (article: $0.staged.article, sourceName: $0.name, sourceNameEN: $0.nameEN)
        }

        // 6) 索引
        let idx = buildSourceIndexes(tempSources)
        var flatIndexByID = [UUID: Int]()
        flatIndexByID.reserveCapacity(flat.count)
        for (k, item) in flat.enumerated() where flatIndexByID[item.article.id] == nil {
            flatIndexByID[item.article.id] = k
        }

        return NewsSnapshot(sources: tempSources,
                            flat: flat,
                            locationByID: idx.locations,
                            sourceIndexByName: idx.names,
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
        displayOrderCache = [:]

        self.sources = srcs
        self.allArticlesSortedForDisplay = flat
        pendingMemorySync = false
        hasLoadedOnce = true
        updateBadgeIfChanged()
        pruneReadRecordsIfNeeded()
        print("新闻数据加载/刷新完成！(后台线程处理)")
    }

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
    // MARK: - 新闻源顺序（拖拽排序，纯本地持久化）
    // ========================================================================

    /// 把 id 移到 targetID 当前所在的位置（拖拽实时换位用）。返回是否真的移动了
    @discardableResult
    func moveSource(id: String, to targetID: String) -> Bool {
        guard id != targetID,
              let from = sources.firstIndex(where: { $0.sourceId == id }),
              let to = sources.firstIndex(where: { $0.sourceId == targetID }) else { return false }
        var list = sources
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        applySourceOrder(list)
        persistCustomSourceOrder()
        return true
    }

    /// 无障碍"上移 / 下移"
    @discardableResult
    func moveSource(id: String, by offset: Int) -> Bool {
        guard let from = sources.firstIndex(where: { $0.sourceId == id }) else { return false }
        let to = from + offset
        guard sources.indices.contains(to) else { return false }
        return moveSource(id: id, to: sources[to].sourceId)
    }

    func resetSourceOrder() {
        UserDefaults.standard.removeObject(forKey: Self.customSourceOrderKey)
        let sorted = Self.sortSources(sources, customOrder: [], preferredOrder: Self.preferredSourceOrder)
        guard sorted.map(\.sourceId) != sources.map(\.sourceId) else { return }
        applySourceOrder(sorted)
    }

    private func applySourceOrder(_ list: [NewsSource]) {
        let idx = Self.buildSourceIndexes(list)
        locationByID = idx.locations
        sourceIndexByName = idx.names
        sources = list          // dataVersion 自增 → 未读缓存 / 显示顺序缓存自动失效
    }

    /// 当前顺序 + 之前保存过、但当前未订阅的源（保留它们的相对位置，重新订阅时不乱）
    private func persistCustomSourceOrder() {
        let current = sources.map(\.sourceId)
        let currentSet = Set(current)
        let old = UserDefaults.standard.stringArray(forKey: Self.customSourceOrderKey) ?? []
        UserDefaults.standard.set(current + old.filter { !currentSet.contains($0) },
                                  forKey: Self.customSourceOrderKey)
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

        // ★ BUG 修复：角标必须立即同步。
        //   旧实现在详情页（下一篇 / 音频连播）只记"内存债务"就 return，
        //   角标要等退出详情页才更新 → 用户直接回桌面时角标一直是旧值。
        //   角标计算只读缓存、不触碰 @Published，不会引起详情页重排。
        updateBadgeIfChanged()

        if isReadingArticle {
            pendingMemorySync = true
            return
        }
        refreshMemoryFromRecords()
    }

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

    // MARK: 遗留"暂存"接口 —— ★已废弃为 no-op（保留签名防止其它文件编译失败）
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

    func finishReading(markCurrentAsRead: Bool = true) {
        let topic = readingArticleTopic
        let id = readingArticleID
        readingArticleID = nil
        readingArticleTopic = nil

        let allowCommit = markCurrentAsRead && !suspendedDuringReading
        if !allowCommit && markCurrentAsRead {
            print("🚫 [阅读会话] 曾离开前台，跳过自动标记已读，保持未读。")
        }

        if allowCommit, let topic = topic {
            applyReadState([ReadTarget(id: id, topic: topic)], read: true)
        }

        if pendingMemorySync { refreshMemoryFromRecords() }
        UserDefaults.standard.synchronize()

        suspendedDuringReading = false
        isReadingArticle = false      // 必须最后：会触发被延后的 loadNews()
    }

    func finishReadingIfNeeded() {
        guard readingArticleID != nil || readingArticleTopic != nil
                || isReadingArticle || pendingMemorySync else { return }
        finishReading(markCurrentAsRead: true)
    }

    // MARK: 已读判定（★ 只以 readRecords 为唯一真相）
    // 旧实现 `records != nil || article.isRead`：阅读期间"标为未读"会被内存里过期的 isRead=true 覆盖
    func isEffectivelyRead(articleID: UUID) -> Bool {
        if let a = article(withID: articleID) { return isArticleEffectivelyRead(a) }
        return false
    }

    func isArticleEffectivelyRead(_ article: Article) -> Bool {
        readRecords[article.topic] != nil
    }

    func syncReadStatusFromPersistence() {
        let fresh = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
        let changed = fresh != readRecords
        if changed {
            readRecords = fresh
            readVersion &+= 1
            updateBadgeIfChanged()
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
    // MARK: - 未读计数（缓存，O(1) 读取）
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
            for a in s.articles where records[a.topic] == nil {
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

    // ========================================================================
    // MARK: - 显示顺序 / 下一篇（★ 严格按用户看到的顺序）
    // ========================================================================
    private func displayOrder(sourceIndex sIdx: Int?) -> DisplayOrder {
        let g = ArticleSortPrefs.groupNewestFirst
        let it = ArticleSortPrefs.itemNewestFirst
        let prefs = (g ? 1 : 0) | (it ? 2 : 0)
        let key = sIdx.map { sources[$0].sourceId } ?? allArticlesKey
        if let c = displayOrderCache[key], c.dataVersion == dataVersion, c.prefs == prefs { return c }

        let days: [String]
        let ids: [UUID]
        if let sIdx {
            let arts = sources[sIdx].articles
            days = arts.map(\.timestamp)
            ids = arts.map(\.id)
        } else {
            let list = allArticlesSortedForDisplay
            days = list.map { $0.article.timestamp }
            ids = list.map { $0.article.id }
        }

        let order = ArticleSortPrefs.group(Array(days.indices), day: { days[$0] },
                                           groupNewestFirst: g, itemNewestFirst: it)
            .flatMap { $0.items }
        var pos = [UUID: Int]()
        pos.reserveCapacity(order.count)
        for (p, idx) in order.enumerated() where pos[ids[idx]] == nil { pos[ids[idx]] = p }

        let result = DisplayOrder(dataVersion: dataVersion, prefs: prefs, order: order, pos: pos)
        displayOrderCache[key] = result
        return result
    }

    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        if let name = sourceName {
            guard let sIdx = sourceIndex(named: name) else { return nil }
            let arts = sources[sIdx].articles
            let o = displayOrder(sourceIndex: sIdx)
            guard let p = o.pos[id] else { return nil }
            for k in o.order[(p + 1)...] where isSelectableNext(arts[k]) {
                return (arts[k], name)
            }
            return nil
        } else {
            let list = allArticlesSortedForDisplay
            let o = displayOrder(sourceIndex: nil)
            guard let p = o.pos[id] else { return nil }
            for k in o.order[(p + 1)...] where isSelectableNext(list[k].article) {
                return (list[k].article, list[k].sourceName)
            }
            return nil
        }
    }

    /// 首页 ▶ 播放：显示顺序中的第一篇未读
    func firstUnreadForPlayback(inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        if let name = sourceName {
            guard let sIdx = sourceIndex(named: name) else { return nil }
            let arts = sources[sIdx].articles
            for k in displayOrder(sourceIndex: sIdx).order where !isArticleEffectivelyRead(arts[k]) {
                return (arts[k], name)
            }
            return nil
        }
        let list = allArticlesSortedForDisplay
        for k in displayOrder(sourceIndex: nil).order where !isArticleEffectivelyRead(list[k].article) {
            return (list[k].article, list[k].sourceName)
        }
        return nil
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
    /// ⚠️ 所属"日期分组"（yyMMdd），由文件名注入，不来自 JSON
    var timestamp: String = ""
    var stableKey: String = ""
    /// ★ 文章发布时间：JSON 中的 "timestamp" 字段（如 "2026-10-12 03:32:50"），用于组内排序
    var publishedAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case topic, article, images, source_id, url, topic_eng, article_eng, hot
        case publishedAt = "timestamp"
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

/// ★ 宽松解码（写在 extension 里以保留成员初始化器）：
///   可选字段类型不符（如 hot 写成字符串、timestamp 写成数字）只丢该字段，
///   不再让整个 JSON 文件解码失败 → 当天所有文章消失。
extension Article {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            topic: try c.decode(String.self, forKey: .topic),
            article: try c.decode(String.self, forKey: .article),
            topic_eng: (try? c.decodeIfPresent(String.self, forKey: .topic_eng)) ?? nil,
            article_eng: (try? c.decodeIfPresent(String.self, forKey: .article_eng)) ?? nil,
            images: (try? c.decodeIfPresent([String].self, forKey: .images)) ?? [],
            source_id: (try? c.decodeIfPresent(String.self, forKey: .source_id)) ?? nil,
            url: (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil,
            hot: (try? c.decodeIfPresent(Int.self, forKey: .hot)) ?? nil,
            publishedAt: (try? c.decodeIfPresent(String.self, forKey: .publishedAt)) ?? nil
        )
    }
}

/// 后台任务包装：保证 endBackgroundTask 一定被调用且只调用一次
@MainActor
final class BadgeBackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "updateBadgeCount") {
            self.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

@MainActor
class AppBadgeManager: ObservableObject {
    func requestAuthorizationAsync() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
            print(granted ? "用户已授予角标权限。" : "用户未授予角标权限。")
        } catch {
            print("角标权限请求失败: \(error.localizedDescription)")
        }
    }

    func requestAuthorization() {
        Task { await requestAuthorizationAsync() }
    }

    /// ★ 使用 async API，全程主线程；后台任务确保进后台瞬间的写入不会被挂起丢失
    func updateBadge(count: Int) {
        let target = max(0, count)
        let bg = BadgeBackgroundTask()
        bg.begin()
        Task { @MainActor in
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(target)
            } catch {
                print("【角标更新失败】: \(error.localizedDescription)")
            }
            bg.end()
        }
    }
}

extension Notification.Name {
    static let newsDataDidUpdate = Notification.Name("newsDataDidUpdate")
    static let newsConfigDidUpdate = Notification.Name("newsConfigDidUpdate")
    static let newsSourceOrderDidReset = Notification.Name("newsSourceOrderDidReset")
}