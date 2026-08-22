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

    var sortedTimestamps: [String] {
        // 统一降序（新->旧），最新日期显示在最上方
        return groupedArticles.keys.sorted(by: >)
    }

    // 【核心修复】原代码在 header 里引用了内层 ForEach 的 `item`，编译不过。
    // 这里改成：该日期组"受限 且 组内仍有未解锁文章"才显示锁 —— 顺手解决
    // "带锁却能随便点开"（文章已被永久解锁）的显示不一致问题。
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
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f
    }()

    private var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Localized.currentLocale
        f.dateFormat = Localized.dateFormatFull
        return f
    }

    var groupedResults: [String: [ArticleItem]] {
        var initial = Dictionary(grouping: results, by: { $0.article.timestamp })
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

    var sortedTimestamps: [String] {
        groupedResults.keys.sorted(by: >)
    }

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
                        HStack {
                            Text("\(formatTimestamp(timestamp)) (\(groupedResults[timestamp]?.count ?? 0))")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.85))
                            if isGroupLocked(timestamp) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.yellow.opacity(0.8))
                                    .font(.footnote)
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
        Button(action: {
            Task { await onTap() }
        }) {
            // 【修改】已解锁的文章不再显示"需要订阅"标签，避免"带锁却能看"的割裂感
            let isLocked = NewsPointsCoordinator.shouldShowLock(timestamp: item.article.timestamp,
                                                               auth: authManager,
                                                               viewModel: viewModel)
                && !NewsPointsCoordinator.canAccess(item.article,
                                                    auth: authManager,
                                                    viewModel: viewModel)

            ArticleRowCardView(
                article: item.article,
                sourceName: item.sourceName,
                sourceNameEN: item.sourceNameEN,
                isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                isContentMatch: item.isContentMatch,
                isLocked: isLocked,
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
                Button {
                    viewModel.markAsUnread(articleID: item.article.id)
                } label: {
                    Label(Localized.markAsUnread_text, systemImage: "circle")
                }
                .tint(.orange)
            } else {
                Button {
                    viewModel.markAsRead(articleID: item.article.id)
                } label: {
                    Label(Localized.markAsRead_text, systemImage: "checkmark.circle")
                }
                .tint(.blue)
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
                }
                label: { Label(Localized.readAbove, systemImage: "arrow.up.to.line.compact") }

                Button {
                    viewModel.markAllBelowAsRead(articleID: article.id, inVisibleList: filteredArticles)
                }
                label: { Label(Localized.readBelow, systemImage: "arrow.down.to.line.compact") }
            }
        }
    }
}

struct TimestampHeader: View {
    let timestamp: String
    let count: Int
    let isExpanded: Bool
    let isLocked: Bool
    let onToggle: () -> Void
    let onPlay: () -> Void

    private let dateGradient = LinearGradient(
        colors: [Color.blue, Color.purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f
    }()

    private var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = Localized.dateFormatShort
        f.locale = Localized.currentLocale
        return f
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                onToggle()
            }
        }) {
            HStack(spacing: 0) {
                Capsule()
                    .fill(isExpanded ? Color.blue : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: 24)
                    .padding(.leading, 12)

                Text(formatTimestamp(timestamp))
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(isExpanded ? AnyShapeStyle(dateGradient) : AnyShapeStyle(Color.primary.opacity(0.8)))
                    .padding(.leading, 12)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer()

                if count > 0 {
                    Button(action: { onPlay() }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(8)
                            .background(Circle().fill(Color.blue.opacity(0.1)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.trailing, 28)
                }

                HStack(spacing: 8) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isExpanded ? .white : .secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule()
                                .fill(isExpanded ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.15))
                        )

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
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.viewBackground)
    }
}

struct ArticleListView: View {
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @Environment(\.appNavPath) var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var showMarkAllReadConfirmation = false

    @State private var showLoginSheet = false
    @State private var showSubscriptionSheet = false

    @State private var showGuestMenu = false
    @State private var showProfileSheet = false

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
        return mode == .unread ? unreadCount : readCount
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
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let source = source else { return [] }
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

    private var unreadCount: Int {
        guard let source = source else { return 0 }
        return source.articles.filter { !$0.isRead }.count
    }

    private var readCount: Int {
        guard let source = source else { return 0 }
        return source.articles.filter { $0.isRead }.count
    }

    var body: some View {
        if source == nil {
            VStack {
                Text(Localized.sourceUnavailable)
                    .foregroundColor(.secondary)
            }
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
                                    withAnimation {
                                        isSearching = false
                                        isSearchActive = false
                                        searchText = ""
                                    }
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
                                    onArticleTap: { item in
                                        await handleArticleTap(item, autoPlay: false)
                                    }
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
                                    onArticleTap: { item in
                                        await handleArticleTap(item, autoPlay: false)
                                    }
                                )
                            }
                        }
                        .listStyle(PlainListStyle())
                        .onAppear {
                            if !hasPerformedAutoExpansion {
                                autoExpandGroups()
                                hasPerformedAutoExpansion = true
                            }
                            // ★★★【需求1】进入/返回本页 → 静默拉一次服务器（带节流，无任何弹窗）★★★
                            Task { await resourceManager.silentRefresh(minInterval: 60, reason: "source-list-appear") }
                        }

                        if !isSearchActive {
                            HStack(spacing: 8) {
                                Picker("Filter", selection: $filterMode) {
                                    ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                                        Text("\(mode.localizedName) (\(self.getCount(for: mode)))")
                                            .tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Button {
                                    showMarkAllReadConfirmation = true
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding([.horizontal, .bottom])
                            .onChange(of: filterMode) { _ in
                                autoExpandGroups()
                            }
                        }
                    }
                    .background(Color.viewBackground.ignoresSafeArea())
                }
            }
            .navigationTitle(displayTitle.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    UserStatusToolbarItem(
                        showGuestMenu: $showGuestMenu,
                        showProfileSheet: $showProfileSheet
                    )
                }

                ToolbarItem(placement: .principal) {
                    if !authManager.isSubscribed {
                        NewsPointsPill()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        withAnimation(.spring()) {
                            isGlobalEnglishMode.toggle()
                        }
                    }) {
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
                            if !isSearching {
                                isSearchActive = false
                                searchText = ""
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.primary)
                    }
                    .accessibilityLabel(Localized.search)
                }
            }
            .overlay(
                DownloadOverlay(
                    isDownloading: isDownloadingImages,
                    progress: downloadProgress,
                    progressText: downloadProgressText
                )
            )
            .alert("", isPresented: $showErrorAlert, actions: { Button(Localized.confirm, role: .cancel) { } }, message: { Text(errorMessage) })
            .sheet(isPresented: $showLoginSheet) { LoginView() }
            .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
            .sheet(isPresented: $showProfileSheet) { UserProfileView() }
            .sheet(isPresented: $showGuestMenu) {
                VStack(spacing: 20) {
                    Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)
                    Text(Localized.loginWelcome).font(.headline)
                    VStack(spacing: 0) {
                        Button {
                            showGuestMenu = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showLoginSheet = true }
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle").font(.title3).frame(width: 30)
                                Text(Localized.loginAccount).font(.body)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                            }
                            .padding().background(Color(UIColor.secondarySystemGroupedBackground))
                        }
                        Divider().padding(.leading, 50)
                        Button {
                            let email = "728308386@qq.com"
                            if let url = URL(string: "mailto:\(email)"), UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope").font(.title3).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Localized.feedback).foregroundColor(.primary)
                                    Text("728308386@qq.com").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.gray)
                            }
                            .padding().background(Color(UIColor.secondarySystemGroupedBackground))
                        }
                    }
                    .cornerRadius(12).padding(.horizontal)
                    Spacer()
                }
                .background(Color(UIColor.systemGroupedBackground))
                .presentationDetents([.fraction(0.30)])
                .presentationDragIndicator(.hidden)
            }
            .confirmationDialog(
                Localized.markAllAsReadConfirm,
                isPresented: $showMarkAllReadConfirmation,
                titleVisibility: .visible
            ) {
                Button(Localized.markAllAsRead, role: .destructive) {
                    viewModel.markAllAsReadInSource(sourceName)
                }
                Button(Localized.cancel, role: .cancel) { }
            }
            .onChange(of: authManager.showSubscriptionSheet) { newValue in
                self.showSubscriptionSheet = newValue
            }
            .onChange(of: authManager.isLoggedIn) { newValue in
                if newValue == true && self.showLoginSheet {
                    self.showLoginSheet = false
                }
                if newValue == true {
                    Task {
                        await NewsQuotaManager.shared.refresh(
                            userId: NewsQuotaManager.currentUserId(auth: authManager)
                        )
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

        let proceedToArticle = {
            await MainActor.run {
                appNavPath?.wrappedValue.append(
                    NavigationTarget.articleDetail(article, self.sourceName, "source", autoPlay)
                )
            }
        }

        guard !article.images.isEmpty else {
            await proceedToArticle()
            return
        }

        if resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        ) {
            await proceedToArticle()
            return
        }

        if !resourceManager.isNetworkAvailable {
            await proceedToArticle()
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp, imageNames: article.images)
            return
        }

        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = Localized.imagePrepare
            withAnimation(.easeOut(duration: firstImageWaitTimeout)) { downloadProgress = 0.9 }
        }

        await resourceManager.waitForImages(
            timestamp: article.timestamp,
            imageNames: [article.images[0]],
            timeout: firstImageWaitTimeout
        )

        await MainActor.run {
            downloadProgress = 1.0
            isDownloadingImages = false
        }

        await proceedToArticle()

        resourceManager.enqueueImageDownloads(timestamp: article.timestamp, imageNames: article.images)
    }

    private func autoExpandGroups() {
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        let sortedTimestamps = groupedArticles.keys.sorted(by: >)

        if authManager.isSubscribed {
            if let latestTimestamp = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[sourceName] = [latestTimestamp]
            } else {
                viewModel.expandedTimestampsBySource[sourceName] = []
            }
        } else {
            if sortedTimestamps.count == 1, let singleTimestamp = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[sourceName] = [singleTimestamp]
            } else {
                viewModel.expandedTimestampsBySource[sourceName] = []
            }
        }
    }

    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
        } catch {
            if isManual {
                switch error {
                case is DecodingError:
                    self.errorMessage = Localized.parseError
                case let urlError as URLError where
                    urlError.code == .cannotConnectToHost ||
                    urlError.code == .timedOut ||
                    urlError.code == .notConnectedToInternet:
                    self.errorMessage = Localized.networkError
                default:
                    self.errorMessage = Localized.unknownErrorMsg
                }
                self.showErrorAlert = true
                print("手动同步失败: \(error)")
            } else {
                print("自动同步静默失败: \(error)")
            }
        }
    }
}

// ==================== 全部文章列表 ====================

struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @Environment(\.appNavPath) var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var showMarkAllReadConfirmation = false

    @State private var showLoginSheet = false
    @State private var showSubscriptionSheet = false

    @State private var showGuestMenu = false
    @State private var showProfileSheet = false

    @State private var hasPerformedAutoExpansion = false

    // MARK: - 辅助计算属性

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
    private var firstImageWaitTimeout: TimeInterval { 0.0 }

    private var searchResults: [ArticleItem] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return viewModel.allArticlesSortedForDisplay.compactMap { item -> ArticleItem? in
            if item.article.topic.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName, sourceNameEN: item.sourceNameEN, isContentMatch: false)
            }
            if item.article.article.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName, sourceNameEN: item.sourceNameEN, isContentMatch: true)
            }
            return nil
        }
    }

    private func getCount(for mode: ArticleFilterMode) -> Int {
        return mode == .unread ? totalUnreadCount : totalReadCount
    }

    private func getFilterTitle(for mode: ArticleFilterMode) -> String {
        let name = mode.localizedName
        let count = getCount(for: mode)
        return "\(name) (\(count))"
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
                            withAnimation {
                                isSearching = false
                                isSearchActive = false
                                searchText = ""
                            }
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
                            onArticleTap: { item in
                                await handleArticleTap(item, autoPlay: false)
                            }
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
                            onArticleTap: { item in
                                await handleArticleTap(item, autoPlay: false)
                            }
                        )
                    }
                }
                .listStyle(PlainListStyle())
                .onAppear {
                    if !hasPerformedAutoExpansion {
                        autoExpandGroups()
                        hasPerformedAutoExpansion = true
                    }
                    // ★★★【需求1】进入/返回本页 → 静默刷新（带节流）★★★
                    Task { await resourceManager.silentRefresh(minInterval: 60, reason: "all-list-appear") }
                }

                if !isSearchActive {
                    HStack(spacing: 8) {
                        Picker("Filter", selection: $filterMode) {
                            ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                                Text(getFilterTitle(for: mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Button {
                            showMarkAllReadConfirmation = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                        }
                    }
                    .padding([.horizontal, .bottom])
                    .onChange(of: filterMode) { _ in
                        autoExpandGroups()
                    }
                }
            }
            .background(Color.viewBackground.ignoresSafeArea())
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                UserStatusToolbarItem(
                    showGuestMenu: $showGuestMenu,
                    showProfileSheet: $showProfileSheet
                )
            }

            ToolbarItem(placement: .principal) {
                if !authManager.isSubscribed {
                    NewsPointsPill()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    withAnimation(.spring()) {
                        isGlobalEnglishMode.toggle()
                    }
                }) {
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
                        if !isSearching {
                            isSearchActive = false
                            searchText = ""
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.primary)
                }
                .accessibilityLabel(Localized.search)
            }
        }
        .overlay(
            DownloadOverlay(
                isDownloading: isDownloadingImages,
                progress: downloadProgress,
                progressText: downloadProgressText
            )
        )
        .alert("", isPresented: $showErrorAlert, actions: { Button(Localized.confirm, role: .cancel) { } }, message: { Text(errorMessage) })
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .sheet(isPresented: $showProfileSheet) { UserProfileView() }
        .sheet(isPresented: $showGuestMenu) {
            VStack(spacing: 20) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)
                Text(Localized.loginWelcome).font(.headline)
                VStack(spacing: 0) {
                    Button {
                        showGuestMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showLoginSheet = true }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle").font(.title3).frame(width: 30)
                            Text(Localized.loginAccount).font(.body)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                        }
                        .padding().background(Color(UIColor.secondarySystemGroupedBackground))
                    }
                    Divider().padding(.leading, 50)
                    Button {
                        let email = "728308386@qq.com"
                        if let url = URL(string: "mailto:\(email)"), UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "envelope").font(.title3).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Localized.feedback).foregroundColor(.primary)
                                Text("728308386@qq.com").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.gray)
                        }
                        .padding().background(Color(UIColor.secondarySystemGroupedBackground))
                    }
                }
                .cornerRadius(12).padding(.horizontal)
                Spacer()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .presentationDetents([.fraction(0.30)])
            .presentationDragIndicator(.hidden)
        }
        .confirmationDialog(
            Localized.markAllAsReadConfirm,
            isPresented: $showMarkAllReadConfirmation,
            titleVisibility: .visible
        ) {
            Button(Localized.markAllAsRead, role: .destructive) {
                viewModel.markAllAsReadInSource(nil)
            }
            Button(Localized.cancel, role: .cancel) { }
        }
        .onChange(of: authManager.showSubscriptionSheet) { newValue in
            self.showSubscriptionSheet = newValue
        }
        .onChange(of: authManager.isLoggedIn) { newValue in
            if newValue == true && self.showLoginSheet {
                self.showLoginSheet = false
            }
            if newValue == true {
                Task {
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager)
                    )
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

        let proceedToArticle = {
            await MainActor.run {
                appNavPath?.wrappedValue.append(
                    NavigationTarget.articleDetail(article, sourceName, "all", autoPlay)
                )
            }
        }

        guard !article.images.isEmpty else {
            await proceedToArticle()
            return
        }

        if resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        ) {
            await proceedToArticle()
            return
        }

        if !resourceManager.isNetworkAvailable {
            await proceedToArticle()
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp, imageNames: article.images)
            return
        }

        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = Localized.imagePrepare
            withAnimation(.easeOut(duration: firstImageWaitTimeout)) { downloadProgress = 0.9 }
        }

        await resourceManager.waitForImages(
            timestamp: article.timestamp,
            imageNames: [article.images[0]],
            timeout: firstImageWaitTimeout
        )

        await MainActor.run {
            downloadProgress = 1.0
            isDownloadingImages = false
        }

        await proceedToArticle()

        resourceManager.enqueueImageDownloads(timestamp: article.timestamp, imageNames: article.images)
    }

    private func autoExpandGroups() {
        let key = viewModel.allArticlesKey
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        let sortedTimestamps = groupedArticles.keys.sorted(by: >)

        if authManager.isSubscribed {
            if let latestTimestamp = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[key] = [latestTimestamp]
            } else {
                viewModel.expandedTimestampsBySource[key] = []
            }
        } else {
            if sortedTimestamps.count == 1, let singleTimestamp = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[key] = [singleTimestamp]
            } else {
                viewModel.expandedTimestampsBySource[key] = []
            }
        }
    }

    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
        } catch {
            if isManual {
                await MainActor.run {
                    switch error {
                    case is DecodingError:
                        self.errorMessage = Localized.parseError
                    case let urlError as URLError where
                        urlError.code == .cannotConnectToHost ||
                        urlError.code == .timedOut ||
                        urlError.code == .notConnectedToInternet:
                        self.errorMessage = Localized.networkError
                    default:
                        self.errorMessage = Localized.unknownErrorMsg
                    }
                    self.showErrorAlert = true
                }
                print("手动同步失败: \(error)")
            }
        }
    }
}