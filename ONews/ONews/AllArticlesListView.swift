import SwiftUI

// 新建的视图，用于展示所有来源的文章
struct AllArticlesListView: View {
    // @ObservedObject 订阅从父视图传递过来的 ViewModel 的变化
    @ObservedObject var viewModel: NewsViewModel

    var body: some View {
        List {
            // 首先遍历所有的新闻来源
            ForEach(viewModel.sources) { source in
                // 然后遍历该来源下的所有文章
                ForEach(source.articles) { article in
                    // 为每篇文章创建一个导航链接，指向文章详情页
                    NavigationLink(destination: ArticleDetailView(article: article, sourceName: source.name, viewModel: viewModel)) {
                        VStack(alignment: .leading, spacing: 8) {
                            // 显示文章所属的来源名称
                            Text(source.name)
                                .font(.caption)
                                .foregroundColor(.gray)
                            // 显示文章标题
                            Text(article.topic)
                                .fontWeight(.semibold)
                                // 根据 isRead 状态决定文字颜色
                                .foregroundColor(article.isRead ? .gray : .primary)
                        }
                        .padding(.vertical, 8)
                    }
                    // 隐藏分隔线，保持UI统一
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(PlainListStyle()) // 使用朴素列表样式，适合连续的列表
        .navigationTitle("All Articles") // 设置导航栏标题
        .navigationBarTitleDisplayMode(.inline)
    }
}
