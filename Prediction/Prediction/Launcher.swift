import SwiftUI

@main
struct PredictionApp: App {
    @StateObject private var syncManager = SyncManager()
    @StateObject private var authManager = AuthManager()
    @StateObject private var prefManager = PreferenceManager()
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if syncManager.showForceUpdate {
                    ForceUpdateView(storeURL: syncManager.appStoreURL)
                } else if !hasCompletedOnboarding {
                    WelcomeView(hasCompletedOnboarding: $hasCompletedOnboarding)
                } else {
                    MainContainerView()
                }
            }
            .environmentObject(syncManager)
            .environmentObject(authManager)
            .environmentObject(prefManager)
            .preferredColorScheme(.dark)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                authManager.handleAppDidBecomeActive()
            }
        }
    }
}

struct MainContainerView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var prefManager: PreferenceManager
    
    // ✅ 改动1：默认选中 kalshi（当前稳定的数据源）
    @State private var selectedSource: PredictionSource = .kalshi
    // 【新增】排序模式，默认 Trend
    @State private var sortMode: ListSortMode = .trend
    @State private var showProfileSheet = false
    @State private var showPreferenceSheet = false
    @State private var showSearchSheet = false
    @State private var showSubscriptionSheet = false
    @State private var showLoginSheet = false
    @State private var showSyncError = false
    @State private var syncErrorMsg = ""
    @State private var hasAttemptedSync = false
    
    // ✅ 新增：新分类弹窗相关状态
    @State private var showNewCategorySheet = false
    @State private var pendingNewCategories: [(type: String, subtypes: [String])] = []
    
    @Environment(\.scenePhase) private var scenePhase
    
    // 动态计算当前有数据的来源列表（同时考虑主文件和 trend 文件）
    private var availableSources: [PredictionSource] {
        var sources: [PredictionSource] = []
        if !syncManager.polymarketItems.isEmpty || !syncManager.polymarketTrendItems.isEmpty {
            sources.append(.polymarket)
        }
        if !syncManager.kalshiItems.isEmpty || !syncManager.kalshiTrendItems.isEmpty {
            sources.append(.kalshi)
        }
        return sources
    }
    
    // 【修改】根据 sortMode 决定数据源
    private var filteredItems: [PredictionItem] {
        let baseItems: [PredictionItem]
        
        switch sortMode {
        case .highestVolume:
            // 直接使用主文件（已按 volume 排序）
            baseItems = selectedSource == .polymarket
                ? syncManager.polymarketItems
                : syncManager.kalshiItems
            
        case .trend:
            // 使用 trend 文件；如果 trend 文件不存在则回退到主文件
            let trendItems = selectedSource == .polymarket
                ? syncManager.polymarketTrendItems
                : syncManager.kalshiTrendItems
            if trendItems.isEmpty {
                baseItems = selectedSource == .polymarket
                    ? syncManager.polymarketItems
                    : syncManager.kalshiItems
            } else {
                baseItems = trendItems
            }
            
        case .new:
            // 从 trend 文件中筛选 isNew == true 的项目
            let trendItems = selectedSource == .polymarket
                ? syncManager.polymarketTrendItems
                : syncManager.kalshiTrendItems
            baseItems = trendItems.filter { $0.isNew }
        }
        
        if prefManager.selectedSubtypes.isEmpty { return baseItems }
        return baseItems.filter { prefManager.selectedSubtypes.contains($0.subtype) }
    }
    
    // 判断是否完全没有任何数据
    private var hasNoDataAtAll: Bool {
        syncManager.polymarketItems.isEmpty && syncManager.kalshiItems.isEmpty
        && syncManager.polymarketTrendItems.isEmpty && syncManager.kalshiTrendItems.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 仅当有多个来源时显示 Tab 栏
                    if availableSources.count > 1 {
                        sourceTabBar
                    }
                    
                    // 卡片列表
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            // 【修改】更新时间 + 排序平铺按钮 同一行
                            infoBar
                            
                            // 通知条
                            if let note = syncManager.activeNotification {
                                NotificationBanner(message: note) {
                                    syncManager.dismissNotification()
                                }
                            }
                            
                            if filteredItems.isEmpty {
                                emptyStateView
                            } else {
                                ForEach(filteredItems) { item in
                                    PredictionCardView(
                                        item: item,
                                        isSubscribed: authManager.isSubscribed,
                                        onLockedTap: { handleLockedTap() }
                                    )
                                    .padding(.horizontal, 16)
                                }
                            }
                            
                            Spacer().frame(height: 40)
                        }
                        .padding(.top, 8)
                    }
                }
                
                // 同步 HUD
                if syncManager.isSyncing {
                    syncHUD
                }
                if syncManager.showAlreadyUpToDateAlert {
                    upToDateHUD
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if authManager.isLoggedIn {
                            showProfileSheet = true
                        } else {
                            showLoginSheet = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: authManager.isLoggedIn ? "person.circle.fill" : "person.circle")
                            if authManager.isSubscribed {
                                Image(systemName: "crown.fill")
                                    .font(.caption2).foregroundColor(.yellow)
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button { showSearchSheet = true } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 15))
                        }
                        
                        // 【修改】偏好设置按钮增加兜底同步逻辑
                        Button {
                            handlePreferenceButtonTap()
                        } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                        }
                        .disabled(syncManager.isSyncing)
                        
                        Button {
                            Task { await doManualSync() }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 15))
                        }
                        .disabled(syncManager.isSyncing)
                    }
                }
            }
            .sheet(isPresented: $showProfileSheet) { UserProfileView() }
            .sheet(isPresented: $showLoginSheet) { LoginView() }
            .sheet(isPresented: $showPreferenceSheet) {
                NavigationStack {
                    PreferenceSelectionView(isOnboarding: false)
                }
            }
            .sheet(isPresented: $showSearchSheet) {
                // 搜索依然使用主文件（数据最全）
                PredictionSearchView(
                    items: syncManager.polymarketItems + syncManager.kalshiItems,
                    isSubscribed: authManager.isSubscribed,
                    onLockedTap: { handleLockedTap() }
                )
            }
            .sheet(isPresented: $authManager.showSubscriptionSheet) {
                SubscriptionView()
            }
            // ✅ 新增：新分类弹窗
            .sheet(isPresented: $showNewCategorySheet) {
                NewCategorySheet(newCategories: pendingNewCategories)
            }
            .onChange(of: scenePhase) { new in
                if new == .active && !hasAttemptedSync {
                    hasAttemptedSync = true
                    Task { try? await syncManager.checkAndSync() }
                }
            }
            .onChange(of: authManager.isLoggedIn) { newVal in
                if newVal { showLoginSheet = false }
            }
            .onAppear {
                adjustSelectedSource()
                // 首次出现时延迟检查新分类（等数据加载完毕）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    checkForNewCategories()
                }
            }
            .onChange(of: syncManager.polymarketItems.count) { _ in adjustSelectedSource() }
            .onChange(of: syncManager.kalshiItems.count) { _ in adjustSelectedSource() }
            .onChange(of: syncManager.polymarketTrendItems.count) { _ in adjustSelectedSource() }
            .onChange(of: syncManager.kalshiTrendItems.count) { _ in adjustSelectedSource() }
            // ✅ 新增：同步完成后检查新分类
            .onChange(of: syncManager.isSyncing) { isSyncing in
                if !isSyncing {
                    // 延迟一点，等 HUD 消失后再弹窗，体验更好
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        checkForNewCategories()
                    }
                }
            }
            .alert("同步失败", isPresented: $showSyncError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(syncErrorMsg)
            }
        }
    }
    
    // MARK: - ✅ 新增：检查是否有新分类需要弹窗
    private func checkForNewCategories() {
        // 正在同步或已经弹窗中，跳过
        guard !syncManager.isSyncing,
              !syncManager.showAlreadyUpToDateAlert,
              !showNewCategorySheet else { return }
        
        let allItems = syncManager.polymarketItems + syncManager.kalshiItems
        guard !allItems.isEmpty else { return }
        
        // 老用户迁移：首次升级到有此功能的版本时，标记所有现有分类为已知
        prefManager.migrateKnownSubtypesIfNeeded(from: allItems)
        
        // 检测新分类
        let newCats = prefManager.detectNewSubtypes(from: allItems)
        if !newCats.isEmpty {
            pendingNewCategories = newCats
            showNewCategorySheet = true
        }
    }
    
    // MARK: - Info Bar
    private var infoBar: some View {
        HStack {
            if !syncManager.serverUpdateTime.isEmpty {
                Text("\(syncManager.serverUpdateTime)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 替换为平铺的按钮选择器
            sortModeSelector
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
    
    // MARK: - 排序模式平铺选择器 (替换原有的 sortModeMenu)
    private var sortModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(ListSortMode.allCases) { mode in
                Button {
                    // 添加轻微动画让切换更平滑
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sortMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10))
                        Text(mode.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1) // ✅ 限制单行显示
                            .fixedSize(horizontal: true, vertical: false) // ✅ 强制横向不被挤压换行
                    }
                    // 选中时文字为白色，未选中时为次要颜色
                    .foregroundColor(sortMode == mode ? .white : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // 选中时背景为蓝色，未选中时为半透明灰色/蓝色
                    .background(
                        sortMode == mode 
                        ? Color.blue 
                        : Color.blue.opacity(0.1)
                    )
                    .cornerRadius(8)
                }
            }
        }
    }
    
    // MARK: - Tab Bar
    // ✅ 改动6：遍历 availableSources 而非 PredictionSource.allCases
    private var sourceTabBar: some View {
        HStack(spacing: 0) {
            ForEach(availableSources) { source in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedSource = source
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(source.rawValue)
                            .font(.system(size: 15, weight: selectedSource == source ? .bold : .medium))
                            .foregroundColor(selectedSource == source ? .white : .secondary)
                        
                        Rectangle()
                            .fill(selectedSource == source ? Color.blue : Color.clear)
                            .frame(height: 3)
                            .cornerRadius(1.5)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - 空状态
    // ✅ 改动7：区分"完全无数据"和"偏好过滤导致为空"两种情况
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            if hasNoDataAtAll {
                // 完全没有数据（可能是首次启动、网络问题等）
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 50)).foregroundColor(.secondary.opacity(0.3))
                Text("暂无数据")
                    .foregroundColor(.secondary)
                Text("请点击右上角刷新按钮同步最新数据")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else if sortMode == .new {
                // New 模式下没有新项目
                Image(systemName: "sparkles")
                    .font(.system(size: 50)).foregroundColor(.secondary.opacity(0.3))
                Text("暂无新增预测项")
                    .foregroundColor(.secondary)
                Text("当前没有标记为「New」的预测项目")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else {
                // 有数据但被偏好筛选过滤掉了
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 50)).foregroundColor(.secondary.opacity(0.3))
                Text("暂无匹配的预测项")
                    .foregroundColor(.secondary)
                Button("调整偏好") { showPreferenceSheet = true }
                    .font(.subheadline).foregroundColor(.blue)
            }
        }
        .padding(.top, 80)
    }
    
    // MARK: - HUD
    private var syncHUD: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.2)
            Text("同步中...").font(.headline).foregroundColor(.white)
        }
        .frame(width: 160, height: 120)
        .background(Material.ultraThinMaterial)
        .background(Color.black.opacity(0.4))
        .cornerRadius(20)
    }
    
    private var upToDateHUD: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundColor(.green)
            Text("已是最新").font(.headline).foregroundColor(.white)
        }
        .frame(width: 160, height: 120)
        .background(Material.ultraThinMaterial)
        .background(Color.black.opacity(0.5))
        .cornerRadius(20)
        .transition(.opacity.combined(with: .scale))
    }
    
    // MARK: - 操作
    private func doManualSync() async {
        do {
            try await syncManager.checkAndSync(isManual: true)
        } catch {
            syncErrorMsg = "网络连接失败，请稍后重试"
            showSyncError = true
        }
    }

    // 【新增】处理偏好设置按钮点击
    private func handlePreferenceButtonTap() {
        // 如果本地完全没有数据（说明之前没同步成功过），则先尝试同步
        if hasNoDataAtAll {
            Task {
                do {
                    try await syncManager.checkAndSync(isManual: true)
                    // 同步成功后，如果有数据了，再打开偏好设置
                    if !hasNoDataAtAll {
                        showPreferenceSheet = true
                    } else {
                        syncErrorMsg = "服务器暂无数据"
                        showSyncError = true
                    }
                } catch {
                    syncErrorMsg = "网络连接失败，请检查网络权限后重试"
                    showSyncError = true
                }
            }
        } else {
            // 已经有数据了，直接打开
            showPreferenceSheet = true
        }
    }
    
    private func handleLockedTap() {
        if authManager.isLoggedIn {
            authManager.showSubscriptionSheet = true
        } else {
            showLoginSheet = true
        }
    }
    
    // ✅ 改动8：自动调整选中来源——如果当前选中的来源没有数据，切换到有数据的来源
    private func adjustSelectedSource() {
        guard !availableSources.isEmpty else { return }
        if !availableSources.contains(selectedSource) {
            selectedSource = availableSources.first!
        }
    }
}

// MARK: - 通知条
struct NotificationBanner: View {
    let message: String
    let onClose: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .foregroundColor(.orange).font(.system(size: 14))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(12)
        .background(Color.cardBg)
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}