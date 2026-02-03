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
                Text(Localized.imageLoading) // 【双语化】
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

// 【新增】通用的通知条组件
struct NotificationBannerView: View {
    let message: String
    let onClose: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 图标
            Image(systemName: "bell.badge.fill")
                .foregroundColor(.orange)
                .font(.system(size: 16))
                .padding(.top, 3) // 微调对齐
            
            // 文字
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true) // 允许换行
                .lineLimit(3) // 最多显示3行，防止太长
            
            Spacer()
            
            // 关闭按钮
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(12)
        // 背景样式：自适应浅色/深色模式
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 2)
        )
        // 边框（可选，增加一点精致感）
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity)) // 出现/消失动画
    }
}

// MARK: - 【新增】个人中心视图 (User Profile)
struct UserProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    // 【新增】获取 ResourceManager
    @EnvironmentObject var resourceManager: ResourceManager
    @Environment(\.dismiss) var dismiss
    // 【新增】为了让界面随语言刷新
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false 
    
    // 【新增】控制退出登录确认框的状态
    @State private var showLogoutConfirmation = false
    
    // 【新增】离线下载相关状态
    @State private var showCellularAlert = false
    @State private var isBulkDownloading = false
    @State private var bulkProgress: Double = 0.0
    @State private var bulkProgressText = ""
    @State private var bulkDownloadError = false
    @State private var bulkDownloadErrorMessage = ""
    @State private var showSuccessToast = false
    
    var body: some View {
        ZStack { // 使用 ZStack 以便显示遮罩
            NavigationView {
                List {
                    // 1. 用户信息部分 (保持不变)
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
                                        Text("\(Localized.validUntil): \(formatDateLocal(dateStr, isEnglish: isGlobalEnglishMode))")
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
                                    Text(Localized.notLoggedIn)
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.leading, 8)
                        }
                        .padding(.vertical, 10)
                    }
                    
                    // 【新增】功能部分：离线下载
                    Section(header: Text(isGlobalEnglishMode ? "Features" : "功能")) {
                        Button {
                            handleOfflineDownloadTap()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading) {
                                    Text(isGlobalEnglishMode ? "Offline Image Download" : "离线下载所有图片")
                                        .foregroundColor(.primary)
                                    Text(isGlobalEnglishMode ? "Download images for cached articles" : "下载已缓存文章的图片，离线可读")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    
                    // 2. 支持与反馈部分 (保持不变)
                    Section(header: Text(Localized.feedback)) {
                        Button {
                            let email = "728308386@qq.com"
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
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = "728308386@qq.com"
                            } label: {
                                Label(isGlobalEnglishMode ? "Copy Email" : "复制邮箱地址", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    
                    // 3. 退出登录部分 (保持不变)
                    Section {
                        if authManager.isLoggedIn {
                            Button(role: .destructive) {
                                showLogoutConfirmation = true
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
                        Button(Localized.close) { dismiss() }
                    }
                }
                .alert(isGlobalEnglishMode ? "Sign Out" : "确认退出登录", isPresented: $showLogoutConfirmation) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Sign Out" : "退出登录", role: .destructive) {
                        authManager.signOut()
                        dismiss()
                    }
                } message: {
                    Text(isGlobalEnglishMode ? 
                         "After signing out, you will no longer be able to access premium content. You can restore access by signing back in with the same Apple ID." : 
                         "退出登录后，您将无法查看受限内容。重新登录同一 Apple 账号即可恢复权限。")
                }
                // 【新增】蜂窝网络警告弹窗
                .alert(isGlobalEnglishMode ? "Cellular Network Detected" : "正在使用蜂窝网络", isPresented: $showCellularAlert) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Download Anyway" : "继续下载") {
                        startBulkDownload()
                    }
                } message: {
                    Text(isGlobalEnglishMode ? 
                         "You are currently using cellular data. Downloading all images may consume a significant amount of data. Do you want to continue?" : 
                         "当前检测到非 Wi-Fi 环境。离线下载所有图片可能会消耗较多流量，是否继续？")
                }
                // 【新增】错误弹窗
                .alert(isGlobalEnglishMode ? "Download Failed" : "下载失败", isPresented: $bulkDownloadError) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(bulkDownloadErrorMessage)
                }
            }
            
            // 【新增】下载进度遮罩
            if isBulkDownloading {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    
                    VStack(spacing: 8) {
                        Text(isGlobalEnglishMode ? "Downloading Images..." : "正在离线缓存图片...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        ProgressView(value: bulkProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .frame(width: 200)
                        
                        Text(bulkProgressText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .monospacedDigit()
                    }
                }
                .padding(30)
                .background(Material.ultraThinMaterial)
                .cornerRadius(20)
                .shadow(radius: 10)
            }
            
            // 【新增】成功提示 Toast
            if showSuccessToast {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(isGlobalEnglishMode ? "All images downloaded!" : "所有图片已离线缓存！")
                            .foregroundColor(.primary)
                            .fontWeight(.medium)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(30)
                    .shadow(radius: 10)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(100)
            }
        }
    }
    
    // 【新增】处理点击逻辑
    private func handleOfflineDownloadTap() {
        // 1. 检查是否连接了 Wi-Fi
        if resourceManager.isWifiConnected {
            // 是 Wi-Fi，直接开始
            startBulkDownload()
        } else {
            // 不是 Wi-Fi，弹窗警告
            showCellularAlert = true
        }
    }
    
    // 【新增】执行下载
    private func startBulkDownload() {
        isBulkDownloading = true
        bulkProgress = 0.0
        bulkProgressText = isGlobalEnglishMode ? "Preparing..." : "准备中..."
        
        Task {
            do {
                try await resourceManager.downloadAllOfflineImages { current, total in
                    // 更新进度
                    self.bulkProgress = total > 0 ? Double(current) / Double(total) : 1.0
                    self.bulkProgressText = "\(current) / \(total)"
                }
                
                await MainActor.run {
                    isBulkDownloading = false
                    showSuccessToast = true
                    // 2秒后隐藏 Toast
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showSuccessToast = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isBulkDownloading = false
                    bulkDownloadErrorMessage = error.localizedDescription
                    bulkDownloadError = true
                }
            }
        }
    }
}

// MARK: - Helper Functions
func formatDateLocal(_ isoString: String, isEnglish: Bool) -> String {
    let isoFormatter = ISO8601DateFormatter()
    // 增加对毫秒和各种网络时间格式的支持
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
    
    // 2. 创建显示格式化器 (用于输出给用户看)
    let displayFormatter = DateFormatter()
    // 【双语化修复】根据当前模式选择区域
    displayFormatter.locale = Locale(identifier: isEnglish ? "en_US" : "zh_CN")
    displayFormatter.dateStyle = .medium
    displayFormatter.timeStyle = .short
    
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
        if isEnglish { return datePart }
        return datePart.replacingOccurrences(of: "-", with: "年", range: datePart.range(of: "-"))
                       .replacingOccurrences(of: "-", with: "月") + "日"
    }
    
    return isoString // 原样返回
}

// MARK: - 【修改】导航栏用户状态视图
// 修改逻辑：不再直接传入 showLoginSheet，而是传入两个 Sheet 的控制状态
struct UserStatusToolbarItem: View {
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false 
    
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
                    Text(Localized.loginAccount) // 【双语化】
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .clipShape(Capsule())
                .foregroundColor(.primary)
            }
        }
        .accessibilityLabel(authManager.isLoggedIn ? Localized.profileTitle : Localized.loginAccount)
    }
}

// MARK: - Main Source List View
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
    
    private var searchResults: [(article: Article, sourceName: String, sourceNameEN: String, isContentMatch: Bool)] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // 这里的 compactMap 签名也对应更新
        return viewModel.allArticlesSortedForDisplay.compactMap { item -> (Article, String, String, Bool)? in
            if item.article.topic.lowercased().contains(keyword) {
                // item 现在包含 (article, sourceName, sourceNameEN)
                return (item.article, item.sourceName, item.sourceNameEN, false)
            }
            if item.article.article.lowercased().contains(keyword) {
                return (item.article, item.sourceName, item.sourceNameEN, true)
            }
            return nil
        }
    }

    // 【修改】更新分组逻辑以适应新的元组结构
    private func groupedSearchByTimestamp() -> [String: [(article: Article, sourceName: String, sourceNameEN: String, isContentMatch: Bool)]] {
        var initial = Dictionary(grouping: searchResults, by: { $0.article.timestamp })
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

    // 【修改】类型增加 sourceNameEN
    private func sortedSearchTimestamps(for groups: [String: [(article: Article, sourceName: String, sourceNameEN: String, isContentMatch: Bool)]]) -> [String] {
        return groups.keys.sorted(by: >)
    }
    
    var body: some View {
        // 【修改】将 NavigationView 升级为 NavigationStack
        NavigationStack {
            VStack(spacing: 0) {
                // 1. 搜索栏
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
                
                // 【新增】2. 通知条 (插入在这里)
                // 只有当有内容时才显示
                if let message = resourceManager.activeNotification {
                    NotificationBannerView(message: message) {
                        resourceManager.dismissNotification()
                    }
                }
                
                // 3. 主内容区
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
                            // 【核心修改】点击刷新时，同时同步资源和用户状态
                            Task { 
                                // 1. 同步新闻内容
                                await syncResources(isManual: true) 
                                // 2. 同步用户订阅状态 (手动重试机制)
                                await authManager.checkServerSubscriptionStatus()
                            }
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
            // MARK: - Guest Menu (Bottom Sheet)
            VStack(spacing: 20) {
                // 顶部小横条
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                
                Text(Localized.loginWelcome) // 【双语化】
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
                            Text(Localized.loginAccount) // 【双语化】
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
                                Text(Localized.feedback) // 【双语化】
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
                // 1. 原有的同步状态遮罩 (Loading / 下载进度)
                // 注意：加一个判断 !resourceManager.showAlreadyUpToDateAlert，防止两个弹窗重叠
                if resourceManager.isSyncing && !resourceManager.showAlreadyUpToDateAlert {
                    VStack(spacing: 15) {
                        if resourceManager.syncMessage.contains("最新") || resourceManager.syncMessage.contains("date") {
                            // 这一步其实是为了兼容旧逻辑，但现在我们有专门的弹窗了，可以保留作为双重保险
                            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundColor(.white)
                            Text(resourceManager.syncMessage).font(.headline).foregroundColor(.white)
                        } else if resourceManager.isDownloading {
                            Text(resourceManager.syncMessage).font(.headline).foregroundColor(.white)
                            ProgressView(value: resourceManager.downloadProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .white))
                                .padding(.horizontal, 50)
                        } else {
                            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(1.2)
                            Text(Localized.loading).foregroundColor(.white.opacity(0.9)) // 【双语化】
                        }
                    }
                    .frame(width: 200, height: 160) // 小巧的 HUD 尺寸
                    .background(Material.ultraThinMaterial)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(20)
                }
                
                // 2. 【新增】"已是最新" 的自动消失弹窗
                if resourceManager.showAlreadyUpToDateAlert {
                    VStack(spacing: 15) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green) // 或者 .white
                        
                        // 这里直接调用 Localized.upToDate
                        Text(Localized.upToDate) // "已是最新版本"
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .frame(width: 180, height: 160) // 方形 HUD
                    .background(Material.ultraThinMaterial)
                    .background(Color.black.opacity(0.6)) // 深色背景
                    .cornerRadius(20)
                    .transition(.opacity.combined(with: .scale)) // 出现动画
                    .zIndex(100) // 确保在最上层
                }
                
                // 3. 图片下载遮罩
                DownloadOverlay(isDownloading: isDownloadingImages, progress: downloadProgress, progressText: downloadProgressText)
            }
            // 添加动画支持
            .animation(.easeInOut, value: resourceManager.isSyncing)
            .animation(.easeInOut, value: resourceManager.showAlreadyUpToDateAlert)
        )
        .alert(Localized.ok, isPresented: $showErrorAlert, actions: { Button(Localized.ok, role: .cancel) { } }, message: { Text(errorMessage) })
    }

    // 【新增】辅助函数：格式化显示时间文案
    private func formatUpdateTime(_ rawTime: String) -> String {
        // 如果是英文模式
        if isGlobalEnglishMode {
            return "Updated: \(rawTime)"
        } else {
            // 中文模式
            return "更新时间: \(rawTime)"
        }
    }

    // MARK: - 搜索结果视图 (使用新的卡片)
    private var searchResultsView: some View {
        List {
            let grouped = groupedSearchByTimestamp()
            let timestamps = sortedSearchTimestamps(for: grouped)
            
            if searchResults.isEmpty {
                Section {
                    Text(Localized.noMatch) // 【双语化】
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(timestamps, id: \.self) { timestamp in
                    Section(header:
                        HStack {
                            Text(Localized.searchResults) // 【双语化】
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
                                // 注意：handleArticleTap 的参数是一个 3 元素的元组，这里 item 是 4 元素
                                // 我们需要重新构建一下参数传给它
                                let tapItem = (article: item.article, sourceName: item.sourceName, isContentMatch: item.isContentMatch)
                                Task { await handleArticleTap(tapItem) }
                            }) {
                                let isLocked = !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: item.article.timestamp)
                                
                                ArticleRowCardView(
                                    article: item.article,
                                    sourceName: item.sourceName,
                                    sourceNameEN: item.sourceNameEN, // 【核心修改】传入 item.sourceNameEN
                                    isReadEffective: viewModel.isArticleEffectivelyRead(item.article),
                                    isContentMatch: item.isContentMatch,
                                    isLocked: isLocked,
                                    showEnglish: isGlobalEnglishMode // 【核心修改】传入当前的语言开关
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                // 保持原有菜单逻辑
                                if item.article.isRead {
                                    Button { viewModel.markAsUnread(articleID: item.article.id) } label: { Label(Localized.markAsUnread_text, systemImage: "circle") }
                                } else {
                                    Button { viewModel.markAsRead(articleID: item.article.id) } label: { Label(Localized.markAsRead_text, systemImage: "checkmark.circle") }
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
                        // 使用 VStack 将卡片和下方的时间条组合在一起，作为一个整体单元
                        VStack(alignment: .leading, spacing: 6) {
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
                                    // 右侧数字
                                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                                        Text("\(viewModel.totalUnreadCount)")
                                            .font(.system(size: 42, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                        
                                        Text(Localized.unread)
                                            .font(.caption.bold())
                                            .foregroundColor(.white.opacity(0.8))
                                            .padding(.bottom, 4)
                                    }
                                }
                                .padding(24)
                                .background(
                                    LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]), startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .cornerRadius(20)
                                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                                .overlay(alignment: .bottomTrailing) {
                                    Button(action: {
                                        Task { await handlePlayAll() }
                                    }) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 50))
                                            .foregroundColor(.white)
                                            .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
                                            .background(Circle().fill(Color.blue))
                                    }
                                    .padding(.trailing, 20)
                                    .padding(.bottom, -25)
                                }
                                }
                                .buttonStyle(ScaleButtonStyle())
                                
                                // 2. 卡片外部左下方的更新时间条
                                if !resourceManager.serverUpdateTime.isEmpty {
                                    HStack(spacing: 4) {
                                        // 图标
                                        // Image(systemName: "arrow.triangle.2.circlepath") // 循环更新图标
                                        //     .font(.caption2)
                                        //     .foregroundColor(.secondary)
                                        
                                        // 时间文字
                                        Text(formatUpdateTime(resourceManager.serverUpdateTime))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced)) // 等宽字体显专业
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.leading, 8) // 让它比卡片边缘稍微缩进一点点，视觉上更协调
                                    .transition(.opacity) // 出现时的淡入动画
                                }
                            }
                        .padding(.horizontal, 16)
                        .buttonStyle(ScaleButtonStyle()) // 增加点击缩放效果
                        // 为了给悬挂的播放按钮留出空间，增加一点间距
                        Spacer().frame(height: 10)
                        
                        // 3. 分源列表
                        VStack(spacing: 1) {
                            ForEach(viewModel.sources) { source in
                                NavigationLink(value: NavigationTarget.source(source.name)) {
                                    HStack(spacing: 15) {
                                        // 源图标占位 (可以使用首字母)
                                        // 使用新的智能图标组件
                                        SourceIconView(sourceName: source.name)
                                        
                                        // 【修改这里】
                                        Text(isGlobalEnglishMode ? source.name_en : source.name)
                                            .font(.body.weight(.medium))
                                            .foregroundColor(.primary)
                                            // 添加动画让切换顺滑
                                            .animation(.none, value: isGlobalEnglishMode)
                                        
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
        
        // 准备导航的闭包
        let prepareNavigation = {
            await MainActor.run {
                self.shouldAutoPlayNextNav = autoPlay // 【新增】设置自动播放状态
                self.selectedArticleItem = (article, sourceName)
                self.isNavigationActive = true
            }
        }

        // 3. 检查是否有图片需要下载
        guard !article.images.isEmpty else {
            await prepareNavigation()
            return
        }
        
        // 2. 检查图片是否已在本地存在
        let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
            timestamp: article.timestamp,
            imageNames: article.images
        )
        
        // 3. 如果图片已存在，直接进
        if imagesAlreadyExist {
            await prepareNavigation()
            return
        }
        
        // 4. 如果图片不存在，开始下载流程
        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = Localized.imagePrepare
        }
        
        do {
            // 尝试下载
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    // 这个闭包会在主线程上被调用，可以直接更新UI状态
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    // 【双语化】已下载 x / y
                    self.downloadProgressText = "\(Localized.imageDownloaded) \(current) / \(total)"
                }
            )
            
            // 下载成功
            await MainActor.run { isDownloadingImages = false }
            await prepareNavigation()
            
        } catch {
            // 【核心修改】下载失败时的降级处理
            await MainActor.run {
                // 无论什么错误，先关闭遮罩
                isDownloadingImages = false
                
                // 判断是否为网络错误
                let isNetworkError = (error as? URLError)?.code == .notConnectedToInternet ||
                                     (error as? URLError)?.code == .timedOut ||
                                     (error as? URLError)?.code == .networkConnectionLost ||
                                     (error as? URLError)?.code == .cannotConnectToHost

                if isNetworkError {
                    print("网络不可用，进入离线阅读模式")
                    // 网络错误：直接进入文章（降级）
                    Task { await prepareNavigation() }
                } else {
                    // 其他错误（如服务器文件丢失）：弹窗提示
                    errorMessage = "\(Localized.fetchFailed): \(error.localizedDescription)"
                    showErrorAlert = true
                }
            }
        }
    }
    
    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            // 【修改】同步完成后，确保 ViewModel 也更新了配置
            viewModel.loadNews()
        } catch {
            // 只有手动同步才弹窗报错，自动同步失败（如没网）则静默失败，加载本地旧数据
            if isManual {
                await MainActor.run {
                    // 确保遮罩消失
                    resourceManager.isSyncing = false
                    
                    switch error {
                    case is DecodingError:
                        self.errorMessage = isGlobalEnglishMode ? "Data parsing failed." : "数据解析失败。"
                        self.showErrorAlert = true
                    case let urlError as URLError where
                        urlError.code == .cannotConnectToHost ||
                        urlError.code == .timedOut ||
                        urlError.code == .notConnectedToInternet:
                        self.errorMessage = Localized.networkError
                        self.showErrorAlert = true
                    default:
                        self.errorMessage = isGlobalEnglishMode ? "Unknown error." : "发生未知错误。"
                        self.showErrorAlert = true
                    }
                }
                print("手动同步失败: \(error)")
            } else {
                print("自动同步失败 (离线模式): \(error)")
                // 即使同步失败，也要加载本地已有的新闻
                await MainActor.run {
                    resourceManager.isSyncing = false
                    viewModel.loadNews()
                }
            }
        }
    }
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let parsingFormatter = DateFormatter()
        parsingFormatter.dateFormat = "yyMMdd"
        
        guard let date = parsingFormatter.date(from: timestamp) else { return timestamp }
        
        let displayFormatter = DateFormatter()
        // 【双语化修复】根据当前模式选择区域
        displayFormatter.locale = Locale(identifier: isGlobalEnglishMode ? "en_US" : "zh_CN")
        displayFormatter.dateFormat = isGlobalEnglishMode ? "MMM d, yyyy, EEEE" : "yyyy年M月d日, EEEE"
        
        return displayFormatter.string(from: date)
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
