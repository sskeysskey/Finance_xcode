import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread
    case read

    var localizedName: String {
        switch self {
        case .unread: return Localized.unread
        case .read: return Localized.read
        }
    }
}

// ==================== 【需求2】免费标识判定 ====================
@MainActor
enum NewsFreeBadge {
    /// 未订阅用户 + 该日期已过锁定期 → 显示"免费"
    static func isFree(timestamp: String, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed || auth.isPermanentVIP { return false }   // ← 加 isPermanentVIP
        return !viewModel.isTimestampLocked(timestamp: timestamp)
    }
}

// ==================== 【补丁】免登录订阅引导：免费新闻阅读计数 ====================
@MainActor
enum AnonFreeReadTracker {
    /// 仅"未登录 + 未订阅 + 该文章属于已解锁的旧新闻"才计数
    static func note(_ article: Article, auth: AuthManager, viewModel: NewsViewModel) {
        guard !auth.isLoggedIn, !auth.isSubscribed else { return }
        guard !viewModel.isTimestampLocked(timestamp: article.timestamp) else { return }
        AnonymousSubscribePromptManager.shared.noteFreeArticleRead()
    }
}

struct FreeTagView: View {
    var compact: Bool = false
    var body: some View {
        HStack(spacing: 3) {
            Text(Localized.isEnglish ? "FREE" : "免费")
                .font(.system(size: compact ? 14 : 16, weight: .heavy, design: .rounded))
        }
        .foregroundColor(Color(red: 0.08, green: 0.68, blue: 0.28))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(
            Capsule().fill(Color(red:0.18, green:0.82, blue:0.38).opacity(0.12))
        )
        .overlay(Capsule().stroke(Color(red:0.18, green:0.82, blue:0.38).opacity(0.38), lineWidth: 0.6))
    }
}

// ==================== 公共协议和扩展 ====================
protocol ArticleListDataSource {
    var baseFilteredArticles: [ArticleItem] { get }
    var filterMode: ArticleFilterMode { get }
}

struct ArticleItem: Identifiable {
    let id: UUID
    let article: Article
    let sourceName: String?
    let sourceNameEN: String?
    var isContentMatch: Bool = false

    init(article: Article, sourceName: String? = nil, sourceNameEN: String? = nil, isContentMatch: Bool = false) {
        self.id = article.id
        self.article = article
        self.sourceName = sourceName
        self.sourceNameEN = sourceNameEN
        self.isContentMatch = isContentMatch
    }
}

struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String?
    let sourceNameEN: String?
    let isReadEffective: Bool
    let isContentMatch: Bool
    let isLocked: Bool
    let isFree: Bool                    // ★【需求2】
    let showEnglish: Bool

    init(article: Article, sourceName: String?, sourceNameEN: String? = nil, isReadEffective: Bool,
         isContentMatch: Bool = false, isLocked: Bool = false, isFree: Bool = false,
         showEnglish: Bool = false) {
        self.article = article
        self.sourceName = sourceName
        self.sourceNameEN = sourceNameEN
        self.isReadEffective = isReadEffective
        self.isContentMatch = isContentMatch
        self.isLocked = isLocked
        self.isFree = isFree
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
                        .font(.system(size: 11, weight: .bold))
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
                } else if isFree {
                    // ★【需求2】旧新闻：淡绿色"免费"
                    FreeTagView()
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

struct ArticleListContent: View {
    let items: [ArticleItem]
    let filterMode: ArticleFilterMode
    let expandedTimestamps: Set<String>
    let viewModel: NewsViewModel
    let authManager: AuthManager
    let showEnglish: Bool
    let onToggleTimestamp: (String) -> Void
    let onPlayTimestamp: (String) -> Void
    let onArticleTap: (ArticleItem) async -> Void
    @ObservedObject private var newsQuota = NewsQuotaManager.shared

    var groupedArticles: [String: [ArticleItem]] {
        let initial = Dictionary(grouping: items, by: { $0.article.timestamp })
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }

    var sortedTimestamps: [String] { groupedArticles.keys.sorted(by: >) }

    private func isGroupLocked(_ timestamp: String) -> Bool {
        guard NewsPointsCoordinator.shouldShowLock(timestamp: timestamp,
                                                  auth: authManager,
                                                  viewModel: viewModel) else { return false }
        let group = groupedArticles[timestamp] ?? []
        if group.isEmpty { return true }
        return group.contains { !NewsPointsCoordinator.canAccess($0.article,
                                                                auth: authManager,
                                                                viewModel: viewModel) }
    }

    var body: some View {
        ForEach(sortedTimestamps, id: \.self) { timestamp in
            Section {
                if expandedTimestamps.contains(timestamp) {
                    ForEach(groupedArticles[timestamp] ?? []) { item in
                        ArticleRowButton(
                            item: item,
                            filterMode: filterMode,
                            viewModel: viewModel,
                            authManager: authManager,
                            filteredArticles: items,
                            onTap: { await onArticleTap(item) },
                            showEnglish: showEnglish
                        )
                    }
                }
            } header: {
                TimestampHeader(
                    timestamp: timestamp,
                    count: groupedArticles[timestamp]?.count ?? 0,
                    isExpanded: expandedTimestamps.contains(timestamp),
                    isLocked: isGroupLocked(timestamp),
                    isFree: NewsFreeBadge.isFree(timestamp: timestamp,
                                                 auth: authManager,
                                                 viewModel: viewModel),
                    onToggle: { onToggleTimestamp(timestamp) },
                    onPlay: { onPlayTimestamp(timestamp) }
                )
            }
        }
    }
}

struct SearchResultsList: View {
    let results: [ArticleItem]
    let viewModel: NewsViewModel
    let authManager: AuthManager
    let showEnglish: Bool
    let onArticleTap: (ArticleItem) async -> Void
    @ObservedObject private var newsQuota = NewsQuotaManager.shared

    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"; return f
    }()

    private var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Localized.currentLocale
        f.dateFormat = Localized.dateFormatFull
        return f
    }

    var groupedResults: [String: [ArticleItem]] {
        Dictionary(grouping: results, by: { $0.article.timestamp }).mapValues { Array($0.reversed()) }
    }

    var sortedTimestamps: [String] { groupedResults.keys.sorted(by: >) }

    private func isGroupLocked(_ timestamp: String) -> Bool {
        guard NewsPointsCoordinator.shouldShowLock(timestamp: timestamp,
                                                  auth: authManager,
                                                  viewModel: viewModel) else { return false }
        let group = groupedResults[timestamp] ?? []
        if group.isEmpty { return true }
        return group.contains { !NewsPointsCoordinator.canAccess($0.article,
                                                                auth: authManager,
                                                                viewModel: viewModel) }
    }

    var body: some View {
        if results.isEmpty {
            Section {
                Text(Localized.noMatch)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            } header: {
                Text(Localized.searchResults)
                    .font(.headline)
                    .foregroundColor(.blue.opacity(0.7))
                    .padding(.vertical, 4)
            }
        } else {
            ForEach(sortedTimestamps, id: \.self) { timestamp in
                Section(header:
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Localized.searchResults)
                            .font(.subheadline)
                            .foregroundColor(.blue.opacity(0.7))
                        HStack(spacing: 6) {
                            Text("\(formatTimestamp(timestamp)) (\(groupedResults[timestamp]?.count ?? 0))")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.85))
                            if isGroupLocked(timestamp) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.yellow.opacity(0.8))
                                    .font(.footnote)
                            } else if NewsFreeBadge.isFree(timestamp: timestamp,
                                                           auth: authManager,
                                                           viewModel: viewModel) {
                                FreeTagView(compact: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                ) {
                    ForEach(groupedResults[timestamp] ?? []) { item in
                        ArticleRowButton(
                            item: item,
                            filterMode: .unread,
                            viewModel: viewModel,
                            authManager: authManager,
                            filteredArticles: [],
                            onTap: { await onArticleTap(item) },
                            showEnglish: showEnglish
                        )
                    }
                }
            }
        }
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp }
        return displayFormatter.string(from: date)
    }
}

struct ArticleRowButton: View {
    let item: ArticleItem
    let filterMode: ArticleFilterMode
    let viewModel: NewsViewModel
    let authManager: AuthManager
    let filteredArticles: [ArticleItem]
    let onTap: () async -> Void
    let showEnglish: Bool
    @ObservedObject private var newsQuota = NewsQuotaManager.shared

    var body: some View {
        Button(action: { Task { await onTap() } }) {
            let isLocked = NewsPointsCoordinator.shouldShowLock(timestamp: item.article.timestamp,
                                                               auth: authManager,
                                                               viewModel: viewModel)
                && !NewsPointsCoordinator.canAccess(item.article,
                                                    auth: authManager,
                                                    viewModel: viewModel)

            // ★【需求2】3 天前的旧新闻，对未订阅用户显示"免费"
            let isFree = !isLocked && NewsFreeBadge.isFree(timestamp: item.article.timestamp,
                                                          auth: authManager,
                                                          viewModel: viewModel)

            ArticleRowCardView(
                article: item.article,
                sourceName: item.sourceName,
                sourceNameEN: item.sourceNameEN,
                isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                isContentMatch: item.isContentMatch,
                isLocked: isLocked,
                isFree: isFree,
                showEnglish: showEnglish
            )
        }
        .buttonStyle(PlainButtonStyle())
        .id(item.article.id)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            ArticleContextMenu(
                article: item.article,
                filterMode: filterMode,
                viewModel: viewModel,
                filteredArticles: filteredArticles.map { $0.article }
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if viewModel.isArticleEffectivelyRead(item.article) {
                Button { viewModel.markAsUnread(articleID: item.article.id) } label: {
                    Label(Localized.markAsUnread_text, systemImage: "circle")
                }.tint(.orange)
            } else {
                Button { viewModel.markAsRead(articleID: item.article.id) } label: {
                    Label(Localized.markAsRead_text, systemImage: "checkmark.circle")
                }.tint(.blue)
            }
        }
    }
}

struct ArticleContextMenu: View {
    let article: Article
    let filterMode: ArticleFilterMode
    let viewModel: NewsViewModel
    let filteredArticles: [Article]

    var body: some View {
        if viewModel.isArticleEffectivelyRead(article) {
            Button { viewModel.markAsUnread(articleID: article.id) }
            label: { Label(Localized.markAsUnread_text, systemImage: "circle") }
        } else {
            Button { viewModel.markAsRead(articleID: article.id) }
            label: { Label(Localized.markAsRead_text, systemImage: "checkmark.circle") }

            if filterMode == .unread && !filteredArticles.isEmpty {
                Divider()
                Button {
                    viewModel.markAllAboveAsRead(articleID: article.id, inVisibleList: filteredArticles)
                } label: { Label(Localized.readAbove, systemImage: "arrow.up.to.line.compact") }

                Button {
                    viewModel.markAllBelowAsRead(articleID: article.id, inVisibleList: filteredArticles)
                } label: { Label(Localized.readBelow, systemImage: "arrow.down.to.line.compact") }
            }
        }
    }
}

struct TimestampHeader: View {
    let timestamp: String
    let count: Int
    let isExpanded: Bool
    let isLocked: Bool
    let isFree: Bool                       // ★【需求2】
    let onToggle: () -> Void
    let onPlay: () -> Void

    private let dateGradient = LinearGradient(
        colors: [Color.blue, Color.purple],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"; return f
    }()

    private var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = Localized.dateFormatShort
        f.locale = Localized.currentLocale
        return f
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { onToggle() }
        }) {
            HStack(spacing: 0) {
                Capsule()
                    .fill(isExpanded ? Color.blue : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: 24)
                    .padding(.leading, 12)

                Text(formatTimestamp(timestamp))
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(isExpanded ? AnyShapeStyle(dateGradient)
                                                : AnyShapeStyle(Color.primary.opacity(0.8)))
                    .padding(.leading, 12)
                    .fixedSize(horizontal: true, vertical: false)

                // ★【需求2】日期分组头上的"免费"
                if isFree && !isLocked {
                    FreeTagView(compact: true).padding(.leading, 8)
                }

                Spacer()

                // ★ 音频播放按钮跟随展开状态高亮
                if count > 0 {
                    Button(action: { onPlay() }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isExpanded ? .blue : .gray)
                            .padding(8)
                            .background(Circle().fill(isExpanded ? Color.blue.opacity(0.18) : Color.gray.opacity(0.15)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.trailing, 20)
                }

                HStack(spacing: 8) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2).foregroundColor(.orange)
                    }
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isExpanded ? .white : .secondary)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .background(Capsule().fill(isExpanded ? Color.blue.opacity(0.8)
                                                             : Color.secondary.opacity(0.15)))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.trailing, 12)
            }
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp }
        return displayFormatter.string(from: date)
    }
}

// ==================== 单一来源列表 ====================

struct EmptyStateView: View {
    @AppStorage("isGlobalEnglishMode") private var isEnglish = false
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.3))
            Text(isEnglish ? "No unread articles" : "当前无未读文章")
                .font(.headline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.viewBackground)
    }
}

struct ArticleListView: View {
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    // @ObservedObject private var supportManager = SupportChatManager.shared
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @Environment(\.appNavPath) var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var showMarkAllReadConfirmation = false

    @State private var showProfileSheet = false          // ★ Guest 菜单 / LoginView 已删除
    @State private var hasPerformedAutoExpansion = false

    private var firstImageWaitTimeout: TimeInterval { 0.0 }

    private var displayTitle: String {
        guard let source = source else { return sourceName }
        return isGlobalEnglishMode ? source.name_en : source.name
    }

    private var source: NewsSource? {
        viewModel.sources.first(where: { $0.name == sourceName })
    }

    private func getCount(for mode: ArticleFilterMode) -> Int {
        mode == .unread ? unreadCount : readCount
    }

    private var baseFilteredArticles: [ArticleItem] {
        guard let source = source else { return [] }
        return source.articles
            .filter { article in
                let isReadEff = viewModel.isArticleEffectivelyRead(article)
                return (filterMode == .unread) ? !isReadEff : isReadEff
            }
            .map { ArticleItem(article: $0, sourceName: nil) }
    }

    private var searchResults: [ArticleItem] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let source = source else { return [] }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source.articles.compactMap { article -> ArticleItem? in
            if article.topic.lowercased().contains(keyword) {
                return ArticleItem(article: article, sourceName: nil, isContentMatch: false)
            }
            if article.article.lowercased().contains(keyword) {
                return ArticleItem(article: article, sourceName: nil, isContentMatch: true)
            }
            return nil
        }
    }

    private var unreadCount: Int { source?.articles.filter { !$0.isRead }.count ?? 0 }
    private var readCount: Int { source?.articles.filter { $0.isRead }.count ?? 0 }

    var body: some View {
        if source == nil {
            VStack { Text(Localized.sourceUnavailable).foregroundColor(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.viewBackground.ignoresSafeArea())
        } else {
            ZStack {
                if filterMode == .unread && baseFilteredArticles.isEmpty {
                    EmptyStateView()
                } else {
                    VStack(spacing: 0) {
                        if isSearching {
                            SearchBarInline(
                                text: $searchText,
                                placeholder: Localized.searchPlaceholder,
                                onCommit: {
                                    isSearchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                },
                                onCancel: {
                                    withAnimation { isSearching = false; isSearchActive = false; searchText = "" }
                                }
                            )
                        }

                        if let message = resourceManager.activeNotification {
                            NotificationBannerView(message: message) {
                                resourceManager.dismissNotification()
                            }
                            .background(Color.viewBackground)
                        }

                        List {
                            if isSearchActive {
                                SearchResultsList(
                                    results: searchResults,
                                    viewModel: viewModel,
                                    authManager: authManager,
                                    showEnglish: isGlobalEnglishMode,
                                    onArticleTap: { item in await handleArticleTap(item, autoPlay: false) }
                                )
                            } else {
                                ArticleListContent(
                                    items: baseFilteredArticles,
                                    filterMode: filterMode,
                                    expandedTimestamps: viewModel.expandedTimestampsBySource[sourceName, default: Set<String>()],
                                    viewModel: viewModel,
                                    authManager: authManager,
                                    showEnglish: isGlobalEnglishMode,
                                    onToggleTimestamp: { timestamp in
                                        viewModel.toggleTimestampExpansion(for: sourceName, timestamp: timestamp)
                                    },
                                    onPlayTimestamp: { timestamp in
                                        if let firstItem = baseFilteredArticles.first(where: { $0.article.timestamp == timestamp }) {
                                            Task { await handleArticleTap(firstItem, autoPlay: true) }
                                        }
                                    },
                                    onArticleTap: { item in await handleArticleTap(item, autoPlay: false) }
                                )
                            }
                        }
                        .listStyle(PlainListStyle())
                        .onAppear {
                            if !hasPerformedAutoExpansion {
                                autoExpandGroups(); hasPerformedAutoExpansion = true
                            }
                            Task { await resourceManager.silentRefresh(minInterval: 60, reason: "source-list-appear") }
                            // // 刷新客服未读状态
                            // Task { 
                            //     await SupportChatManager.shared.refresh(
                            //         userId: SupportIdentity.userId(appleId: authManager.userIdentifier)
                            //     )
                            // }
                        }

                        if !isSearchActive {
                            HStack(spacing: 8) {
                                Picker("Filter", selection: $filterMode) {
                                    ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                                        Text("\(mode.localizedName) (\(self.getCount(for: mode)))").tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Button { showMarkAllReadConfirmation = true } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 20)).foregroundColor(.blue)
                                }
                            }
                            .padding([.horizontal, .bottom])
                            .onChange(of: filterMode) { _ in autoExpandGroups() }
                        }
                    }
                    .background(Color.viewBackground.ignoresSafeArea())
                }
            }
            .navigationTitle(displayTitle.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    UserStatusToolbarItem(showProfileSheet: $showProfileSheet)
                }
                ToolbarItem(placement: .principal) {
                    // 匿名订阅用户 & 未登录用户都不该看到点数胶囊
                    if authManager.isLoggedIn && !authManager.isSubscribed { NewsPointsPill() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { withAnimation(.spring()) { isGlobalEnglishMode.toggle() } }) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 1.5)
                                .background(!isGlobalEnglishMode ? Color.primary : Color.clear)
                                .clipShape(Circle())
                            Text(isGlobalEnglishMode ? "中" : "英")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(!isGlobalEnglishMode ? Color.viewBackground : Color.primary)
                        }
                        .frame(width: 24, height: 24)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            isSearching.toggle()
                            if !isSearching { isSearchActive = false; searchText = "" }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass").foregroundColor(.primary)
                    }
                    .accessibilityLabel(Localized.search)
                }
            }
            // // ➕ 在线客服悬浮按钮
            // .supportBubble(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
            // // 独立挂载客服 sheet，避免和下面的 showProfileSheet 互相覆盖
            // .background(
            //     Color.clear.sheet(isPresented: $supportManager.showChat) {
            //         SupportChatView(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
            //     }
            // )
            .overlay(
                DownloadOverlay(isDownloading: isDownloadingImages,
                                progress: downloadProgress,
                                progressText: downloadProgressText)
            )
            .alert("", isPresented: $showErrorAlert,
                   actions: { Button(Localized.confirm, role: .cancel) { } },
                   message: { Text(errorMessage) })
            .sheet(isPresented: $showProfileSheet) { UserProfileView() }
            .confirmationDialog(Localized.markAllAsReadConfirm,
                                isPresented: $showMarkAllReadConfirmation,
                                titleVisibility: .visible) {
                Button(Localized.markAllAsRead, role: .destructive) {
                    viewModel.markAllAsReadInSource(sourceName)
                }
                Button(Localized.cancel, role: .cancel) { }
            }
            .onChange(of: authManager.isLoggedIn) { newValue in
                if newValue {
                    Task {
                        await NewsQuotaManager.shared.refresh(
                            userId: NewsQuotaManager.currentUserId(auth: authManager))
                    }
                }
            }
        }
    }

    private func handleArticleTap(_ item: ArticleItem, autoPlay: Bool = false) async {
        let article = item.article

        if !NewsPointsCoordinator.canAccess(article, auth: authManager, viewModel: viewModel) {
            NewsPointsCoordinator.shared.attemptUnlockArticle(article, auth: authManager, viewModel: viewModel) {
                Task { await self.handleArticleTap(item, autoPlay: autoPlay) }
            }
            return
        }

        // ★【补丁·需求b】免费旧新闻阅读计数
        AnonFreeReadTracker.note(article, auth: authManager, viewModel: viewModel)

        let proceedToArticle = {
            await MainActor.run {
                appNavPath?.wrappedValue.append(
                    NavigationTarget.articleDetail(article, self.sourceName, "source", autoPlay))
            }
        }

        // ★【需求6】图片一律后台下载，永不阻塞进入详情页
        if !article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp,
                                                  imageNames: article.images,
                                                  priority: true)
        }
        await proceedToArticle()
    }

    private func autoExpandGroups() {
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        let sortedTimestamps = groupedArticles.keys.sorted(by: >)
        if authManager.isSubscribed {
            viewModel.expandedTimestampsBySource[sourceName] =
                sortedTimestamps.first.map { [$0] } ?? []
        } else {
            if sortedTimestamps.count == 1, let s = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[sourceName] = [s]
            } else {
                viewModel.expandedTimestampsBySource[sourceName] = []
            }
        }
    }
}

// ==================== 全部文章列表 ====================

struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    // @ObservedObject private var supportManager = SupportChatManager.shared
    @EnvironmentObject var authManager: AuthManager

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @Environment(\.appNavPath) var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var showMarkAllReadConfirmation = false
    @State private var showProfileSheet = false
    @State private var hasPerformedAutoExpansion = false

    private var baseFilteredArticles: [ArticleItem] {
        viewModel.allArticlesSortedForDisplay
            .filter { item in
                let isReadEff = viewModel.isArticleEffectivelyRead(item.article)
                return (filterMode == .unread) ? !isReadEff : isReadEff
            }
            .map { ArticleItem(article: $0.article, sourceName: $0.sourceName, sourceNameEN: $0.sourceNameEN) }
    }

    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }

    private var searchResults: [ArticleItem] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.allArticlesSortedForDisplay.compactMap { item -> ArticleItem? in
            if item.article.topic.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName,
                                   sourceNameEN: item.sourceNameEN, isContentMatch: false)
            }
            if item.article.article.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName,
                                   sourceNameEN: item.sourceNameEN, isContentMatch: true)
            }
            return nil
        }
    }

    private func getCount(for mode: ArticleFilterMode) -> Int {
        mode == .unread ? totalUnreadCount : totalReadCount
    }

    private func getFilterTitle(for mode: ArticleFilterMode) -> String {
        "\(mode.localizedName) (\(getCount(for: mode)))"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if isSearching {
                    SearchBarInline(
                        text: $searchText,
                        placeholder: Localized.searchPlaceholder,
                        onCommit: {
                            isSearchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        },
                        onCancel: {
                            withAnimation { isSearching = false; isSearchActive = false; searchText = "" }
                        }
                    )
                }

                if let message = resourceManager.activeNotification {
                    NotificationBannerView(message: message) {
                        resourceManager.dismissNotification()
                    }
                    .background(Color.viewBackground)
                }

                List {
                    if isSearchActive {
                        SearchResultsList(
                            results: searchResults,
                            viewModel: viewModel,
                            authManager: authManager,
                            showEnglish: isGlobalEnglishMode,
                            onArticleTap: { item in await handleArticleTap(item, autoPlay: false) }
                        )
                    } else {
                        ArticleListContent(
                            items: baseFilteredArticles,
                            filterMode: filterMode,
                            expandedTimestamps: viewModel.expandedTimestampsBySource[viewModel.allArticlesKey, default: Set<String>()],
                            viewModel: viewModel,
                            authManager: authManager,
                            showEnglish: isGlobalEnglishMode,
                            onToggleTimestamp: { timestamp in
                                viewModel.toggleTimestampExpansion(for: viewModel.allArticlesKey, timestamp: timestamp)
                            },
                            onPlayTimestamp: { timestamp in
                                if let firstItem = baseFilteredArticles.first(where: { $0.article.timestamp == timestamp }) {
                                    Task { await handleArticleTap(firstItem, autoPlay: true) }
                                }
                            },
                            onArticleTap: { item in await handleArticleTap(item, autoPlay: false) }
                        )
                    }
                }
                .listStyle(PlainListStyle())
                .onAppear {
                    if !hasPerformedAutoExpansion {
                        autoExpandGroups(); hasPerformedAutoExpansion = true
                    }
                    Task { await resourceManager.silentRefresh(minInterval: 60, reason: "all-list-appear") }
                    // // 刷新客服未读状态
                    // Task { 
                    //     await SupportChatManager.shared.refresh(
                    //         userId: SupportIdentity.userId(appleId: authManager.userIdentifier)
                    //     )
                    // }
                }

                if !isSearchActive {
                    HStack(spacing: 8) {
                        Picker("Filter", selection: $filterMode) {
                            ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                                Text(getFilterTitle(for: mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Button { showMarkAllReadConfirmation = true } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 20)).foregroundColor(.blue)
                        }
                    }
                    .padding([.horizontal, .bottom])
                    .onChange(of: filterMode) { _ in autoExpandGroups() }
                }
            }
            .background(Color.viewBackground.ignoresSafeArea())
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                UserStatusToolbarItem(showProfileSheet: $showProfileSheet)
            }
            ToolbarItem(placement: .principal) {
                // 匿名订阅用户 & 未登录用户都不该看到点数胶囊
                if authManager.isLoggedIn && !authManager.isSubscribed { NewsPointsPill() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { withAnimation(.spring()) { isGlobalEnglishMode.toggle() } }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 1.5)
                            .background(!isGlobalEnglishMode ? Color.primary : Color.clear)
                            .clipShape(Circle())
                        Text(isGlobalEnglishMode ? "中" : "英")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(!isGlobalEnglishMode ? Color.viewBackground : Color.primary)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation {
                        isSearching.toggle()
                        if !isSearching { isSearchActive = false; searchText = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass").foregroundColor(.primary)
                }
                .accessibilityLabel(Localized.search)
            }
        }
        // // ➕ 在线客服悬浮按钮
        // .supportBubble(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        // // 独立挂载客服 sheet
        // .background(
        //     Color.clear.sheet(isPresented: $supportManager.showChat) {
        //         SupportChatView(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        //     }
        // )
        .overlay(
            DownloadOverlay(isDownloading: isDownloadingImages,
                            progress: downloadProgress,
                            progressText: downloadProgressText)
        )
        .alert("", isPresented: $showErrorAlert,
               actions: { Button(Localized.confirm, role: .cancel) { } },
               message: { Text(errorMessage) })
        .sheet(isPresented: $showProfileSheet) { UserProfileView() }
        .confirmationDialog(Localized.markAllAsReadConfirm,
                            isPresented: $showMarkAllReadConfirmation,
                            titleVisibility: .visible) {
            Button(Localized.markAllAsRead, role: .destructive) {
                viewModel.markAllAsReadInSource(nil)
            }
            Button(Localized.cancel, role: .cancel) { }
        }
        .onChange(of: authManager.isLoggedIn) { newValue in
            if newValue {
                Task {
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager))
                }
            }
        }
    }

    private func handleArticleTap(_ item: ArticleItem, autoPlay: Bool = false) async {
        let article = item.article
        guard let sourceName = item.sourceName else { return }

        if !NewsPointsCoordinator.canAccess(article, auth: authManager, viewModel: viewModel) {
            NewsPointsCoordinator.shared.attemptUnlockArticle(article, auth: authManager, viewModel: viewModel) {
                Task { await self.handleArticleTap(item, autoPlay: autoPlay) }
            }
            return
        }

        // ★【补丁·需求b】
        AnonFreeReadTracker.note(article, auth: authManager, viewModel: viewModel)

        if !article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp,
                                                  imageNames: article.images,
                                                  priority: true)
        }
        await MainActor.run {
            appNavPath?.wrappedValue.append(
                NavigationTarget.articleDetail(article, sourceName, "all", autoPlay))
        }
    }

    private func autoExpandGroups() {
        let key = viewModel.allArticlesKey
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        let sortedTimestamps = groupedArticles.keys.sorted(by: >)
        if authManager.isSubscribed {
            viewModel.expandedTimestampsBySource[key] = sortedTimestamps.first.map { [$0] } ?? []
        } else {
            if sortedTimestamps.count == 1, let s = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[key] = [s]
            } else {
                viewModel.expandedTimestampsBySource[key] = []
            }
        }
    }
}