import SwiftUI
import UIKit
import Photos

// ActivityView 结构体保持不变...
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        vc.modalPresentationStyle = .automatic
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    let unreadCount: Int
    @ObservedObject var viewModel: NewsViewModel
    var requestNextArticle: () -> Void
    var requestPreviousArticle: () -> Void
    
    @State private var isSharePresented = false
    @State private var isAtTop = false
    @State private var isAtBottom = false

    // ==================== 修改点 1 of 3：新增状态变量 ====================
    // 用于控制“已复制”提示条的显示
    @State private var showCopyToast = false
    // 提示条要显示的文字
    @State private var toastMessage = ""
    // =================================================================

    var body: some View {
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        let remainingImages = Array(article.images.dropFirst())
        
        let distributeEvenly = !remainingImages.isEmpty && remainingImages.count < paragraphs.count
        let insertionInterval = distributeEvenly
            ? paragraphs.count / (remainingImages.count + 1)
            : 1

        // ==================== 修改点 2 of 3：使用 ZStack 包裹视图 ====================
        // ZStack 允许我们将提示条（Toast）浮动在滚动视图之上
        ZStack {
            ScrollView {
                Color.clear.frame(height: 1)
                    .onAppear { self.isAtTop = true }
                    .onDisappear { self.isAtTop = false }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formatDate(from: article.timestamp))
                            .font(.caption).foregroundColor(.gray)
                        
                        Text(article.topic)
                            .font(.system(.title, design: .serif)).fontWeight(.bold)
                        Text(sourceName.replacingOccurrences(of: "_", with: " "))
                            .font(.subheadline).foregroundColor(.gray)
                    }
                    .padding(.horizontal, 20)
                    
                    if let firstImage = article.images.first {
                        ArticleImageView(imageName: firstImage, timestamp: article.timestamp)
                    }

                    ForEach(paragraphs.indices, id: \.self) { pIndex in
                        Text(paragraphs[pIndex])
                            .font(.custom("NewYork-Regular", size: 21))
                            .lineSpacing(15)
                            .padding(.horizontal, 18)
                            // ==================== 修改点 3 of 3：修改长按手势的逻辑 ====================
                            .gesture(
                                LongPressGesture()
                                    .onEnded { _ in
                                        // 1. 复制文本到剪贴板
                                        UIPasteboard.general.string = paragraphs[pIndex]
                                        
                                        // 2. 设置提示文字并显示提示条（带动画）
                                        self.toastMessage = "选中段落已复制"
                                        withAnimation(.spring()) {
                                            self.showCopyToast = true
                                        }
                                        
                                        // 3. 2秒后自动隐藏提示条（带动画）
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            withAnimation(.spring()) {
                                                self.showCopyToast = false
                                            }
                                        }
                                    }
                            )
                            // ==========================================================================

                        if (pIndex + 1) % insertionInterval == 0 {
                            let imageIndexToInsert = (pIndex + 1) / insertionInterval - 1
                            if imageIndexToInsert < remainingImages.count {
                                ArticleImageView(
                                    imageName: remainingImages[imageIndexToInsert],
                                    timestamp: article.timestamp
                                )
                            }
                        }
                    }

                    if !distributeEvenly && remainingImages.count > paragraphs.count {
                        let extraImages = remainingImages.dropFirst(paragraphs.count)
                        ForEach(Array(extraImages), id: \.self) { imageName in
                            ArticleImageView(imageName: imageName, timestamp: article.timestamp)
                        }
                    }

                    Color.clear.frame(height: 1)
                        .onAppear { self.isAtBottom = true }
                        .onDisappear { self.isAtBottom = false }
                }
                .padding(.vertical)
            }
            
            // --- 这是新增的提示条视图 ---
            if showCopyToast {
                VStack {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                        Text(toastMessage)
                            .foregroundColor(.white)
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule()) // 使用胶囊形状
                    .shadow(radius: 10)
                    
                    Spacer() // 将提示条推到顶部
                }
                .padding(.top, 5) // 距离顶部安全区一点距离
                .transition(.move(edge: .top).combined(with: .opacity)) // 定义出现和消失的动画
                .zIndex(1) // 确保它在最上层
            }
        }
        .toolbar {
            // 中间位置：源名称 + unread + 日期
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        // 源名称
                        Text(sourceName.replacingOccurrences(of: "_", with: " "))
                            .font(.headline)
                        // unread + 日期
                        HStack(spacing: 8) {
                            Text("\(unreadCount) unread")
                            Text(formatMonthDay(from: article.timestamp))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isSharePresented = true } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSharePresented) {
            let shareText = article.topic + "\n\n" + paragraphs.joined(separator: "\n\n")
            ActivityView(activityItems: [shareText])
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .simultaneousGesture(
            DragGesture().onEnded { value in
                if self.isAtBottom && value.translation.height < -300 { self.requestNextArticle() }
                else if self.isAtTop && value.translation.height > 300 { self.requestPreviousArticle() }
            }
        )
    }
    
    // 在 struct ArticleDetailView 里，和 formatDate 同级添加：
    private func formatMonthDay(from timestamp: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyMMdd"
        guard let date = input.date(from: timestamp) else {
            return timestamp
        }
        let output = DateFormatter()
        output.dateFormat = "MMMM d"
        output.locale = Locale(identifier: "en_US_POSIX")
        return output.string(from: date)
    }
    
    private func formatDate(from timestamp: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyMMdd"

        guard let date = inputFormatter.date(from: timestamp) else {
            return timestamp.uppercased()
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        outputFormatter.locale = Locale(identifier: "en_US_POSIX")

        return outputFormatter.string(from: date).uppercased()
    }
}

// ArticleImageView, ZoomableImageView, ZoomableScrollView 的代码保持不变
struct ArticleImageView: View {
    let imageName: String
    let timestamp: String
    @State private var isShowingZoomView = false

    private let horizontalPadding: CGFloat = 20
    
    // 新增：计算图片在 Documents 目录中的完整路径
    private var imagePath: String {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }
    
    // 新增：从路径加载 UIImage
    private func loadImage() -> UIImage? {
        // UIImage(named:) 只能从 App Bundle 加载
        // 我们需要从一个绝对路径加载
        return UIImage(contentsOfFile: imagePath)
    }

    var body: some View {
            VStack(spacing: 8) {
                // 使用新的加载方式
                if let uiImage = loadImage() {
                    Button(action: { self.isShowingZoomView = true }) {
                        Image(uiImage: uiImage)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity).clipped()
                    }
                    .buttonStyle(PlainButtonStyle())

                    Text((imageName as NSString).deletingPathExtension)
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, horizontalPadding)
                        .textSelection(.enabled)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.fill").font(.largeTitle).foregroundColor(.gray)
                        // 显示我们尝试加载的路径，方便调试
                        Text("图片加载失败: \(imagePath)").font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                    .padding(.horizontal, horizontalPadding)
                }
            }
            .fullScreenCover(isPresented: $isShowingZoomView) {
                // ZoomableImageView 也需要修改
                ZoomableImageView(imageName: imageName, timestamp: timestamp, isPresented: $isShowingZoomView)
            }
            .padding(.vertical, 10)
        }
    }

struct ZoomableImageView: View {
    let imageName: String
    let timestamp: String
    @Binding var isPresented: Bool

    @State private var showSaveAlert = false
    @State private var saveAlertMessage = ""

    // 新增：计算图片在 Documents 目录中的完整路径
    private var imagePath: String {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }
    
    // 新增：从路径加载 UIImage 的辅助函数
    private func loadImage() -> UIImage? {
        return UIImage(contentsOfFile: imagePath)
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // ZoomableScrollView 已经修改，所以这里不需要改动
            ZoomableScrollView(imageName: imageName, timestamp: timestamp)
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundColor(.white.opacity(0.7))
                            .background(Color.black.opacity(0.5).clipShape(Circle()))
                    }.padding()
                }
                Spacer()
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: saveImageToPhotoLibrary) {
                        Image(systemName: "arrow.down.circle.fill").font(.largeTitle).foregroundColor(.white.opacity(0.7))
                            .background(Color.black.opacity(0.5).clipShape(Circle()))
                    }.padding()
                }
            }
        }
        .gesture(DragGesture().onEnded { value in
            if value.translation.height > 100 { isPresented = false }
        })
        .alert(isPresented: $showSaveAlert) { Alert(title: Text(saveAlertMessage)) }
    }

    private func saveImageToPhotoLibrary() {
        // 不再从 Bundle 加载，而是从 Documents 目录的绝对路径加载
        guard let uiImage = loadImage() else {
            saveAlertMessage = "图片加载失败，无法保存"
            showSaveAlert = true
            return
        }
        
        guard let imageData = uiImage.jpegData(compressionQuality: 1.0) else {
            saveAlertMessage = "图片转换失败"; showSaveAlert = true; return
        }
        
        // 权限请求和保存逻辑保持不变
        let requestAuth: (@escaping (PHAuthorizationStatus) -> Void) -> Void = { callback in
            if #available(iOS 14, *) { PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: callback) }
            else { PHPhotoLibrary.requestAuthorization(callback) }
        }
        requestAuth { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    PHPhotoLibrary.shared().performChanges {
                        let req = PHAssetCreationRequest.forAsset()
                        req.addResource(with: .photo, data: imageData, options: nil)
                    } completionHandler: { success, error in
                        DispatchQueue.main.async {
                            saveAlertMessage = success ? "已保存到相册" : "保存失败：\(error?.localizedDescription ?? "未知错误")"
                            showSaveAlert = true
                        }
                    }
                default:
                    saveAlertMessage = "没有相册权限，保存失败"; showSaveAlert = true
                }
            }
        }
    }
}

struct ZoomableScrollView: UIViewRepresentable {
    let imageName: String
    let timestamp: String

    func makeUIView(context: Context) -> UIScrollView {
        // 1. 获取 Documents 目录
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 2. 构建图片的完整文件路径
        let imagePath = documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
        
        // 3. 从文件路径加载图片，而不是从 Bundle
        guard let image = UIImage(contentsOfFile: imagePath) else {
            // 如果图片加载失败，返回一个空的滚动视图，防止崩溃
            print("ZoomableScrollView 无法加载图片于: \(imagePath)")
            return UIScrollView()
        }

        let scrollView = UIScrollView()
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo:scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        context.coordinator.imageView = imageView
        
        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // Coordinator 类本身不需要任何修改
    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        var imageView: UIImageView?
        init(_ parent: ZoomableScrollView) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let zoomRect = zoomRect(for: scrollView, with: point, scale: scrollView.maximumZoomScale / 2)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
        private func zoomRect(for scrollView: UIScrollView, with point: CGPoint, scale: CGFloat) -> CGRect {
            let newSize = CGSize(width: scrollView.frame.width / scale, height: scrollView.frame.height / scale)
            let newOrigin = CGPoint(x: point.x - newSize.width / 2.0, y: point.y - newSize.height / 2.0)
            return CGRect(origin: newOrigin, size: newSize)
        }
    }
}
