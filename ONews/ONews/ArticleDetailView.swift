import SwiftUI
import UIKit // 导入 UIKit 以使用 UIScrollView

// 1. 定义一个 SwiftUI 可以用的分享面板封装
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        // （可选）再给它一个 modalPresentationStyle
        vc.modalPresentationStyle = .automatic
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}

// ArticleDetailView 结构体保持不变，无需修改
struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    var requestNextArticle: () -> Void
    var requestPreviousArticle: () -> Void
    
    // —— 新增的状态 ——
    @State private var isSharePresented = false
    
    @State private var isAtTop = false
    @State private var isAtBottom = false

    var body: some View {
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        let remainingImages = Array(article.images.dropFirst())
        
        let insertionInterval = (!remainingImages.isEmpty && paragraphs.count > remainingImages.count)
            ? (paragraphs.count / (remainingImages.count + 1))
            : (paragraphs.count + 1)

        ScrollView {
            Color.clear
                .frame(height: 1)
                .onAppear {
                    self.isAtTop = true
                    print("滚动到顶部")
                }
                .onDisappear {
                    self.isAtTop = false
                    print("离开顶部")
                }
            
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
                        .font(.custom("NewYork-Regular", size: 22))
                        .lineSpacing(13)
                        .padding(.horizontal, 20)
                        .textSelection(.enabled)
                    
                    if insertionInterval > 0 && (pIndex + 1) % insertionInterval == 0 {
                        let imageIndexToInsert = ((pIndex + 1) / insertionInterval) - 1
                        
                        if imageIndexToInsert < remainingImages.count {
                            ArticleImageView(imageName: remainingImages[imageIndexToInsert])
                        }
                    }
                }
                
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        self.isAtBottom = true
                        print("滚动到底部")
                    }
                    .onDisappear {
                        self.isAtBottom = false
                        print("离开底部")
                    }
            }
            .padding(.vertical)
        }
        // 3. 导航栏右侧加一个分享按钮
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isSharePresented = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        // 4. 当 isSharePresented = true 时，弹出系统分享面板
        .sheet(isPresented: $isSharePresented) {
            // 构造要分享的纯文本
            let title = article.topic
            let bodyText = paragraphs.joined(separator: "\n\n")
            let shareText = title + "\n\n" + bodyText

            ActivityView(activityItems: [shareText])
                // ↓—————— 关键 ↓——————
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .simultaneousGesture(
            DragGesture().onEnded { value in
                if self.isAtBottom && value.translation.height < -300 {
                    print("检测到符合条件的上滑手势，请求下一篇")
                    self.requestNextArticle()
                }
                else if self.isAtTop && value.translation.height > 300 {
                    print("检测到符合条件的下滑手势，请求上一篇")
                    self.requestPreviousArticle()
                }
            }
        )
    }
    
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'AT' HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }
}

// 辅助视图：用于从 Bundle 加载图片并处理占位符
struct ArticleImageView: View {
    let imageName: String
    @State private var isShowingZoomView = false

    private let horizontalPadding: CGFloat = 20

    var body: some View {
        let fullPath = "news_images/\(imageName)"

        VStack(spacing: 8) {
            if let uiImage = UIImage(named: fullPath) {
                Button(action: {
                    self.isShowingZoomView = true
                }) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
                .buttonStyle(PlainButtonStyle())

                Text((imageName as NSString).deletingPathExtension)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)
                    .textSelection(.enabled)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, horizontalPadding)
            }
        }
        .fullScreenCover(isPresented: $isShowingZoomView) {
            // ==================== 修改点 1: 传入图片名称 ====================
            // ZoomableImageView 现在是我们的容器视图
            ZoomableImageView(imageName: imageName, isPresented: $isShowingZoomView)
            // =============================================================
        }
        .padding(.vertical, 10)
    }
}


// ==================== 修改点 2: 重构 ZoomableImageView ====================
// 这个视图现在是一个容器，负责管理背景、关闭按钮和新的 ZoomableScrollView
struct ZoomableImageView: View {
    let imageName: String
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // 黑色背景
            Color.black
                .edgesIgnoringSafeArea(.all)

            // 使用我们新的、基于 UIScrollView 的视图来显示和操作图片
            ZoomableScrollView(imageName: imageName)

            // 右上角的关闭按钮
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        isPresented = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.7))
                            .background(Color.black.opacity(0.5).clipShape(Circle()))
                    }
                    .padding()
                }
                Spacer()
            }
        }
        // 当单击背景时也关闭视图 (这是通过 ZoomableScrollView 内部的 tap gesture 实现的)
        .onTapGesture {
            isPresented = false
        }
    }
}
// =======================================================================


// ==================== 新增: 核心解决方案 ZoomableScrollView ====================
// 使用 UIViewRepresentable 封装一个功能齐全的 UIScrollView
struct ZoomableScrollView: UIViewRepresentable {
    let imageName: String

    // 1. 创建底层的 UIView (UIScrollView)
    func makeUIView(context: Context) -> UIScrollView {
        let fullPath = "news_images/\(imageName)"
        guard let image = UIImage(named: fullPath) else {
            // 如果图片加载失败，返回一个空的 scroll view
            return UIScrollView()
        }

        // 创建 ScrollView 和 ImageView
        let scrollView = UIScrollView()
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        // 将 ImageView 添加到 ScrollView
        scrollView.addSubview(imageView)
        
        // 设置 AutoLayout 约束
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo:scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        // 配置 ScrollView
        scrollView.delegate = context.coordinator // 设置代理以启用缩放
        scrollView.maximumZoomScale = 5.0 // 最大缩放倍数
        scrollView.minimumZoomScale = 1.0 // 最小缩放倍数
        scrollView.bouncesZoom = true // 允许缩放时有弹性效果
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        // 关联 Coordinator 和 ImageView
        context.coordinator.imageView = imageView
        
        // 添加双击手势
        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)

        return scrollView
    }

    // 2. 当 SwiftUI 状态变化时更新 UIView
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // 在这个简单场景下，我们不需要在视图更新时做什么
        // 如果图片名称是 @State 变量，则需要在这里更新图片
    }

    // 3. 创建 Coordinator
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // 4. Coordinator 类，用于处理代理回调和手势
    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        var imageView: UIImageView?

        init(_ parent: ZoomableScrollView) {
            self.parent = parent
        }

        // 这个代理方法告诉 ScrollView 应该缩放哪个子视图
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        // 双击手势的处理方法
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                // 如果当前已放大，则恢复到原始大小
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // 如果当前是原始大小，则在双击位置放大
                let point = gesture.location(in: imageView)
                let zoomRect = zoomRect(for: scrollView, with: point, scale: scrollView.maximumZoomScale / 2)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
        
        // 计算双击后要放大的区域
        private func zoomRect(for scrollView: UIScrollView, with point: CGPoint, scale: CGFloat) -> CGRect {
            let newSize = CGSize(
                width: scrollView.frame.width / scale,
                height: scrollView.frame.height / scale
            )
            let newOrigin = CGPoint(
                x: point.x - newSize.width / 2.0,
                y: point.y - newSize.height / 2.0
            )
            return CGRect(origin: newOrigin, size: newSize)
        }
    }
}
// =======================================================================
