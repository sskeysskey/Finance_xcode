import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread = "未读"
    case read = "已读"
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
    var isContentMatch: Bool = false // 【新增】增加内容匹配标志，并提供默认值
     
    // 【修改】更新初始化方法以支持 isContentMatch
    init(article: Article, sourceName: String? = nil, isContentMatch: Bool = false) {
        self.id = article.id
        self.article = article
        self.sourceName = sourceName
        self.isContentMatch = isContentMatch
    }
}

extension ArticleListDataSource {
    func groupedByTimestamp(_ items: [ArticleItem]) -> [String: [ArticleItem]] {
        let initial = Dictionary(grouping: items, by: { $0.article.timestamp })
        // 【修改】对于未读列表，内部文章顺序保持不变（通常是按 topic 字母序）；对于已读列表，反转顺序以将最新阅读的放在分组顶部。
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }
    
    func sortedTimestamps(for groups: [String: [ArticleItem]]) -> [String] {
        // 【修改】统一将日期分组排序改为降序（新->旧）。
        // 无论是在 'read' 还是 'unread' 模式下，都显示最新的日期分组在最上方。
        return groups.keys.sorted(by: >)
    }
}

// ==================== 共享组件 ====================
struct ArticleListContent: View {
    let items: [ArticleItem]
    let filterMode: ArticleFilterMode
    let expandedTimestamps: Set<String>
    let viewModel: NewsViewModel
    // 【新增】传入 AuthManager 以判断登录状态
    let authManager: AuthManager
    let onToggleTimestamp: (String) -> Void
    let onArticleTap: (ArticleItem) async -> Void
    
    var groupedArticles: [String: [ArticleItem]] {
        let initial = Dictionary(grouping: items, by: { $0.article.timestamp })
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }
    
    var sortedTimestamps: [String] {
        // 【修改】统一将日期分组排序改为降序（新->旧）。
        // 这样未读列表也会将最新的日期显示在最上方。
        return groupedArticles.keys.sorted(by: >)
    }
    
    var body: some View {
        ForEach(sortedTimestamps, id: \.self) { timestamp in
            Section {
                if expandedTimestamps.contains(timestamp) {
                    ForEach(groupedArticles[timestamp] ?? []) { item in
                        // 【修改】将 authManager 传递下去
                        ArticleRowButton(
                            item: item,
                            filterMode: filterMode,
                            viewModel: viewModel,
                            authManager: authManager,
                            filteredArticles: items,
                            onTap: { await onArticleTap(item) }
                        )
                    }
                }
            } header: {
                // 【修改】锁定条件：未订阅 且 时间戳被锁定
                let isLocked = !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: timestamp)
                TimestampHeader(
                    timestamp: timestamp,
                    count: groupedArticles[timestamp]?.count ?? 0,
                    isExpanded: expandedTimestamps.contains(timestamp),
                    isLocked: isLocked, // 传递锁定状态
                    onToggle: { onToggleTimestamp(timestamp) }
                )
            }
        }
    }
}

struct SearchResultsList: View {
    let results: [ArticleItem]
    let viewModel: NewsViewModel
    // 【新增】传入 AuthManager
    let authManager: AuthManager
    let onArticleTap: (ArticleItem) async -> Void
    
    var groupedResults: [String: [ArticleItem]] {
        var initial = Dictionary(grouping: results, by: { $0.article.timestamp })
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }
    
    var sortedTimestamps: [String] {
        groupedResults.keys.sorted(by: >)
    }
    
    var body: some View {
        if results.isEmpty {
            Section {
                Text("未找到匹配的文章")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            } header: {
                Text("搜索结果")
                    .font(.headline)
                    .foregroundColor(.blue.opacity(0.7))
                    .padding(.vertical, 4)
            }
        } else {
            ForEach(sortedTimestamps, id: \.self) { timestamp in
                Section(header:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("搜索结果")
                            .font(.subheadline)
                            .foregroundColor(.blue.opacity(0.7))
                        HStack {
                            Text("\(formatTimestamp(timestamp)) (\(groupedResults[timestamp]?.count ?? 0))")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.85))
                            // 【修改】锁定条件：未订阅 且 时间戳被锁定
                            if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: timestamp) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.yellow.opacity(0.8))
                                    .font(.footnote)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                ) {
                    ForEach(groupedResults[timestamp] ?? []) { item in
                        // 【修改】传递 authManager
                        ArticleRowButton(
                            item: item,
                            filterMode: .unread, // 搜索结果统一按未读模式处理上下文菜单
                            viewModel: viewModel,
                            authManager: authManager,
                            filteredArticles: [],
                            onTap: { await onArticleTap(item) }
                        )
                    }
                }
            }
        }
    }
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}

struct ArticleRowButton: View {
    let item: ArticleItem
    let filterMode: ArticleFilterMode
    let viewModel: NewsViewModel
    // 【新增】传入 AuthManager
    let authManager: AuthManager
    let filteredArticles: [ArticleItem]
    let onTap: () async -> Void
    
    var body: some View {
        Button(action: {
            Task { await onTap() }
        }) {
            // 【修改】锁定条件：未订阅 且 时间戳被锁定
            let isLocked = !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: item.article.timestamp)
            ArticleRowCardView(
                article: item.article,
                sourceName: item.sourceName,
                isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                isContentMatch: item.isContentMatch,
                isLocked: isLocked // 传递锁定状态
            )
        }
        .buttonStyle(PlainButtonStyle())
        .id(item.article.id)
        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
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
    }
}

struct ArticleContextMenu: View {
    let article: Article
    let filterMode: ArticleFilterMode
    let viewModel: NewsViewModel
    let filteredArticles: [Article]
    
    var body: some View {
        if article.isRead {
            Button { viewModel.markAsUnread(articleID: article.id) }
            label: { Label("标记为未读", systemImage: "circle") }
        } else {
            Button { viewModel.markAsRead(articleID: article.id) }
            label: { Label("标记为已读", systemImage: "checkmark.circle") }
            
            if filterMode == .unread && !filteredArticles.isEmpty {
                Divider()
                Button {
                    viewModel.markAllAboveAsRead(articleID: article.id, inVisibleList: filteredArticles)
                }
                label: { Label("以上全部已读", systemImage: "arrow.up.to.line.compact") }
                
                Button {
                    viewModel.markAllBelowAsRead(articleID: article.id, inVisibleList: filteredArticles)
                }
                label: { Label("以下全部已读", systemImage: "arrow.down.to.line.compact") }
            }
        }
    }
}

struct TimestampHeader: View {
    let timestamp: String
    let count: Int
    let isExpanded: Bool
    // 【新增】接收锁定状态
    let isLocked: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // 【新增】如果锁定，显示锁图标
            if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundColor(.yellow.opacity(0.8))
                    .font(.callout)
                    .transition(.opacity)
            }
            
            Text(formatTimestamp(timestamp))
                .font(.headline)
                .foregroundColor(.blue.opacity(0.7))
            
            Spacer(minLength: 8)
            
            Text("\(count)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .foregroundColor(.secondary)
                .font(.footnote.weight(.semibold))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                onToggle()
            }
        }
    }
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}

// ==================== 单一来源列表 ====================
struct ArticleListView: View {
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    // 【新增】获取认证管理器
    @EnvironmentObject var authManager: AuthManager
    
    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var selectedArticle: Article?
    @State private var isNavigationActive = false
    // 【新增】控制登录弹窗
    @State private var showLoginSheet = false
    // 【新增】控制订阅弹窗
    @State private var showSubscriptionSheet = false
    
    // 【修复需求】新增一个状态变量，用于记录是否已经执行过初始的自动展开逻辑
    @State private var hasPerformedAutoExpansion = false
    
    private var source: NewsSource? {
        viewModel.sources.first(where: { $0.name == sourceName })
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
    
    // 【修改】更新搜索逻辑
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
                Text("新闻源不再可用")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 【修改】使用系统背景
            .background(Color.viewBackground.ignoresSafeArea())
        } else {
            ZStack {
                VStack(spacing: 0) {
                    if isSearching {
                        SearchBarInline(
                            text: $searchText,
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
                    
                    List {
                        if isSearchActive {
                            SearchResultsList(
                                results: searchResults,
                                viewModel: viewModel,
                                authManager: authManager, // 传递
                                onArticleTap: handleArticleTap
                            )
                        } else {
                            ArticleListContent(
                                items: baseFilteredArticles,
                                filterMode: filterMode,
                                expandedTimestamps: viewModel.expandedTimestampsBySource[sourceName, default: Set<String>()],
                                viewModel: viewModel,
                                authManager: authManager, // 传递
                                onToggleTimestamp: { timestamp in
                                    viewModel.toggleTimestampExpansion(for: sourceName, timestamp: timestamp)
                                },
                                onArticleTap: handleArticleTap
                            )
                        }
                    }
                    .listStyle(PlainListStyle())
                    // 【修复需求】修改 onAppear 逻辑：仅在首次进入时执行自动展开
                    .onAppear {
                        if !hasPerformedAutoExpansion {
                            autoExpandGroups()
                            hasPerformedAutoExpansion = true
                        }
                    }
                    
                    if !isSearchActive {
                        Picker("Filter", selection: $filterMode) {
                            ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                                let count = (mode == .unread) ? unreadCount : readCount
                                Text("\(mode.rawValue) (\(count))").tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding([.horizontal, .bottom])
                        // 【修改】当筛选模式改变时，强制重新执行自动展开逻辑（无视 hasPerformedAutoExpansion）
                        .onChange(of: filterMode) { _, _ in
                            autoExpandGroups()
                        }
                    }
                }
                .background(Color.viewBackground.ignoresSafeArea())
            }
            .navigationDestination(isPresented: $isNavigationActive) {
                if let article = selectedArticle {
                    ArticleContainerView(
                        article: article,
                        sourceName: sourceName,
                        context: .fromSource(sourceName),
                        viewModel: viewModel,
                        resourceManager: resourceManager
                    )
                }
            }
            .navigationTitle(sourceName.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 【新增】用户状态工具栏按钮
                ToolbarItem(placement: .topBarLeading) {
                    UserStatusToolbarItem(showLoginSheet: $showLoginSheet)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await syncResources(isManual: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(resourceManager.isSyncing)
                    .accessibilityLabel("刷新")
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
                    }
                    .accessibilityLabel("搜索")
                }
            }
            .overlay(
                DownloadOverlay(
                    isDownloading: isDownloadingImages,
                    progress: downloadProgress,
                    progressText: downloadProgressText
                )
            )
            .alert("", isPresented: $showErrorAlert, actions: { Button("好的", role: .cancel) { } }, message: { Text(errorMessage) })
            .sheet(isPresented: $showLoginSheet) { LoginView() }
            // 【新增】订阅弹窗
            .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
            // 【修改】监听 AuthManager 的 showSubscriptionSheet 信号
            .onChange(of: authManager.showSubscriptionSheet) { _, newValue in
                self.showSubscriptionSheet = newValue
            }
            .onChange(of: authManager.isLoggedIn) { _, newValue in
                // 当登录状态变为 true (表示登录成功) 并且登录弹窗正显示时
                if newValue == true && self.showLoginSheet {
                    // 自动关闭登录弹窗
                    self.showLoginSheet = false
                    print("登录成功，自动关闭 LoginView。")
                }
            }
        }
    }
    
    private func handleArticleTap(_ item: ArticleItem) async {
        let article = item.article
        
        // 【修改】点击文章时的锁定检查：未订阅 且 被锁定
        if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: article.timestamp) {
            if !authManager.isLoggedIn {
                // 如果没登录，先登录
                showLoginSheet = true
            } else {
                // 如果已登录但没订阅，显示订阅页
                showSubscriptionSheet = true
            }
            return
        }
        
        guard !article.images.isEmpty else {
            selectedArticle = article
            isNavigationActive = true
            return
        }
        
        let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        )
        
        if imagesAlreadyExist {
            await MainActor.run {
                selectedArticle = article
                isNavigationActive = true
            }
            return
        }
        
        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = "准备中..."
        }
        
        do {
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "已下载 \(current) / \(total)"
                }
            )
            
            await MainActor.run {
                isDownloadingImages = false
                selectedArticle = article
                isNavigationActive = true
            }
        } catch {
            await MainActor.run {
                isDownloadingImages = false
                errorMessage = "图片下载失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    // 【修改】新的自动展开逻辑：根据当前过滤后的文章数量动态决定
    private func autoExpandGroups() {
        // 1. 获取当前模式下（未读/已读）的所有日期分组
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        
        // 2. 核心逻辑：如果只有一个分组，则展开；如果有多个，则全部折叠（清空展开集合）
        if groupedArticles.keys.count == 1, let singleTimestamp = groupedArticles.keys.first {
            viewModel.expandedTimestampsBySource[sourceName] = [singleTimestamp]
        } else {
            // 如果大于1个分组，强制折叠所有（清空集合）
            // 这样每次切换模式或进入页面，如果分组多，就会自动收起，符合你的需求
            viewModel.expandedTimestampsBySource[sourceName] = []
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
                    self.errorMessage = "数据解析失败,请稍后重试。"
                    self.showErrorAlert = true
                case let urlError as URLError where
                    urlError.code == .cannotConnectToHost ||
                    urlError.code == .timedOut ||
                    urlError.code == .notConnectedToInternet:
                    self.errorMessage = "网络连接失败，请检查网络设置或稍后重试。"
                    self.showErrorAlert = true
                default:
                    self.errorMessage = "发生未知错误，请稍后重试。"
                    self.showErrorAlert = true
                }
                print("手动同步失败: \(error)")
            } else {
                print("自动同步静默失败: \(error)")
            }
        }
    }
}

// ==================== 所有文章列表 ====================
// AllArticlesListView 的修改逻辑与 ArticleListView 完全一致，主要是替换锁定判断条件
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    // 【新增】获取认证管理器
    @EnvironmentObject var authManager: AuthManager
    
    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var selectedArticleItem: (article: Article, sourceName: String)?
    @State private var isNavigationActive = false
    // 【新增】控制登录弹窗
    @State private var showLoginSheet = false
    // 【新增】
    @State private var showSubscriptionSheet = false
    
    // 【修复需求】新增一个状态变量，用于记录是否已经执行过初始的自动展开逻辑
    @State private var hasPerformedAutoExpansion = false
    
    private var baseFilteredArticles: [ArticleItem] {
        viewModel.allArticlesSortedForDisplay
            .filter { item in
                let isReadEff = viewModel.isArticleEffectivelyRead(item.article)
                return (filterMode == .unread) ? !isReadEff : isReadEff
            }
            .map { ArticleItem(article: $0.article, sourceName: $0.sourceName) }
    }
    
    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }
    
    // 【修改】更新搜索逻辑
    private var searchResults: [ArticleItem] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        return viewModel.allArticlesSortedForDisplay.compactMap { item -> ArticleItem? in
            if item.article.topic.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName, isContentMatch: false)
            }
            if item.article.article.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName, isContentMatch: true)
            }
            return nil
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if isSearching {
                    SearchBarInline(
                        text: $searchText,
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
                
                List {
                    if isSearchActive {
                        SearchResultsList(
                            results: searchResults,
                            viewModel: viewModel,
                            authManager: authManager, // 传递
                            onArticleTap: handleArticleTap
                        )
                    } else {
                        ArticleListContent(
                            items: baseFilteredArticles,
                            filterMode: filterMode,
                            expandedTimestamps: viewModel.expandedTimestampsBySource[viewModel.allArticlesKey, default: Set<String>()],
                            viewModel: viewModel,
                            authManager: authManager, // 传递
                            onToggleTimestamp: { timestamp in
                                viewModel.toggleTimestampExpansion(for: viewModel.allArticlesKey, timestamp: timestamp)
                            },
                            onArticleTap: handleArticleTap
                        )
                    }
                }
                .listStyle(PlainListStyle())
                // 【修复需求】修改 onAppear 逻辑：仅在首次进入时执行自动展开
                .onAppear {
                    if !hasPerformedAutoExpansion {
                        autoExpandGroups()
                        hasPerformedAutoExpansion = true
                    }
                }
                
                if !isSearchActive {
                    Picker("Filter", selection: $filterMode) {
                        ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                            let count = (mode == .unread) ? totalUnreadCount : totalReadCount
                            Text("\(mode.rawValue) (\(count))").tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding([.horizontal, .bottom])
                    // 【修改】当筛选模式改变时，强制重新执行自动展开逻辑（无视 hasPerformedAutoExpansion）
                    .onChange(of: filterMode) { _, _ in
                        autoExpandGroups()
                    }
                }
            }
            .background(Color.viewBackground.ignoresSafeArea())
        }
        .navigationDestination(isPresented: $isNavigationActive) {
            if let item = selectedArticleItem {
                ArticleContainerView(
                    article: item.article,
                    sourceName: item.sourceName,
                    context: .fromAllArticles,
                    viewModel: viewModel,
                    resourceManager: resourceManager
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 【新增】用户状态工具栏按钮
            ToolbarItem(placement: .topBarLeading) {
                UserStatusToolbarItem(showLoginSheet: $showLoginSheet)
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await syncResources(isManual: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(resourceManager.isSyncing)
                .accessibilityLabel("刷新")
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
                }
                .accessibilityLabel("搜索")
            }
        }
        .overlay(
            DownloadOverlay(
                isDownloading: isDownloadingImages,
                progress: downloadProgress,
                progressText: downloadProgressText
            )
        )
        .alert("", isPresented: $showErrorAlert, actions: { Button("好的", role: .cancel) { } }, message: { Text(errorMessage) })
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        // 【新增】
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onChange(of: authManager.showSubscriptionSheet) { _, newValue in
            self.showSubscriptionSheet = newValue
        }
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            // 当登录状态变为 true (表示登录成功) 并且登录弹窗正显示时
            if newValue == true && self.showLoginSheet {
                // 自动关闭登录弹窗
                self.showLoginSheet = false
                print("登录成功，自动关闭 LoginView。")
            }
        }
    }
    
    private func handleArticleTap(_ item: ArticleItem) async {
        let article = item.article
        guard let sourceName = item.sourceName else { return }
        
        // 【修改】锁定检查
        if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: article.timestamp) {
            if !authManager.isLoggedIn {
                showLoginSheet = true
            } else {
                showSubscriptionSheet = true
            }
            return
        }
        
        guard !article.images.isEmpty else {
            selectedArticleItem = (article, sourceName)
            isNavigationActive = true
            return
        }
        
        let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        )
        
        if imagesAlreadyExist {
            await MainActor.run {
                selectedArticleItem = (article, sourceName)
                isNavigationActive = true
            }
            return
        }
        
        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = "准备中..."
        }
        
        do {
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "已下载 \(current) / \(total)"
                }
            )
            
            await MainActor.run {
                isDownloadingImages = false
                selectedArticleItem = (article, sourceName)
                isNavigationActive = true
            }
        } catch {
            await MainActor.run {
                isDownloadingImages = false
                errorMessage = "图片下载失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    // 【修改】新的自动展开逻辑
    private func autoExpandGroups() {
        let key = viewModel.allArticlesKey
        
        // 1. 获取当前模式下（未读/已读）的所有日期分组
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        
        // 2. 核心逻辑：如果只有一个分组，则展开；如果有多个，则全部折叠
        if groupedArticles.keys.count == 1, let singleTimestamp = groupedArticles.keys.first {
            viewModel.expandedTimestampsBySource[key] = [singleTimestamp]
        } else {
            viewModel.expandedTimestampsBySource[key] = []
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
                    self.errorMessage = "数据解析失败，请稍后重试。"
                    self.showErrorAlert = true
                case let urlError as URLError where
                    urlError.code == .cannotConnectToHost ||
                    urlError.code == .timedOut ||
                    urlError.code == .notConnectedToInternet:
                    self.errorMessage = "网络连接失败，请检查网络设置或稍后重试。"
                    self.showErrorAlert = true
                default:
                    self.errorMessage = "发生未知错误，请稍后重试。"
                    self.showErrorAlert = true
                }
                print("手动同步失败: \(error)")
            } else {
                print("自动同步静默失败: \(error)")
            }
        }
    }
}