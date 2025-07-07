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

    var body: some View {
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        let remainingImages = Array(article.images.dropFirst())
        
        // ---------- 新逻辑开始 ----------
                // 是否走“均匀分布”分支
                let distributeEvenly = !remainingImages.isEmpty && remainingImages.count < paragraphs.count

                // 均匀分布时，间隔为 paragraphs.count / (remainingImages.count + 1)
                // 否则，插入间隔设为 1（即每个段落后都插一张）
                let insertionInterval = distributeEvenly
                    ? paragraphs.count / (remainingImages.count + 1)
                    : 1
                // ---------- 新逻辑结束 ----------

                ScrollView {
                    Color.clear.frame(height: 1) // 用于检测是否滚动到顶部
                        .onAppear { self.isAtTop = true }
                        .onDisappear { self.isAtTop = false }

                    VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    // ==================== 修改点 1 of 2 ====================
                    // 调用新的格式化函数，并传入文章自己的时间戳
                    Text(formatDate(from: article.timestamp))
                        .font(.caption).foregroundColor(.gray)
                    // =====================================================
                    
                    Text(article.topic)
                        .font(.system(.title, design: .serif)).fontWeight(.bold)
                    Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.subheadline).foregroundColor(.gray)
                }
                .padding(.horizontal, 20)
                // 第一张图片保持不变
                if let firstImage = article.images.first {
                    ArticleImageView(imageName: firstImage, timestamp: article.timestamp)
                }

                // 正文段落 + 插图
                ForEach(paragraphs.indices, id: \.self) { pIndex in
                    Text(paragraphs[pIndex])
                        .font(.custom("NewYork-Regular", size: 21))
                        .lineSpacing(15)
                        .padding(.horizontal, 18)

                    // 计算应该插入哪一张图
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

                // ---------- 新增：当图片多于段落时，把多余的图片追加到末尾 ----------
                if !distributeEvenly && remainingImages.count > paragraphs.count {
                    let extraImages = remainingImages.dropFirst(paragraphs.count)
                    ForEach(Array(extraImages), id: \.self) { imageName in
                        ArticleImageView(imageName: imageName, timestamp: article.timestamp)
                    }
                }
                // ------------------------------------------------------------------

                Color.clear.frame(height: 1) // 用于检测是否滚动到底部
                    .onAppear { self.isAtBottom = true }
                    .onDisappear { self.isAtBottom = false }
            }
            .padding(.vertical)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text(sourceName.replacingOccurrences(of: "_", with: " ")).font(.headline)
                    Text("\(unreadCount) unread").font(.caption).foregroundColor(.secondary)
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
    
    // ==================== 修改点 2 of 2 ====================
    // 重写此函数，使其接收时间戳字符串并进行格式化
    private func formatDate(from timestamp: String) -> String {
        // 用于解析 "250704" 格式的 formatter
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyMMdd"

        // 尝试将时间戳字符串转换为 Date 对象
        guard let date = inputFormatter.date(from: timestamp) else {
            // 如果解析失败，直接返回原始时间戳作为备用
            return timestamp.uppercased()
        }

        // 用于输出 "FRIDAY, JULY 4, 2025" 格式的 formatter
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "EEEE, MMMM d, yyyy" // <- 移除了 'AT' HH:mm
        outputFormatter.locale = Locale(identifier: "en_US_POSIX") // 保证在任何设备上格式一致

        // 返回格式化后的、大写的日期字符串
        return outputFormatter.string(from: date).uppercased()
    }
    // =====================================================
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
            // let fullPath = "news_images_\(timestamp)/\(imageName)" // <- 旧代码，删除

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
        // ==================== 核心修改点 ====================
        // 不再从 Bundle 加载，而是从 Documents 目录的绝对路径加载
        guard let uiImage = loadImage() else {
            saveAlertMessage = "图片加载失败，无法保存"
            showSaveAlert = true
            return
        }
        // =====================================================
        
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
        // ==================== 核心修改点 ====================
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
        // =====================================================

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
