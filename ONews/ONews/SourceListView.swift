import SwiftUI

struct SourceListView: View {
    // @StateObject 确保 ViewModel 的生命周期与视图绑定，只创建一次
    @StateObject private var viewModel = NewsViewModel()
    @Binding var isAuthenticated: Bool

    var body: some View {
        // NavigationView 是实现导航功能的基础
        NavigationView {
            List {
                // "Unread" 行
                ZStack {
                    // 1. 这是用户看到的 "Unread" 行内容
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

                    // 2. 覆盖其上的透明 NavigationLink，用于处理点击跳转
                    NavigationLink(destination: AllArticlesListView(viewModel: viewModel)) {
                        EmptyView()
                    }
                    .opacity(0)
                }
                .listRowSeparator(.hidden)
                
                // 新闻来源列表
                ForEach(viewModel.sources) { source in
                    ZStack {
                        // 可见的行内容
                        HStack {
                            Text(source.name)
                                .fontWeight(.semibold)
                            Spacer()
                            // ==================== 主要修改点 ====================
                            // 将 .articles.count 替换为 .unreadCount
                            // 现在这里显示的是每个来源的未读文章数量
                            Text("\(source.unreadCount)")
                                .foregroundColor(.gray)
                            // =================================================
                        }
                        .padding(.vertical, 8)
                        
                        // 不可见的导航触发器
                        NavigationLink(destination: ArticleListView(source: source, viewModel: viewModel)) {
                            EmptyView()
                        }
                        .opacity(0)
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
            }
        }
        .accentColor(.gray)
        .preferredColorScheme(.dark)
    }
}
