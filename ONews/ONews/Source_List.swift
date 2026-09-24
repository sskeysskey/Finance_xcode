import SwiftUI

// 【修改】扩展导航目标，增加文章详情
enum NavigationTarget: Hashable {
    case allArticles
    case source(String)
    case articleDetail(Article, String, String, Bool)
    // 【修改】Prediction 入口，增加一个可选参数用于指定初始栏目 ("polymarket" 或 "kalshi")
    case predictionEntry(String?)
    case videoModule   // 【新增】
    // ✅新增：视频搜索页
    case videoSearch
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
    @EnvironmentObject var predictionSyncManager: PredictionSyncManager
    @State private var showPrediction = false
    @State private var predictionDefaultSource = "polymarket"
    // 【新增】为了让界面随语言刷新
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false 
    
    // 【新增】控制退出登录确认框的状态
    @State private var showLogoutConfirmation = false
    @State private var showLegacySubscriptionSheet = false
    
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

    // 【新增】在线客服
    @ObservedObject private var supportManager = SupportChatManager.shared
    @State private var showSupportChat = false
    @AppStorage(NewsPointsPrefs.storageKey) private var autoDeductPoints = false

    // 【新增】统一取客服用的 userId
    private var supportUserId: String {
        SupportIdentity.userId(appleId: authManager.userIdentifier)
    }
    
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

                    if !authManager.isLoggedIn {
                        Section {
                            Button {
                                authManager.signInWithApple()
                            } label: {
                                HStack {
                                    Image(systemName: "apple.logo")
                                    Text(Localized.loginAccount).fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray)
                                }
                            }
                            Button {
                                PurchaseFlowManager.shared.restore(auth: authManager)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text(Localized.restorePurchase)
                                    Spacer()
                                }
                            }
                        } footer: {
                            Text(isGlobalEnglishMode
                                ? "Subscribed without signing in? Tap Restore Purchases after changing devices."
                                : "免登录订阅的用户换设备后，用同一个 Apple ID 点「恢复购买」即可。")
                        }
                    }
                    
                    // 【新增】解决审核员找不到购买入口的问题：常驻订阅入口
                    if !authManager.isSubscribed {
                        Section {
                            Button {
                                showLegacySubscriptionSheet = true
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

                    // 【新增】预测市场入口（从首页迁移到此）
                    if predictionSyncManager.hasPolymarketAvailable || predictionSyncManager.hasKalshiAvailable {
                        Section {
                            Button {
                                predictionDefaultSource = predictionSyncManager.hasPolymarketAvailable ? "polymarket" : "kalshi"
                                showPrediction = true
                            } label: {
                                HStack {
                                    Image(systemName: "chart.bar.xaxis.ascending")
                                        .foregroundColor(.purple)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isGlobalEnglishMode ? "Prediction Markets" : "预测市场")
                                            .foregroundColor(.primary)
                                            .fontWeight(.medium)
                                        Text(isGlobalEnglishMode ? "Polymarket & Kalshi mirror" : "全球预测市场镜像站")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
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
                        if !authManager.isSubscribed {
                            Toggle(isOn: $autoDeductPoints) {
                                HStack {
                                    Image(systemName: "bolt.circle.fill")
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isGlobalEnglishMode ? "Auto-deduct points" : "阅读受限新闻时直接扣点")
                                            .foregroundColor(.primary)
                                        Text(isGlobalEnglishMode
                                             ? "Skip the confirmation dialog (audio keeps playing)"
                                             : "跳过每次的确认弹窗，音频播报更连贯")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .tint(.blue)
                        }
                    }
                    
                    // 支持与反馈部分
                    Section(header: Text(Localized.feedback)) {
                        
                        // ✅【新增】在线客服（带未读角标，点开与原悬浮球完全一致）
                        Button {
                            supportManager.pendingOpenType = nil   // 只打开列表，不定位特定会话
                            showSupportChat = true
                        } label: {
                            HStack {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .purple],
                                                             startPoint: .topLeading,
                                                             endPoint: .bottomTrailing))
                                        .frame(width: 26, height: 26)
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isGlobalEnglishMode ? "Online Support" : "在线客服")
                                        .foregroundColor(.primary)
                                        .fontWeight(.medium)
                                    Text(isGlobalEnglishMode
                                         ? "Playback, subscription, points, anything."
                                         : "播放、订阅、点数、建议…任何问题都可以")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                // 未读角标
                                if supportManager.unreadTotal > 0 {
                                    Text(supportManager.unreadTotal > 99 ? "99+" : "\(supportManager.unreadTotal)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.red))
                                }
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        // 邮件反馈（原有）
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
                    
                    // ✅【修复】版本号独立成行（与「删除账号」彻底分开），且未登录也能看到
                    Section(header: Text(isGlobalEnglishMode ? "About" : "关于")) {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.gray)
                            Text(isGlobalEnglishMode ? "Version" : "版本号")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("v\(appVersion)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
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
                            
                            // ✅【修复】删除账号：不再混入版本号
                            Button(role: .destructive) {
                                showDeleteAccountConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash.fill")
                                    Text(isGlobalEnglishMode ? "Delete Account" : "删除账号")
                                    Spacer()
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
                // ✅【新增】在线客服窗（本地状态，避免和根首页的全局 sheet 冲突）
                .sheet(isPresented: $showSupportChat) {
                    SupportChatView(userId: supportUserId)
                }
                .sheet(isPresented: $showLegacySubscriptionSheet) { SubscriptionView() }
                // ✅【新增】进入个人中心即刷新未读数
                .task {
                    await supportManager.refresh(userId: supportUserId)
                }
                .fullScreenCover(isPresented: $showPrediction) {
                    NavigationStack {
                        PredictionEntryView(initialSource: predictionDefaultSource)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button(isGlobalEnglishMode ? "Close" : "关闭") {
                                        showPrediction = false
                                    }
                                }
                            }
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
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
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

// MARK: - 导航栏用户状态视图（★需求1：不再有登录中转页）
struct UserStatusToolbarItem: View {
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @Binding var showProfileSheet: Bool

    var body: some View {
        Button(action: primaryAction) {
            if authManager.isLoggedIn || authManager.isSubscribed {
                HStack(spacing: 6) {
                    Image(systemName: "person.circle.fill")
                    if authManager.isSubscribed {
                        Image(systemName: "crown.fill").foregroundColor(.yellow).font(.caption)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .clipShape(Capsule()).foregroundColor(.primary)
            } else {
                Text(Localized.loginAccount)
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .clipShape(Capsule()).foregroundColor(.primary)
            }
        }
        // 长按 = 更多入口（未登录用户也能进个人中心 / 反馈 / 恢复购买）
        .contextMenu {
            if !authManager.isLoggedIn {
                Button {
                    authManager.signInWithApple()
                } label: { Label(Localized.loginAccount, systemImage: "apple.logo") }
            }
            Button {
                showProfileSheet = true
            } label: { Label(Localized.profileTitle, systemImage: "person.crop.circle") }

            Button {
                PurchaseFlowManager.shared.restore(auth: authManager)
            } label: { Label(Localized.restorePurchase, systemImage: "arrow.clockwise") }

            Button {
                if let url = URL(string: "mailto:728308386@qq.com"),
                   UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
            } label: { Label(Localized.feedback, systemImage: "envelope") }
        }
        .accessibilityLabel(authManager.isLoggedIn ? Localized.profileTitle : Localized.loginAccount)
    }

    private func primaryAction() {
        if authManager.isLoggedIn || authManager.isSubscribed {
            showProfileSheet = true
        } else {
            // ★ 直接拉起苹果登录，不再经过任何中转页
            authManager.signInWithApple()
        }
    }
}

// MARK: - Main Source List View
// ============================================================================
// ★ 性能重构：
//   旧实现里 SourceListView 既是 NavigationStack 宿主，又观察 ResourceManager（图片下载时高频变化），
//   导致你在详情页阅读 / 听音频时，整个导航根（含详情页、列表页）被反复重算。
//   现在拆成：
//     SourceListView  —— 薄壳：只把引用往下传（Equatable 截断重算）
//     SourceListRoot  —— NavigationStack + 导航目的地：不观察任何高频对象
//     SourceHomeView  —— 首页本体：只观察 NewsViewModel
//     若干小 Host     —— 横幅 / 刷新按钮 / HUD / 视频卡 / 更新时间，各自局部观察 ResourceManager
// ============================================================================
struct SourceListView: View {
    @EnvironmentObject private var viewModel: NewsViewModel
    @EnvironmentObject private var resourceManager: ResourceManager

    var body: some View {
        SourceListRoot(viewModel: viewModel, resourceManager: resourceManager)
            .equatable()
    }
}

private struct SourceListRoot: View, Equatable {
    let viewModel: NewsViewModel
    let resourceManager: ResourceManager

    @State private var navPath = NavigationPath()
    @State private var lastNavDepth = 0

    static func == (l: SourceListRoot, r: SourceListRoot) -> Bool {
        l.viewModel === r.viewModel && l.resourceManager === r.resourceManager
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            SourceHomeView(viewModel: viewModel, resourceManager: resourceManager)
                .navigationDestination(for: NavigationTarget.self) { target in
                    destination(for: target)
                }
        }
        .environment(\.appNavPath, $navPath)
        .tint(.blue)
        .modifier(SupportChatSheetHost())
        .overlay(SyncHUDOverlay(resourceManager: resourceManager))
        .onChange(of: navPath.count) { _, newDepth in
            let isBack = newDepth < lastNavDepth
            lastNavDepth = newDepth
            guard isBack else { return }

            // 任何形式的返回都强制把详情页"已读"同步落盘
            viewModel.finishReadingIfNeeded()

            let auth = AuthManager.shared
            Task {
                await resourceManager.silentRefresh(minInterval: 45, reason: "nav-back(\(newDepth))")
                await NewsQuotaManager.shared.refresh(userId: NewsQuotaManager.currentUserId(auth: auth))
            }

            if AnonymousSubscribePromptManager.shared.hasPending {
                AnonymousSubscribePromptManager.shared.flushIfNeeded()
            } else {
                NotificationPermissionManager.shared.record(newDepth == 0 ? .newsHomeReturn : .newsListReturn)
            }
        }
    }

    @ViewBuilder
    private func destination(for target: NavigationTarget) -> some View {
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
        case .predictionEntry(let source):
            PredictionEntryView(initialSource: source)
        case .videoModule:
            VideoModuleView(showBackButton: true)
        case .videoSearch:
            VideoSearchDestinationView()
        }
    }
}

// MARK: - 首页本体
private struct HomeSearchHit: Identifiable, Sendable {
    let id: UUID
    let article: Article
    let sourceName: String
    let sourceNameEN: String
    let isContentMatch: Bool
}

private struct HomeSearchGroup: Identifiable, Sendable {
    var id: String { timestamp }
    let timestamp: String
    let items: [HomeSearchHit]
}

private struct SourceHomeView: View {
    @ObservedObject var viewModel: NewsViewModel
    let resourceManager: ResourceManager        // ★ 不观察

    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var predictionSyncManager: PredictionSyncManager
    @Environment(\.appNavPath) private var appNavPath
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var didBootstrap = false
    @State private var showAddSourceSheet = false
    @State private var showProfileSheet = false

    @State private var isSearching = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var searchGroups: [HomeSearchGroup] = []

    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                SearchBarInline(
                    text: $searchText,
                    placeholder: Localized.searchPlaceholder,
                    onCommit: { runSearch() },
                    onCancel: { withAnimation { closeSearch() } }
                )
                .padding(.bottom, 8)
                .background(Color.viewBackground)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HomeNotificationBannerHost(resourceManager: resourceManager)
            WishReplyBanner(userId: authManager.userIdentifier)
            ReportReplyBanner(userId: authManager.userIdentifier)

            if isSearchActive {
                searchResultsView
            } else {
                HomeContentGate(resourceManager: resourceManager,
                                onAddSource: { showAddSourceSheet = true }) {
                    HomeSourceList(viewModel: viewModel, resourceManager: resourceManager)
                        .equatable()
                }
            }
        }
        .supportBubble(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        .background(Color.viewBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                UserStatusToolbarItem(showProfileSheet: $showProfileSheet)
            }
            ToolbarItem(placement: .principal) {
                if authManager.isLoggedIn && !authManager.isSubscribed { NewsPointsPill() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
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

                    Button {
                        withAnimation {
                            if isSearching { closeSearch() } else { isSearching = true }
                        }
                    } label: {
                        Image(systemName: isSearching ? "xmark.circle.fill" : "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                    }

                    Button { showAddSourceSheet = true } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                    }

                    HomeRefreshButton(resourceManager: resourceManager) { manualRefresh() }
                }
                .foregroundColor(.primary)
            }
        }
        .onAppear { bootstrapIfNeeded() }
        .onChange(of: viewModel.allArticlesSortedForDisplay.count) { _, _ in
            if isSearchActive { runSearch() }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: { viewModel.loadNews() }) {
            NavigationView { AddSourceView(isFirstTimeSetup: false) }
                .environmentObject(resourceManager)
        }
        .fullScreenCover(isPresented: $showProfileSheet) { UserProfileView() }
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue {
                Task {
                    let uid = FreeQuotaManager.currentUserId(auth: authManager)
                    await FreeQuotaManager.shared.refresh(userId: uid)
                    await NewsQuotaManager.shared.refresh(userId: uid)
                }
            }
        }
        .alert(Localized.ok, isPresented: $showErrorAlert,
               actions: { Button(Localized.ok, role: .cancel) { } },
               message: { Text(errorMessage) })
    }

    // MARK: 启动（只执行一次，与旧版 NavigationStack.onAppear 语义一致）
    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        viewModel.finishReadingIfNeeded()   // 必须在 loadNews 之前
        viewModel.loadNews()

        let vm = viewModel, rm = resourceManager, english = isGlobalEnglishMode
        Task { _ = await HomeSyncRunner.run(isManual: false, viewModel: vm, resourceManager: rm, english: english) }

        let uid = authManager.userIdentifier
        Task { await SupportChatManager.shared.refresh(userId: SupportIdentity.userId(appleId: uid)) }
        Task { await predictionSyncManager.refreshAvailabilityFromServer() }
        Task { await WishReplyManager.shared.refresh(userId: uid) }
        Task { await ReportReplyManager.shared.refresh(userId: uid) }
        Task { await FreeQuotaManager.shared.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
        Task { await NewsQuotaManager.shared.refresh(userId: NewsQuotaManager.currentUserId(auth: authManager)) }
    }

    private func manualRefresh() {
        let vm = viewModel, rm = resourceManager, english = isGlobalEnglishMode
        Task {
            if let msg = await HomeSyncRunner.run(isManual: true, viewModel: vm, resourceManager: rm, english: english) {
                errorMessage = msg
                showErrorAlert = true
            }
            await authManager.checkServerSubscriptionStatus()
            let uid = FreeQuotaManager.currentUserId(auth: authManager)
            await FreeQuotaManager.shared.refresh(userId: uid)
            await NewsQuotaManager.shared.refresh(userId: uid)
        }
    }

    // MARK: 搜索（★ 只在提交时后台计算一次，不再每次重绘都扫全文）
    private func runSearch() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { isSearchActive = false; searchGroups = []; return }
        let pool = viewModel.allArticlesSortedForDisplay
        Task {
            let groups = await Task.detached(priority: .userInitiated) {
                SourceHomeView.search(pool: pool, keyword: kw)
            }.value
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == kw else { return }
            searchGroups = groups
            isSearchActive = true
        }
    }

    nonisolated private static func search(
        pool: [(article: Article, sourceName: String, sourceNameEN: String)],
        keyword kw: String
    ) -> [HomeSearchGroup] {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func hit(_ s: String?) -> Bool {
            guard let s, !s.isEmpty else { return false }
            return s.range(of: kw, options: opts) != nil
        }
        var hits: [HomeSearchHit] = []
        for item in pool {
            let a = item.article
            if hit(a.topic) || hit(a.topic_eng) {
                hits.append(HomeSearchHit(id: a.id, article: a, sourceName: item.sourceName,
                                          sourceNameEN: item.sourceNameEN, isContentMatch: false))
            } else if hit(a.article) || hit(a.article_eng) {
                hits.append(HomeSearchHit(id: a.id, article: a, sourceName: item.sourceName,
                                          sourceNameEN: item.sourceNameEN, isContentMatch: true))
            }
        }
        let dict = Dictionary(grouping: hits, by: { $0.article.timestamp })
        return dict.keys.sorted(by: >).map {
            HomeSearchGroup(timestamp: $0, items: Array((dict[$0] ?? []).reversed()))
        }
    }

    private func closeSearch() {
        isSearching = false
        isSearchActive = false
        searchText = ""
        searchGroups = []
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        ONewsDateText.string(timestamp,
                             format: isGlobalEnglishMode ? "MMM d, yyyy, EEEE" : "yyyy年M月d日, EEEE",
                             locale: Locale(identifier: isGlobalEnglishMode ? "en_US" : "zh_CN"))
    }

    private var searchResultsView: some View {
        List {
            if searchGroups.isEmpty {
                Section {
                    Text(Localized.noMatch)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(searchGroups) { group in
                    Section(header:
                        HStack {
                            Text(Localized.searchResults)
                            Spacer()
                            Text(formatTimestamp(group.timestamp))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    ) {
                        ForEach(group.items) { item in
                            let isRead = viewModel.isArticleEffectivelyRead(item.article)
                            let isLocked = NewsPointsCoordinator.shouldShowLock(timestamp: item.article.timestamp,
                                                                                auth: authManager, viewModel: viewModel)
                                && !NewsPointsCoordinator.canAccess(item.article, auth: authManager, viewModel: viewModel)
                            let isFree = !isLocked && NewsFreeBadge.isFree(timestamp: item.article.timestamp,
                                                                           auth: authManager, viewModel: viewModel)
                            Button(action: {
                                HomeArticleOpener.open(item.article, sourceName: item.sourceName,
                                                       autoPlay: false, isFromAll: true,
                                                       viewModel: viewModel, resourceManager: resourceManager,
                                                       navPath: appNavPath)
                            }) {
                                ArticleRowCardView(
                                    article: item.article,
                                    sourceName: item.sourceName,
                                    sourceNameEN: item.sourceNameEN,
                                    isReadEffective: isRead,
                                    isContentMatch: item.isContentMatch,
                                    isLocked: isLocked,
                                    isFree: isFree,
                                    showEnglish: isGlobalEnglishMode
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                if isRead {
                                    Button { withAnimation { viewModel.markAsUnread(article: item.article) } }
                                        label: { Label(Localized.markAsUnread_text, systemImage: "circle") }
                                } else {
                                    Button { withAnimation { viewModel.markAsRead(article: item.article) } }
                                        label: { Label(Localized.markAsRead_text, systemImage: "checkmark.circle") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .background(Color.viewBackground)
        .transition(.opacity.animation(.easeInOut))
    }
}

// MARK: - 首页列表（Equatable：父视图重绘时引用不变就跳过；自身仍随 NewsViewModel 刷新）
private struct HomeSourceList: View, Equatable {
    @ObservedObject var viewModel: NewsViewModel
    let resourceManager: ResourceManager

    @Environment(\.appNavPath) private var appNavPath
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    static func == (l: HomeSourceList, r: HomeSourceList) -> Bool {
        l.viewModel === r.viewModel && l.resourceManager === r.resourceManager
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                HomeVideoCardHost(resourceManager: resourceManager)

                onewsAllCard
                    .padding(.horizontal, 16)

                HomeUpdateTimeRow(resourceManager: resourceManager)

                VStack(spacing: 1) {
                    ForEach(viewModel.sources) { source in
                        NavigationLink(value: NavigationTarget.source(source.name)) {
                            HStack(spacing: 15) {
                                SourceIconView(sourceName: source.name)
                                Text(isGlobalEnglishMode ? source.name_en : source.name)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                    .animation(.none, value: isGlobalEnglishMode)
                                Spacer()
                                let unread = source.unreadCount
                                if unread > 0 {
                                    Text("\(unread)")
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
                                Button(action: { playSource(source.name) }) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.primary)
                                        .padding(8)
                                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(Color.cardBackground)
                        }

                        if source.id != viewModel.sources.last?.id {
                            Divider()
                                .padding(.leading, 110)
                                .background(Color.cardBackground)
                        }
                    }
                }
                .cornerRadius(16)
                .padding(.horizontal, 16)
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)

                Spacer().frame(height: 40)
            }
            .padding(.top, 10)
        }
    }

    private var onewsAllCard: some View {
        NavigationLink(value: NavigationTarget.allArticles) {
            HStack(alignment: .center, spacing: 1) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Localized.allArticlesDesc)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text("\(viewModel.totalUnreadCount)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(Localized.unread)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.bottom, 2)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    Button(action: { playAll() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 11))
                            Text(isGlobalEnglishMode ? "Play" : "音频播报")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .cornerRadius(16)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: { appNavPath?.wrappedValue.append(NavigationTarget.allArticles) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "text.book.closed.fill").font(.system(size: 11))
                            Text(isGlobalEnglishMode ? "Read" : "文本阅读")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .cornerRadius(16)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .fixedSize()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .cornerRadius(18)
            .shadow(color: .blue.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func playAll() {
        guard let target = viewModel.allArticlesSortedForDisplay.first(where: {
            !viewModel.isArticleEffectivelyRead($0.article)
        }) else {
            print("没有未读文章，无需播放。")
            return
        }
        ONewsHaptics.light()
        HomeArticleOpener.open(target.article, sourceName: target.sourceName,
                               autoPlay: true, isFromAll: true,
                               viewModel: viewModel, resourceManager: resourceManager,
                               navPath: appNavPath)
    }

    private func playSource(_ sourceName: String) {
        guard let source = viewModel.sources.first(where: { $0.name == sourceName }) else { return }
        guard let target = source.articles.first(where: { !viewModel.isArticleEffectivelyRead($0) }) else {
            appNavPath?.wrappedValue.append(NavigationTarget.source(sourceName))
            return
        }
        ONewsHaptics.light()
        HomeArticleOpener.open(target, sourceName: sourceName,
                               autoPlay: true, isFromAll: false,
                               viewModel: viewModel, resourceManager: resourceManager,
                               navPath: appNavPath)
    }
}

// MARK: - 局部观察 ResourceManager 的小视图
private struct HomeNotificationBannerHost: View {
    @ObservedObject var resourceManager: ResourceManager
    var body: some View {
        if let message = resourceManager.activeNotification {
            NotificationBannerView(message: message) { resourceManager.dismissNotification() }
        }
    }
}

private struct HomeRefreshButton: View {
    @ObservedObject var resourceManager: ResourceManager
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium))
        }
        .disabled(resourceManager.isSyncing)
    }
}

private struct HomeContentGate<Content: View>: View {
    @ObservedObject var resourceManager: ResourceManager
    let onAddSource: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if SubscriptionManager.shared.subscribedSourceIDs.isEmpty && !resourceManager.isSyncing {
            VStack(spacing: 20) {
                Image(systemName: "newspaper")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary.opacity(0.3))
                Text(Localized.noSubscriptions)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Button(action: onAddSource) {
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
            content()
        }
    }
}

private struct HomeUpdateTimeRow: View {
    @ObservedObject var resourceManager: ResourceManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        if !resourceManager.serverUpdateTime.isEmpty {
            HStack {
                Text(isGlobalEnglishMode
                     ? "Updated: \(resourceManager.serverUpdateTime)"
                     : "更新时间: \(resourceManager.serverUpdateTime)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .transition(.opacity)
        }
    }
}

private struct HomeVideoCardHost: View {
    @ObservedObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        if (resourceManager.showVideoModule || authManager.isPermanentVIP) && !authManager.isVideoModuleBlocked {
            card.padding(.horizontal, 16)
        }
    }

    private var card: some View {
        let disguise = resourceManager.useReviewDisguise
        let titleText = disguise
            ? (isGlobalEnglishMode ? "Video" : "视频模块")
            : (isGlobalEnglishMode ? "Video Library" : "影视频道")
        let subtitleText = disguise
            ? (isGlobalEnglishMode ? "Classic films, timeless memories" : "老片新看")
            : (isGlobalEnglishMode ? "Movies · US Drama · K-Drama · Variety Show · Anime" : "电影 · 美剧 · 韩剧 · 综艺 · 动漫")

        return NavigationLink(value: NavigationTarget.videoModule) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color.pink.opacity(0.9), Color.orange.opacity(0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                        .shadow(color: .pink.opacity(0.5), radius: 6, x: 0, y: 3)
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(titleText)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        if !disguise {
                            Text("HOT")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .cornerRadius(4)
                        }
                    }
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                ZStack {
                    LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.35),
                                            Color(red: 0.35, green: 0.12, blue: 0.45),
                                            Color(red: 0.50, green: 0.15, blue: 0.35)],
                                   startPoint: .leading, endPoint: .trailing)
                    RadialGradient(colors: [Color.white.opacity(0.15), Color.clear],
                                   center: .topLeading, startRadius: 5, endRadius: 150)
                }
            )
            .cornerRadius(16)
            .shadow(color: Color.purple.opacity(0.3), radius: 8, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

/// 同步 HUD：只有这一层观察 isSyncing / showAlreadyUpToDateAlert
private struct SyncHUDOverlay: View {
    @ObservedObject var resourceManager: ResourceManager

    var body: some View {
        ZStack {
            if resourceManager.isSyncing && resourceManager.isDownloading && !resourceManager.showAlreadyUpToDateAlert {
                VStack(spacing: 15) {
                    Text(resourceManager.syncMessage).font(.headline).foregroundColor(.white)
                    ProgressView(value: resourceManager.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .white))
                        .padding(.horizontal, 50)
                }
                .frame(width: 200, height: 160)
                .background(Material.ultraThinMaterial)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
            }

            if resourceManager.showAlreadyUpToDateAlert {
                VStack(spacing: 15) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    Text(Localized.upToDate)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(width: 180, height: 160)
                .background(Material.ultraThinMaterial)
                .background(Color.black.opacity(0.6))
                .cornerRadius(20)
                .transition(.opacity.combined(with: .scale))
                .zIndex(100)
            }
        }
        .animation(.easeInOut, value: resourceManager.isSyncing)
        .animation(.easeInOut, value: resourceManager.showAlreadyUpToDateAlert)
    }
}

/// 在线客服弹窗：ViewModifier 自己观察 SupportChatManager，不牵连导航根
private struct SupportChatSheetHost: ViewModifier {
    @ObservedObject private var supportManager = SupportChatManager.shared
    @EnvironmentObject private var authManager: AuthManager

    func body(content: Content) -> some View {
        content.sheet(isPresented: $supportManager.showChat) {
            SupportChatView(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        }
    }
}

// MARK: - 打开文章（首页 / 搜索 / 播放按钮共用）
@MainActor
enum HomeArticleOpener {
    static func open(_ article: Article, sourceName: String, autoPlay: Bool, isFromAll: Bool,
                     viewModel: NewsViewModel, resourceManager: ResourceManager,
                     navPath: Binding<NavigationPath>?) {
        let auth = AuthManager.shared
        if !NewsPointsCoordinator.canAccess(article, auth: auth, viewModel: viewModel) {
            NewsPointsCoordinator.shared.attemptUnlockArticle(article, auth: auth, viewModel: viewModel) {
                Task { @MainActor in
                    proceed(article, sourceName: sourceName, autoPlay: autoPlay, isFromAll: isFromAll,
                            viewModel: viewModel, resourceManager: resourceManager, navPath: navPath)
                }
            }
            return
        }
        proceed(article, sourceName: sourceName, autoPlay: autoPlay, isFromAll: isFromAll,
                viewModel: viewModel, resourceManager: resourceManager, navPath: navPath)
    }

    private static func proceed(_ article: Article, sourceName: String, autoPlay: Bool, isFromAll: Bool,
                                viewModel: NewsViewModel, resourceManager: ResourceManager,
                                navPath: Binding<NavigationPath>?) {
        AnonFreeReadTracker.note(article, auth: AuthManager.shared, viewModel: viewModel)
        if !article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp,
                                                  imageNames: article.images,
                                                  priority: true)
        }
        ArticleBodyCache.shared.prefetch(article: article)
        navPath?.wrappedValue.append(
            NavigationTarget.articleDetail(article, sourceName, isFromAll ? "all" : sourceName, autoPlay))
    }
}

// MARK: - 同步（首启 / 手动刷新共用）
@MainActor
enum HomeSyncRunner {
    /// 返回需要提示给用户的错误文案（仅手动同步时会返回）
    static func run(isManual: Bool, viewModel: NewsViewModel,
                    resourceManager: ResourceManager, english: Bool) async -> String? {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
            return nil
        } catch {
            resourceManager.isSyncing = false
            guard isManual else {
                print("自动同步失败 (离线模式): \(error)")
                viewModel.loadNews()
                return nil
            }
            print("手动同步失败: \(error)")
            switch error {
            case is DecodingError:
                return english ? "Data parsing failed." : "数据解析失败。"
            case let urlError as URLError where
                urlError.code == .cannotConnectToHost ||
                urlError.code == .timedOut ||
                urlError.code == .notConnectedToInternet:
                return Localized.networkError
            default:
                return english ? "Unknown error." : "发生未知错误。"
            }
        }
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

// MARK: - 寻片回复横幅（第二阶段：后台回复 → 首页展示）
struct WishReplyBanner: View {
    @ObservedObject private var manager = WishReplyManager.shared
    let userId: String?
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        Group {
            if let reply = manager.pendingReplies.first {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 16))
                        .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isGlobalEnglishMode ? "Reply to your request" : "你的寻片请求有回复啦")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.primary)

                        if !reply.wish_content.isEmpty {
                            Text("「\(reply.wish_content)」")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Text(reply.admin_reply ?? "")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 8)
                    // ✅ 由 VStack 改为 HStack，横向：回复按钮在左，关闭叉在右
                    HStack(spacing: 8) {
                        // 回复按钮 → 打开在线客服并定位到该会话
                        Button {
                            SupportChatManager.shared.openChat(type: "wish")
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(isGlobalEnglishMode ? "Reply" : "回复")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.blue))
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Button {
                            Task { await manager.acknowledge(reply, userId: userId) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(6)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 自带动画：拉到/关闭回复时平滑出现/消失，且不依赖父视图
        .animation(.easeInOut, value: manager.pendingReplies.first?.id)
    }
}

// MARK: - 举报回复横幅（后台回复举报 → 首页展示）
struct ReportReplyBanner: View {
    @ObservedObject private var manager = ReportReplyManager.shared
    let userId: String?
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        Group {
            if let reply = manager.pendingReplies.first {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.bubble.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                        .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isGlobalEnglishMode ? "Reply to your report" : "你举报的链接有回复啦")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.primary)

                        if let title = reply.video_title, !title.isEmpty {
                            let ep = (reply.episode_name?.isEmpty == false)
                                     ? " · \(reply.episode_name!)" : ""
                            Text("「\(title)\(ep)」")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Text(reply.admin_reply ?? "")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 8)
                    // ✅ VStack → HStack，回复按钮在左，关闭叉在右
                    HStack(spacing: 8) {
                        // 回复按钮 → 打开在线客服并定位到该会话
                        Button {
                            SupportChatManager.shared.openChat(type: "report")
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(isGlobalEnglishMode ? "Reply" : "回复")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.blue))
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Button {
                            Task { await manager.acknowledge(reply, userId: userId) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(6)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.25), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: manager.pendingReplies.first?.id)
    }
}

// 2. 在 Source_List.swift 文件末尾添加包装视图：
struct VideoSearchDestinationView: View {
    @EnvironmentObject var videoDataManager: OVideoDataManager
    var body: some View {
        VideoSearchTabView(dataManager: videoDataManager, autoFocus: true)
    }
}