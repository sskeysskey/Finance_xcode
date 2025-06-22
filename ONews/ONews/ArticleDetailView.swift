import SwiftUI

struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 顶部日期和时间
                Text(formattedTimestamp())
                    .font(.caption)
                    .foregroundColor(.gray)
                
                // 主题
                Text(article.topic)
                // CHANGE: 字体稍微变大，更具冲击力
                    .font(.system(.title, design: .serif)) // 使用系统衬线字体
                    .fontWeight(.bold)
                
                // 来源
                Text(sourceName.replacingOccurrences(of: "_", with: " ")) // 将下划线替换为空格
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                // 文章正文
                Text(article.article)
                // CHANGE: 显著增大正文字体，并使用New York衬线字体，提升阅读舒适度
                    .font(.custom("NewYork-Regular", size: 20))
                    // CHANGE: 增加行间距
                    .lineSpacing(15)
            }
            .padding(.horizontal, 20) // 增加左右内边距
            .padding(.vertical)
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
