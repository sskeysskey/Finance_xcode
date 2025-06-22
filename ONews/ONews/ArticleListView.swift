import SwiftUI

struct ArticleListView: View {
    let source: NewsSource
    // @ObservedObject 订阅从父视图传递过来的 ViewModel 的变化
    @ObservedObject var viewModel: NewsViewModel

    var body: some View {
        List {
            // 日期显示
            Text(formattedDate())
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.top)
                // CHANGE: 隐藏这个特定行的分隔符
                .listRowSeparator(.hidden)

            // 遍历该来源下的所有文章
            ForEach(source.articles) { article in
                NavigationLink(destination: ArticleDetailView(article: article, sourceName: source.name, viewModel: viewModel)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.name)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(article.topic)
                            .fontWeight(.semibold)
                            // 根据 isRead 状态决定文字颜色
                            .foregroundColor(article.isRead ? .gray : .primary)
                    }
                    .padding(.vertical, 8)
                }
                // CHANGE: 隐藏所有新闻条目的分隔符
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(PlainListStyle()) // 使用朴素列表样式
        .navigationTitle("Unread")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // 格式化日期的辅助函数
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN") // 可根据需要调整地区
        
        if Calendar.current.isDateInToday(Date()) {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return "TODAY, \(formatter.string(from: Date()).uppercased())"
        } else if Calendar.current.isDateInYesterday(Date()) {
            return "YESTERDAY"
        } else {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return formatter.string(from: Date()).uppercased()
        }
    }
}
