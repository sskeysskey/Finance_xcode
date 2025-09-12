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

    @ObservedObject var audioPlayerManager: AudioPlayerManager
    var requestNextArticle: () -> Void

    @State private var isSharePresented = false
    @State private var showCopyToast = false
    @State private var toastMessage = ""

    // 新增：动画控制
    @State private var isTransitioning = false
    @State private var previousArticle: Article? = nil

    // 顶部锚点常量
    private let topAnchorID = "top"

    var body: some View {
        // 预处理当前文章段落
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 顶部锚点
                    Color.clear
                        .frame(height: 0.1)
                        .id(topAnchorID)

                    // 使用 ZStack 实现“旧内容 -> 新内容”的过渡
                    ZStack {
                        if let prev = previousArticle {
                            ContentBody(
                                article: prev,
                                sourceName: sourceName,
                                unreadCount: unreadCount,
                                viewModel: viewModel,
                                audioPlayerManager: audioPlayerManager,
                                requestNextArticle: requestNextArticle,
                                isGhost: true, // 旧内容，作为过渡影子
                                showCopyToast: $showCopyToast,
                                toastMessage: $toastMessage
                            )
                            .transition(.identity) // 控制通过偏移与透明度，不用默认 transition
                            .opacity(isTransitioning ? 0 : 0) // 旧内容只在过渡时显示，过渡结束即为 0
                            .offset(x: isTransitioning ? -20 : -20) // 旧内容向左滑出
                            .allowsHitTesting(false) // 防止交互
                        }

                        ContentBody(
                            article: article,
                            sourceName: sourceName,
                            unreadCount: unreadCount,
                            viewModel: viewModel,
                            audioPlayerManager: audioPlayerManager,
                            requestNextArticle: requestNextArticle,
                            isGhost: false,
                            showCopyToast: $showCopyToast,
                            toastMessage: $toastMessage
                        )
                        .opacity(isTransitioning ? 0 : 1) // 新内容在过渡时先透明，结束后呈现
                        .offset(x: isTransitioning ? 20 : 0) // 新内容从右轻推进入
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.12), value: isTransitioning)
                    .padding(.vertical)
                }
                // 当文章切换时，先触发过渡标志，再滚动至顶部（延后一帧）
                .onChange(of: article.id) { _, _ in
                    // 启动过渡
                    isTransitioning = true
                    previousArticle = previousArticle == nil || previousArticle?.id == article.id ? nil : previousArticle

                    // 为了让旧内容有参照，立即把 previousArticle 设为切换前的文章快照
                    // 注意：外部在 setState 切换 article 前，SwiftUI 会刷新此视图。为了确保拿到旧值，
                    // 我们这里的 previousArticle 已在 onAppear 中初始化为当前 article。
                    // 在每次 id 变化时，如果 previousArticle 与新 id 相同，则无需展示影子。

                    // 下一 runloop 执行滚动，避免与布局切换在同一帧
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(topAnchorID, anchor: .top)
                        }
                    }

                    // 过渡结束后复位
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        isTransitioning = false
                        // 切换完成，影子移除
                        previousArticle = article
                    }
                }
                // 初次出现确保在顶部、并设置 previousArticle 作为初始影子源
                .onAppear {
                    previousArticle = article
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
            }

            // 顶部复制成功吐司
            if showCopyToast {
                VStack {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.white)
                        Text(toastMessage).foregroundColor(.white).fontWeight(.semibold)
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
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    // 播放/停止保持不变
                    Button(action: {
                        if audioPlayerManager.isPlaybackActive {
                            audioPlayerManager.stop()
                        } else {
                            let fullText = article.article
                                .components(separatedBy: .newlines)
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n\n")
                            audioPlayerManager.startPlayback(text: fullText)
                        }
                    }) {
                        Image(systemName: audioPlayerManager.isPlaybackActive ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .disabled(audioPlayerManager.isSynthesizing)

                    Button { isSharePresented = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSharePresented) {
            let shareText = article.topic + "\n\n" + paragraphs.joined(separator: "\n\n")
            ActivityView(activityItems: [shareText])
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    // 日期格式化与原样保持
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

// 将原正文布局抽成单独视图，便于在 ZStack 中做过渡
private struct ContentBody: View {
    let article: Article
    let sourceName: String
    let unreadCount: Int
    @ObservedObject var viewModel: NewsViewModel

    @ObservedObject var audioPlayerManager: AudioPlayerManager
    var requestNextArticle: () -> Void

    // 是否为过渡中的“影子”视图
    let isGhost: Bool

    @Binding var showCopyToast: Bool
    @Binding var toastMessage: String

    var body: some View {
        let paragraphs = article.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let remainingImages = Array(article.images.dropFirst())
        let distributeEvenly = !remainingImages.isEmpty && remainingImages.count < paragraphs.count
        let insertionInterval = distributeEvenly ? max(1, paragraphs.count / (remainingImages.count + 1)) : 1

        VStack(alignment: .leading, spacing: 16) {
            // 标题区
            VStack(alignment: .leading, spacing: 8) {
                Text(formatDate(from: article.timestamp))
                    .font(.caption).foregroundColor(.gray)

                Text(article.topic)
                    .font(.system(.title, design: .serif)).fontWeight(.bold)

                Text(sourceName.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline).foregroundColor(.gray)
            }
            .padding(.horizontal, 20)

            // 首图
            if let firstImage = article.images.first {
                ArticleImageView(imageName: firstImage, timestamp: article.timestamp)
            }

            // 正文段落与插图
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
                                withAnimation(.spring()) { self.showCopyToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation(.spring()) { self.showCopyToast = false }
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

            // 阅读下一篇按钮（功能不变）
            Button(action: {
                self.requestNextArticle()
            }) {
                HStack {
                    Text("读取下一篇").fontWeight(.bold)
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
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
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
