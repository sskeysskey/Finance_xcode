import SwiftUI

struct PredictionMainContainerView: View {
    // 【新增】接收从外部传入的初始栏目参数
    var initialSource: String? = nil
    
    @EnvironmentObject var syncManager: PredictionSyncManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var prefManager: PreferenceManager
    @EnvironmentObject var transManager: TranslationManager

    @State private var selectedSource: PredictionSource = .kalshi
    @State private var sortMode: ListSortMode = .trend
    @State private var showProfileSheet = false
    @State private var showPreferenceSheet = false
    @State private var showSearchSheet = false
    @State private var showSubscriptionSheet = false
    @State private var showLoginSheet = false
    @State private var showSyncError = false
    @State private var syncErrorMsg = ""
    @State private var hasAttemptedSync = false
    
    // ✅ 新增：用于记录是否是首次进入当前页面
    @State private var hasAppearedOnce = false

    // ✅ 新增：用于管理详情页导航的选中项
    @State private var selectedDetailItem: PredictionItem?

    // ✅ 保留：可取消的新分类检测任务（用于 debounce）
    @State private var newCategoryCheckTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

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

    // ✅ 改为函数，接收 mode 参数，供 TabView 每页独立使用
    private func itemsForMode(_ mode: ListSortMode) -> [PredictionItem] {
        let baseItems: [PredictionItem]

        switch mode {
        case .highestVolume:
            baseItems = selectedSource == .polymarket
                ? syncManager.polymarketItems
                : syncManager.kalshiItems

        case .trend:
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
            let trendItems = selectedSource == .polymarket
                ? syncManager.polymarketTrendItems
                : syncManager.kalshiTrendItems
            baseItems = trendItems.filter { $0.isNew }
        }

        if prefManager.selectedSubtypes.isEmpty { return baseItems }
        return baseItems.filter { prefManager.selectedSubtypes.contains($0.subtype) }
    }

    private var hasNoDataAtAll: Bool {
        syncManager.polymarketItems.isEmpty && syncManager.kalshiItems.isEmpty
        && syncManager.polymarketTrendItems.isEmpty && syncManager.kalshiTrendItems.isEmpty
    }

    var body: some View {
        // 【关键改动】不再嵌套 NavigationStack，因为已在 ONews 的 NavigationStack 中
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                if availableSources.count > 1 {
                    sourceTabBar
                }
                infoBar.padding(.bottom, 8)

                TabView(selection: $sortMode) {
                    ForEach([ListSortMode.new, .trend, .highestVolume]) { mode in
                        listPage(for: mode).tag(mode)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            if syncManager.isSyncing { syncHUD }
            if syncManager.showAlreadyUpToDateAlert { upToDateHUD }
        }
        .navigationTitle("预测市场")
        .navigationBarTitleDisplayMode(.inline)
        // ✅ 关键修复：将 navigationDestination 放在 ZStack 上，位于所有 lazy 容器之外
        .navigationDestination(isPresented: Binding(
            get: { selectedDetailItem != nil },
            set: { if !$0 { selectedDetailItem = nil } }
        )) {
            if let item = selectedDetailItem {
                PredictionDetailView(item: item)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    // 中英切换
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            transManager.toggle()
                        }
                    } label: {
                        Text(transManager.language == .chinese ? "英" : "中")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                    }
                    
                    // 搜索
                    Button { showSearchSheet = true } label: {
                        // ✅ 修改：显式指定颜色
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundColor(.primary) 
                    }
                    
                    // 偏好
                    Button { handlePreferenceButtonTap() } label: {
                        // ✅ 修改：显式指定颜色
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .overlay(alignment: .topTrailing) {
                                if prefManager.hasNewCategories {
                                    Circle().fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 4, y: -4)
                                }
                            }
                    }
                    .disabled(syncManager.isSyncing)
                    
                    // 刷新
                    Button {
                        Task { await doManualSync() }
                    } label: {
                        // ✅ 修改：显式指定颜色
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                    }
                    .disabled(syncManager.isSyncing)
                }
            }
        }
        // 【关键】移除了 .sheet(isPresented: $showProfileSheet) 和 .sheet(isPresented: $showLoginSheet)
        // 因为登录和个人中心由 ONews 的 SourceListView 层统一管理
        .sheet(isPresented: $showPreferenceSheet) {
            NavigationStack {
                PreferenceSelectionView(isOnboarding: false)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            PredictionSearchView(
                items: syncManager.polymarketItems + syncManager.kalshiItems,
                isSubscribed: authManager.isSubscribed,  // ← 共用 ONews AuthManager
                onLockedTap: { handleLockedTap() }
            )
        }
        // 【关键】订阅弹窗也由 ONews 的 authManager 统一控制
        .sheet(isPresented: $authManager.showSubscriptionSheet) {
            SubscriptionView()  // ONews 的订阅视图
        }
        .onChange(of: scenePhase) { new in
            if new == .active && !hasAttemptedSync {
                hasAttemptedSync = true
                Task { try? await syncManager.checkAndSync() }
            }
        }
        .onAppear {
            // 【新增】根据传入的参数设置初始选中的栏目
            if let source = initialSource {
                if source == "polymarket" {
                    selectedSource = .polymarket
                } else if source == "kalshi" {
                    selectedSource = .kalshi
                }
            }
            
            adjustSelectedSource()
            transManager.reload()
            
            // ✅ 修改：只在首次进入该页面时触发自动同步，从详情页返回时不触发
            if !hasAppearedOnce {
                hasAppearedOnce = true
                if !syncManager.isSyncing {
                    Task {
                        try? await syncManager.checkAndSync(isManual: false)
                    }
                }
            }
        }
        .onChange(of: syncManager.polymarketItems.count) { _ in adjustSelectedSource() }
        .onChange(of: syncManager.kalshiItems.count) { _ in adjustSelectedSource() }
        .onChange(of: syncManager.polymarketTrendItems.count) { _ in adjustSelectedSource() }
        .onChange(of: syncManager.kalshiTrendItems.count) { _ in adjustSelectedSource() }
        .onChange(of: syncManager.isSyncing) { isSyncing in
            if !isSyncing { transManager.reload() }
        }
        .onChange(of: syncManager.dataGeneration) { _ in
            newCategoryCheckTask?.cancel()
            newCategoryCheckTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                checkForNewCategories()
            }
        }
        .alert("同步失败", isPresented: $showSyncError) {
            Button("确定", role: .cancel) {}
        } message: { Text(syncErrorMsg) }
    }

    // MARK: - listPage（与原版基本一致，PredictionCardView 已经共用 ONews AuthManager）
    @ViewBuilder
    private func listPage(for mode: ListSortMode) -> some View {
        let items = itemsForMode(mode)
        
        // 1. 引入 ScrollViewReader 以便进行编程式滚动
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    // 2. 在最顶部添加一个不可见的锚点视图，并赋予唯一 ID
                    Color.clear.frame(height: 0)
                        .id("top_anchor_\(mode)")
                    
                    // 通知条
                    if let note = syncManager.activeNotification {
                        NotificationBanner(message: note) {
                            syncManager.dismissNotification()
                        }
                    }
                    
                    if items.isEmpty {
                        emptyStateForMode(mode)
                    } else {
                        ForEach(items) { item in
                            PredictionCardView(
                                item: item,
                                isSubscribed: authManager.isSubscribed,
                                onLockedTap: { handleLockedTap() },          // ✅ 补上逗号
                                onNavigateToDetail: { selectedDetailItem = item }  // ✅ 修正参数名
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.top, 8)
            }
            // 3. 监听 sortMode 的变化。当用户滑动/点击切换到当前 mode 时，触发滚动到顶部
            .onChange(of: sortMode) { newMode in
                if newMode == mode {
                    // 可以根据需要决定是否加 withAnimation
                    proxy.scrollTo("top_anchor_\(mode)", anchor: .top)
                }
            }
            // 切换数据源时强制重建 ScrollView，自动回到顶部
            .id("page_\(mode)_\(selectedSource)")
        }
    }

    // MARK: - ✅ 简化：检查新分类（只更新 prefManager 状态，不弹窗）
    private func checkForNewCategories() {
        guard !syncManager.isSyncing else { return }
        
        let allItems = syncManager.polymarketItems + syncManager.kalshiItems
        guard !allItems.isEmpty else { return }
        
        prefManager.updateNewCategoryStatus(from: allItems)
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

            sortModeSelector
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 排序模式选择器
    private var sortModeSelector: some View {
        HStack(spacing: 8) {
            // 👇 将 ListSortMode.allCases 替换为自定义顺序的数组
            ForEach([ListSortMode.new, .trend, .highestVolume]) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sortMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10))
                        Text(mode.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundColor(sortMode == mode ? Color(UIColor.systemBackground) : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        sortMode == mode
                        ? Color.primary
                        : Color.primary.opacity(0.06)
                    )
                    .cornerRadius(12)
                }
            }
        }
    }

    // MARK: - Tab Bar
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
                            .foregroundColor(selectedSource == source ? .primary : .secondary)

                        Rectangle()
                            .fill(selectedSource == source ? Color.primary : Color.clear)
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

    // MARK: - 空状态（改为接收 mode 参数）
    @ViewBuilder
    private func emptyStateForMode(_ mode: ListSortMode) -> some View {
        VStack(spacing: 16) {
            if hasNoDataAtAll {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 50)).foregroundColor(.secondary.opacity(0.3))
                Text("暂无数据")
                    .foregroundColor(.secondary)
                Text("请点击右上角刷新按钮同步最新数据")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else if mode == .new {
                Image(systemName: "sparkles")
                    .font(.system(size: 50)).foregroundColor(.secondary.opacity(0.3))
                Text("暂无新增预测项")
                    .foregroundColor(.secondary)
                Text("当前没有标记为「New」的预测项目")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 50)).foregroundColor(.secondary.opacity(0.3))
                Text("暂无匹配的预测项")
                    .foregroundColor(.secondary)
                Button("调整偏好") { showPreferenceSheet = true }
                    .font(.subheadline).foregroundColor(.primary)
            }
        }
        .padding(.top, 80)
    }

    // MARK: - HUD
    private var syncHUD: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.primary).scaleEffect(1.2)
            Text("同步中...").font(.headline).foregroundColor(.primary)
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
            Text("已是最新").font(.headline).foregroundColor(.primary)
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

    private func handlePreferenceButtonTap() {
        if hasNoDataAtAll {
            Task {
                do {
                    try await syncManager.checkAndSync(isManual: true)
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
            showPreferenceSheet = true
        }
    }

    // 【关键】点击锁定内容时，弹出 ONews 的统一订阅页
    private func handleLockedTap() {
        authManager.showSubscriptionSheet = true
    }

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
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(5)
                    .background(Color.primary.opacity(0.1))
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