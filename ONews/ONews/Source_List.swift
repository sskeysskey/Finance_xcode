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
                            // 【修改】调用 syncResources 时，明确指出是手动触发
                            await syncResources(isManual: true)
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
                // 【修改】调用 syncResources 时，使用默认的 isManual: false
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
                        // 【新增】判断是否是“已是最新”的提示状态
                        if resourceManager.syncMessage == "当前已是最新" || resourceManager.syncMessage == "新闻清单已是最新。" {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                            
                            Text(resourceManager.syncMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        // 【修改】将原来的下载中逻辑放入 else if
                        else if resourceManager.isDownloading {
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
    
    // 【修改】函数签名，增加 isManual 参数
    private func syncResources(isManual: Bool = false) async {
        do {
            // 【修改】将 isManual 参数传递给 resourceManager
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
        } catch {
            // 【新增】只在手动刷新时才显示网络错误弹窗
            if isManual {
                switch error {
                case is DecodingError:
                    self.errorMessage = "数据解析失败，请稍后重试。"
                    self.showErrorAlert = true
                case let urlError as URLError where
                    urlError.code == .cannotConnectToHost ||
                    urlError.code == .timedOut ||
                    urlError.code == .notConnectedToInternet:
                    self.errorMessage = "网络连接失败，请检查网络设置或稍后重试。"
                    self.showErrorAlert = true
                default:
                    self.errorMessage = "发生未知错误，请稍后重试。"
                    self.showErrorAlert = true
                }
                print("手动同步失败: \(error)")
            } else {
                // 自动同步失败时，在控制台打印日志，不打扰用户
                print("自动同步静默失败: \(error)")
            }
        }
    }
}
