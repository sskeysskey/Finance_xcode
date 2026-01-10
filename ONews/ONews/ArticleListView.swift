import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread
    case read
    
    // 获取对应的本地化文本
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
    var isContentMatch: Bool = false // 【新增】增加内容匹配标志，并提供默认值
     
    // 【修改】更新初始化方法以支持 isContentMatch
    init(article: Article, sourceName: String? = nil, isContentMatch: Bool = false) {
        self.id = article.id
        self.article = article
        self.sourceName = sourceName
        self.isContentMatch = isContentMatch
    }
}

struct ArticleListContent: View {
    let items: [ArticleItem]
    let filterMode: ArticleFilterMode
    let expandedTimestamps: Set<String>
    let viewModel: NewsViewModel
    // 【新增】传入 AuthManager 以判断登录状态
    let authManager: AuthManager
    // 【新增】
    let showEnglish: Bool 
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
                            onTap: { await onArticleTap(item) },
                            // 【新增】传递参数
                            showEnglish: showEnglish 
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
    // 【新增】
    let showEnglish: Bool
    let onArticleTap: (ArticleItem) async -> Void
    
    // 【优化】静态 formatter
    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f
    }()
    
    // 【修改】动态获取 Formatter，适配语言切换
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
                            onTap: { await onArticleTap(item) },
                            // 【新增】传递参数
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
    
    // 1. 【新增】接收外部传入的状态
    let showEnglish: Bool
    
    var body: some View {
        Button(action: {
            Task { await onTap() }
        }) {
            let isLocked = !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: item.article.timestamp)
            
            // 【修改】传入 showEnglish 参数
            ArticleRowCardView(
                article: item.article,
                sourceName: item.sourceName,
                isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                isContentMatch: item.isContentMatch,
                isLocked: isLocked,
                // 3. 【修改】使用传入的参数
                showEnglish: showEnglish 
            )
        }
        .buttonStyle(PlainButtonStyle()) // 取消按钮默认点击高亮效果，改用缩放动画（可选）
        .id(item.article.id)
        // 【关键修改】调整内边距，让卡片左右有空隙，上下有间隔
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden) // 隐藏系统分割线
        .listRowBackground(Color.clear) // 列表背景透明
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
            label: { Label(Localized.markAsUnread_text, systemImage: "circle") }
        } else {
            // ✅ 修正：添加了 label: { ... }
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

    // 定义一个渐变色，让日期看起来更有质感（蓝紫色系）
    private let dateGradient = LinearGradient(
        colors: [Color.blue, Color.purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // 【优化】静态 formatter
    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f
    }()
    
    // 【修改】动态获取 Formatter
    private var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = Localized.dateFormatShort
        f.locale = Localized.currentLocale
        return f
    }
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { // 更Q弹的动画
                onToggle()
            }
        }) {
            HStack(spacing: 0) {
                // 1. 左侧装饰条（指示状态）
                Capsule()
                    .fill(isExpanded ? Color.blue : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: 24)
                    .padding(.leading, 12)

                // 2. 日期文字 (带渐变效果)
                Text(formatTimestamp(timestamp))
                    .font(.system(size: 18, weight: .heavy, design: .rounded)) // 更粗的字体
                    .foregroundStyle(isExpanded ? AnyShapeStyle(dateGradient) : AnyShapeStyle(Color.primary.opacity(0.8)))
                    .padding(.leading, 12)
                    .fixedSize(horizontal: true, vertical: false) // 保持你要求的不换行

                Spacer()

                // 3. 右侧信息区 (数量 + 锁 + 箭头)
                HStack(spacing: 8) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    // 数量胶囊
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isExpanded ? .white : .secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule()
                                .fill(isExpanded ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.15))
                        )

                    // 旋转箭头
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.trailing, 12)
            }
            .padding(.vertical, 10)
            // 4. 背景：毛玻璃效果 + 阴影
            .background(.ultraThinMaterial) // iOS 系统级毛玻璃
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            .padding(.horizontal, 3) // 让整个Header左右悬空，不贴边
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

struct ArticleListView: View {
    let sourceName: String // 这是中文名，用于数据库查找
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    // 【新增】获取认证管理器
    @EnvironmentObject var authManager: AuthManager
    // 【新增】引入全局语言状态
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
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
    
    // 【新增】控制未登录 Guest 菜单和已登录 Profile
    @State private var showGuestMenu = false
    @State private var showProfileSheet = false
    
    @State private var hasPerformedAutoExpansion = false
    
    // 【新增】获取当前应显示的标题
    private var displayTitle: String {
        guard let source = source else { return sourceName }
        // 如果是英文模式，返回 source.name_en，否则返回 source.name
        return isGlobalEnglishMode ? source.name_en : source.name
    }
    
    private var source: NewsSource? {
        viewModel.sources.first(where: { $0.name == sourceName })
    }
    
    // 1. 【新增】辅助函数：专门用于获取数量，减轻 View 的负担
    private func getCount(for mode: ArticleFilterMode) -> Int {
        return mode == .unread ? unreadCount : readCount
    } // ✅ 修正：这里补上了丢失的大括号 "}"
    
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
                Text(Localized.sourceUnavailable)
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
                            placeholder: Localized.searchPlaceholder, // 【修改】
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
                                // 【新增】传递状态
                        showEnglish: isGlobalEnglishMode, 
                                onArticleTap: handleArticleTap
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
                        // 2. 【修改】大幅简化 Picker 的写法，解决编译器超时和 scope 找不到的问题
                        Picker("Filter", selection: $filterMode) {
                            ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                                Text("\(mode.localizedName) (\(self.getCount(for: mode)))")
                                    .tag(mode)
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
                        resourceManager: resourceManager,
                        autoPlayOnAppear: false // 【修改】适配新参数
                    )
                }
            }
            // 【修改点】原代码是 sourceName.replacingOccurrences...
            // 改为使用 displayTitle 属性
            .navigationTitle(displayTitle.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 【修改】调用更新后的 UserStatusToolbarItem
                ToolbarItem(placement: .topBarLeading) {
                    UserStatusToolbarItem(
                        showGuestMenu: $showGuestMenu,
                        showProfileSheet: $showProfileSheet
                    )
                }

                // 【新增】中英切换按钮 (放在刷新按钮之前或之后)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        withAnimation(.spring()) {
                            isGlobalEnglishMode.toggle()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 1.5)
                                // 如果是英文模式(true)，背景实心，代表状态激活
                                .background(isGlobalEnglishMode ? Color.primary : Color.clear)
                                .clipShape(Circle())
                            
                            // 【修正文字逻辑】
                            // isGlobalEnglishMode 为 true (英文状态) -> 显示 "中" (提示点击切回中文)
                            // isGlobalEnglishMode 为 false (中文状态) -> 显示 "En" (提示点击切成英文)
                            Text(isGlobalEnglishMode ? "中" : "En") 
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isGlobalEnglishMode ? Color.viewBackground : Color.primary)
                        }
                        .frame(width: 24, height: 24)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await syncResources(isManual: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.primary) // 【添加这行】强制使用黑白色系
                    }
                    .disabled(resourceManager.isSyncing)
                    .accessibilityLabel(Localized.refresh)
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
                            .foregroundColor(.primary) // 【添加这行】强制使用黑白色系
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
            // 【新增】订阅弹窗
            .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
            // 【新增】个人中心 Sheet
            .sheet(isPresented: $showProfileSheet) { UserProfileView() }
            // 【新增】未登录底部菜单 Sheet
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
        
        // --- ✅ 修正后的代码 (中心化逻辑) ---
        // 只要没订阅且被锁定，直接弹订阅页。
        // 如果用户没登录，SubscriptionView 会自己弹登录窗，这里不用管。
        if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: article.timestamp) {
            showSubscriptionSheet = true
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
            downloadProgressText = Localized.imagePrepare
        }
        
        do {
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "\(Localized.imageDownloaded) \(current) / \(total)"
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
                errorMessage = "\(Localized.fetchFailed): \(error.localizedDescription)"
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
    // 【新增】获取认证管理器
    @EnvironmentObject var authManager: AuthManager
    
    // 1. 补上 AppStorage
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
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
    
    // 【新增】状态
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
    
    // MARK: - 核心修复：添加辅助函数
    
    // 修复 1：定义获取数量的函数（使用 totalUnreadCount）
    private func getCount(for mode: ArticleFilterMode) -> Int {
        return mode == .unread ? totalUnreadCount : totalReadCount
    }
    
    // 修复 2：定义获取标题文字的函数（解决编译器超时问题）
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
                
                List {
                    if isSearchActive {
                        SearchResultsList(
                            results: searchResults,
                            viewModel: viewModel,
                            authManager: authManager, // 传递
                            // 【新增】传递状态
                            showEnglish: isGlobalEnglishMode,
                            onArticleTap: handleArticleTap
                        )
                    } else {
                        ArticleListContent(
                            items: baseFilteredArticles,
                            filterMode: filterMode,
                            expandedTimestamps: viewModel.expandedTimestampsBySource[viewModel.allArticlesKey, default: Set<String>()],
                            viewModel: viewModel,
                            authManager: authManager, // 传递
                            // 【新增】传递状态
                            showEnglish: isGlobalEnglishMode,
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
                    // 修复 3：使用 getFilterTitle 简化视图逻辑
                    Picker("Filter", selection: $filterMode) {
                        ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                            Text(getFilterTitle(for: mode)).tag(mode)
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
                    resourceManager: resourceManager,
                    autoPlayOnAppear: false // 【修改】适配新参数
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 【修改】调用更新后的 UserStatusToolbarItem
            ToolbarItem(placement: .topBarLeading) {
                UserStatusToolbarItem(
                    showGuestMenu: $showGuestMenu,
                    showProfileSheet: $showProfileSheet
                )
            }

            // 【新增】中英切换按钮 (放在刷新按钮之前或之后)
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    withAnimation(.spring()) {
                        isGlobalEnglishMode.toggle()
                    }
                }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 1.5)
                            .background(isGlobalEnglishMode ? Color.primary : Color.clear)
                            .clipShape(Circle())
                        
                        // 修正：英文状态显示“中”，中文状态显示“En”
                        Text(isGlobalEnglishMode ? "中" : "En")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isGlobalEnglishMode ? Color.viewBackground : Color.primary)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await syncResources(isManual: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.primary)
                }
                .disabled(resourceManager.isSyncing)
                .accessibilityLabel(Localized.refresh)
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
        // 【新增】
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        // 【新增】Sheet
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
        
        // 【修改后】简化逻辑：只要被锁定，就显示 SubscriptionView
        if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: article.timestamp) {
            showSubscriptionSheet = true
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
            downloadProgressText = Localized.imagePrepare
        }
        
        do {
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "\(Localized.imageDownloaded) \(current) / \(total)"
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
                errorMessage = "\(Localized.fetchFailed): \(error.localizedDescription)"
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
                await MainActor.run { // 建议在主线程更新 UI 状态
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
                    self.showErrorAlert = true // 移出 switch，确保所有错误都弹窗
                }
                print("手动同步失败: \(error)")
            }
        }
    }
}
