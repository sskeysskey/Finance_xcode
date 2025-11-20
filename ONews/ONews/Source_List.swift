import SwiftUI

// 【修改】定义导航目标，source 只存储名称
enum NavigationTarget: Hashable {
    case allArticles
    case source(String)  // 只存储源的名称，而不是整个 NewsSource
}

// 【新增】从 ArticleListView.swift 复制过来的下载遮罩视图，用于显示图片下载进度
struct DownloadOverlay: View {
    let isDownloading: Bool
    let progress: Double
    let progressText: String
    
    var body: some View {
        if isDownloading {
            VStack(spacing: 12) {
                Text("正在加载图片...")
                    .font(.headline)
                    .foregroundColor(.white)
                
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .white))
                    .padding(.horizontal, 40)
                
                Text(progressText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.75))
            .edgesIgnoringSafeArea(.all)
        }
    }
}

// 【新增】导航栏用户状态视图
struct UserStatusToolbarItem: View {
    @EnvironmentObject var authManager: AuthManager
    @Binding var showLoginSheet: Bool
    
    var body: some View {
        if authManager.isLoggedIn {
            Menu {
                // 显示订阅状态
                if authManager.isSubscribed {
                    Label("专业版会员", systemImage: "crown.fill")
                } else {
                    Label("免费版用户", systemImage: "person")
                }
                
                if let date = authManager.subscriptionExpiryDate {
                    Text("有效期至: \(date.prefix(10))")
                        .font(.caption)
                }
                
                Divider()
                
                Button(role: .destructive) {
                    authManager.signOut()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                ZStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundColor(.white)
                    // 如果已订阅，加个小皇冠
                    if authManager.isSubscribed {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                            .offset(x: 8, y: -8)
                    }
                }
            }
        } else {
            Button(action: {
                showLoginSheet = true
            }) {
                Image(systemName: "person.circle")
                    .foregroundColor(.white)
            }
            .accessibilityLabel("登录")
        }
    }
}


struct SourceListView: View {
    @EnvironmentObject var viewModel: NewsViewModel
    @EnvironmentObject var resourceManager: ResourceManager
    // 【新增】获取认证管理器
    @EnvironmentObject var authManager: AuthManager
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    @State private var showAddSourceSheet = false
    // 【新增】控制登录弹窗的显示
    @State private var showLoginSheet = false
    // 【新增】
    @State private var showSubscriptionSheet = false
    
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
    // 【新增】用于程序化导航和图片下载的状态变量
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var selectedArticleItem: (article: Article, sourceName: String)?
    @State private var isNavigationActive = false
    
    // 【修改】更新 searchResults 的数据结构和搜索逻辑
    private var searchResults: [(article: Article, sourceName: String, isContentMatch: Bool)] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // 使用 compactMap 来处理更复杂的匹配逻辑
        return viewModel.allArticlesSortedForDisplay.compactMap { item -> (Article, String, Bool)? in
            // 优先匹配标题
            if item.article.topic.lowercased().contains(keyword) {
                return (item.article, item.sourceName, false) // false 表示不是内容匹配
            }
            // 如果标题不匹配，再匹配正文
            if item.article.article.lowercased().contains(keyword) {
                return (item.article, item.sourceName, true) // true 表示是内容匹配
            }
            // 都没有匹配，则返回 nil
            return nil
        }
    }

    // 【修改】更新分组逻辑以适应新的元组结构
    private func groupedSearchByTimestamp() -> [String: [(article: Article, sourceName: String, isContentMatch: Bool)]] {
        var initial = Dictionary(grouping: searchResults, by: { $0.article.timestamp })
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

    // 【修改】更新排序逻辑以适应新的元组结构
    private func sortedSearchTimestamps(for groups: [String: [(article: Article, sourceName: String, isContentMatch: Bool)]]) -> [String] {
        return groups.keys.sorted(by: >)
    }
    
    var body: some View {
        // 【修改】将 NavigationView 升级为 NavigationStack
        NavigationStack {
            VStack(spacing: 0) {
                if isSearching {
                    SearchBarInline(
                        text: $searchText,
                        placeholder: "搜索标题或正文关键字", // 【修改】更新 placeholder
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
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if isSearchActive {
                    searchResultsView
                } else {
                    sourceAndAllArticlesView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Image("welcome_background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.4).ignoresSafeArea())
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 【新增】将用户状态按钮放在最左边
                ToolbarItem(placement: .navigationBarLeading) {
                    UserStatusToolbarItem(showLoginSheet: $showLoginSheet)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        withAnimation {
                            isSearching.toggle()
                            if !isSearching {
                                isSearchActive = false
                                searchText = ""
                            }
                        }
                    }) {
                        Image(systemName: isSearching ? "xmark.circle.fill" : "magnifyingglass")
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("搜索")
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showAddSourceSheet = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await syncResources(isManual: true)
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                    }
                    .disabled(resourceManager.isSyncing)
                }
            }
            .navigationBarTitle(isSearching ? "" : "", displayMode: .inline)
            // 【修改】添加 navigationDestination 来处理所有来自此视图的导航请求
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .allArticles:
                    AllArticlesListView(viewModel: viewModel, resourceManager: resourceManager)
                case .source(let sourceName):
                    ArticleListView(sourceName: sourceName, viewModel: viewModel, resourceManager: resourceManager)
                }
            }
            // 【新增】为搜索结果的程序化导航添加 destination
            .navigationDestination(isPresented: $isNavigationActive) {
                if let item = selectedArticleItem {
                    ArticleContainerView(
                        article: item.article,
                        sourceName: item.sourceName,
                        context: .fromAllArticles, // 搜索结果的上下文视为 "All Articles"
                        viewModel: viewModel,
                        resourceManager: resourceManager
                    )
                }
            }
        }
        .accentColor(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.loadNews()
            Task {
                await syncResources()
            }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: {
            print("AddSourceView 已关闭，重新加载新闻...")
            viewModel.loadNews()
        }) {
            NavigationView {
                AddSourceView(
                    isFirstTimeSetup: false,
                    onConfirm: {
                        print("AddSourceView 确定：关闭并刷新")
                        showAddSourceSheet = false
                    }
                )
            }
            .preferredColorScheme(.dark)
            .environmentObject(resourceManager)
        }
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
        .overlay(
            // 【修改】将两个遮罩层组合在一起，避免互相覆盖
            ZStack {
                // 原有的同步状态遮罩
                if resourceManager.isSyncing {
                    VStack(spacing: 15) {
                        if resourceManager.syncMessage == "当前已是最新" || resourceManager.syncMessage == "新闻清单已是最新。" {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                            
                            Text(resourceManager.syncMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        else if resourceManager.isDownloading {
                            Text(resourceManager.syncMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            ProgressView(value: resourceManager.downloadProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .white))
                                .padding(.horizontal, 50)
                            
                            Text(resourceManager.progressText)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            
                            Text(resourceManager.syncMessage)
                                .padding(.top, 10)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
                    .edgesIgnoringSafeArea(.all)
                    .contentShape(Rectangle())
                }
                
                // 【新增】图片下载遮罩
                DownloadOverlay(
                    isDownloading: isDownloadingImages,
                    progress: downloadProgress,
                    progressText: downloadProgressText
                )
            }
        )
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    private var searchResultsView: some View {
        List {
            let grouped = groupedSearchByTimestamp()
            let timestamps = sortedSearchTimestamps(for: grouped)

            if searchResults.isEmpty {
                Section {
                    Text("未找到匹配的文章")
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("搜索结果")
                        .font(.headline)
                        .foregroundColor(.blue.opacity(0.7))
                        .padding(.vertical, 4)
                }
            } else {
                ForEach(timestamps, id: \.self) { timestamp in
                    Section(header:
                        VStack(alignment: .leading, spacing: 2) {
                            Text("搜索结果")
                                .font(.subheadline)
                                .foregroundColor(.blue.opacity(0.7))
                            Text("\(formatTimestamp(timestamp)) (\(grouped[timestamp]?.count ?? 0))")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.85))
                        }
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    ) {
                        // 【核心修改】将 NavigationLink 替换为 Button，并调用 handleArticleTap
                        ForEach(grouped[timestamp] ?? [], id: \.article.id) { item in
                            Button(action: {
                                Task { await handleArticleTap(item) }
                            }) {
                                // 【修改】传递锁定状态
                                let isLocked = !authManager.isLoggedIn && viewModel.isTimestampLocked(timestamp: item.article.timestamp)
                                ArticleRowCardView(
                                    article: item.article,
                                    sourceName: item.sourceName,
                                    isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                                    isContentMatch: item.isContentMatch,
                                    isLocked: isLocked
                                )
                                .colorScheme(.dark)
                            }
                            .buttonStyle(PlainButtonStyle()) // 使用 PlainButtonStyle 避免 List 行的默认按钮样式
                            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                if item.article.isRead {
                                    Button { viewModel.markAsUnread(articleID: item.article.id) }
                                    label: { Label("标记为未读", systemImage: "circle") }
                                } else {
                                    Button { viewModel.markAsRead(articleID: item.article.id) }
                                    label: { Label("标记为已读", systemImage: "checkmark.circle") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .transition(.opacity.animation(.easeInOut))
    }
    
    private var sourceAndAllArticlesView: some View {
        Group {
            if SubscriptionManager.shared.subscribedSources.isEmpty && !resourceManager.isSyncing {
                VStack(spacing: 20) {
                    Text("您还没有订阅任何新闻源")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))
                    Button(action: { showAddSourceSheet = true }) {
                        Label("点击这里添加", systemImage: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    // 【修改】使用新的 value-based NavigationLink
                    NavigationLink(value: NavigationTarget.allArticles) {
                        HStack {
                            Text("ALL")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(viewModel.totalUnreadCount)")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    
                    ForEach(viewModel.sources) { source in
                        NavigationLink(value: NavigationTarget.source(source.name)) {
                            HStack {
                                Text(source.name)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(source.unreadCount)")
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .transition(.opacity.animation(.easeInOut))
    }
    
    // 【新增】处理文章点击和图片下载的函数
    private func handleArticleTap(_ item: (article: Article, sourceName: String, isContentMatch: Bool)) async {
        let article = item.article
        let sourceName = item.sourceName
        
        // 【修改】锁定检查：未订阅 且 被锁定
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
        
        // 2. 检查图片是否已在本地存在
        let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        )
        
        // 3. 如果图片已存在，直接导航
        if imagesAlreadyExist {
            await MainActor.run {
                selectedArticleItem = (article, sourceName)
                isNavigationActive = true
            }
            return
        }
        
        // 4. 如果图片不存在，开始下载流程
        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = "准备中..."
        }
        
        do {
            // 调用下载方法，并传入进度更新的闭包
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    // 这个闭包会在主线程上被调用，可以直接更新UI状态
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "已下载 \(current) / \(total)"
                }
            )
            
            // 5. 下载成功后，隐藏遮罩并执行导航
            await MainActor.run {
                isDownloadingImages = false
                selectedArticleItem = (article, sourceName)
                isNavigationActive = true
            }
        } catch {
            // 6. 下载失败，隐藏遮罩并显示错误提示
            await MainActor.run {
                isDownloadingImages = false
                errorMessage = "图片下载失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }
    
    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            // 【修改】同步完成后，确保 ViewModel 也更新了配置
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
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}