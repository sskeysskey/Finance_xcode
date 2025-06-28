import SwiftUI
import UIKit // 导入 UIKit 以使用 UIScrollView
import Photos  // 新增

// ActivityView 结构体保持不变...
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        vc.modalPresentationStyle = .automatic
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}


struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    // ==================== 新增属性 ====================
    /// 接收从父视图传递过来的未读文章数量
    let unreadCount: Int
    // ===============================================
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
        
        let insertionInterval = (!remainingImages.isEmpty && paragraphs.count > remainingImages.count)
            ? (paragraphs.count / (remainingImages.count + 1))
            : (paragraphs.count + 1)

        ScrollView {
            // ... ScrollView 的内容保持不变 ...
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
                        .font(.custom("NewYork-Regular", size: 21))
                        .lineSpacing(14)
                        .padding(.horizontal, 18)
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
        // ==================== 核心修改 ====================
        // 使用 .toolbar 修改器来定义导航栏项目
        .toolbar {
            // 返回按钮和分享按钮已经由系统和其他视图定义，我们只添加中间部分
            
            // 使用 .principal 位置来放置自定义的中央标题视图
            ToolbarItem(placement: .principal) {
                VStack {
                    // 第一行：显示来源名称
                    Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // 第二行：显示剩余未读数量
                    Text("\(unreadCount) unread")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // 分享按钮（这个可以保留，因为它在 .navigationBarTrailing 位置）
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isSharePresented = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline) // 确保导航栏是紧凑样式
        // =====================================================
        .sheet(isPresented: $isSharePresented) {
            let title = article.topic
            let bodyText = paragraphs.joined(separator: "\n\n")
            let shareText = title + "\n\n" + bodyText

            ActivityView(activityItems: [shareText])
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
            ZoomableImageView(imageName: imageName, isPresented: $isShowingZoomView)
        }
        .padding(.vertical, 10)
    }
}


// ==================== 主要修改点: ZoomableImageView ====================
// 这个视图现在是一个容器，负责管理背景、关闭按钮和新的 ZoomableScrollView
struct ZoomableImageView: View {
    let imageName: String
    @Binding var isPresented: Bool

    // 新增：保存结果状态
    @State private var showSaveAlert = false
    @State private var saveAlertMessage = ""

    var body: some View {
        ZStack {
            // 黑色背景
            Color.black
                .edgesIgnoringSafeArea(.all)

            // 图片滚动 & 缩放
            // ZoomableScrollView 内部已经处理了双击手势，所以我们不需要在这里添加
            ZoomableScrollView(imageName: imageName)

            // 关闭按钮（右上角）
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.7))
                            .background(Color.black.opacity(0.5).clipShape(Circle()))
                    }
                    .padding()
                }
                Spacer()
            }

            // 下载按钮（右下角）
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: saveImageToPhotoLibrary) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.7))
                            .background(Color.black.opacity(0.5).clipShape(Circle()))
                    }
                    .padding()
                }
            }
        }
        // ==================== 修改点 1: 移除单击手势，添加拖拽手势 ====================
        // .onTapGesture { isPresented = false } // <- 移除这一行
        .gesture(
            DragGesture().onEnded { value in
                // 检查垂直方向的拖动距离
                // 如果向下滑动超过 100 个点，则关闭视图
                if value.translation.height > 100 {
                    isPresented = false
                }
            }
        )
        // =======================================================================
        // 保存结果弹窗
        .alert(isPresented: $showSaveAlert) {
            Alert(title: Text(saveAlertMessage))
        }
    }

    // MARK: - 保存图片到相册 (这部分逻辑保持不变)
    private func saveImageToPhotoLibrary() {
        let fullPath = "news_images/\(imageName)"
        guard let uiImage = UIImage(named: fullPath) else {
          saveAlertMessage = "图片加载失败，无法保存"
          showSaveAlert = true
          return
        }

        guard let imageData = uiImage.jpegData(compressionQuality: 1.0) else {
          saveAlertMessage = "图片转换失败"
          showSaveAlert = true
          return
        }

        let requestAuth: (@escaping (PHAuthorizationStatus) -> Void) -> Void = { callback in
          if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: callback)
          } else {
            PHPhotoLibrary.requestAuthorization(callback)
          }
        }

        requestAuth { status in
          DispatchQueue.main.async {
            switch status {
            case .authorized, .limited:
              PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                creationRequest.addResource(
                  with: .photo,
                  data: imageData,
                  options: options
                )
              } completionHandler: { success, error in
                DispatchQueue.main.async {
                  if success {
                    saveAlertMessage = "已保存到相册"
                  } else {
                    saveAlertMessage = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                  }
                  showSaveAlert = true
                }
              }
            case .denied, .restricted:
              saveAlertMessage = "没有相册权限，保存失败"
              showSaveAlert = true
            case .notDetermined:
              saveAlertMessage = "相册权限未确定"
              showSaveAlert = true
            @unknown default:
              saveAlertMessage = "未知的相册权限状态"
              showSaveAlert = true
            }
          }
        }
      }
}
// =======================================================================


// ==================== ZoomableScrollView 保持不变 ====================
// 这部分代码已经实现了双击缩放功能，无需修改
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
                // 放大到最大倍数的一半，这是一个固定的倍率
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
