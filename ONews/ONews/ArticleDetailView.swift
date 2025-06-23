import SwiftUI

// ArticleDetailView 结构体保持不变，无需修改
struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @State private var hasMarkedAsRead = false

    var body: some View {
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        let remainingImages = Array(article.images.dropFirst())
        
        let insertionInterval = (!remainingImages.isEmpty && paragraphs.count > remainingImages.count)
            ? (paragraphs.count / (remainingImages.count + 1))
            : (paragraphs.count + 1)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                .padding(.horizontal, 20)

                if let firstImage = article.images.first {
                    ArticleImageView(imageName: firstImage)
                }
                
                ForEach(paragraphs.indices, id: \.self) { pIndex in
                    Text(paragraphs[pIndex])
                        .font(.custom("NewYork-Regular", size: 23))
                        .lineSpacing(12)
                        .padding(.horizontal, 20)
                    
                    if insertionInterval > 0 && (pIndex + 1) % insertionInterval == 0 {
                        let imageIndexToInsert = ((pIndex + 1) / insertionInterval) - 1
                        
                        if imageIndexToInsert < remainingImages.count {
                            ArticleImageView(imageName: remainingImages[imageIndexToInsert])
                        }
                    }
                }
            }
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


// ==================== 主要修改区域在此 ====================
// 辅助视图：用于从 Bundle 加载图片并处理占位符
struct ArticleImageView: View {
    let imageName: String
    @State private var isShowingZoomView = false // 控制全屏视图的显示状态

    private let horizontalPadding: CGFloat = 20

    var body: some View {
        let fullPath = "news_images/\(imageName)"

        // 将整个视图包装在一个按钮中
        Button(action: {
            // 点击时，将 isShowingZoomView 设为 true
            self.isShowingZoomView = true
        }) {
            VStack(spacing: 8) {
                if let uiImage = UIImage(named: fullPath) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipped()

                    Text((imageName as NSString).deletingPathExtension)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, horizontalPadding)
                } else {
                    // 保持原来的占位符样式
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
                            .padding(.horizontal, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
        // 使用 PlainButtonStyle 来移除按钮的默认蓝色 tint 效果
        .buttonStyle(PlainButtonStyle())
        // 使用 .fullScreenCover 来呈现全屏视图
        .fullScreenCover(isPresented: $isShowingZoomView) {
            ZoomableImageView(imageName: imageName, isPresented: $isShowingZoomView)
        }
        .padding(.vertical, 10)
    }
}

// ==================== 新增的视图：用于全屏缩放和拖动图片 ====================
struct ZoomableImageView: View {
    let imageName: String
    @Binding var isPresented: Bool // 用于关闭视图

    // 状态变量
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        let fullPath = "news_images/\(imageName)"
        
        // 缩放手势
        let magnificationGesture = MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale *= delta
            }
            .onEnded { _ in
                lastScale = 1.0
                // 限制最小缩放为1倍
                if scale < 1.0 {
                    withAnimation {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
        
        // 拖动手势
        let dragGesture = DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                lastOffset = offset
            }
        
        // 双击重置手势
        let doubleTapGesture = TapGesture(count: 2)
            .onEnded {
                withAnimation {
                    scale = 1.0
                    offset = .zero
                    lastScale = 1.0
                    lastOffset = .zero
                }
            }

        ZStack {
            // 黑色背景
            Color.black
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    // 单击背景关闭视图
                    isPresented = false
                }

            // 图片
            if let uiImage = UIImage(named: fullPath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    // 只有当图片被放大时才允许拖动
                    .gesture(scale > 1 ? dragGesture : nil)
                    // 必须将缩放手势和双击手势组合起来
                    // `simultaneously(with:)` 允许两个手势同时识别
                    .gesture(SimultaneousGesture(magnificationGesture, doubleTapGesture))
            } else {
                // 如果图片加载失败，显示错误信息并允许关闭
                VStack {
                    Text("图片无法加载")
                        .foregroundColor(.white)
                    Button("关闭") {
                        isPresented = false
                    }
                    .foregroundColor(.blue)
                }
            }
            
            // 右上角的关闭按钮
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        isPresented = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}
