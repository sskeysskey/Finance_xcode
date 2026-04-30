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
    
    // ✅ 新增：用于 matchedGeometryEffect 的命名空间
    @Namespace private var sourceTabNS
    @Namespace private var sortTabNS

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

    // ✅ 改：接收 source 参数，让 TabView 每个 source 分页独立
    private func itemsForMode(_ mode: ListSortMode, source: PredictionSource) -> [PredictionItem] {
        let baseItems: [PredictionItem]

        switch mode {
        case .highestVolume:
            baseItems = source == .polymarket
                ? syncManager.polymarketItems
                : syncManager.kalshiItems

        case .trend:
            let trendItems = source == .polymarket
                ? syncManager.polymarketTrendItems
                : syncManager.kalshiTrendItems
            if trendItems.isEmpty {
                baseItems = source == .polymarket
                    ? syncManager.polymarketItems
                    : syncManager.kalshiItems
            } else {
                baseItems = trendItems
            }

        case .new:
            let trendItems = source == .polymarket
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
                infoBar.padding(.bottom, 6)

                // ✅ 关键改动：根据可用数据源数量，决定左右滑动的行为
                if availableSources.count > 1 {
                    // 多个数据源时，左右滑动切换数据源
                    TabView(selection: $selectedSource) {
                        ForEach(availableSources) { source in
                            listPage(for: source, mode: sortMode)
                                .tag(source)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.25), value: selectedSource)
                } else if let singleSource = availableSources.first {
                    // 只有一个数据源时，左右滑动切换排序模式 (New / Trend / Top)
                    TabView(selection: $sortMode) {
                        ForEach([ListSortMode.new, .trend, .highestVolume]) { mode in
                            listPage(for: singleSource, mode: mode)
                                .tag(mode)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.25), value: sortMode)
                } else {
                    // 没有数据源时的兜底显示
                    listPage(for: .polymarket, mode: sortMode)
                }
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

    // MARK: - listPage（接收 source + mode 两个参数）
    @ViewBuilder
    private func listPage(for source: PredictionSource, mode: ListSortMode) -> some View {
        let items = itemsForMode(mode, source: source)
        
        // 1. 引入 ScrollViewReader 以便进行编程式滚动
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    // 2. 在最顶部添加一个不可见的锚点视图，并赋予唯一 ID
                    Color.clear.frame(height: 0)
                        .id("top_anchor_\(source)_\(mode)")
                    
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
                                onLockedTap: { handleLockedTap() },
                                onNavigateToDetail: { selectedDetailItem = item }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.top, 8)
            }
            // 切换排序模式时滚到顶部
            .onChange(of: sortMode) { newMode in
                if source == selectedSource || availableSources.count <= 1 {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("top_anchor_\(source)_\(newMode)", anchor: .top)
                    }
                }
            }
            // 切换 source 到当前页时也回到顶部
            .onChange(of: selectedSource) { newSource in
                if newSource == source {
                    proxy.scrollTo("top_anchor_\(source)_\(sortMode)", anchor: .top)
                }
            }
        }
    }

    // MARK: - ✅ 简化：检查新分类（只更新 prefManager 状态，不弹窗）
    private func checkForNewCategories() {
        guard !syncManager.isSyncing else { return }
        
        let allItems = syncManager.polymarketItems + syncManager.kalshiItems
        guard !allItems.isEmpty else { return }
        
        prefManager.updateNewCategoryStatus(from: allItems)
    }

    // MARK: - Info Bar（更新时间 + 排序选择器）
    private var infoBar: some View {
        HStack(spacing: 10) {
            if !syncManager.serverUpdateTime.isEmpty {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: 6, height: 6)
                    // ✅ 修改点：添加 lineLimit(1) 和 fixedSize()
                    Text(syncManager.serverUpdateTime.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer()

            sortModeSelector
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 排序模式选择器（Segmented Pill 风格）
    private var sortModeSelector: some View {
        HStack(spacing: 4) {
            ForEach([ListSortMode.new, .trend, .highestVolume]) { mode in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        sortMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    // 修改点：使用 Color(uiColor: .systemBackground) 确保在 Dark Mode 下背景是白色时，文字是黑色
                .foregroundColor(sortMode == mode ? Color(uiColor: .systemBackground) : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        sortMode == mode
                        ? Color.primary // 在 Dark Mode 下是白色
                        : Color.primary.opacity(0.06)
                    )
                    .cornerRadius(12)
                }
            }
        }
    }

    // MARK: - Source Tab Bar（matched indicator 动画）
    private var sourceTabBar: some View {
        HStack(spacing: 0) {
            ForEach(availableSources) { source in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedSource = source
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(source.rawValue)
                            .font(.system(size: 15, weight: selectedSource == source ? .bold : .medium))
                            .foregroundColor(selectedSource == source ? .primary : .secondary)
                            .animation(.easeInOut(duration: 0.2), value: selectedSource)

                        ZStack {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 3)
                            if selectedSource == source {
                                Capsule()
                                    .fill(LinearGradient.brandGradientHorizontal)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "sourceUnderline", in: sourceTabNS)
                            }
                        }
                        .frame(width: 120)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 空状态（改为接收 mode 参数）
    @ViewBuilder
    private func emptyStateForMode(_ mode: ListSortMode) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient.brandGradient.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: emptyIconName(for: mode))
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(LinearGradient.brandGradient)
            }

            if hasNoDataAtAll {
                Text("暂无数据")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("请点击右上角刷新按钮同步最新数据")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else if mode == .new {
                Text("暂无新增预测项")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("当前没有标记为「New」的预测项目")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else {
                Text("暂无匹配的预测项")
                    .font(.headline)
                    .foregroundColor(.primary)
                Button("调整偏好") { showPreferenceSheet = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LinearGradient.brandGradient)
            }
        }
        .padding(.top, 80)
    }

    private func emptyIconName(for mode: ListSortMode) -> String {
        if hasNoDataAtAll { return "icloud.and.arrow.down" }
        if mode == .new { return "sparkles" }
        return "chart.bar.doc.horizontal"
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