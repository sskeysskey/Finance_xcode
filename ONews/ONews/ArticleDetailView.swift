import SwiftUI

struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @State private var hasMarkedAsRead = false

    var body: some View {
        // ==================== 修正点 1: 逻辑代码移到此处 ====================
        // 在返回视图之前，先准备好所有需要的数据。
        
        // 1. 将文章按换行符分割成段落，并过滤掉空行。
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        // 2. 获取除第一张以外的剩余图片。
        let remainingImages = Array(article.images.dropFirst())
        
        // 3. 计算图片插入的间隔。
        // 为了均匀分布，我们将段落数除以 (图片数 + 1)。
        // 如果没有剩余图片或段落不够，则设置一个超大的间隔值，使其永不触发。
        let insertionInterval = (!remainingImages.isEmpty && paragraphs.count > remainingImages.count)
            ? (paragraphs.count / (remainingImages.count + 1))
            : (paragraphs.count + 1)

        // =================================================================

        ScrollView {
            // VStack 现在只包含纯粹的视图组件
            VStack(alignment: .leading, spacing: 16) {
                
                // ==================== 改动点 1: 将顶部文本打包并添加内边距 ====================
                // 将时间、标题、来源包裹在一个 VStack 中，并对这个 VStack 应用内边距。
                VStack(alignment: .leading, spacing: 8) {
                    Text(formattedTimestamp())
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text(article.topic)
                        .font(.system(.title, design: .serif))
                        .fontWeight(.bold)
                    
                    Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 20) // 只对这个文本块应用水平内边距
                // =======================================================================

                // ==================== 改动点 2: 图片没有水平内边距 =======================
                // 第一张图片现在会自然地延伸到屏幕边缘
                if let firstImage = article.images.first {
                    ArticleImageView(imageName: firstImage)
                }
                
                // 遍历所有段落来构建文章主体
                ForEach(paragraphs.indices, id: \.self) { pIndex in
                    // 显示段落文本
                    Text(paragraphs[pIndex])
                        .font(.custom("NewYork-Regular", size: 20))
                        .lineSpacing(10)
                        .padding(.horizontal, 20) // 每个段落也应用水平内边距
                    // =======================================================================
                    
                    // 插入的图片同样没有水平内边距
                    if insertionInterval > 0 && (pIndex + 1) % insertionInterval == 0 {
                        // 计算应该插入第几张图片
                        let imageIndexToInsert = ((pIndex + 1) / insertionInterval) - 1
                        
                        // 确保计算出的索引没有越界
                        if imageIndexToInsert < remainingImages.count {
                            ArticleImageView(imageName: remainingImages[imageIndexToInsert])
                        }
                    }
                    // =================================================================
                }
            }
            // 只保留垂直方向的内边距，给顶部和底部留出空间
            .padding(.vertical)
        }
        .navigationTitle(sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
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


// 辅助视图：用于从 Bundle 加载图片并处理占位符 (此部分无需修改)
struct ArticleImageView: View {
    let imageName: String

    var body: some View {
        let fullPath = "news_images/\(imageName)"
        
        if let uiImage = UIImage(named: fullPath) {
            Image(uiImage: uiImage)
                .resizable()
                // 改为 .fill 并限制高度，可以获得更好的视觉效果，防止图片过高
                .aspectRatio(contentMode: .fill)
                .frame(height: 250, alignment: .center) // 给一个固定的高度或最大高度
                .clipped() // 裁剪掉超出部分
                // .cornerRadius(0) // 边缘到边缘的图片通常没有圆角
        } else {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(imageName)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .frame(minHeight: 150)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.vertical, 10)
        }
    }
}
