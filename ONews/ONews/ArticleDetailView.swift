import SwiftUI
import UIKit
import Photos

// MARK: - ActivityView (保持不变)
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

// MARK: - ImageLoader (保持不变)
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    @Published var isFailed = false // 新增失败状态标记
    
    private static var cache = NSCache<NSString, UIImage>()
    
    // 【新增】初始化时同步检查缓存，避免首帧闪烁和高度跳变！
    init(imagePath: String? = nil) {
        if let path = imagePath {
            let cacheKey = path as NSString
            if let cached = Self.cache.object(forKey: cacheKey) {
                self.image = cached
            }
        }
    }
    
    // 改为异步方法，并返回一个 Bool 表示本地加载是否成功
    func load(from path: String) async -> Bool {
        let cacheKey = path as NSString
        
        // 1. 先检查内存缓存
        if let cached = Self.cache.object(forKey: cacheKey) {
            self.image = cached
            self.isFailed = false
            return true
        }
        
        // 2. 异步加载本地文件
        isLoading = true
        self.isFailed = false
        
        // 【优化】将读取和解码彻底放入后台线程
        let loadedImage = await Task.detached(priority: .userInitiated) {
            guard let rawImage = UIImage(contentsOfFile: path) else { return nil as UIImage? }
            // 提前在后台线程进行解码，防止主线程渲染时掉帧
            return await rawImage.byPreparingForDisplay() ?? rawImage
        }.value
        
        self.isLoading = false
        
        if let img = loadedImage {
            Self.cache.setObject(img, forKey: cacheKey)
            self.image = img
            return true
        } else {
            self.isFailed = true
            return false // 图片不存在或已损坏
        }
    }
    
    static func clearCache() {
        cache.removeAllObjects()
    }
}

// MARK: - ArticleDetailView
struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    let unreadCountForGroup: Int
    let totalUnreadCount: Int
    // 【修改】改为 Binding，接收父视图的状态
    @Binding var isEnglishMode: Bool 
    @ObservedObject var viewModel: NewsViewModel

    // 【修改为】：让它变成普通属性，不再触发 ArticleDetailView 的整体刷新
    let audioPlayerManager: AudioPlayerManager
    var requestNextArticle: () async -> Void
    // 【新增】用于处理右上角音频按钮点击的闭包
    var onAudioToggle: () -> Void
    
    @State private var isSharePresented = false
    @State private var cachedAttrParagraphs: [NSAttributedString] = []
    
    // 【新增】控制推广弹窗显示
    @State private var showNewsPromoSheet = false
    
    // 【优化】使用 @State 缓存耗时计算的结果，避免 body 每次刷新都重算
    @State private var cachedParagraphs: [String] = []
    @State private var cachedRemainingImages: [String] = []
    @State private var cachedInsertionInterval: Int = 1
    @State private var cachedDistributeEvenly: Bool = false
    // 【新增】标记内容是否准备就绪，防止闪烁
    @State private var isContentReady = false

    // 【修改】控制自定义分享菜单
    @State private var showCustomShareSheet = false
    // 【新增】控制系统分享（点击“更多”后显示）
    @State private var showSystemActivitySheet = false
    // 【新增】控制微信引导页
    @State private var showWeChatGuideSheet = false
    // 【新增】字体调整相关
    @State private var showFontAdjustment = false
    @AppStorage("articleBodyFontSize") private var articleBodyFontSize: Double = 25
    @AppStorage("imageCaptionFontSize") private var imageCaptionFontSize: Double = 12
    
    // 【新增 2】判断是否存在有效的英文版本
    private var hasEnglishVersion: Bool {
        guard let tEng = article.topic_eng, !tEng.isEmpty,
              let aEng = article.article_eng, !aEng.isEmpty else {
            return false
        }
        return true
    }
    
    // 获取当前应显示的标题
    private var displayTopic: String {
        (isEnglishMode && hasEnglishVersion) ? (article.topic_eng ?? article.topic) : article.topic
    }
    
    // 【新增】获取当前应显示的来源名称 (Banner 标题)
    private var displaySourceName: String {
        // 如果是英文模式，尝试在 viewModel 的 sources 列表中查找对应的英文名
        if isEnglishMode {
            // 注意：这里的 sourceName 通常是中文名（作为ID使用），我们用它来查找 Source 对象
            if let source = viewModel.sources.first(where: { $0.name == sourceName }) {
                return source.name_en
            }
        }
        // 默认为传入的 sourceName (中文)
        return sourceName
    }
    
    // 【修改】去掉星期几，只保留日期
    // 【优化：改为静态全局复用】
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    
    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        // 注意：因为 Localized 可能会随语言切换，Locale 的赋值我们移到具体使用的方法中
        return f
    }()
    
    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd"
        return f
    }()
    
    var body: some View {
        ZStack {
            ScrollView {
                // 【优化 1】使用 LazyVStack 替代 VStack
                // 这使得只有进入屏幕的段落和图片才会被渲染，极大减少长文章的内存占用和卡顿
                LazyVStack(alignment: .leading, spacing: 16) {
                    
                    // 头部信息区域
                    VStack(alignment: .leading, spacing: 8) {
                        // --- 修改开始 ---
                        HStack(alignment: .center, spacing: 10) {
                            Text(formatDate(from: article.timestamp))
                                .font(.caption).foregroundColor(.gray)

                                // 如果存在 url 且格式正确，则显示超链接
                            if let urlString = article.url, let url = URL(string: urlString) {
                                Link(destination: url) {
                                    HStack(spacing: 2) {
                                        Text(Localized.originalLink)
                                        Image(systemName: "arrow.up.right")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.blue) // 经典的链接蓝色
                                }
                            }
                        }
                        
                        // 【修改 1】这里使用动态的 displayTopic
                        Text(displayTopic)
                            .font(.system(.title, design: .serif)).fontWeight(.bold)
                            // 英文标题通常不需要那么紧凑，可以微调，这里保持一致即可
                            .animation(.none, value: isEnglishMode) 
                    }
                    .padding(.horizontal, 20)
                    // 【优化】给头部一个固定的 ID，防止 LazyVStack 刷新时跳动
                    .id("Header-\(article.id)")
                    
                    if let firstImage = article.images.first {
                        ArticleImageView(imageName: firstImage, timestamp: article.timestamp)
                            .padding(.horizontal, 0) // 图片内部已有 padding
                    }
                    
                    // 【优化】仅当内容准备好后才显示段落，避免布局跳变
                    if isContentReady {
                        ForEach(cachedParagraphs.indices, id: \.self) { pIndex in
                            // ⭐ 核心替换：用 NativeParagraphView 替代 SwiftUI Text
                            // - 移除了 .font / .lineSpacing（已在 NSAttributedString 中预设）
                            // - 移除了 .onLongPressGesture（UITextView 原生支持选择+复制）
                            if pIndex < cachedAttrParagraphs.count {
                                NativeParagraphView(attributedText: cachedAttrParagraphs[pIndex])
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 18)
                                    .id("p-\(article.id)-\(pIndex)")
                            }

                            // 图片插入逻辑（保持不变）
                            if (pIndex + 1) % cachedInsertionInterval == 0 {
                                let imageIndexToInsert = (pIndex + 1) / cachedInsertionInterval - 1
                                if imageIndexToInsert < cachedRemainingImages.count {
                                    ArticleImageView(
                                        imageName: cachedRemainingImages[imageIndexToInsert],
                                        timestamp: article.timestamp
                                    )
                                    .id("img-\(article.id)-\(imageIndexToInsert)")
                                }
                            }
                        }

                        // 尾部多余图片（保持不变）
                        if !cachedDistributeEvenly && cachedRemainingImages.count > cachedParagraphs.count {
                            let extraImages = cachedRemainingImages.dropFirst(cachedParagraphs.count)
                            ForEach(Array(extraImages), id: \.self) { imageName in
                                ArticleImageView(imageName: imageName, timestamp: article.timestamp)
                            }
                        }
                    } else {
                        // 占位符，防止进入页面时一片空白
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                    }
                    
                    Button(action: {
                        Task {
                            await self.requestNextArticle()
                        }
                    }) {
                        HStack {
                            Text(Localized.readNext)
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
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Localized.isEnglish ? "More from Developer" : "“毛遂自荐”博主另一款精品应用")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .center) // <--- 关键修改：让文字容器填满宽度并居中
                        
                        HStack {
                            Spacer()
                            // 唯一保留的应用：美股精灵
                            PromoCardView(
                                title: Localized.isEnglish ? "US Stock Elf" : "美股精灵",
                                subtitle: Localized.isEnglish ? "AI Stock Picks" : "AI算法每日荐股，全球财经数据一站搞定，炒美股必备伴侣。",
                                imageName: "logo_stock_elf_small", // 对应 Assets 中的名字
                                isSystemIcon: false,        // 告诉视图这不是系统图标
                                colors: [.blue, .purple]
                            ) {
                                showNewsPromoSheet = true
                            }
                            .frame(width: 220) // 限制宽度使其保持原本的方块感
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 100)
                }
                .padding(.vertical)
            }
            
            // if showCopyToast {
            //     VStack {
            //         HStack {
            //             Image(systemName: "checkmark.circle.fill")
            //                 .foregroundColor(.white)
            //             Text(toastMessage)
            //                 .foregroundColor(.white)
            //                 .fontWeight(.semibold)
            //         }
            //         .padding(.vertical, 12)
            //         .padding(.horizontal, 20)
            //         .background(Color.black.opacity(0.75))
            //         .clipShape(Capsule())
            //         .shadow(radius: 10)
                    
            //         Spacer()
            //     }
            //     .padding(.top, 5)
            //     .transition(.move(edge: .top).combined(with: .opacity))
            //     .zIndex(1)
            // }
        }
        .onAppear {
            // 每次出现时，重置为中文模式（或者你可以根据需求保留状态）
            // isEnglishMode = false 
            prepareContent()
        }
        .onChange(of: article) { _ in
            // 文章切换时，先标记未就绪，避免显示旧内容
            isContentReady = false
            prepareContent()
        }
        // 【新增 4】监听语言模式切换，重新计算段落布局
        .onChange(of: isEnglishMode) { _ in
            prepareContent()
        }
        // 【新增】监听字体大小变化，重新构建段落
        .onChange(of: articleBodyFontSize) { _ in
            prepareContent()
        }
        // --- 核心修改区域：Toolbar ---
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    // 【修改】使用 displaySourceName 替代 sourceName
                    Text(displaySourceName.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                        // 添加动画，防止文字切换时生硬跳变
                        .animation(.none, value: isEnglishMode)
                    
                    HStack(spacing: 8) {
                        if unreadCountForGroup == totalUnreadCount {
                            Text("\(totalUnreadCount)")
                        } else {
                            Text("\(unreadCountForGroup) | \(totalUnreadCount)")
                        }
                        // 这里调用的是 formatMonthDay，下面已经修改了该函数的实现
                        Text(formatMonthDay(from: article.timestamp))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) { // 稍微增加间距
                    // 【新增 5】中/英 切换按钮
                    if hasEnglishVersion {
                        Button(action: {
                            withAnimation(.spring()) {
                                isEnglishMode.toggle()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.primary, lineWidth: 1.5)
                                    // 【修改】逻辑反转：!isEnglishMode (即中文模式) 时实心
                                    .background(!isEnglishMode ? Color.primary : Color.clear)
                                    .clipShape(Circle())
                                    
                                Text(isEnglishMode ? "中" : "英")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    // 【修改】逻辑反转：!isEnglishMode (即中文模式) 时文字反色
                                    .foregroundColor(!isEnglishMode ? Color.viewBackground : Color.primary)
                            }
                            .frame(width: 24, height: 24)
                        }
                        // 稍微给个过渡动画
                        .transition(.scale.combined(with: .opacity))
                    }
                    // 【修改】使用独立的按钮组件，传入 manager
                    AudioToolbarButton(
                        audioPlayerManager: audioPlayerManager,
                        onAudioToggle: onAudioToggle
                    )
                    
                    Menu {
                        Button(action: { showCustomShareSheet = true }) {
                            Label(Localized.isEnglish ? "Share" : "分享", systemImage: "square.and.arrow.up")
                        }
                        Button(action: { showFontAdjustment = true }) {
                            Label(Localized.isEnglish ? "Font Size" : "字体大小", systemImage: "textformat.size")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                // 【修改点1】这里添加 .primary 颜色，使图标变为黑白（跟随系统主题）
                .foregroundColor(.primary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
                // 1. 自定义分享菜单
        .sheet(isPresented: $showCustomShareSheet) {
            CustomShareSheet(
                onWeChatAction: {
                    // --- 核心逻辑：复制文本并弹出引导 ---
                    let text = createShareText()
                    UIPasteboard.general.string = text
                    
                    // 延迟一点时间，让当前 sheet 收起动画完成后再弹出下一个
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showWeChatGuideSheet = true
                    }
                },
                onSystemShareAction: {
                    // --- 核心逻辑：调用系统分享 ---
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showSystemActivitySheet = true
                    }
                }
            )
        }
        // 2. 微信引导页
        .sheet(isPresented: $showWeChatGuideSheet) {
            WeChatGuideView()
        }
        // 3. 原生系统分享（作为“更多”选项）
        .sheet(isPresented: $showSystemActivitySheet) {
            ActivityView(activityItems: [createShareText()])
                .presentationDetents([.medium, .large])
        }

        // 【新增】挂载推广弹窗
        .sheet(isPresented: $showNewsPromoSheet) {
            NewsPromoView(onOpenAction: {
                // 关闭弹窗
                showNewsPromoSheet = false
                // 延迟执行跳转，保证动画流畅
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    openApp(scheme: "globalnews://", appId: "6754904170")
                }
            })
        }
        .sheet(isPresented: $showFontAdjustment) {
            FontAdjustmentView()
                .presentationDetents([.large])
        }
    }

    // 【新增】生成分享文本的辅助函数，避免在 ViewBuilder 中写复杂逻辑
    private func createShareText() -> String {
        let limit = 7
        let textParts = cachedParagraphs.prefix(limit)
        var bodyText = textParts.joined(separator: "\n\n")
        
        if cachedParagraphs.count > limit {
            bodyText += Localized.shareFooter
        }
        
        // 【修改 2】分享时也使用当前显示的语言标题
        return displayTopic + "\n\n" + bodyText
    }
    
    // 【优化 2】将耗时的文本处理移至后台线程，富文本构建保留在主线程（适配 Swift 6 并发安全）
    private func prepareContent() {
        let currentArticle = self.article
        let currentMode = self.isEnglishMode
        let currentBodyFontSize = CGFloat(self.articleBodyFontSize)

        // 使用 Task.detached 将纯文本处理移出主线程
        Task.detached(priority: .userInitiated) {
            // 1. 选择文本源
            let contentToParse: String
            if currentMode, let contentEng = currentArticle.article_eng, !contentEng.isEmpty {
                contentToParse = contentEng
            } else {
                contentToParse = currentArticle.article
            }

            // 2. 分段 (后台执行)
            let paras = contentToParse
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            // 3. 图片分布逻辑 (后台执行)
            let imgs = Array(currentArticle.images.dropFirst())
            let distribute = !imgs.isEmpty && imgs.count < paras.count
            let interval = distribute ? max(1, paras.count / (imgs.count + 1)) : 1

            // 4. 回到主线程构建 NSAttributedString 并更新 UI
            await MainActor.run {
                guard self.article.id == currentArticle.id else { return }
                
                // ⭐ 在主线程访问 UIKit 属性并生成 NSAttributedString，解决 Swift 6 报错
                let font = NativeParagraphView.makeFont(size: currentBodyFontSize)
                let style = NativeParagraphView.makeParagraphStyle(for: currentBodyFontSize)
                let textColor = UIColor.label

                let attrParas = paras.map { text in
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: font,
                            .paragraphStyle: style,
                            .foregroundColor: textColor
                        ]
                    )
                }

                self.cachedParagraphs = paras
                self.cachedAttrParagraphs = attrParas
                self.cachedRemainingImages = imgs
                self.cachedDistributeEvenly = distribute
                self.cachedInsertionInterval = interval

                withAnimation(.easeIn(duration: 0.2)) {
                    self.isContentReady = true
                }
            }
        }
    }
    
    private func openApp(scheme: String, appId: String) {
        let appUrl = URL(string: scheme)
        let storeUrl = URL(string: "https://apps.apple.com/cn/app/id\(appId)")
        
        if let appUrl = appUrl, UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl)
        } else if let storeUrl = storeUrl {
            UIApplication.shared.open(storeUrl)
        }
    }
    
    // 【优化】使用静态 Formatter
    private func formatMonthDay(from timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else {
            return timestamp
        }
        Self.monthDayFormatter.locale = Localized.currentLocale
        return Self.monthDayFormatter.string(from: date)
    }
    
    private func formatDate(from timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else {
            return timestamp.uppercased()
        }
        Self.longDateFormatter.dateFormat = Localized.dateFormatFull
        Self.longDateFormatter.locale = Localized.currentLocale
        return Self.longDateFormatter.string(from: date).uppercased()
    }
}

// MARK: - 高性能原生段落渲染视图
struct NativeParagraphView: UIViewRepresentable {
    let attributedText: NSAttributedString

    // 公开静态资源，供 prepareContent() 在后台线程复用
    static let paragraphFont: UIFont = {
        if let font = UIFont(name: "NewYork-Regular", size: 25) {
            return font
        }
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        if let serifDesc = descriptor.withDesign(.serif) {
            return UIFont(descriptor: serifDesc, size: 25)
        }
        return UIFont.systemFont(ofSize: 25)
    }()

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 12
        return style
    }()

    // 【新增】动态字号工厂方法
    static func makeFont(size: CGFloat) -> UIFont {
        if let font = UIFont(name: "NewYork-Regular", size: size) {
            return font
        }
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        if let serifDesc = descriptor.withDesign(.serif) {
            return UIFont(descriptor: serifDesc, size: size)
        }
        return UIFont.systemFont(ofSize: size)
    }

    static func makeParagraphStyle(for fontSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = round(fontSize * 0.48)
        return style
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false          // 关键：禁止内部滚动，让高度自适应内容
        tv.isSelectable = true              // 原生长按选词 → 复制/翻译/朗读，替代旧的 onLongPressGesture
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.dataDetectorTypes = []
        // 确保垂直方向高度不被压缩
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // 直接赋值预建好的 NSAttributedString，主线程零开销
        // 仅当内容确实变化时才重新赋值
        if tv.attributedText != attributedText {
            tv.attributedText = attributedText
        }
    }

    // iOS 16+ 精准高度计算，消除 LazyVStack 布局跳动
    @available(iOS 16.0, *)
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        // 【修改】增加 width > 10 的判断，防止由于非预期的极小宽度触发无限布局循环
        guard let width = proposal.width, width > 10, width < .infinity else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

// MARK: - ArticleImageView (保持不变，或确保 ImageLoader 是异步的)
struct ArticleImageView: View {
    let imageName: String
    let timestamp: String
    
    // 【修改】声明时不立刻初始化，留给 init 处理
    @StateObject private var imageLoader: ImageLoader
    @State private var isShowingZoomView = false
    // 【新增】引入全局的 ResourceManager，用于下载缺失或损坏的图片
    @EnvironmentObject var resourceManager: ResourceManager
    @AppStorage("imageCaptionFontSize") private var captionFontSize: Double = 12
    
    private let horizontalPadding: CGFloat = 20
    private var imagePath: String {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }
    
    // 【新增】自定义初始化，提前注入图片路径查缓存
    init(imageName: String, timestamp: String) {
        self.imageName = imageName
        self.timestamp = timestamp
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = documentsDirectory.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
        
        // 关键点：在 StateObject 创建之初，就去查内存缓存
        self._imageLoader = StateObject(wrappedValue: ImageLoader(imagePath: path))
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let uiImage = imageLoader.image {
                    Button(action: { self.isShowingZoomView = true }) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if imageLoader.isLoading {
                    // 【优化】给 ProgressView 一个固定高度，防止 LazyVStack 布局抖动
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200) 
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, horizontalPadding)
                } else {
                    // 【优化】提供手动点击重试按钮
                    Button(action: {
                        Task { await fetchAndLoadImage() }
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill").font(.largeTitle).foregroundColor(.gray)
                            Text("图片加载失败，点击重试").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, horizontalPadding)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
            if imageLoader.image != nil {
                Text((imageName as NSString).deletingPathExtension)
                    .font(.system(size: captionFontSize))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)
                    .textSelection(.enabled)
            }
        }
        .fullScreenCover(isPresented: $isShowingZoomView) {
            ZoomableImageView(imageName: imageName, timestamp: timestamp, isPresented: $isShowingZoomView)
        }
        .padding(.vertical, 10)
        .onAppear {
            // 【修改】如果在 init 阶段就已经命中内存缓存，直接 return，啥也不用做！
            if imageLoader.image != nil { return }
            
            Task {
                // 1. 尝试从本地加载
                let success = await imageLoader.load(from: imagePath)
                // 2. 如果本地不存在或者文件损坏（返回false），自动触发一次修复下载
                if !success {
                    await fetchAndLoadImage()
                }
            }
        }
    }
    
    // 执行修复并重新加载
    private func fetchAndLoadImage() async {
        imageLoader.isLoading = true
        do {
            // 【关键】如果本地存在文件但无法识别为图片（损坏的空文件），必须先删除它
            // 否则 ResourceManager 的下载逻辑会误以为文件已存在而跳过下载
            if FileManager.default.fileExists(atPath: imagePath) {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            
            // 触发下载单张图片
            try await resourceManager.downloadImagesForArticle(
                timestamp: timestamp,
                imageNames: [imageName],
                progressHandler: { _, _ in } // 单张图不需要更新UI进度条
            )
            
            // 下载完成后，再次尝试加载到内存
            _ = await imageLoader.load(from: imagePath)
        } catch {
            print("单张图片自愈修复失败: \(error)")
            imageLoader.isLoading = false
            imageLoader.isFailed = true
        }
    }
}

// MARK: - ZoomableImageView
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
        guard let uiImage = UIImage(contentsOfFile: imagePath) else {
            saveAlertMessage = Localized.imageLoadError; showSaveAlert = true; return
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
                            saveAlertMessage = success ? Localized.saveToAlbum : "\(Localized.saveFailed): \(error?.localizedDescription ?? "")"
                            showSaveAlert = true
                        }
                    }
                default:
                    saveAlertMessage = Localized.noPhotoPermission; showSaveAlert = true
                }
            }
        }
    }
}

// MARK: - ZoomableScrollView (保持不变)
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
                            // 【修改】使用真实的 Asset 图片名称，去掉 foregroundStyle，加上圆角
                            Image("logo_stock_elf_small") 
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                // 添加 App 图标标准的平滑圆角
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            
                            Text(Localized.promoTitle)
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)

                        // 3. 媒体品牌墙
                        VStack(spacing: 10) {
                            Text(Localized.promoFeature).font(.subheadline).foregroundColor(.secondary).textCase(.uppercase)
                            // 在 NewsPromoView 的 body 内部
                            let brands = Localized.isEnglish ? 
                                ["Earnings", "Economy", "Options", "ETF", "Commodity", "FX", "Exchanges", "Bonds", "..."] :
                                ["美股财报", "美国经济数据", "期权分析", "ETF榜单", "大宗商品", "货币汇率", "全球交易所", "各国债券", "..."]
                            FlowLayoutView(items: brands)
                        }
                        .padding(.vertical, 20)

                        // 4. 核心介绍文案
                        VStack(alignment: .leading, spacing: 15) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkles").foregroundColor(.orange)
                                Text(Localized.promoDesc)
                            }.font(.subheadline).foregroundColor(.secondary)
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
                        Text(Localized.downloadInStore).fontWeight(.bold)
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

// 【新增】将音频按钮隔离出来，让它自己去观察状态更新，不连累大视图
struct AudioToolbarButton: View {
    @ObservedObject var audioPlayerManager: AudioPlayerManager
    var onAudioToggle: () -> Void
    
    var body: some View {
        Button(action: onAudioToggle) {
            Image(systemName: audioPlayerManager.isPlaybackActive ? "headphones.slash" : "headphones")
        }
        .disabled(audioPlayerManager.isSynthesizing)
    }
}

// MARK: - 现代化推荐卡片组件
struct PromoCardView: View {
    let title: String
    let subtitle: String
    let imageName: String // 改为图片名称
    let isSystemIcon: Bool // 新增：标记是否为系统图标
    let colors: [Color]
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                
                // 第一行：左边图标，右边名字
                HStack(spacing: 12) {
                    // 图标区域
                    Group {
                        if isSystemIcon {
                            Image(systemName: imageName)
                                .font(.title2)
                                .foregroundStyle(.linearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        } else {
                            Image(imageName) // 加载 Assets 中的图片
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32) // 这里稍微缩小了一点图标尺寸，让横排更精致，你也可以保持40
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: colors.first!.opacity(0.2), radius: 5, x: 0, y: 2)
                    
                    // 名字 (标题)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                
                // 下一行：说明文字
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    // 如果你想让说明文字显示多行，可以改成 .lineLimit(2) 或去掉此限制
                    .lineLimit(2) 
                    // 如果想让文字和上方图标左对齐稍微缩进，可加 padding
                    // .padding(.leading, 2) 
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
            )
        }
        .buttonStyle(PlainButtonStyle()) // 防止按钮默认的蓝色高亮破坏设计
    }
}

// MARK: - 字体大小调整视图
struct FontAdjustmentView: View {
    @AppStorage("articleBodyFontSize") private var bodyFontSize: Double = 25
    @AppStorage("imageCaptionFontSize") private var captionFontSize: Double = 12
    @Environment(\.dismiss) var dismiss

    private let bodyRange: ClosedRange<Double> = 16...36
    private let captionRange: ClosedRange<Double> = 10...20
    private let defaultBodySize: Double = 25
    private let defaultCaptionSize: Double = 12

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {

                    // ── 正文字号 ──
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(Localized.isEnglish ? "Body Font" : "正文字号")
                                .font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            Text("\(Int(bodyFontSize)) pt")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                                .foregroundColor(.secondary)
                            Slider(value: $bodyFontSize, in: bodyRange, step: 1)
                                .tint(.blue)
                            Image(systemName: "textformat.size.larger")
                                .foregroundColor(.secondary)
                        }

                        // 实时预览
                        Text(Localized.isEnglish
                             ? "This is a preview of the body text at the selected size."
                             : "这是一段示例正文，用来预览当前字体大小的实际效果。")
                            .font(.system(size: bodyFontSize, design: .serif))
                            .lineSpacing(bodyFontSize * 0.48)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                    }

                    Divider()

                    // ── 图注字号 ──
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(Localized.isEnglish ? "Caption Font" : "图注字号")
                                .font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            Text("\(Int(captionFontSize)) pt")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Slider(value: $captionFontSize, in: captionRange, step: 1)
                                .tint(.blue)
                            Image(systemName: "textformat.size.larger")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        // 实时预览
                        Text(Localized.isEnglish
                             ? "Sample image caption text"
                             : "示例图片说明文字")
                            .font(.system(size: captionFontSize))
                            .foregroundColor(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                    }

                    Spacer(minLength: 20)

                    // ── 恢复默认 ──
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            bodyFontSize = defaultBodySize
                            captionFontSize = defaultCaptionSize
                        }
                    }) {
                        Text(Localized.isEnglish ? "Reset to Default" : "恢复默认")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                    }
                }
                .padding(20)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(Localized.isEnglish ? "Font Size" : "字体大小")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Localized.isEnglish ? "Done" : "完成") { dismiss() }
                }
            }
        }
    }
}