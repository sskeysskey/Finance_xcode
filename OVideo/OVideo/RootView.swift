import SwiftUI
import Combine

enum SidebarItem: Hashable, Codable {
    case category(String), filter, search, follow, downloads, history
}
enum Route: Hashable { case detail(VideoItem) }

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
                        case .detail(let item): DetailView(item: item)
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