import SwiftUI

struct SourceListView: View {
    // ==================== 修改 1: 实例化我们的新服务 ====================
    // 使用 @StateObject 来确保 viewModel 和 resourceManager 的生命周期与视图绑定
    @StateObject private var viewModel = NewsViewModel()
    @StateObject private var resourceManager = ResourceManager()
    // AppBadgeManager 是一个简单的类，不需要 @StateObject
    private let badgeManager = AppBadgeManager()
    // ====================================================================
    
    @Binding var isAuthenticated: Bool
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // ==================== 修改 2: 引入 scenePhase 环璄变量 ====================
    @Environment(\.scenePhase) private var scenePhase
    // ========================================================================
    
    var body: some View {
        ZStack {
            NavigationView {
                List {
                    // ... List 内部代码保持不变 ...
                    // "Unread" 行
                    ZStack {
                        HStack {
                            Text("Unread")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(viewModel.totalUnreadCount)")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.gray)
                        }
                        .padding()
                        NavigationLink(destination: AllArticlesListView(viewModel: viewModel)) {
                            EmptyView()
                        }.opacity(0)
                    }
                    .listRowSeparator(.hidden)
                    
                    // 新闻来源列表
                    ForEach(viewModel.sources) { source in
                        ZStack {
                            HStack {
                                Text(source.name)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(source.unreadCount)")
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 8)
                            
                            NavigationLink(destination: ArticleListView(source: source, viewModel: viewModel)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // ... Toolbar 代码保持不变 ...
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            isAuthenticated = false
                        }) {
                            Image(systemName: "chevron.backward")
                            Text("登出")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            Task {
                                await syncResources()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(resourceManager.isSyncing)
                    }
                }
            }
            .accentColor(.gray)
            .preferredColorScheme(.dark)
            .onAppear {
                // ==================== 修改 3: 连接 ViewModel 和 BadgeManager ====================
                // 将 badgeManager 的更新方法赋值给 viewModel 的更新器闭包
                viewModel.badgeUpdater = badgeManager.updateBadge
                
                // 请求权限 (如果用户已经授权，此操作不会再次打扰用户)
                badgeManager.requestAuthorization()
                // ==========================================================================
                
                // 视图出现时先加载本地数据，然后再检查更新
                viewModel.loadNews()
                Task {
                    await syncResources()
                }
            }
            // ==================== 修改 4: 监听应用状态变化 ====================
            .onChange(of: scenePhase) { oldPhase, newPhase in
                // 只有当应用从前台活跃状态(.active)进入非活跃或后台状态时，才执行更新。
                // 这能有效避免在视图导航切换时（可能短暂变为 inactive）触发不必要的操作。
                if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
                    badgeManager.updateBadge(count: viewModel.totalUnreadCount)
                    // 优化日志信息，使其更明确
                    print("应用从前台切换到后台，强制更新角标为: \(viewModel.totalUnreadCount)")
                }
            }
            // ====================================================================
            
            // ... 加载/进度覆盖层代码保持不变 ...
            if resourceManager.isSyncing {
                VStack(spacing: 15) {
                    if resourceManager.isDownloading {
                        Text(resourceManager.syncMessage)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        ProgressView(value: resourceManager.downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .padding(.horizontal, 50)
                        
                        Text(resourceManager.progressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text(resourceManager.syncMessage)
                            .padding(.top, 10)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.6))
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
            }
        }
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    // ... syncResources 函数保持不变 ...
    private func syncResources() async {
        do {
            try await resourceManager.checkAndDownloadUpdates()
            viewModel.loadNews()
        } catch {
            switch error {
            case is DecodingError:
                print("同步失败 (服务器返回数据格式错误，已静默处理): \(error)")
                
            case let urlError as URLError where
                urlError.code == .cannotConnectToHost ||
                urlError.code == .timedOut:
                
                print("同步失败 (无法连接或超时，已静默处理): \(error.localizedDescription)")
                
            default:
                print("同步失败 (客户端或其他问题): \(error)")
                self.errorMessage = "网络异常\n\n请点击右上角刷新↻按钮重试"
                self.showErrorAlert = true
            }
        }
    }
}
    
//    // ==================== 移植到外网服务器上替换用的函数 ====================
//        private func syncResources() async {
//            do {
//                try await resourceManager.checkAndDownloadUpdates()
//                viewModel.loadNews()
//            } catch let syncError as SyncError {
//                // We now switch on our clean, high-level error type.
//                switch syncError {
//                    
//                // --- 情况1: 无需打扰用户的静默失败 ---
//                // 这些是暂时性、环境性的问题，用户无法立即解决。
//                // 应用应该静默失败，允许用户使用旧数据。
//                case .serverUnreachable, .serverError, .decodingError:
//                    print("同步静默失败: \(syncError.localizedDescription)")
//                    // 不做任何事，不弹窗。UI会自动解锁。
//                    // For production, you would log these errors to a remote service.
//                    
//                // --- 情况2: 需要告知用户的严重问题 ---
//                // 安全问题或完全未知的错误，最好提示用户。
//                case .securityError, .unknown:
//                    print("同步失败，需要提示用户: \(syncError.localizedDescription)")
//                    self.errorMessage = syncError.localizedDescription
//                    self.showErrorAlert = true
//                }
//            } catch {
//                // Catch any other error that isn't a SyncError (should be rare).
//                print("捕获到未知的非同步错误: \(error)")
//                self.errorMessage = "发生了一个意外错误，请重试。"
//                self.showErrorAlert = true
//            }
//        }
//}
