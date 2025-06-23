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
                Text(formattedTimestamp())
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Text(article.topic)
                    .font(.system(.title, design: .serif))
                    .fontWeight(.bold)
                
                Text(sourceName.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                // 显示第一张图片（如果存在）
                if let firstImage = article.images.first {
                    ArticleImageView(imageName: firstImage)
                }
                
                // 遍历所有段落来构建文章主体
                ForEach(paragraphs.indices, id: \.self) { pIndex in
                    // 显示段落文本
                    Text(paragraphs[pIndex])
                        .font(.custom("NewYork-Regular", size: 20))
                        .lineSpacing(10)
                    
                    // ==================== 修正点 2: 改进图片插入逻辑 ====================
                    // 我们不再使用可变的 imageIndex 计数器。
                    // 而是根据当前段落的索引来决定是否以及插入哪一张图片。
                    
                    // 只有在间隔大于0，且当前段落是插入点时，才尝试插入图片
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
            .padding(.horizontal, 0)
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
        let nameWithoutExtension = (fullPath as NSString).deletingPathExtension
        
        if let uiImage = UIImage(named: nameWithoutExtension) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding(.vertical, 10)
        } else if let uiImage = UIImage(named: fullPath) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding(.vertical, 10)
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
