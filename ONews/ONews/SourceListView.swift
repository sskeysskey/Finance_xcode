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
    
    private func syncResources() async {
        do {
            try await resourceManager.checkAndDownloadUpdates()
            // 同步成功后，重新加载新闻数据以反映更新
            viewModel.loadNews()
        } catch {
            // 根据错误类型，决定是否打扰用户
            switch error {
                
                // --- 情况1: 服务器端或连接性问题，静默处理 ---
            case is DecodingError:
                // 服务器返回了非JSON数据（很可能是HTML错误页），这是服务器问题。
                print("同步失败 (服务器返回数据格式错误，已静默处理): \(error)")
                
                // ==================== 核心修改区域 2: 扩展静默处理的错误类型 ====================
            case let urlError as URLError where
                urlError.code == .cannotConnectToHost || // 连接被拒（IP对，服务没开）
                urlError.code == .timedOut:             // 请求超时（IP错，或网络差）
//                urlError.code == .notConnectedToInternet: // 设备没联网
                
                print("同步失败 (无法连接或超时，已静默处理): \(error.localizedDescription)")
                // 同样不弹窗。UI会自动解锁，用户可以继续使用本地数据。
                // ==========================================================================
                
                // --- 情况2: 其他未知错误，弹窗提示 ---
            default:
                // 对于其他所有错误，我们认为用户需要被告知。
                print("同步失败 (客户端或其他问题): \(error)")
                // 更新一下提示语，引导用户检查网络
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
