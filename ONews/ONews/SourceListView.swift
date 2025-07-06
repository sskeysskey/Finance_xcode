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
                    // ... (你的列表代码保持不变)
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
        .alert("同步出错", isPresented: $showErrorAlert, actions: {
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
            // 关键改动：捕获错误，设置Alert所需的状态
            print("同步失败: \(error)")
            self.errorMessage = "无法连接服务器或下载资源失败。\n\(error.localizedDescription)"
            self.showErrorAlert = true
            // resourceManager内部已经将 isSyncing 置为 false，所以覆盖层会自动消失
        }
    }
}
