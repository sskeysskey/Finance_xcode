import SwiftUI

struct SourceListView: View {
    @StateObject private var viewModel = NewsViewModel()
    
    // 1. 引入 ResourceManager
    @StateObject private var resourceManager = ResourceManager()
    
    @Binding var isAuthenticated: Bool

    var body: some View {
        // 2. 使用 ZStack 来覆盖一个加载视图
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
                    // 添加一个手动刷新按钮
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            Task {
                                await syncResources()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .accentColor(.gray)
            .preferredColorScheme(.dark)
            
            // 3. 如果正在同步，显示加载视图
            if resourceManager.isSyncing {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.5)
                    Text(resourceManager.syncMessage)
                        .padding(.top, 10)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.4))
                .edgesIgnoringSafeArea(.all)
            }
        }
        // 4. 当视图出现时，启动同步任务
        .onAppear {
            Task {
                await syncResources()
            }
        }
    }
    
    // 5. 封装同步和加载逻辑
    private func syncResources() async {
        do {
            try await resourceManager.checkAndDownloadUpdates()
            // 同步完成后，命令 viewModel 重新加载新闻
            viewModel.loadNews()
        } catch {
            // 处理错误，例如显示一个 Alert
            print("同步失败: \(error)")
            resourceManager.syncMessage = "同步失败: \(error.localizedDescription)"
            // 在这里可以添加一个显示错误弹窗的逻辑
        }
    }
}
