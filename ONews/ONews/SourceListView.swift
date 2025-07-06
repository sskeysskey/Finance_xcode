import SwiftUI

struct SourceListView: View {
    @StateObject private var viewModel = NewsViewModel()
    @StateObject private var resourceManager = ResourceManager()
    
    @Binding var isAuthenticated: Bool
    
    // --- 新增状态用于Alert弹窗 ---
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            NavigationView {
                List {
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
                .navigationTitle("Inoreader")
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
                        // 在同步时禁用按钮，防止重复点击
                        .disabled(resourceManager.isSyncing)
                    }
                }
            }
            .accentColor(.gray)
            .preferredColorScheme(.dark)
            // 当本地数据加载后，即使同步失败，用户依然可以操作此NavigationView
            .onAppear {
                // 视图出现时先加载本地数据，然后再检查更新
                viewModel.loadNews()
                Task {
                    await syncResources()
                }
            }
            
            // --- 改进后的加载/进度覆盖层 ---
            if resourceManager.isSyncing {
                VStack(spacing: 15) {
                    // 根据是否处于下载阶段，显示不同UI
                    if resourceManager.isDownloading {
                        // 下载阶段：显示进度条
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
                        // 检查阶段：显示转圈
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
                // 点击背景不会穿透
                .contentShape(Rectangle())
            }
        }
        // --- 非阻塞的错误提示 ---
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    // ==================== 核心修改点在这里 ====================
    private func syncResources() async {
        do {
            try await resourceManager.checkAndDownloadUpdates()
            // 同步成功后，重新加载新闻数据以反映更新
            viewModel.loadNews()
        } catch {
            // 根据错误类型，决定是否打扰用户
            switch error {
                
            // --- 情况1: 服务器端问题，静默处理 ---
            case is DecodingError:
                // 服务器返回了非JSON数据（很可能是HTML错误页），这是服务器问题。
                print("同步失败 (服务器返回数据格式错误，已静默处理): \(error)")
                // 不做任何事，不弹窗。UI会自动解锁，用户可以继续使用本地数据。
                
            case let urlError as URLError where urlError.code == .cannotConnectToHost:
                // 明确是“无法连接到主机”，通常意味着服务器进程未启动。
                print("同步失败 (无法连接到主机，已静默处理): \(error.localizedDescription)")
                // 同样不弹窗。

            // --- 情况2: 客户端问题或其他未知错误，弹窗提示 ---
            default:
                // 对于其他所有错误（如手机没网、超时等），我们认为用户需要被告知。
                print("同步失败 (客户端或其他问题): \(error)")
                // 更新一下提示语，引导用户检查网络
                self.errorMessage = "网络异常\n\n请点击右上角刷新↻按钮重试"
                self.showErrorAlert = true
            }
        }
    }
    // ==========================================================
}
