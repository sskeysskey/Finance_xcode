import SwiftUI

struct SourceListView: View {
    @StateObject private var viewModel = NewsViewModel()
    @StateObject private var resourceManager = ResourceManager()
    private let badgeManager = AppBadgeManager()
    
    @Binding var isAuthenticated: Bool
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // ==================== 核心修改: 添加 Sheet 状态 ====================
    @State private var showAddSourceSheet = false
    // ===============================================================
    
    @Environment(\.scenePhase) private var scenePhase
    
    // 这个计算属性现在依然有效，因为它操作的是 viewModel.sources，
    // 而 viewModel.sources 已经被过滤为只包含订阅的源了。
    private var sourcesWithUnread: [NewsSource] {
        viewModel.sources.filter { $0.unreadCount > 0 }
    }
    
    var body: some View {
        ZStack {
            NavigationView {
                // ==================== 核心修改: 空状态处理 ====================
                Group {
                    if viewModel.sources.isEmpty && !resourceManager.isSyncing {
                        VStack(spacing: 20) {
                            Text("您还没有订阅任何新闻源")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Button(action: { showAddSourceSheet = true }) {
                                Label("点击这里添加", systemImage: "plus.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        List {
                            // "ALL" 链接
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
                            
                            // 订阅源列表
                            ForEach(sourcesWithUnread) { source in
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
                    }
                }
                // ===============================================================
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
                    
                    // ==================== 核心修改: 添加“添加源”按钮 ====================
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            showAddSourceSheet = true
                        }) {
                            Image(systemName: "plus")
                        }
                    }
                    // =================================================================
                    
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
            // ==================== 核心修改: 弹出添加源页面 ====================
            .sheet(isPresented: $showAddSourceSheet, onDismiss: {
                // 当 sheet 关闭时，重新加载新闻以反映订阅变化
                print("AddSourceView 已关闭，重新加载新闻...")
                viewModel.loadNews()
            }) {
                // 将 AddSourceView 包装在 NavigationView 中，使其拥有自己的导航栏
                NavigationView {
                    AddSourceView(isFirstTimeSetup: false)
                }
                .preferredColorScheme(.dark)
            }
            // ===============================================================
            
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
                self.errorMessage = "网络异常\n\nPlease click the refresh button ↻ in the upper right corner to try again"
                self.showErrorAlert = true
            }
        }
    }
}
