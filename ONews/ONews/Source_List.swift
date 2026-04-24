import SwiftUI

// 【修改】扩展导航目标，增加文章详情
enum NavigationTarget: Hashable {
    case allArticles
    case source(String)
    case articleDetail(Article, String, String, Bool)
    // 【修改】Prediction 入口，增加一个可选参数用于指定初始栏目 ("polymarket" 或 "kalshi")
    case predictionEntry(String?)
}

// 【新增】定义一个环境变量，用于跨视图传递 NavigationPath
struct NavigationPathKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationPath>? = nil
}

extension EnvironmentValues {
    var appNavPath: Binding<NavigationPath>? {
        get { self[NavigationPathKey.self] }
        set { self[NavigationPathKey.self] = newValue }
    }
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
    
    // 【新增】删除账号相关状态
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteError = false
    
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
                    
                    // 【新增】解决审核员找不到购买入口的问题：常驻订阅入口
                    if !authManager.isSubscribed {
                        Section {
                            Button {
                                authManager.showSubscriptionSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "crown.fill")
                                        .foregroundColor(.orange)
                                    Text(isGlobalEnglishMode ? "Upgrade to Premium" : "升级专业版")
                                        .foregroundColor(.primary)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    
                    // 功能部分：离线下载
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
                    
                    // 支持与反馈部分
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
                    
                    // 退出与删除账号部分
                    if authManager.isLoggedIn {
                        Section {
                            // 退出登录
                            Button(role: .destructive) {
                                showLogoutConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text(Localized.logout)
                                }
                            }
                            
                            // 【新增】解决 Guideline 5.1.1(v)：删除账号按钮
                            Button(role: .destructive) {
                                showDeleteAccountConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash.fill")
                                    Text(isGlobalEnglishMode ? "Delete Account" : "删除账号")
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
                // 退出登录弹窗
                .alert(isGlobalEnglishMode ? "Sign Out" : "确认退出登录", isPresented: $showLogoutConfirmation) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Sign Out" : "退出登录", role: .destructive) {
                        authManager.signOut()
                        dismiss()
                    }
                } message: {
                    Text(isGlobalEnglishMode ? 
                         "After signing out, you will no longer be able to access premium content." : 
                         "退出登录后，您将无法查看受限内容。")
                }
                // 【新增】删除账号确认弹窗
                .alert(isGlobalEnglishMode ? "Delete Account" : "确认删除账号", isPresented: $showDeleteAccountConfirmation) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { }
                    Button(isGlobalEnglishMode ? "Delete" : "永久删除", role: .destructive) {
                        performAccountDeletion()
                    }
                } message: {
                    Text(isGlobalEnglishMode ? 
                         "This action cannot be undone. All your data and subscription status will be permanently removed from our servers." : 
                         "此操作不可逆。您的所有数据和订阅状态将从我们的服务器上永久删除。")
                }
                // 删除失败弹窗
                .alert(isGlobalEnglishMode ? "Error" : "删除失败", isPresented: $showDeleteError) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(deleteErrorMessage)
                }
                // 蜂窝网络警告弹窗
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
            
            // 删除账号的 Loading 遮罩
            if isDeletingAccount {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text(isGlobalEnglishMode ? "Deleting Account..." : "正在删除账号...").foregroundColor(.white)
                }
            }
            
            // 下载进度遮罩... (保持原有逻辑)
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
    
    // 【新增】执行删除账号
    private func performAccountDeletion() {
        isDeletingAccount = true
        Task {
            do {
                try await authManager.deleteAccount()
                await MainActor.run {
                    isDeletingAccount = false
                    dismiss() // 删除成功后关闭个人中心
                }
            } catch {
                await MainActor.run {
                    isDeletingAccount = false
                    deleteErrorMessage = error.localizedDescription
                    showDeleteError = true
                }
            }
        }
    }
    
    private func handleOfflineDownloadTap() {
        if resourceManager.isWifiConnected { startBulkDownload() } else { showCellularAlert = true }
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
    // 【新增】Prediction 管理器
    @EnvironmentObject var predictionSyncManager: PredictionSyncManager
    @EnvironmentObject var prefManager: PreferenceManager
    @EnvironmentObject var transManager: TranslationManager
    
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("hasCompletedPredictionOnboarding") private var hasCompletedPredictionOnboarding = false
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    // 【新增】全局导航路径
    @State private var navPath = NavigationPath()
    
    @State private var showAddSourceSheet = false
    // 【新增】控制登录弹窗的显示
    @State private var showLoginSheet = false
    
    // 【新增】控制未登录用户的底部菜单
    @State private var showGuestMenu = false
    // 【新增】控制已登录用户的个人中心
    @State private var showProfileSheet = false
    
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
    // 【修改】移除 selectedArticleItem 和 isNavigationActive，不再需要它们了
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    
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
        // 【修改】绑定全局导航路径
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                // 1. 搜索栏
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
                                    // 【修改】逻辑反转：!isGlobalEnglishMode (即中文模式) 时实心
                                    .background(!isGlobalEnglishMode ? Color.primary : Color.clear)
                                    .clipShape(Circle())
                                
                                // 【修改】逻辑反转：中文模式下显示“中”，英文模式下显示“英”
                                Text(isGlobalEnglishMode ? "中" : "英")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    // 【修改】逻辑反转：!isGlobalEnglishMode (即中文模式) 时文字反色
                                    .foregroundColor(!isGlobalEnglishMode ? Color.viewBackground : Color.primary)
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
            // 【修改】统一在这里处理所有的导航目标
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .allArticles:
                    AllArticlesListView(viewModel: viewModel, resourceManager: resourceManager)
                case .source(let sourceName):
                    ArticleListView(sourceName: sourceName, viewModel: viewModel, resourceManager: resourceManager)
                case .articleDetail(let article, let sourceName, let contextStr, let autoPlay):
                    ArticleContainerView(
                        article: article,
                        sourceName: sourceName,
                        context: contextStr == "all" ? .fromAllArticles : .fromSource(sourceName),
                        viewModel: viewModel,
                        resourceManager: resourceManager,
                        autoPlayOnAppear: autoPlay
                    )
                // 【修改】Prediction 入口，接收参数并传递给 EntryView
                case .predictionEntry(let source):
                    PredictionEntryView(initialSource: source)
                }
            }
        }
        // 【新增】将导航路径注入环境，供子视图使用
        .environment(\.appNavPath, $navPath)
        .tint(.blue)
        .onAppear {
            viewModel.loadNews()
            Task { await syncResources() }
            // ✅ 新增：启动时轻量级检查预测数据源可用性（不下载文件）
            Task { await predictionSyncManager.refreshAvailabilityFromServer() }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: { viewModel.loadNews() }) {
            NavigationView {
                AddSourceView(isFirstTimeSetup: false)
            }
            .environmentObject(resourceManager)
        }
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        // ⚠️ 修复 Bug：直接绑定 authManager.showSubscriptionSheet，确保状态双向同步
        .sheet(isPresented: $authManager.showSubscriptionSheet) { SubscriptionView() }
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
        // ⚠️ 修复 Bug：移除了冗余的 .onChange(of: authManager.showSubscriptionSheet)
        .onChange(of: authManager.isLoggedIn, perform: { newValue in
            if newValue == true && self.showLoginSheet {
                self.showLoginSheet = false
            }
        })
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
                    Text(Localized.noSubscriptions)
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
                        
                        // ========================================
                        // 【核心改动】双卡片布局：ONews + Prediction
                        // ========================================
                        HStack(spacing: 12) {
                            // --- 左侧：ONews ALL 卡片 (缩窄版) ---
                            predictionCard
                            
                            // --- 右侧：Prediction 卡片 ---
                            onewsAllCard
                        }
                        .padding(.horizontal, 16)
                        
                        // 更新时间条 (放在双卡片下方)
                        if !resourceManager.serverUpdateTime.isEmpty {
                            HStack {
                                Text(formatUpdateTime(resourceManager.serverUpdateTime))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                        }
                        
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
    
    // MARK: - 左侧 ONews ALL 卡片
    private var onewsAllCard: some View {
        // 注意：这里仍然保留 NavigationLink，以便点击卡片空白处也能跳转
        NavigationLink(value: NavigationTarget.allArticles) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                
                Text(Localized.allArticles)
                    .font(.headline.bold())
                    .foregroundColor(.white)
                
                Text(Localized.allArticlesDesc)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                
                Spacer()
                
                // 未读数
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(viewModel.totalUnreadCount)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(Localized.unread)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 3)
                }
                // 【修改】将按钮放入一个 HStack 中
                HStack(spacing: 8) {
                    // 1. 文本阅读按钮 (点击直接跳转)
                    Button(action: {
                        // 使用全局导航路径跳转
                        navPath.append(NavigationTarget.allArticles)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.book.closed.fill")
                                .font(.system(size: 10))
                            Text(isGlobalEnglishMode ? "Read" : "阅读")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white)
                        .cornerRadius(16)
                    }
                    .buttonStyle(PlainButtonStyle()) // 必须添加，防止触发父级 NavigationLink
                    
                    // 2. 语音播放按钮
                
                    // 播放按钮
                    Button(action: {
                        Task { await handlePlayAll() }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text(isGlobalEnglishMode ? "Play" : "语音")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white)
                        .cornerRadius(16)
                    }
                    .buttonStyle(PlainButtonStyle()) // 必须添加
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 220)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue, Color.purple]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(18)
            .shadow(color: .blue.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(ScaleButtonStyle())
    }
    
    // MARK: - 右侧 Prediction 卡片
    private var predictionCard: some View {
        // ✅ 根据服务器可用性决定默认跳转和显示
        let hasPoly = predictionSyncManager.hasPolymarketAvailable
        let hasKal = predictionSyncManager.hasKalshiAvailable
        // 默认优先 polymarket；若只有 kalshi 则跳 kalshi；两者都没有兜底 polymarket
        let defaultSource: String = hasPoly ? "polymarket" : (hasKal ? "kalshi" : "polymarket")
        
        return NavigationLink(value: NavigationTarget.predictionEntry(defaultSource)) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .font(.title)
                    .foregroundColor(.white)
                
                Text(isGlobalEnglishMode ? "Prediction Markets" : "预测市场")
                    .font(.headline.bold())
                    .foregroundColor(.white)
                
                // ✅ 副标题：根据可用性动态显示
                VStack(alignment: .leading, spacing: 2) {
                    if hasPoly {
                        Text(isGlobalEnglishMode ? "Polymarket Mirror Site" : "全球第一 Polymarket 镜像站")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    
                    if hasKal {
                        Text(isGlobalEnglishMode ? "Kalshi.com Mirror Site" : "全美第一 kalshi.com 镜像站")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // 数据统计
                let totalItems = predictionSyncManager.polymarketItems.count
                    + predictionSyncManager.kalshiItems.count
                
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(totalItems)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(isGlobalEnglishMode ? "topics" : "话题")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 3)
                }
                
                // ✅ 按钮：根据可用性动态显示
                HStack(spacing: 6) {
                    if hasPoly {
                        Button(action: {
                            navPath.append(NavigationTarget.predictionEntry("polymarket"))
                        }) {
                            HStack(spacing: 2) {
                                Text("Polymarket")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    if hasKal {
                        Button(action: {
                            navPath.append(NavigationTarget.predictionEntry("kalshi"))
                        }) {
                            HStack(spacing: 2) {
                                Text("Kalshi")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 220)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.indigo, Color.purple]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(18)
            .shadow(color: .indigo.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(ScaleButtonStyle())
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
        
        // 6. 构造数据结构并跳转
        let itemToPlay = (article: targetItem.article, sourceName: targetItem.sourceName, isContentMatch: false)
        
        // 开启自动播放导航
        await handleArticleTap(itemToPlay, autoPlay: true)
    }

    // 【修改】更新函数签名，增加 autoPlay 参数
    private func handleArticleTap(_ item: (article: Article, sourceName: String, isContentMatch: Bool), autoPlay: Bool = false) async {
        let article = item.article
        let sourceName = item.sourceName
        
        // ⚠️ 修复 Bug：将 showSubscriptionSheet 替换为 authManager.showSubscriptionSheet
        if !authManager.isSubscribed && viewModel.isTimestampLocked(timestamp: article.timestamp) {
            authManager.showSubscriptionSheet = true
            return
        }
        
        // 【修改】使用全局 navPath 进行跳转
        let prepareNavigation = {
            await MainActor.run {
                self.navPath.append(NavigationTarget.articleDetail(article, sourceName, "all", autoPlay))
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
        "麻省理工技术评论": "MIT",
        "大喇叭开始广播了": "BBC"
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

struct PredictionEntryView: View {
    // 【新增】接收初始栏目参数
    var initialSource: String? = nil
    
    @AppStorage("hasCompletedPredictionOnboarding") private var hasCompletedPredictionOnboarding = false
    
    @EnvironmentObject var predictionSyncManager: PredictionSyncManager
    @EnvironmentObject var prefManager: PreferenceManager
    @EnvironmentObject var transManager: TranslationManager
    @EnvironmentObject var authManager: AuthManager  // 共用 ONews 的
    
    var body: some View {
        Group {
            if hasCompletedPredictionOnboarding {
                // 【修改】将参数传递给主容器
                PredictionMainContainerView(initialSource: initialSource)
            } else {
                PredictionWelcomeView(hasCompletedOnboarding: $hasCompletedPredictionOnboarding)
            }
        }
        // 不需要额外注入环境变量，因为父视图已经注入了
        .navigationBarTitleDisplayMode(.inline)
    }
}