// /Users/yanzhang/Documents/Xcode/Indices/Finance/Launcher.swift

import SwiftUI
import Foundation

// 扩展颜色定义（保留 V2 的定义，以防后续需要）
extension Color {
    static let viewBackground = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let cardBackground = Color(red: 44/255, green: 44/255, blue: 46/255)
    static let accentGradientStart = Color(red: 10/255, green: 132/255, blue: 255/255)
    static let accentGradientEnd = Color(red: 94/255, green: 92/255, blue: 230/255)
}

@main
struct Finance: App {
    // 初始化 AuthManager 和 UsageManager
    @StateObject private var authManager = AuthManager()
    @StateObject private var usageManager = UsageManager.shared
    
    var body: some Scene {
        WindowGroup {
            MainContentView()
                // 注入环境对象
                .environmentObject(authManager)
                .environmentObject(usageManager)
        }
    }
}

// MARK: - 更新状态视图
struct UpdateOverlayView: View {
    @ObservedObject var updateManager: UpdateManager

    // 用于格式化字节数的工具
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Group {
            switch updateManager.updateState {
            case .idle:
                EmptyView()
                
            case .checking:
                StatusView(icon: nil, message: "正在检查更新...")
            
            // --- 处理单个文件下载进度的视图 ---
            case .downloadingFile(let name, let progress, let downloaded, let total):
                VStack(spacing: 12) {
                    Text("正在下载 \(name)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    // 只显示 已下载 / 总大小
                    Text("\(byteFormatter.string(fromByteCount: downloaded)) / \(byteFormatter.string(fromByteCount: total))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 300)
                .background(Color(.systemBackground).opacity(0.9))
                .cornerRadius(15)
                .shadow(radius: 10)

            // MARK: - 修改：隐藏了“正在处理文件”及总进度(1/12)的显示
            // 原来的 .downloading(let progress, let total) 被修改为不显示任何内容
            case .downloading:
                EmptyView()
                
            case .alreadyUpToDate:
                StatusView(icon: "checkmark.circle.fill", iconColor: .green, message: "当前已是最新版本")

            case .updateCompleted:
                StatusView(icon: "arrow.down.circle.fill", iconColor: .blue, message: "更新完成")

            case .error(let message):
                VStack {
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text("更新失败")
                    Text(message).font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(10)
                .shadow(radius: 10)
            }
        }
        .animation(.easeInOut, value: updateManager.updateState)
    }
}

// MARK: - 可重用的状态提示视图
struct StatusView: View {
    let icon: String?
    var iconColor: Color = .secondary
    let message: String
    
    var body: some View {
        VStack(spacing: 8) {
            if let iconName = icon {
                Image(systemName: iconName)
                    .font(.largeTitle)
                    .foregroundColor(iconColor)
            } else {
                ProgressView()
            }
            Text(message)
                .font(.headline)
        }
        .padding(20)
        .background(Color(.systemBackground).opacity(0.85))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}

// MARK: - 用户个人中心视图
struct UserProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss
    
    // 新增状态用于控制恢复购买的反馈
    @State private var isRestoring = false
    @State private var restoreMessage = ""
    @State private var showRestoreAlert = false
    
    var body: some View {
        NavigationView {
            List {
                // 用户信息部分
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
                                    Text("有效期至: \(date.prefix(10))") // 简单截取日期
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("免费用户")
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
                
                // 订阅管理部分
                Section(header: Text("订阅管理")) {
                    // 恢复购买按钮
                    Button {
                        performRestore()
                    } label: {
                        HStack {
                            if isRestoring {
                                ProgressView()
                                    .padding(.trailing, 5)
                            } else {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundColor(.blue)
                            }
                            Text(isRestoring ? "正在恢复..." : "恢复购买")
                                .foregroundColor(isRestoring ? .secondary : .primary)
                        }
                    }
                    .disabled(isRestoring)
                }
                
                // 退出登录部分
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
                    } else {
                        // 如果未登录，这里可以提供登录入口，或者直接不显示此 Section
                        Text("您当前使用的是匿名模式")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
            // 恢复结果弹窗
            .alert("恢复结果", isPresented: $showRestoreAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(restoreMessage)
            }
        }
    }
    
    // 执行恢复逻辑
    private func performRestore() {
        isRestoring = true
        Task {
            do {
                // 调用 AuthManager 的恢复方法
                try await authManager.restorePurchases()
                
                await MainActor.run {
                    isRestoring = false
                    if authManager.isSubscribed {
                        restoreMessage = "成功恢复订阅！您现在可以无限制访问数据。"
                    } else {
                        restoreMessage = "未发现有效的订阅记录。"
                    }
                    showRestoreAlert = true
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    restoreMessage = "恢复失败: \(error.localizedDescription)"
                    showRestoreAlert = true
                }
            }
        }
    }
}

struct MainContentView: View {
    @StateObject private var dataService = DataService.shared
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isDataReady = false
    @EnvironmentObject var authManager: AuthManager
    // 【新增】我们需要观察 UsageManager 来更新标题
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var showLoginSheet = false
    @State private var showSubscriptionSheet = false
    // 【新增】控制个人中心显示
    @State private var showProfileSheet = false

    // 监控 App 的生命周期状态
    @Environment(\.scenePhase) private var scenePhase

    // 判断更新流程是否在进行中，用来 disable 刷新按钮
    private var isUpdateInProgress: Bool {
        updateManager.updateState != .idle
    }
    
    // 【新增】计算动态标题
    // 【新增】计算剩余次数的计算属性
    private var remainingLimitTitle: String {
        if authManager.isSubscribed {
            return ""
        } else {
            let remaining = max(0, usageManager.maxFreeLimit - usageManager.dailyCount)
            return "本日限额次数：\(remaining)"
        }
    }

    var body: some View {
        ZStack {
            NavigationStack {
                // 【修改点】使用 ZStack 铺设背景色，解决 Light Mode 下的白色缝隙问题
                ZStack {
                    // 强制背景色为系统分组背景色（浅灰/深灰），铺满全屏
                    Color(UIColor.systemGroupedBackground)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 0) {
                        if isDataReady, let _ = dataService.sectorsPanel {
                            GeometryReader { geometry in
                                VStack(spacing: 0) {
                                    // 1. 主要的分组区域
                                    IndicesContentView()
                                        .frame(height: geometry.size.height * 0.75)
                                    
                                    // 2. 搜索/比较/财报 工具栏
                                    SearchContentView()
                                        .frame(height: geometry.size.height * 0.13)
                                    
                                    // 3. 底部 Tab 栏
                                    TopContentView()
                                        .frame(height: geometry.size.height * 0.12)
                                }
                            }
                        } else {
                            VStack(spacing: 20) {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("正在准备数据...")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
                .navigationBarTitle(remainingLimitTitle, displayMode: .inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if authManager.isLoggedIn {
                            // 已登录：点击显示个人中心
                            Button {
                                showProfileSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "person.circle.fill")
                                    if authManager.isSubscribed {
                                        Image(systemName: "crown.fill").foregroundColor(.yellow).font(.caption)
                                    }
                                }
                            }
                        } else {
                            // 未登录：显示菜单，提供登录选项
                            Menu {
                                Button {
                                    showLoginSheet = true
                                } label: {
                                    Label("登录", systemImage: "person.crop.circle")
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "person.circle")
                                    if authManager.isSubscribed {
                                        // 即使未登录，如果是订阅状态（匿名购买），也显示皇冠
                                        Image(systemName: "crown.fill").foregroundColor(.yellow).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) { // 使用 HStack 并添加间距，确保按钮并排显示
                        
                        // 1. 【新增】“新闻”按钮
                        Button {
                            openNewsApp()
                        } label: {
                            // 这里使用了系统图标 "newspaper"，你也可以换成文字 Text("新闻")
                            Image(systemName: "newspaper")
                        }
                        
                        // 2. 原有的刷新按钮 (保持逻辑不变)
                        Button {
                            Task {
                                DatabaseManager.shared.reconnectToLatestDatabase()
                                let _ = await updateManager.checkForUpdates(isManual: true)
                                print("User triggered refresh: Forcing data reload.")
                                dataService.forceReloadData()
                                await MainActor.run {
                                    self.isDataReady = true
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isUpdateInProgress)
                    }
                }
                }
            }
            .environmentObject(dataService)
            
            // 【核心修复】添加 .task 修饰符
            // 这保证了 View 一初始化就执行，专门解决冷启动问题
            .task {
                print("MainContentView .task triggered (Cold Start)")
                await handleInitialDataLoad()
            }
            // 保留 onChange 以处理从后台切回前台的情况
            .onChange(of: scenePhase) { oldPhase, newPhase in
                // 当 App 变为活跃状态时（例如首次启动，或从后台返回，或关闭系统弹窗后）
                if newPhase == .active {
                    print("App is now active (ScenePhase). Checking data...")
                    Task {
                        await handleInitialDataLoad()
                    }
                }
            }

            // 更新状态浮层
            VStack {
                Spacer()
                    .frame(height: 350) // 【新增】向下偏移
                UpdateOverlayView(updateManager: updateManager)
                Spacer()
            }
        }
        // 【新增】全局弹窗处理
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .sheet(isPresented: $showProfileSheet) { UserProfileView() } // 个人中心
        .onChange(of: authManager.showSubscriptionSheet) { _, val in showSubscriptionSheet = val }
    }

    // 统一的数据加载逻辑
    private func handleInitialDataLoad() async {
        // 双重检查：如果数据已经完全加载（isDataReady 且 sectorsPanel 非空），则跳过
        if isDataReady && dataService.sectorsPanel != nil {
            print("Data is already populated. Skipping load.")
            return
        }
        
        // 检查本地是否已有关键数据文件
        let hasLocalDescription = FileManagerHelper.getLatestFileUrl(for: "description") != nil

        if !hasLocalDescription {
            // 情况一：无本地数据（首次安装或被清理）
            print("No local data found. Starting initial sync...")
            // isManual: false 表示这是自动流程
            let updated = await updateManager.checkForUpdates(isManual: false)
            if updated {
                // 更新成功后，重新连接数据库并强制加载所有数据到内存
                DatabaseManager.shared.reconnectToLatestDatabase()
                dataService.forceReloadData()
                await MainActor.run { isDataReady = true }
                print("Initial sync successful.")
            } else {
                print("Initial sync failed or no update found (unexpected for first run).")
            }
        } else {
            // 情况二：有本地数据（常规冷启动）
            print("Local data found. Loading existing data...")
            
            // 1. 立即加载本地数据
            dataService.loadData()
            
            // 2. 强制主线程更新 UI 状态
            await MainActor.run {
                isDataReady = true
            }

            // 3. 后台静默检查更新
            Task {
                if await updateManager.checkForUpdates(isManual: false) {
                    print("Background update found. Reloading...")
                    DatabaseManager.shared.reconnectToLatestDatabase()
                    dataService.forceReloadData()
                }
            }
        }
    }

    // 将此函数添加到 MainContentView 结构体内部的底部
    private func openNewsApp() {
        // 1. 定义跳转目标
        // 如果你知道"环球要闻"的 URL Scheme (需要在该 App 的 Info.plist 中定义)，请填在这里
        // 例如: let appScheme = "globalnews://"
        // 如果没有配置 Scheme，这一步会失败，直接走下面的 App Store 逻辑
        let appSchemeStr = "globalnews://" 
        
        // 2. 定义 App Store 下载链接
        // 请替换下面的 id123456789 为"环球要闻"真实的 App ID
        let appStoreUrlStr = "https://apps.apple.com/cn/app/id6754591885"
        
        guard let appUrl = URL(string: appSchemeStr),
            let storeUrl = URL(string: appStoreUrlStr) else {
            return
        }
        
        // 3. 尝试跳转
        if UIApplication.shared.canOpenURL(appUrl) {
            // 如果已安装，直接打开
            UIApplication.shared.open(appUrl)
        } else {
            // 如果未安装，跳转到 App Store
            UIApplication.shared.open(storeUrl)
        }
    }

}
