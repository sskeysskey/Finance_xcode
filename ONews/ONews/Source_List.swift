import SwiftUI

struct SourceListView: View {
    @StateObject private var viewModel = NewsViewModel()
    @StateObject private var resourceManager = ResourceManager()
    private let badgeManager = AppBadgeManager()
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    @State private var showAddSourceSheet = false
    
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景图放在 NavigationView 内部，确保不被其根背景遮挡
                Image("welcome_background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.4).ignoresSafeArea())
                
                Group {
                    if viewModel.sources.isEmpty && !resourceManager.isSyncing {
                        VStack(spacing: 20) {
                            Text("您还没有订阅任何新闻源")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.9))
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
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text("\(viewModel.totalUnreadCount)")
                                        .font(.system(size: 28, weight: .bold))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .padding()
                                NavigationLink(destination: AllArticlesListView(viewModel: viewModel)) {
                                    EmptyView()
                                }.opacity(0)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            
                            // 订阅源列表（显示所有来源，未读为 0 也显示）
                            ForEach(viewModel.sources) { source in
                                ZStack {
                                    HStack {
                                        Text(source.name)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text("\(source.unreadCount)")
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                    .padding(.vertical, 8)
                                    
                                    NavigationLink(destination: ArticleListView(source: source, viewModel: viewModel)) {
                                        EmptyView()
                                    }.opacity(0)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden) // iOS 16+
                        .background(Color.clear)          // 兜底
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showAddSourceSheet = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await syncResources()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                    }
                    .disabled(resourceManager.isSyncing)
                }
            }
        }
        .accentColor(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            // iOS 15 兜底：强制 UITableView 背景透明
            let tv = UITableView.appearance()
            tv.backgroundColor = .clear
            tv.separatorStyle = .none
            
            viewModel.badgeUpdater = badgeManager.updateBadge
            badgeManager.requestAuthorization()
            
            viewModel.loadNews()
            Task {
                await syncResources()
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // 当应用从前台切换到后台或非激活状态时
            if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
                // 调用静默提交方法
                viewModel.commitPendingReadsSilently()
            }
            // MARK: - 解决方案：当应用从后台或非激活状态返回前台时
            else if newPhase == .active && (oldPhase == .inactive || oldPhase == .background) {
                // 调用轻量级同步方法，以确保内存状态与持久化状态一致
                viewModel.syncReadStatusFromPersistence()
            }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: {
            print("AddSourceView 已关闭，重新加载新闻...")
            viewModel.loadNews()
        }) {
            NavigationView {
                AddSourceView(
                    isFirstTimeSetup: false,
                    onConfirm: {
                        print("AddSourceView 确定：关闭并刷新")
                        showAddSourceSheet = false
                    }
                )
            }
            .preferredColorScheme(.dark)
        }
        // 加载/进度覆盖层
        .overlay(
            Group {
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
                                .foregroundColor(.white.opacity(0.8))
                            
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            
                            Text(resourceManager.syncMessage)
                                .padding(.top, 10)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
                    .edgesIgnoringSafeArea(.all)
                    .contentShape(Rectangle())
                }
            }
        )
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
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
                print("同步失败 (无法连接或超时，已静默处理): \(urlError.localizedDescription)")
            default:
                print("同步失败 (客户端或其他问题): \(error)")
                self.errorMessage = "网络异常\n\nPlease click the refresh button ↻ in the upper right corner to try again"
                self.showErrorAlert = true
            }
        }
    }
}
