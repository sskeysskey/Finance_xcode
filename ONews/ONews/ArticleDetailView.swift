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
    let unreadCount: Int
    @ObservedObject var viewModel: NewsViewModel
    var requestNextArticle: () -> Void
    var requestPreviousArticle: () -> Void
    
    // ===== 新增 (1/2): 获取视图的 presentationMode 用于手动返回 =====
    @Environment(\.presentationMode) var presentationMode
    // ==========================================================
    
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(unreadCount) unread")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isSharePresented = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSharePresented) {
            let title = article.topic
            let bodyText = paragraphs.joined(separator: "\n\n")
            let shareText = title + "\n\n" + bodyText

            ActivityView(activityItems: [shareText])
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // ===== 修改 (2/2): 更新手势处理逻辑 =====
        .simultaneousGesture(
            DragGesture().onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height
                
                // 检查水平滑动是否是主导方向
                if abs(horizontalAmount) > abs(verticalAmount) {
                    // 如果是向右滑动（正值）且超过了100点的阈值，则执行返回操作
                    if horizontalAmount > 100 {
                        print("检测到符合条件的右滑手势，返回上一级")
                        self.presentationMode.wrappedValue.dismiss()
                    }
                } else {
                    // 否则，保持原有的垂直滑动逻辑来切换文章
                    if self.isAtBottom && verticalAmount < -300 {
                        print("检测到符合条件的上滑手势，请求下一篇")
                        self.requestNextArticle()
                    }
                    else if self.isAtTop && verticalAmount > 300 {
                        print("检测到符合条件的下滑手势，请求上一篇")
                        self.requestPreviousArticle()
                    }
                }
            }
        )
        // =========================================
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


// ZoomableImageView 及其相关代码保持不变
struct ZoomableImageView: View {
    let imageName: String
    @Binding var isPresented: Bool

    @State private var showSaveAlert = false
    @State private var saveAlertMessage = ""

    var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)

            ZoomableScrollView(imageName: imageName)

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
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 100 {
                    isPresented = false
                }
            }
        )
        .alert(isPresented: $showSaveAlert) {
            Alert(title: Text(saveAlertMessage))
        }
    }

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

// ZoomableScrollView 保持不变
struct ZoomableScrollView: UIViewRepresentable {
    let imageName: String

    func makeUIView(context: Context) -> UIScrollView {
        let fullPath = "news_images/\(imageName)"
        guard let image = UIImage(named: fullPath) else {
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

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // no-op
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        var imageView: UIImageView?

        init(_ parent: ZoomableScrollView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

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
