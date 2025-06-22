import SwiftUI

struct SourceListView: View {
    // @StateObject 确保 ViewModel 的生命周期与视图绑定，只创建一次
    @StateObject private var viewModel = NewsViewModel()
    @Binding var isAuthenticated: Bool

    var body: some View {
        // NavigationView 是实现导航功能的基础，包括标题、返回按钮和侧滑返回
        NavigationView {
            // 使用 ZStack 将背景色和列表内容叠放
            ZStack {
                // 设置深色背景，适配设计图
                Color(UIColor.systemGray6).edgesIgnoringSafeArea(.all)
                
                VStack {
                    // 未读总数显示区域
                    HStack {
                        Text("Unread")
                            .font(.system(size: 28, weight: .bold))
                        Text("\(viewModel.totalUnreadCount)")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    
                    // 新闻来源列表
                    List {
                        ForEach(viewModel.sources) { source in
                            // NavigationLink 会在点击时自动导航到 destination 指定的视图
                            NavigationLink(destination: ArticleListView(source: source, viewModel: viewModel)) {
                                HStack {
                                    // 这里可以放一个图标，暂时用SF Symbols代替
                                    Image(systemName: "newspaper")
                                        .foregroundColor(.accentColor)
                                    Text(source.name)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Text("\(source.articles.count)")
                                        .foregroundColor(.gray)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .listRowBackground(Color(UIColor.secondarySystemBackground))
                    }
                    .listStyle(InsetGroupedListStyle()) // 使用分组样式
                }
            }
            .navigationTitle("Inoreader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 添加左上角的返回/登出按钮
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
        .accentColor(.red) // 设置导航链接箭头等元素的颜色
        .preferredColorScheme(.dark) // 强制使用深色模式以匹配设计
    }
}
