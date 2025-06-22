import SwiftUI

struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @State private var hasMarkedAsRead = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 顶部日期和时间
                Text(formattedTimestamp())
                    .font(.caption)
                    .foregroundColor(.gray)
                
                // 主题
                Text(article.topic)
                    .font(.system(.title, design: .serif))
                    .fontWeight(.bold)
                
                // 来源
                Text(sourceName.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                // 文章正文
                Text(article.article)
                    .font(.custom("NewYork-Regular", size: 20))
                    .lineSpacing(15)
            }
            .padding(.horizontal, 20)
            .padding(.vertical)
        }
        .navigationTitle(sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // 当用户离开文章详情页时标记为已读
            if !hasMarkedAsRead {
                viewModel.markAsRead(articleID: article.id)
                hasMarkedAsRead = true
            }
        }
    }
    
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'AT' HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }
}
