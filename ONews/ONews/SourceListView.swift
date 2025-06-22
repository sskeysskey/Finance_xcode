import SwiftUI

struct SourceListView: View {
    // @StateObject 确保 ViewModel 的生命周期与视图绑定，只创建一次
    @StateObject private var viewModel = NewsViewModel()
    @Binding var isAuthenticated: Bool

    var body: some View {
        // NavigationView 是实现导航功能的基础
        NavigationView {
            // 主要改动点 1: 移除了 ZStack 和背景色定义
            // 列表将占据整个屏幕，并使用 InsetGroupedListStyle 的默认深色背景
            List {
                // 主要改动点 2: 将 "Unread" 部分放入 NavigationLink，使其可点击
                // 点击后会导航到我们新创建的 AllArticlesListView
                NavigationLink(destination: AllArticlesListView(viewModel: viewModel)) {
                    HStack {
                        Text("Unread")
                            .font(.system(size: 28, weight: .bold))
                            // 让 "Unread" 文本颜色与普通导航链接文本颜色一致
                            .foregroundColor(.primary)
                        
                        Spacer() // 添加一个 Spacer 将计数推到右边
                        
                        Text("\(viewModel.totalUnreadCount)")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.gray)
                    }
                    .padding()
                    // 背景色现在由 listRowBackground 控制，与下方列表项统一
                }
                .listRowBackground(Color(UIColor.secondarySystemBackground))
                .listRowSeparator(.hidden) // 隐藏这一行的分隔线
                
                // 新闻来源列表
                ForEach(viewModel.sources) { source in
                    NavigationLink(destination: ArticleListView(source: source, viewModel: viewModel)) {
                        HStack {
                            Text(source.name)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(source.articles.count)")
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowSeparator(.hidden)
                }
                .listRowBackground(Color(UIColor.secondarySystemBackground))
            }
            .listStyle(InsetGroupedListStyle()) // 使用分组样式
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
        .accentColor(.red)
        .preferredColorScheme(.dark)
    }
}
