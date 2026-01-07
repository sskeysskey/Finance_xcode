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
    // 【新增】为了让界面随语言刷新
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false 
    
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
                                Text(Localized.premiumUser)
                                    .font(.subheadline)
                                    .foregroundColor(.yellow)
                                    .bold()
                                if let dateStr = authManager.subscriptionExpiryDate {
                                    Text("有效期至: \(formatDateLocal(dateStr))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                 Text(Localized.freeUser)
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
                Section(header: Text(Localized.feedback)) {
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
                                Text(Localized.feedback)
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
                                Text(Localized.logout)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Localized.profileTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// 辅助函数：放在 View 结构体外面或内部
func formatDateLocal(_ isoString: String) -> String {
    // 1. 创建解析器 (用于读取服务器返回的 ISO8601 字符串)
    let isoFormatter = ISO8601DateFormatter()
    // 增加对毫秒和各种网络时间格式的支持
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
    
    // 2. 创建显示格式化器 (用于输出给用户看)
    let displayFormatter = DateFormatter()
    displayFormatter.locale = Locale(identifier: "zh_CN") // ⚡️ 核心：强制指定为中文区域
    displayFormatter.dateStyle = .medium  // 显示如：2026年1月20日
    displayFormatter.timeStyle = .short   // 显示如：11:02 (如果不需要时间，可以改为 .none)
    
    // 尝试解析标准 ISO 格式 (带 Z 或偏移量)
    if let date = isoFormatter.date(from: isoString) {
        return displayFormatter.string(from: date)
    }
    
    // 兜底方案 A：尝试解析不带 Z 的简单 ISO 格式
    let fallbackISO = ISO8601DateFormatter()
    fallbackISO.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    if let date = fallbackISO.date(from: isoString) {
        return displayFormatter.string(from: date)
    }
    
    // 兜底方案 B：如果解析彻底失败，直接处理字符串 (处理 2026-01-20 这种格式)
    if isoString.contains("-") && isoString.count >= 10 {
        let datePart = String(isoString.prefix(10))
        return datePart.replacingOccurrences(of: "-", with: "年", range: datePart.range(of: "-"))
                       .replacingOccurrences(of: "-", with: "月") + "日"
    }
    
    return isoString // 原样返回
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
                    if authManager.isSubscribed {
                        Image(systemName: "crown.fill").foregroundColor(.yellow).font(.caption)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
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
    // ... 确保有 @AppStorage ...
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false 
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    // 【新增】用于控制跳转时是否自动播放的状态
    @State private var shouldAutoPlayNextNav: Bool = false
    
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
                        // ✅ 【新增】中英切换按钮 (放在最左边，作为第一个元素)
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
                                
                                // 逻辑：英文模式显示"中"，中文模式显示"En"
                                Text(isGlobalEnglishMode ? "中" : "En")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(isGlobalEnglishMode ? Color.viewBackground : Color.primary)
                            }
                            .frame(width: 24, height: 24)
                        }
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
                        context: .fromAllArticles, // 搜索结果或All列表点击都视为 All 上下文
                        viewModel: viewModel,
                        resourceManager: resourceManager,
                        
                        // 👇👇👇 【核心修复】这里必须把状态传进去，否则默认为 false 👇👇👇
                        autoPlayOnAppear: shouldAutoPlayNextNav
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
                            Text(Localized.loginAccount)
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
                                Text(Localized.feedback)
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
                            Text(Localized.searchResults)
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
                    Text(Localized.noSubscriptions) // 【修改】
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button(action: { showAddSourceSheet = true }) {
                        Text(Localized.addSubscriptionBtn)
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
                            Text(Localized.mySubscriptions) 
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
                                    Text(Localized.allArticles) 
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                    Text(Localized.allArticlesDesc)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                Spacer()
                                // 【修改】将 VStack 改为 HStack，并设置底部对齐
                                HStack(alignment: .lastTextBaseline, spacing: 4) {
                                    Text("\(viewModel.totalUnreadCount)")
                                        .font(.system(size: 42, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                    
                                    Text(Localized.unread)
                                        .font(.caption.bold())
                                        .foregroundColor(.white.opacity(0.8))
                                        // 稍微调整一下位置，防止在大字体旁显得太靠下（可选）
                                        .padding(.bottom, 4) 
                                }

                            }
                            .padding(24)
                            .background(
                                LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]), startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .cornerRadius(20)
                            .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            // 【新增】在这里叠加播放按钮
                            .overlay(alignment: .bottomTrailing) {
                                Button(action: {
                                    // 执行一键播放逻辑
                                    Task { await handlePlayAll() }
                                }) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 50)) // 大个按钮
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
                                        .background(Circle().fill(Color.blue)) // 填充蓝色背景防止透视
                                }
                                .padding(.trailing, 20)
                                .padding(.bottom, -25) // 让按钮悬挂在卡片边缘，增加立体感
                            }
                        }
                        .padding(.horizontal, 16)
                        .buttonStyle(ScaleButtonStyle()) // 增加点击缩放效果
                        // 为了给悬挂的播放按钮留出空间，增加一点间距
                        Spacer().frame(height: 30)
                        
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

    // 【修改】处理点击“Play All”按钮的逻辑
    private func handlePlayAll() async {
        // 1. 获取所有排序后的文章列表
        let allItems = viewModel.allArticlesSortedForDisplay
        
        // 2. 筛选出所有“未读”的文章
        let unreadItems = allItems.filter { item in
            !viewModel.isArticleEffectivelyRead(item.article)
        }
        
        // 3. 优先取第一篇未读；如果全部已读，则兜底取整个列表的第一篇（最新的那篇）
        guard let targetItem = unreadItems.first ?? allItems.first else {
            return
        }
        
        // 4. 构造数据结构
        let itemToPlay = (article: targetItem.article, sourceName: targetItem.sourceName, isContentMatch: false)
        
        // 5. 调用复用的逻辑，并开启自动播放
        await handleArticleTap(itemToPlay, autoPlay: true)
    }

    // 【修改】更新函数签名，增加 autoPlay 参数
    private func handleArticleTap(_ item: (article: Article, sourceName: String, isContentMatch: Bool), autoPlay: Bool = false) async {
        let article = item.article
        let sourceName = item.sourceName
        
        // 【修改后】简化逻辑：只要被锁定，就显示 SubscriptionView
        if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: article.timestamp) {
            showSubscriptionSheet = true
            return
        }
        
        // 准备导航
        let prepareNavigation = {
            await MainActor.run {
                self.shouldAutoPlayNextNav = autoPlay // 【新增】设置自动播放状态
                self.selectedArticleItem = (article, sourceName)
                self.isNavigationActive = true
            }
        }

        guard !article.images.isEmpty else {
            await prepareNavigation()
            return
        }
        
        // 2. 检查图片是否已在本地存在
        let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        )
        
        // 3. 如果图片已存在，直接导航
        if imagesAlreadyExist {
            await prepareNavigation()
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
            }
            await prepareNavigation() // 下载成功后跳转
            
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
