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
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
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
        .onDisappear {
            // 可选恢复
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // 当应用从前台切换到后台或非激活状态时
            if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
                // 使用“静默提交”：只更新持久化与角标，不刷新 sources，避免导航栈被重建
                viewModel.commitPendingReadsSilently()
                
                // 用静默计算得到的未读数更新角标（也可依赖 viewModel.badgeUpdater 内部逻辑）
                let unread = viewModel.totalUnreadCount // 此处使用当前内存态，不触发刷新
                badgeManager.updateBadge(count: unread)
                
                print("应用进入后台，已静默提交暂存的已读文章并更新角标为: \(unread)")
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
