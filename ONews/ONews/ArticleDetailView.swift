import SwiftUI

struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部日期和时间
                Text(formattedTimestamp())
                    .font(.caption)
                    .foregroundColor(.gray)
                
                // 主题
                Text(article.topic)
                    .font(.title)
                    .fontWeight(.bold)
                
                // 来源
                Text(sourceName.replacingOccurrences(of: "_", with: " ")) // 将下划线替换为空格
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                // 分割线
                Divider()
                
                // 文章正文
                Text(article.article)
                    .font(.body)
                    .lineSpacing(8) // 增加行间距，提高可读性
            }
            .padding()
        }
        .navigationTitle(sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 当视图出现时，立即调用 ViewModel 将文章标记为已读
            viewModel.markAsRead(articleID: article.id)
        }
    }
    
    // 格式化时间戳的辅助函数
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'AT' HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX") // 使用POSIX确保格式一致
        return formatter.string(from: Date()).uppercased()
    }
}
