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

// MARK: - 【修改后】开屏马赛克加载视图 (聚拢版)
struct MosaicLoadingView: View {
    // 控制动画状态
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // 背景色
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            
            GeometryReader { geo in
                // 1. 获取屏幕中心点
                let centerX = geo.size.width / 2
                let centerY = geo.size.height / 2
                
                // 2. 定义偏移量 (控制聚拢程度)
                // xOffset: 水平距离中心的距离 (数值越小越聚拢)
                // yOffset: 垂直距离中心的距离
                let xOffset: CGFloat = 90  
                let yOffset: CGFloat = 140 
                
                ZStack {
                    // 左上：美 (红色系) -> 中心向左上偏移
                    MosaicCharacter(char: "美", colors: [.red, .orange, .pink])
                        .position(x: centerX - xOffset, y: centerY - yOffset)
                    
                    // 右上：股 (蓝色系) -> 中心向右上偏移
                    MosaicCharacter(char: "股", colors: [.blue, .cyan, .mint])
                        .position(x: centerX + xOffset, y: centerY - yOffset)
                    
                    // 左下：精 (紫色系) -> 中心向左下偏移
                    MosaicCharacter(char: "精", colors: [.purple, .indigo, .blue])
                        .position(x: centerX - xOffset, y: centerY + yOffset)
                    
                    // 右下：灵 (绿色系) -> 中心向右下偏移
                    MosaicCharacter(char: "灵", colors: [.green, .yellow, .orange])
                        .position(x: centerX + xOffset, y: centerY + yOffset)
                }
            }
            
            // 3. 中心加载内容 (保持不变)
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                
                Text("正在准备数据...")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding(30)
            .background(.regularMaterial) // 毛玻璃背景，防止文字重叠看不清
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        }
    }
}


// 单个马赛克文字组件
struct MosaicCharacter: View {
    let char: String
    let colors: [Color]
    @State private var animate = false
    
    var body: some View {
        Text(char)
            .font(.system(size: 80, weight: .heavy, design: .monospaced)) // 使用等宽字体更有像素感
            .foregroundStyle(
                // 文字填充渐变色
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                // 叠加网格纹理，模拟马赛克效果
                Image(systemName: "square.grid.3x3.fill") // 使用系统网格图标作为纹理
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.white)
                    .opacity(0.15) // 半透明白色覆盖
                    .blendMode(.overlay)
            )
            // 呼吸动画
            .scaleEffect(animate ? 1.05 : 0.95)
            .opacity(animate ? 1.0 : 0.6)
            .blur(radius: 0.5) // 轻微模糊，增加梦幻感
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 2.0)
                    .repeatForever(autoreverses: true)
                ) {
                    animate = true
                }
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

                // MARK: - 【新增】问题反馈部分
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
                            // 加一个复制图标提示用户可以点击
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .contextMenu {
                        // 长按复制邮箱，防止用户没装邮件App
                        Button {
                            UIPasteboard.general.string = "728308386@qq.com"
                        } label: {
                            Label("复制邮箱地址", systemImage: "doc.on.doc")
                        }
                    }
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

    // 【新增】控制“财经要闻”弹窗显示
    @State private var showNewsPromoSheet = false 

    @State private var showGuestMenu = false        // 【新增】：控制未登录用户的菜单

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
            return "每日免费限额\(remaining)"
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
                                    // 【修改点 1】增加高度占比，从 0.75 -> 0.79
                                    IndicesContentView()
                                        .frame(height: geometry.size.height * 0.79)
                                    
                                    // 2. 搜索/比较/财报 工具栏
                                    // 【修改点 2】减小高度占比，从 0.13 -> 0.10
                                    SearchContentView()
                                        .frame(height: geometry.size.height * 0.10)
                                    
                                    // 3. 底部 Tab 栏
                                    // 【修改点 3】减小高度占比，从 0.12 -> 0.11
                                    TopContentView()
                                        .frame(height: geometry.size.height * 0.11)
                                }
                            }
                        } else {
                            // 【修改点】使用新的马赛克加载视图
                            MosaicLoadingView()
                        }
                    }
                }
                // 👇 替换为这一行（保持 Inline 模式但不设文字）
                .navigationBarTitleDisplayMode(.inline)
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
                            // MARK: - 【修改】未登录状态：点击弹出底部菜单
                            Button {
                                showGuestMenu = true // 触发底部弹窗
                            } label: {
                                HStack {
                                    Image(systemName: "person.circle")
                                    // 即使是匿名购买的会员也显示皇冠
                                    if authManager.isSubscribed {
                                        Image(systemName: "crown.fill").foregroundColor(.yellow).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    // 中间位置：自定义额度显示
                    ToolbarItem(placement: .principal) {
                        if !authManager.isSubscribed {
                            HStack(spacing: 6) {
                                // 图标：使用小闪电或票据图标
                                Image(systemName: "bolt.shield.fill") // 或者 "ticket.fill"
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                
                                // 文字：计算剩余额度
                                let remaining = max(0, usageManager.maxFreeLimit - usageManager.dailyCount)
                                Text("今日免费点数 \(remaining)")
                                    .font(.system(size: 13, weight: .medium)) // 使用更小的字体
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                // 背景：磨砂玻璃质感的胶囊形状
                                Capsule()
                                    .fill(Color(.tertiarySystemFill))
                                    // 可选：添加一点极细的边框让它更精致
                                    .overlay(
                                        Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                                    )
                            )
                            // 强制不截断，优先压缩间距
                            .fixedSize(horizontal: true, vertical: false)
                        } else {
                            // 如果是会员，可以留空，或者显示一个精致的 App Logo / 名称
                            // Text("Finance").font(.headline)
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 12) { // 稍微调整间距
                                
                            // 1. 【修改】“新闻”按钮 -> “财经要闻”醒目文字按钮
                            Button {
                                // 点击不再直接跳转，而是弹出介绍页
                                showNewsPromoSheet = true
                            } label: {
                                HStack(spacing: 4) {
                                    // Image(systemName: "flame.fill") // 加个小火苗图标增加紧迫感/热度
                                    //     .font(.caption)
                                    Text("财经要闻")
                                        .font(.system(size: 14, weight: .bold))
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .foregroundColor(.white)
                                .background(
                                    // 醒目的渐变背景 (紫红色调)
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.purple, Color.red]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(Capsule()) // 胶囊形状
                                .shadow(color: Color.red.opacity(0.3), radius: 3, x: 0, y: 2) // 阴影增加立体感
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

        // 【新增】未登录用户的底部菜单
        .sheet(isPresented: $showGuestMenu) {
            VStack(spacing: 20) {
                // 顶部小横条
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                
                Text("欢迎使用美股精灵")
                    .font(.headline)
                
                VStack(spacing: 0) {
                    // 选项 1：登录
                    Button {
                        showGuestMenu = false // 先关闭菜单
                        // 延迟一点点再打开登录页，体验更流畅
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
                    
                    Divider().padding(.leading, 50) // 分割线
                    
                    // 选项 2：问题反馈 (这里空间很大，可以随便放邮箱)
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
                                Text("728308386@qq.com") // 邮箱显示在这里非常清晰
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
            // 【关键】限制高度：只占据屏幕底部约 25%~30% 的高度，不像全屏那么重
            .presentationDetents([.fraction(0.30)]) 
            .presentationDragIndicator(.hidden)
        }

        // 【新增】财经要闻推广弹窗
        .sheet(isPresented: $showNewsPromoSheet) {
            NewsPromoView(onOpenAction: {
                // 关闭弹窗
                showNewsPromoSheet = false
                // 执行原来的跳转逻辑
                // 稍微延迟一下，让弹窗关闭动画看起来顺滑，或者直接跳转也可以
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    openNewsApp()
                }
            })
            // 建议：加上这个可以让弹窗在 iPad 上或其他场景下展示得更自然（可选）
            .presentationDetents([.large]) 
        }

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

// MARK: - 【新增】财经要闻推广页
struct NewsPromoView: View {
    // 传入跳转逻辑
    var onOpenAction: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            // 背景：由上至下的微妙渐变
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color(UIColor.systemBackground)]),
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 25) {
                // 1. 顶部把手（指示可向下滑动关闭）
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 25) {
                        
                        // 2. 头部 ICON 和 标题
                        VStack(spacing: 15) {
                            Image(systemName: "newspaper.circle.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .foregroundStyle(
                                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)

                            Text("全球财经要闻 · 一手掌握\n支持语音播放")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center) // ✅ 加这一行
                        }
                        .padding(.top, 20)

                        // 3. 媒体品牌墙 (视觉化展示)
                        VStack(spacing: 10) {
                            Text("汇聚国际一线媒体精华")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            
                            // 使用流式布局或简单的多行排列
                            let brands = ["纽约时报", "伦敦金融时报", "华尔街日报", "Bloomberg布隆伯格", "经济学人", "路透社", "日经新闻", "华盛顿邮报", "..."]
                            
                            FlowLayoutView(items: brands)
                        }
                        .padding(.vertical, 20)

                        // 4. 核心介绍文案
                        VStack(alignment: .leading, spacing: 15) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.orange)
                                Text("原版内容，AI总结翻译，配原版图片，支持语音播放。欢迎尝试...")
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                        )
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 100) // 防止内容被按钮遮挡
                }
            }

            // 5. 底部悬浮按钮
            VStack {
                Spacer()
                Button(action: {
                    onOpenAction()
                }) {
                    HStack {
                        Image(systemName: "app.badge.fill")
                        Text("跳转到商店页面下载")
                            .fontWeight(.bold)
                    }
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(28)
                    .shadow(color: .blue.opacity(0.4), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}

// 简单的流式布局辅助视图
struct FlowLayoutView: View {
    let items: [String]
    
    var body: some View {
        // 简单模拟流式布局，这里用几行 HStack 组合
        VStack(spacing: 8) {
            HStack {
                // 安全检查：防止数组越界崩溃 (虽然你现在数据是固定的)
                if items.indices.contains(0) { BrandTag(text: items[0]) }
                if items.indices.contains(1) { BrandTag(text: items[1]) }
                if items.indices.contains(2) { BrandTag(text: items[2]) }
            }
            HStack {
                if items.indices.contains(3) { BrandTag(text: items[3]) }
                if items.indices.contains(4) { BrandTag(text: items[4]) }
            }
            HStack {
                if items.indices.contains(5) { BrandTag(text: items[5]) }
                if items.indices.contains(6) { BrandTag(text: items[6]) }
            }
            // MARK: - 新增这一行来显示被遗漏的内容
            HStack {
                if items.indices.contains(7) { BrandTag(text: items[7]) } // 华盛顿邮报
                if items.indices.contains(8) { BrandTag(text: items[8]) } // ...
            }
        }
    }
}

struct BrandTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(8)
    }
}
