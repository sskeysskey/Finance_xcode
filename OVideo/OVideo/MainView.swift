import SwiftUI
import AppKit
import Combine
import Foundation
import IOKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gear") }
            PlaybackSettings().tabItem { Label("播放", systemImage: "play.rectangle") }
            DownloadSettings().tabItem { Label("下载", systemImage: "arrow.down.circle") }
            AccountSettings().tabItem { Label("账号", systemImage: "person.crop.circle") }
        }
        .frame(width: 520, height: 340)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var config = AppConfigManager.shared
    var body: some View {
        Form {
            Toggle(lang.t("英文界面", "English UI"), isOn: $lang.isEnglish)
            LabeledContent(lang.t("内容更新时间", "Content updated"), value: config.updateTime)
            LabeledContent(lang.t("版本", "Version"), value: DeviceIdentity.appVersion)
            Button(lang.t("清理图片内存缓存", "Clear image cache")) { ImageCache.shared.clear() }
        }.padding(20).formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @EnvironmentObject var lang: LanguageManager
    @AppStorage("GW_AutoNext") private var autoNext = true
    @AppStorage("GW_EpAsc") private var asc = true
    var body: some View {
        Form {
            Toggle(lang.t("播完自动下一集", "Auto play next episode"), isOn: $autoNext)
            Toggle(lang.t("剧集正序排列", "Episodes ascending"), isOn: $asc)
            LabeledContent(lang.t("默认倍速", "Default speed"),
                value: String(format: "%g", SpeedStore.rate) + "x")
            Text(lang.t("播放窗口支持全屏、画中画、⌘[ / ⌘] 切换集数。",
                        "Player supports full screen, PiP and ⌘[ / ⌘] to switch episodes."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var dm = HLSDownloadManager.shared
    @AppStorage("GW_SegConcurrency") private var seg = 6
    var body: some View {
        Form {
            Stepper(lang.t("分片并发数：\(seg)", "Segment concurrency: \(seg)"), value: $seg, in: 2...12)
            LabeledContent(lang.t("已占用空间", "Disk usage"), value: formatBytes(dm.totalDiskUsage))
            Button(lang.t("在 Finder 中打开下载目录", "Open downloads folder")) {
                NSWorkspace.shared.open(dm.storageRoot)
            }
            Text(lang.t("退出应用会暂停下载，下次启动可继续（断点续传）。",
                        "Quitting pauses downloads; they resume next launch."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @State private var confirmDelete = false
    var body: some View {
        Form {
            if auth.isLoggedIn {
                LabeledContent("ID", value: String((auth.userIdentifier ?? "").prefix(10)) + "…")
                LabeledContent(lang.t("会员", "Membership"),
                               value: auth.isSubscribed
                                ? (auth.isPermanentVIP ? lang.t("长期有效", "Lifetime")
                                                       : (auth.subscriptionExpiryDate ?? "-"))
                                : lang.t("免费版", "Free"))
                Button(lang.t("退出登录", "Sign Out")) { auth.signOut() }
                Button(lang.t("删除账号", "Delete Account"), role: .destructive) { confirmDelete = true }
            } else {
                Button(lang.t("使用 Apple 登录", "Sign in with Apple")) { auth.signInWithApple() }
            }
            Button(lang.t("恢复购买", "Restore Purchases")) { Task { try? await auth.restorePurchases() } }
            Link(lang.t("问题反馈：728308386@qq.com", "Feedback: 728308386@qq.com"),
                 destination: URL(string: "mailto:728308386@qq.com")!)
        }
        .padding(20).formStyle(.grouped)
        .alert(lang.t("确认删除账号？", "Delete account?"), isPresented: $confirmDelete) {
            Button(lang.t("取消", "Cancel"), role: .cancel) {}
            Button(lang.t("永久删除", "Delete"), role: .destructive) {
                Task { try? await auth.deleteAccount() }
            }
        } message: {
            Text(lang.t("此操作不可恢复，您的数据与订阅记录将从服务器删除。",
                        "This cannot be undone."))
        }
    }
}


@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    @Published var isEnglish: Bool {
        didSet { UserDefaults.standard.set(isEnglish, forKey: "isGlobalEnglishMode") }
    }
    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "isGlobalEnglishMode") == nil {
            let lang = Locale.preferredLanguages.first ?? "en"
            d.set(!lang.hasPrefix("zh"), forKey: "isGlobalEnglishMode")
        }
        isEnglish = d.bool(forKey: "isGlobalEnglishMode")
    }
    func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}

/// 非 View 环境下的取值（Manager 内部用）
func T(_ zh: String, _ en: String) -> String {
    UserDefaults.standard.bool(forKey: "isGlobalEnglishMode") ? en : zh
}

extension Color {
    static let cardBG = Color(nsColor: .controlBackgroundColor)
    static let winBG  = Color(nsColor: .windowBackgroundColor)
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: b)
}
func formatSpeed(_ bps: Double) -> String {
    if bps <= 0 { return "—" }
    return formatBytes(Int64(bps)) + "/s"
}


enum DeviceIdentity {
    /// 稳定设备 ID（与服务端 dev_ 前缀约定一致）
    static let deviceId: String = {
        if let hw = hardwareUUID() { return "dev_" + hw }
        let key = "GW_FallbackDeviceUUID"
        if let s = UserDefaults.standard.string(forKey: key) { return "dev_" + s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: key)
        return "dev_" + s
    }()

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                        IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service,
                        "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (cf.takeRetainedValue() as? String)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

enum SidebarItem: Hashable, Codable {
    case category(String), filter, search, follow, downloads, history
}

// ⭐ 增加 .search(String) 路由支持
enum Route: Hashable { 
    case detail(VideoItem)
    case search(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var selection: SidebarItem? = .category("Featured")
    @Published var path = NavigationPath()
    @Published var sort: VideoSortOption = {
        VideoSortOption(rawValue: UserDefaults.standard.string(forKey: "GW_Sort") ?? "date") ?? .date
    }() { didSet { UserDefaults.standard.set(sort.rawValue, forKey: "GW_Sort") } }
    @Published var searchFocusToken = 0
    @Published var showSubscription = false
    private init() {}

    func go(_ item: SidebarItem) { path = NavigationPath(); selection = item }
    func focusSearch() { go(.search); searchFocusToken += 1 }
}

struct RootView: View {
    @EnvironmentObject var data: VideoDataManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var app = AppState.shared
    @ObservedObject var config = AppConfigManager.shared
    @ObservedObject var track = SeriesTrackManager.shared
    @ObservedObject var quota = QuotaManager.shared
    @ObservedObject var replies = ReplyCenter.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $app.path) {
                detailRoot
                    .navigationDestination(for: Route.self) { r in
                        switch r {
                        case .detail(let item): 
                            DetailView(item: item)
                        case .search(let kw): 
                            SearchView(initialKeyword: kw)
                        }
                    }
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .sheet(isPresented: $app.showSubscription) { SubscriptionView() }
        .task {
            await config.refresh()
            await data.bootstrap(userId: auth.userIdentifier)
            await quota.refresh(userId: QuotaManager.currentUserId(auth: auth))
            await track.refresh(force: true)
            await replies.refresh(userId: auth.userIdentifier)
            if app.selection == nil { app.selection = .category(data.categoryNames.first ?? "Featured") }
        }
        .onChangeCompat(of: config.useReviewDisguise) { _ in
            data.resetCache()
            Task { await data.bootstrap(userId: auth.userIdentifier) }
        }
        .onChangeCompat(of: auth.isLoggedIn) { _ in
            Task {
                await quota.refresh(userId: QuotaManager.currentUserId(auth: auth))
                await replies.refresh(userId: auth.userIdentifier)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            auth.handleBecomeActive()
            Task {
                await quota.refresh(userId: QuotaManager.currentUserId(auth: auth))
                await track.refresh()
            }
        }
    }

    // MARK: 侧边栏
    private var sidebar: some View {
        List(selection: $app.selection) {
            Section(lang.t("频道", "Channels")) {
                ForEach(data.categoryNames, id: \.self) { c in
                    Label(config.categoryDisplayName(c, english: lang.isEnglish),
                          systemImage: icon(for: c))
                        .tag(SidebarItem.category(c))
                }
            }
            Section(lang.t("发现", "Discover")) {
                Label(lang.t("分类检索", "Filter"), systemImage: "line.3.horizontal.decrease.circle")
                    .tag(SidebarItem.filter)
                Label(lang.t("搜索", "Search"), systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
            }
            Section(lang.t("我的", "Library")) {
                HStack {
                    Label(lang.t("追剧", "Following"), systemImage: "bell")
                    if track.unseenCount > 0 {
                        Spacer()
                        Text("\(track.unseenCount)").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.red, in: Capsule()).foregroundStyle(.white)
                    }
                }.tag(SidebarItem.follow)
                Label(lang.t("下载管理", "Downloads"), systemImage: "arrow.down.circle")
                    .tag(SidebarItem.downloads)
                Label(lang.t("观看记录", "History"), systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider()
            if auth.isSubscribed {
                HStack {
                    Image(systemName: "crown.fill").foregroundStyle(.yellow)
                    Text(lang.t("会员已开通", "Premium")).font(.callout)
                    Spacer()
                }
            } else {
                Button {
                    app.showSubscription = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lang.t("免费点数 \(quota.remaining)", "Points \(quota.remaining)"))
                                .font(.callout.weight(.medium))
                            Text(lang.t("升级会员不限量", "Upgrade for unlimited"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func icon(for key: String) -> String {
        switch key {
        case "Featured": return "flame"
        case "Movie":    return "film"
        case "Drama":    return "tv"
        case "Show":     return "sparkles"
        case "Anime":    return "star.bubble"
        default:         return "square.stack"
        }
    }

    // MARK: 主区
    @ViewBuilder private var detailRoot: some View {
        if !config.moduleEnabled || auth.isVideoModuleBlocked {
            ModuleClosedView()
        } else {
            switch app.selection {
            case .category(let c): HomeGridView(category: c)
            case .filter:          FilterView()
            case .search:          SearchView()
            case .follow:          FollowView()
            case .downloads:       DownloadsView()
            case .history:         HistoryView()
            case nil:              ProgressView()
            }
        }
    }
}

struct ModuleClosedView: View {
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        ContentUnavailableViewCompat(
            title: lang.t("暂时无法浏览", "Temporarily unavailable"),
            message: lang.t("因版权原因，内容暂时关闭，敬请谅解。",
                            "Content is temporarily closed for copyright reasons."),
            systemImage: "film.stack")
    }
}

/// macOS 13 兼容的空状态视图
struct ContentUnavailableViewCompat: View {
    let title: String, message: String, systemImage: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 46)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.winBG)
    }
}

@main
struct GWVideoApp: App {
    @StateObject private var lang = LanguageManager.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var data = VideoDataManager()
    @StateObject private var config = AppConfigManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if config.showForceUpdate { ForceUpdateView(storeURL: config.storeURL) }
            }
            .environmentObject(lang)
            .environmentObject(auth)
            .environmentObject(data)
            .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands() }

        // 独立播放窗口
        WindowGroup(id: "player", for: PlayPayload.self) { $payload in
            if let payload {
                PlayerWindowView(payload: payload)
                    .environmentObject(lang)
                    .environmentObject(auth)
            }
        }
        .defaultSize(width: 1120, height: 660)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environmentObject(lang).environmentObject(auth)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var app = AppState.shared
    @ObservedObject var lang = LanguageManager.shared
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandMenu(lang.t("浏览", "Browse")) {
            Button(lang.t("搜索", "Search")) { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button(lang.t("分类检索", "Filter")) { app.go(.filter) }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button(lang.t("追剧提醒", "Following")) { app.go(.follow) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button(lang.t("下载管理", "Downloads")) { app.go(.downloads) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Button(lang.t("观看记录", "History")) { app.go(.history) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
            Divider()
            Button(lang.t("刷新", "Refresh")) {
                Task { await AppConfigManager.shared.refresh() }
            }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appInfo) {
            Button(lang.t("会员与点数…", "Membership & Points…")) { app.showSubscription = true }
        }
        CommandGroup(replacing: .help) {
            Link(lang.t("问题反馈", "Send Feedback"),
                 destination: URL(string: "mailto:728308386@qq.com")!)
        }
    }
}

struct ForceUpdateView: View {
    let storeURL: String
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85)).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 60)).foregroundStyle(.blue)
                Text(lang.t("需要更新", "Update Required")).font(.title.bold()).foregroundStyle(.white)
                Text(lang.t("当前版本已停止服务，请更新后继续使用。",
                            "This version is no longer supported."))
                    .foregroundStyle(.secondary)
                Button(lang.t("前往 App Store", "Open App Store")) {
                    if let u = URL(string: storeURL.isEmpty ? "macappstore://apps.apple.com" : storeURL) {
                        NSWorkspace.shared.open(u)
                    }
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}

/// 跨 macOS 13 / 14 / 15 的 onChange 替代品：
/// 不使用 macOS 14 已弃用的 onChange(of:perform:)，也不使用 macOS 14 才有的双参数 onChange。
struct GWChangeObserver<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void
    @State private var last: V?

    func body(content: Content) -> some View {
        content.task(id: value) {
            if let l = last, l != value { action(value) }
            last = value
        }
    }
}

extension View {
    /// 用法与旧的 .onChange(of:) { newValue in } 完全一致
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        modifier(GWChangeObserver(value: value, action: action))
    }
}
