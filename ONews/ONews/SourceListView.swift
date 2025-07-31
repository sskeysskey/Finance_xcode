import SwiftUI

struct SourceListView: View {
    // ==================== 视图模型和服务 (无变化) ====================
    @StateObject private var viewModel = NewsViewModel()
    @StateObject private var resourceManager = ResourceManager()
    private let badgeManager = AppBadgeManager()
    
    @Binding var isAuthenticated: Bool
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    @Environment(\.scenePhase) private var scenePhase
    
    // ==================== 核心修改: 添加一个计算属性来过滤来源 ====================
    /// 这个计算属性只返回那些未读文章数大于 0 的新闻来源。
    private var sourcesWithUnread: [NewsSource] {
        viewModel.sources.filter { $0.unreadCount > 0 }
    }
    // ==========================================================================
    
    var body: some View {
        ZStack {
            NavigationView {
                List {
                    ZStack {
                        HStack {
                            Text("ALL")
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
                    
                    // ==================== 核心修改: 使用过滤后的来源列表 ====================
                    // 将 ForEach 的数据源从 viewModel.sources 改为 sourcesWithUnread
                    ForEach(sourcesWithUnread) { source in
                    // ==========================================================================
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
                viewModel.badgeUpdater = badgeManager.updateBadge
                badgeManager.requestAuthorization()
                
                viewModel.loadNews()
                Task {
                    await syncResources()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
                    badgeManager.updateBadge(count: viewModel.totalUnreadCount)
                    print("应用从前台切换到后台，强制更新角标为: \(viewModel.totalUnreadCount)")
                }
            }
            
            // 加载/进度覆盖层 (无变化)
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
    
    // syncResources 函数 (无变化)
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
