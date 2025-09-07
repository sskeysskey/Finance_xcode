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
    
    // 接收 AudioPlayerManager，保持不变
    @ObservedObject var audioPlayerManager: AudioPlayerManager

    var requestNextArticle: () -> Void

    @State private var isSharePresented = false

    @State private var showCopyToast = false
    @State private var toastMessage = ""

    var body: some View {
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        let remainingImages = Array(article.images.dropFirst())
        
        let distributeEvenly = !remainingImages.isEmpty && remainingImages.count < paragraphs.count
        let insertionInterval = distributeEvenly
            ? paragraphs.count / (remainingImages.count + 1)
            : 1

        ZStack {
            ScrollView {
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
                            .gesture(
                                LongPressGesture()
                                    .onEnded { _ in
                                        UIPasteboard.general.string = paragraphs[pIndex]
                                        self.toastMessage = "选中段落已复制"
                                        withAnimation(.spring()) {
                                            self.showCopyToast = true
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            withAnimation(.spring()) {
                                                self.showCopyToast = false
                                            }
                                        }
                                    }
                            )

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
                    
                    Button(action: {
                        self.requestNextArticle()
                    }) {
                        HStack {
                            Text("读取下一篇")
                                .fontWeight(.bold)
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                .padding(.vertical)
            }
            
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
                    .clipShape(Capsule())
                    .shadow(radius: 10)
                    
                    Spacer()
                }
                .padding(.top, 5)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("\(unreadCount) unread")
                        Text(formatMonthDay(from: article.timestamp))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            // ==================== 主要修改点：移除音频按钮 ====================
            ToolbarItem(placement: .navigationBarTrailing) {
                // 只保留分享按钮
                Button { isSharePresented = true } label: { Image(systemName: "square.and.arrow.up") }
            }
            // =============================================================
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSharePresented) {
            let shareText = article.topic + "\n\n" + paragraphs.joined(separator: "\n\n")
            ActivityView(activityItems: [shareText])
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
    
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
// ... (剩余代码保持不变)
struct ArticleImageView: View {
    let imageName: String
    let timestamp: String
    @State private var isShowingZoomView = false

    private let horizontalPadding: CGFloat = 20
    
    private var imagePath: String {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }
    
    private func loadImage() -> UIImage? {
        return UIImage(contentsOfFile: imagePath)
    }

    var body: some View {
            VStack(spacing: 8) {
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
                        Text("图片加载失败: \(imagePath)").font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                    .padding(.horizontal, horizontalPadding)
                }
            }
            .fullScreenCover(isPresented: $isShowingZoomView) {
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

    private var imagePath: String {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }
    
    private func loadImage() -> UIImage? {
        return UIImage(contentsOfFile: imagePath)
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
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
        guard let uiImage = loadImage() else {
            saveAlertMessage = "图片加载失败，无法保存"
            showSaveAlert = true
            return
        }
        
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

struct ZoomableScrollView: UIViewRepresentable {
    let imageName: String
    let timestamp: String

    func makeUIView(context: Context) -> UIScrollView {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imagePath = documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
        
        guard let image = UIImage(contentsOfFile: imagePath) else {
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
