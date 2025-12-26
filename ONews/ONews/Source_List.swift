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

// MARK: - 【新增】个人中心视图 (User Profile)
struct UserProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                // 1. 用户信息部分
                Section {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        VStack(alignment: .leading, spacing: 4) {
                            if authManager.isSubscribed {
                                Text("专业版会员")
                                    .font(.subheadline)
                                    .foregroundColor(.yellow)
                                    .bold()
                                if let date = authManager.subscriptionExpiryDate {
                                    Text("有效期至: \(date.prefix(10))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("免费版用户")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            if let userId = authManager.userIdentifier {
                                Text("ID: \(userId.prefix(6))...")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            } else {
                                Text("未登录")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 10)
                }
                
                // 2. 支持与反馈部分 (类似 Finance App)
                Section(header: Text("支持与反馈")) {
                    Button {
                        let email = "728308386@qq.com"
                        // 使用 mailto 协议唤起邮件客户端
                        if let url = URL(string: "mailto:\(email)") {
                            if UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("问题反馈")
                                    .foregroundColor(.primary)
                                Text("728308386@qq.com")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            // 加一个图标提示用户可以点击
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .contextMenu {
                        // 长按复制邮箱
                        Button {
                            UIPasteboard.general.string = "728308386@qq.com"
                        } label: {
                            Label("复制邮箱地址", systemImage: "doc.on.doc")
                        }
                    }
                }
                
                // 3. 退出登录部分
                Section {
                    if authManager.isLoggedIn {
                        Button(role: .destructive) {
                            authManager.signOut()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("退出登录")
                            }
                        }
                    }
                }
            }
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 【修改】导航栏用户状态视图
// 修改逻辑：不再直接传入 showLoginSheet，而是传入两个 Sheet 的控制状态
struct UserStatusToolbarItem: View {
    @EnvironmentObject var authManager: AuthManager
    
    // 接收两个绑定的状态
    @Binding var showGuestMenu: Bool
    @Binding var showProfileSheet: Bool
    
    var body: some View {
        Button(action: {
            if authManager.isLoggedIn {
                // 已登录：显示个人中心
                showProfileSheet = true
            } else {
                // 未登录：显示底部 Guest 菜单
                showGuestMenu = true
            }
        }) {
            if authManager.isLoggedIn {
                HStack(spacing: 6) {
                    Image(systemName: "person.circle.fill")
                        .font(.body)
                    Text(authManager.isSubscribed ? "PRO" : "User")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundColor(.primary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "person.circle")
                    Text("登录")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundColor(.primary)
            }
        }
        .accessibilityLabel(authManager.isLoggedIn ? "个人中心" : "登录或反馈")
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
    
    // 【新增】控制未登录用户的底部菜单
    @State private var showGuestMenu = false
    // 【新增】控制已登录用户的个人中心
    @State private var showProfileSheet = false
    
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
    // 用于程序化导航和图片下载的状态变量
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var selectedArticleItem: (article: Article, sourceName: String)?
    @State private var isNavigationActive = false
    
    // 静态 formatter
    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f
    }()
    
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日, EEEE"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
    
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
                // 搜索栏
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
                    .padding(.bottom, 8)
                    .background(Color.viewBackground)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if isSearchActive {
                    searchResultsView
                } else {
                    sourceAndAllArticlesView
                }
            }
            // 【修改】使用系统背景色
            .background(Color.viewBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 【修改】将用户状态按钮更新为新的逻辑
                ToolbarItem(placement: .navigationBarLeading) {
                    UserStatusToolbarItem(
                        showGuestMenu: $showGuestMenu,
                        showProfileSheet: $showProfileSheet
                    )
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation {
                                isSearching.toggle()
                                if !isSearching { isSearchActive = false; searchText = "" }
                            }
                        } label: {
                            Image(systemName: isSearching ? "xmark.circle.fill" : "magnifyingglass")
                                .font(.system(size: 16, weight: .medium))
                        }
                        
                        Button { showAddSourceSheet = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                        }
                        
                        Button {
                            Task { await syncResources(isManual: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .disabled(resourceManager.isSyncing)
                    }
                    .foregroundColor(.primary)
                }
            }
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
        .tint(.blue)
        .onAppear {
            viewModel.loadNews()
            Task { await syncResources() }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: { viewModel.loadNews() }) {
            NavigationView {
                AddSourceView(isFirstTimeSetup: false)
            }
            .environmentObject(resourceManager)
        }
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        // 【新增】
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        // 【新增】个人中心 Sheet
        .sheet(isPresented: $showProfileSheet) { UserProfileView() }
        // 【新增】未登录底部菜单 Sheet (仿 Finance)
        .sheet(isPresented: $showGuestMenu) {
            VStack(spacing: 20) {
                // 顶部小横条
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                
                Text("欢迎使用 ONews")
                    .font(.headline)
                
                VStack(spacing: 0) {
                    // 选项 1：登录
                    Button {
                        showGuestMenu = false // 先关闭菜单
                        // 延迟一点点再打开登录页
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showLoginSheet = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .font(.title3)
                                .frame(width: 30)
                            Text("登录账户")
                                .font(.body)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                    }
                    
                    Divider().padding(.leading, 50)
                    
                    // 选项 2：问题反馈
                    Button {
                        let email = "728308386@qq.com"
                        if let url = URL(string: "mailto:\(email)") {
                            if UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "envelope")
                                .font(.title3)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("问题反馈")
                                    .foregroundColor(.primary)
                                Text("728308386@qq.com")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                    }
                }
                .cornerRadius(12)
                .padding(.horizontal)
                
                Spacer()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .presentationDetents([.fraction(0.30)]) // 只占据底部 30%
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
        .overlay(
            // 【修改】将两个遮罩层组合在一起，避免互相覆盖
            ZStack {
                // 原有的同步状态遮罩
                if resourceManager.isSyncing {
                    // 简单的同步 HUD
                    VStack(spacing: 15) {
                        if resourceManager.syncMessage.contains("最新") {
                            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundColor(.white)
                            Text(resourceManager.syncMessage).font(.headline).foregroundColor(.white)
                        } else if resourceManager.isDownloading {
                            Text(resourceManager.syncMessage).font(.headline).foregroundColor(.white)
                            ProgressView(value: resourceManager.downloadProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .white))
                                .padding(.horizontal, 50)
                        } else {
                            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(1.2)
                            Text("正在同步...").foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .frame(width: 200, height: 160) // 小巧的 HUD 尺寸
                    .background(Material.ultraThinMaterial)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(20)
                }
                
                DownloadOverlay(isDownloading: isDownloadingImages, progress: downloadProgress, progressText: downloadProgressText)
            }
        )
        .alert("", isPresented: $showErrorAlert, actions: { Button("好的", role: .cancel) { } }, message: { Text(errorMessage) })
    }
    
    // MARK: - 搜索结果视图 (使用新的卡片)
    private var searchResultsView: some View {
        List {
            let grouped = groupedSearchByTimestamp()
            let timestamps = sortedSearchTimestamps(for: grouped)
            
            if searchResults.isEmpty {
                Section {
                    Text("未找到匹配的文章")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(timestamps, id: \.self) { timestamp in
                    Section(header:
                        HStack {
                            Text("搜索结果")
                            Spacer()
                            Text(formatTimestamp(timestamp))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    ) {
                        // 【核心修改】将 NavigationLink 替换为 Button，并调用 handleArticleTap
                        ForEach(grouped[timestamp] ?? [], id: \.article.id) { item in
                            Button(action: {
                                Task { await handleArticleTap(item) }
                            }) {
                                // 【修改】传递锁定状态
                                // 应该判断是否订阅 (!isSubscribed)
                                let isLocked = !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: item.article.timestamp)
                                ArticleRowCardView(
                                    article: item.article,
                                    sourceName: item.sourceName,
                                    isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                                    isContentMatch: item.isContentMatch,
                                    isLocked: isLocked
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                // 保持原有菜单逻辑
                                if item.article.isRead {
                                    Button { viewModel.markAsUnread(articleID: item.article.id) } label: { Label("标为未读", systemImage: "circle") }
                                } else {
                                    Button { viewModel.markAsRead(articleID: item.article.id) } label: { Label("标为已读", systemImage: "checkmark.circle") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        // .scrollContentBackground(.hidden) // 可以保留或移除，Plain 样式下通常需要处理背景
        .background(Color.viewBackground)
        .transition(.opacity.animation(.easeInOut))
    }
    
    // MARK: - 主列表视图 (UI核心重构)
    private var sourceAndAllArticlesView: some View {
        Group {
            if SubscriptionManager.shared.subscribedSourceIDs.isEmpty && !resourceManager.isSyncing {
                VStack(spacing: 20) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("您还没有订阅任何新闻源")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button(action: { showAddSourceSheet = true }) {
                        Text("添加订阅")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // 1. 顶部大标题
                        HStack {
                            Text("我的订阅")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        
                        // 2. "ALL" 聚合大卡片
                        NavigationLink(value: NavigationTarget.allArticles) {
                            HStack {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                    Text("全部文章")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                    Text("汇集所有订阅源")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(viewModel.totalUnreadCount)")
                                        .font(.system(size: 42, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                    Text("未读")
                                        .font(.caption.bold())
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .padding(24)
                            .background(
                                LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]), startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .cornerRadius(20)
                            .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                        .padding(.horizontal, 16)
                        .buttonStyle(ScaleButtonStyle()) // 增加点击缩放效果
                        
                        // 3. 分源列表
                        VStack(spacing: 1) {
                            ForEach(viewModel.sources) { source in
                                NavigationLink(value: NavigationTarget.source(source.name)) {
                                    HStack(spacing: 15) {
                                        // 源图标占位 (可以使用首字母)
                                        // 使用新的智能图标组件
                                        SourceIconView(sourceName: source.name)
                                        
                                        Text(source.name)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        if source.unreadCount > 0 {
                                            Text("\(source.unreadCount)")
                                                .font(.caption.bold())
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.1))
                                                .foregroundColor(.blue)
                                                .clipShape(Capsule())
                                        } else {
                                            Image(systemName: "checkmark")
                                                .font(.caption)
                                                .foregroundColor(.secondary.opacity(0.5))
                                        }
                                        
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary.opacity(0.3))
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .background(Color.cardBackground) // 使用卡片背景
                                }
                                
                                // 自定义分割线 (除了最后一个)
                                if source.id != viewModel.sources.last?.id {
                                    Divider()
                                        .padding(.leading, 70) // 对齐文字
                                        .background(Color.cardBackground)
                                }
                            }
                        }
                        .cornerRadius(16) // 列表圆角
                        .padding(.horizontal, 16)
                        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                        
                        // 底部留白
                        Spacer().frame(height: 40)
                    }
                    .padding(.top, 10)
                }
            }
        }
    }
    
    // 【新增】处理文章点击和图片下载的函数
    private func handleArticleTap(_ item: (article: Article, sourceName: String, isContentMatch: Bool)) async {
        let article = item.article
        let sourceName = item.sourceName
        
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
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp }
        return Self.displayFormatter.string(from: date)
    }
}

// 简单的按钮点击缩放效果
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SourceIconView: View {
    let sourceName: String
    
    // 自定义映射表：如果想让某些特定的源显示特定的缩写，可以在这里配置
    // 例如：["华尔街日报": "WSJ", "New York Times": "NYT"]
    private let customAbbreviations: [String: String] = [
        "环球资讯": "WSJ",
        "一手新闻源": "WSJ",
        "欧美媒体": "FT",
        "海外视角": "WP",
        "最酷最敢说": "B",
        "时政锐评": "日",
        "英文期刊": "NYT",
        "前沿技术": "经",
        "语音播报": "Reu",
        "可以听的新闻": "MIT",
        "麻省理工技术评论": "MIT"
    ]
    
    var body: some View {
        // 1. 优先尝试加载图片
        // UIImage(named:) 会在 Assets 中查找完全匹配名字的图片
        if let _ = UIImage(named: sourceName) {
            Image(sourceName)
                .resizable()
                .scaledToFit() // 保持比例填充
                .frame(width: 40, height: 40)
                // 给图片加一点圆角，类似 App 图标的样式（方圆形），比纯圆更现代
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        } else {
            // 2. 如果没有图片，回退到文字 Logo
            ZStack {
                // 背景色：可以使用随机色，或者根据名字哈希生成固定颜色，这里暂时用统一的高级灰
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.1)) // 淡蓝色背景
                
                Text(getDisplayText())
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.blue) // 蓝色文字
            }
            .frame(width: 40, height: 40)
        }
    }
    
    // 获取要显示的文字
    private func getDisplayText() -> String {
        // 如果在自定义字典里有，就用字典的
        if let abbr = customAbbreviations[sourceName] {
            return abbr
        }
        // 否则取前两个字符（如果只有1个字就取1个），看起来比1个字更丰富
        return String(sourceName.prefix(1))
    }
}
