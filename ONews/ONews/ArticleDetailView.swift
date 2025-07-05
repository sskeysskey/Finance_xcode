import SwiftUI
import UIKit
import Photos

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
        
        let insertionInterval = (!remainingImages.isEmpty && paragraphs.count > remainingImages.count)
            ? (paragraphs.count / (remainingImages.count + 1))
            : (paragraphs.count + 1)

        ScrollView {
            Color.clear.frame(height: 1).onAppear { self.isAtTop = true }
                .onDisappear { self.isAtTop = false }
            
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(formattedTimestamp())
                        .font(.caption).foregroundColor(.gray)
                    Text(article.topic)
                        .font(.system(.title, design: .serif)).fontWeight(.bold)
                    Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.subheadline).foregroundColor(.gray)
                }
                .padding(.horizontal, 20)

                if let firstImage = article.images.first {
                    // ===== 修改: 传递 timestamp =====
                    ArticleImageView(imageName: firstImage, timestamp: article.timestamp)
                }
                
                ForEach(paragraphs.indices, id: \.self) { pIndex in
                    Text(paragraphs[pIndex])
                        .font(.custom("NewYork-Regular", size: 21)).lineSpacing(15)
                        .padding(.horizontal, 18).textSelection(.enabled)
                    
                    if insertionInterval > 0 && (pIndex + 1) % insertionInterval == 0 {
                        let imageIndexToInsert = ((pIndex + 1) / insertionInterval) - 1
                        if imageIndexToInsert < remainingImages.count {
                            // ===== 修改: 传递 timestamp =====
                            ArticleImageView(imageName: remainingImages[imageIndexToInsert], timestamp: article.timestamp)
                        }
                    }
                }
                
                Color.clear.frame(height: 1).onAppear { self.isAtBottom = true }
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
    
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'AT' HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }
}

// ===== 修改: ArticleImageView 接收 timestamp =====
struct ArticleImageView: View {
    let imageName: String
    let timestamp: String // 新增
    @State private var isShowingZoomView = false

    private let horizontalPadding: CGFloat = 20

    var body: some View {
        // 动态构建图片路径
        let fullPath = "news_images_\(timestamp)/\(imageName)"

        VStack(spacing: 8) {
            if let uiImage = UIImage(named: fullPath) {
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
                    Text("图片加载失败: \(fullPath)").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                .padding(.horizontal, horizontalPadding)
            }
        }
        .fullScreenCover(isPresented: $isShowingZoomView) {
            // 传递 timestamp 到下一层
            ZoomableImageView(imageName: imageName, timestamp: timestamp, isPresented: $isShowingZoomView)
        }
        .padding(.vertical, 10)
    }
}


// ===== 修改: ZoomableImageView 接收 timestamp =====
struct ZoomableImageView: View {
    let imageName: String
    let timestamp: String // 新增
    @Binding var isPresented: Bool

    @State private var showSaveAlert = false
    @State private var saveAlertMessage = ""

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            // 传递 timestamp
            ZoomableScrollView(imageName: imageName, timestamp: timestamp)

            // 关闭和下载按钮 (UI不变)
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
        // 动态构建图片路径
        let fullPath = "news_images_\(timestamp)/\(imageName)"
        guard let uiImage = UIImage(named: fullPath) else {
          saveAlertMessage = "图片加载失败，无法保存"
          showSaveAlert = true
          return
        }
        // ... 剩余保存逻辑不变 ...
        guard let imageData = uiImage.jpegData(compressionQuality: 1.0) else {
          saveAlertMessage = "图片转换失败"; showSaveAlert = true; return
        }
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

// ===== 修改: ZoomableScrollView 接收 timestamp =====
struct ZoomableScrollView: UIViewRepresentable {
    let imageName: String
    let timestamp: String // 新增

    func makeUIView(context: Context) -> UIScrollView {
        // 动态构建图片路径
        let fullPath = "news_images_\(timestamp)/\(imageName)"
        guard let image = UIImage(named: fullPath) else { return UIScrollView() }

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
