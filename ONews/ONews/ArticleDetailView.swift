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
    let unreadCountForGroup: Int
    let totalUnreadCount: Int
    @ObservedObject var viewModel: NewsViewModel

    // 【修改】保持对 manager 的观察以获取状态
    @ObservedObject var audioPlayerManager: AudioPlayerManager
    var requestNextArticle: () async -> Void
    // 【新增】用于处理右上角音频按钮点击的闭包
    var onAudioToggle: () -> Void
    
    @State private var isSharePresented = false
    @State private var showCopyToast = false
    @State private var toastMessage = ""
    
    // 【新增】控制推广弹窗显示
    @State private var showNewsPromoSheet = false
    
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
                        
                        // 【修改需求2】此处原有的 sourceName 代码已被移除
                        // Text(sourceName.replacingOccurrences(of: "_", with: " "))
                        //    .font(.subheadline).foregroundColor(.gray)
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
                        Task {
                            await self.requestNextArticle()
                        }
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
                    .padding(.top, 20) // 稍微调整上边距
                    
                    // 【新增】在这里插入文字链接触发器
                    Button(action: {
                        showNewsPromoSheet = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill") // 可选：加个小星星图标
                                .font(.caption)
                            Text("毛遂自荐：博主另一款精品应用\n炒美股必备伴侣——“美股精灵”")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .underline() // 下划线增加链接感
                        }
                        .foregroundColor(.blue.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 30) // 给底部留点空间
                        .padding(.top, 5)
                    }
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
                        if unreadCountForGroup == totalUnreadCount {
                            Text("\(totalUnreadCount) 未读")
                        } else {
                            Text("\(unreadCountForGroup) | \(totalUnreadCount) 未读")
                        }
                        // 这里调用的是 formatMonthDay，下面已经修改了该函数的实现
                        Text(formatMonthDay(from: article.timestamp))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    // 【修改】按钮的 action 现在调用 onAudioToggle 闭包
                    Button(action: onAudioToggle) {
                        Image(systemName: audioPlayerManager.isPlaybackActive ? "headphones.slash" : "headphones")
                    }
                    .disabled(audioPlayerManager.isSynthesizing)
                    
                    Button { isSharePresented = true } label: { Image(systemName: "square.and.arrow.up") }
                }
                // 【修改点1】这里添加 .primary 颜色，使图标变为黑白（跟随系统主题）
                .foregroundColor(.primary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSharePresented) {
            let shareText = article.topic + "\n\n" + paragraphs.joined(separator: "\n\n")
            ActivityView(activityItems: [shareText])
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        // 【新增】挂载推广弹窗
        .sheet(isPresented: $showNewsPromoSheet) {
            NewsPromoView(onOpenAction: {
                // 关闭弹窗
                showNewsPromoSheet = false
                // 延迟执行跳转，保证动画流畅
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    openNewsApp()
                }
            })
            // 如果你的 B 程序支持 iOS 16+，建议加上下面这行让弹窗更自然
            // .presentationDetents([.large])
        }
    }

    // 【新增】跳转逻辑函数（直接放在结构体内部底部即可）
    private func openNewsApp() {
        // 1. 定义跳转目标 URL Scheme (如果 App A 有定义)
        let appSchemeStr = "globalnews://"
        
        // 2. 定义 App Store 下载链接 (记得替换这里的 ID)
        let appStoreUrlStr = "https://apps.apple.com/cn/app/id6754591885"
        
        guard let appUrl = URL(string: appSchemeStr),
              let storeUrl = URL(string: appStoreUrlStr) else {
            return
        }
        
        // 3. 尝试跳转
        if UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl)
        } else {
            UIApplication.shared.open(storeUrl)
        }
    }

    // 【修改需求1】修改日期格式化函数
    private func formatMonthDay(from timestamp: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyMMdd"
        guard let date = input.date(from: timestamp) else {
            return timestamp
        }
        let output = DateFormatter()
        // 修改为中文格式：11月29日
        output.dateFormat = "M月d日"
        output.locale = Locale(identifier: "zh_CN")
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

// MARK: - 【移植自A程序】财经要闻推广页
struct NewsPromoView: View {
    // 传入跳转逻辑
    var onOpenAction: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            // 背景：由上至下的微妙渐变
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color(UIColor.systemBackground)]),
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 25) {
                // 1. 顶部把手
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 25) {
                        // 2. 头部 ICON 和 标题
                        VStack(spacing: 15) {
                            Image(systemName: "newspaper.circle.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .foregroundStyle(
                                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)

                            Text("全球财经要闻 · 一手掌握\n支持语音播放")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)

                        // 3. 媒体品牌墙
                        VStack(spacing: 10) {
                            Text("汇聚国际一线媒体精华")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            let brands = ["纽约时报", "伦敦金融时报", "华尔街日报", "Bloomberg布隆伯格", "经济学人", "路透社", "日经新闻", "华盛顿邮报", "..."]
                            FlowLayoutView(items: brands)
                        }
                        .padding(.vertical, 20)

                        // 4. 核心介绍文案
                        VStack(alignment: .leading, spacing: 15) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.orange)
                                Text("原版内容，AI总结翻译，配原版图片，支持语音播放。欢迎尝试...")
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                        )
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 100)
                }
            }

            // 5. 底部悬浮按钮
            VStack {
                Spacer()
                Button(action: {
                    onOpenAction()
                }) {
                    HStack {
                        Image(systemName: "app.badge.fill")
                        Text("跳转到商店页面下载")
                            .fontWeight(.bold)
                    }
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(28)
                    .shadow(color: .blue.opacity(0.4), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}

// 简单的流式布局辅助视图
struct FlowLayoutView: View {
    let items: [String]
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if items.indices.contains(0) { BrandTag(text: items[0]) }
                if items.indices.contains(1) { BrandTag(text: items[1]) }
                if items.indices.contains(2) { BrandTag(text: items[2]) }
            }
            HStack {
                if items.indices.contains(3) { BrandTag(text: items[3]) }
                if items.indices.contains(4) { BrandTag(text: items[4]) }
            }
            HStack {
                if items.indices.contains(5) { BrandTag(text: items[5]) }
                if items.indices.contains(6) { BrandTag(text: items[6]) }
            }
             HStack {
                if items.indices.contains(7) { BrandTag(text: items[7]) }
                if items.indices.contains(8) { BrandTag(text: items[8]) }
            }
        }
    }
}

struct BrandTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(8)
    }
}
