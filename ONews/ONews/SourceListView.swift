import SwiftUI

struct SourceListView: View {
    // @StateObject 确保 ViewModel 的生命周期与视图绑定，只创建一次
    @StateObject private var viewModel = NewsViewModel()
    @Binding var isAuthenticated: Bool

    var body: some View {
        // NavigationView 是实现导航功能的基础
        NavigationView {
            List {
                // 主要改动点: 将 "Unread" 行也修改为 ZStack 结构来隐藏尖括号
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
                .listRowBackground(Color(UIColor.secondarySystemBackground))
                .listRowSeparator(.hidden)
                
                // 新闻来源列表（保持 ZStack 结构）
                ForEach(viewModel.sources) { source in
                    ZStack {
                        // 可见的行内容
                        HStack {
                            Text(source.name)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(source.articles.count)")
                                .foregroundColor(.gray)
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
                .listRowBackground(Color(UIColor.secondarySystemBackground))
            }
            .listStyle(InsetGroupedListStyle())
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
