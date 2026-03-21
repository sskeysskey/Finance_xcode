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
    @State private var showProfileSheet = false
    @State private var showPreferenceSheet = false
    @State private var showSearchSheet = false
    @State private var showSubscriptionSheet = false
    @State private var showLoginSheet = false
    @State private var showSyncError = false
    @State private var syncErrorMsg = ""
    @State private var hasAttemptedSync = false
    
    @Environment(\.scenePhase) private var scenePhase
    
    // ✅ 改动2：动态计算当前有数据的来源列表
    private var availableSources: [PredictionSource] {
        var sources: [PredictionSource] = []
        if !syncManager.polymarketItems.isEmpty { sources.append(.polymarket) }
        if !syncManager.kalshiItems.isEmpty { sources.append(.kalshi) }
        return sources
    }
    
    private var filteredItems: [PredictionItem] {
        let items = selectedSource == .polymarket
            ? syncManager.polymarketItems
            : syncManager.kalshiItems
        
        if prefManager.selectedSubtypes.isEmpty { return items }
        return items.filter { prefManager.selectedSubtypes.contains($0.subtype) }
    }
    
    // ✅ 改动3：判断当前是否完全没有任何数据
    private var hasNoDataAtAll: Bool {
        syncManager.polymarketItems.isEmpty && syncManager.kalshiItems.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // ✅ 改动4：仅当有多个来源时显示 Tab 栏
                    if availableSources.count > 1 {
                        sourceTabBar
                    }
                    
                    // 卡片列表
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            // 更新时间
                            if !syncManager.serverUpdateTime.isEmpty {
                                HStack {
                                    Text("更新: \(syncManager.serverUpdateTime)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                            }
                            
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
                        Button { showPreferenceSheet = true } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                        }
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
                PredictionSearchView(
                    items: syncManager.polymarketItems + syncManager.kalshiItems,
                    isSubscribed: authManager.isSubscribed,
                    onLockedTap: { handleLockedTap() }
                )
            }
            .sheet(isPresented: $authManager.showSubscriptionSheet) {
                SubscriptionView()
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
            // ✅ 改动5：监听数据变化，自动调整选中的来源
            .onAppear { adjustSelectedSource() }
            .onChange(of: syncManager.polymarketItems.count) { _ in adjustSelectedSource() }
            .onChange(of: syncManager.kalshiItems.count) { _ in adjustSelectedSource() }
            .alert("同步失败", isPresented: $showSyncError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(syncErrorMsg)
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