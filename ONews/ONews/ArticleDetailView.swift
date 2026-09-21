import SwiftUI
import UIKit
import Photos
import ImageIO

// MARK: - 1. PreferenceKey（仅 VIP 吸顶条使用，普通用户不会挂载探针）
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - ActivityView
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

// ============================================================================
// MARK: - ★ 正文排版：预构建 + 全局缓存（Reeder 式"内容先到位，绝不闪占位"）
// ============================================================================

/// 正文由若干"块"组成：连续段落被合并成 **一个** UITextView，图片单独成块。
/// 这样一篇文章的原生视图数量从 N(段落) 降到 (图片数+1)，排版次数同步下降。
struct ArticleBodyBlock: Identifiable {
    enum Content {
        case text(NSAttributedString)
        case image(String)
    }
    let id: String
    let content: Content
}

/// 预构建结果（class：可直接放进 NSCache；@unchecked Sendable：允许跨线程构建后回传）
final class PreparedArticleBody: @unchecked Sendable {
    let bodyID: String
    let blocks: [ArticleBodyBlock]
    let paragraphs: [String]       // 分享文本用
    init(bodyID: String, blocks: [ArticleBodyBlock], paragraphs: [String]) {
        self.bodyID = bodyID
        self.blocks = blocks
        self.paragraphs = paragraphs
    }
}

enum ArticleBodyBuilder {

    /// 纯计算，可在任意线程执行（UIFont / NSAttributedString 构建是线程安全的）
    static func build(article: Article, english: Bool, fontSize: CGFloat, bodyID: String) -> PreparedArticleBody {

        // 1. 选择语言
        let source: String
        if english, let eng = article.article_eng, !eng.isEmpty {
            source = eng
        } else {
            source = article.article
        }

        // 2. 分段
        let paras = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // 3. 图片分布（与旧逻辑完全一致，保证观感不变）
        let allImages = article.images
        let rest = Array(allImages.dropFirst())
        let distribute = !rest.isEmpty && rest.count < paras.count
        let interval = distribute ? max(1, paras.count / (rest.count + 1)) : 1

        // 4. 文本属性
        let font = NativeParagraphView.makeFont(size: fontSize)
        let style = NativeParagraphView.makeParagraphStyle(for: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: UIColor.label      // 动态色，暗黑模式自动跟随
        ]

        var blocks: [ArticleBodyBlock] = []
        var pending = NSMutableAttributedString()
        var textBlockSeq = 0

        func flushText() {
            guard pending.length > 0 else { return }
            blocks.append(.init(id: "\(bodyID)#t\(textBlockSeq)",
                                content: .text(NSAttributedString(attributedString: pending))))
            textBlockSeq += 1
            pending = NSMutableAttributedString()
        }

        if let first = allImages.first {
            blocks.append(.init(id: "\(bodyID)#i-first", content: .image(first)))
        }

        for (pIndex, para) in paras.enumerated() {
            if pending.length > 0 {
                pending.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            pending.append(NSAttributedString(string: para, attributes: attrs))

            if (pIndex + 1) % interval == 0 {
                let imgIdx = (pIndex + 1) / interval - 1
                if imgIdx >= 0 && imgIdx < rest.count {
                    flushText()
                    blocks.append(.init(id: "\(bodyID)#i\(imgIdx)", content: .image(rest[imgIdx])))
                }
            }
        }
        flushText()

        // 尾部多余图片
        if !distribute && rest.count > paras.count {
            for (offset, name) in rest.dropFirst(paras.count).enumerated() {
                blocks.append(.init(id: "\(bodyID)#tail\(offset)", content: .image(name)))
            }
        }

        return PreparedArticleBody(bodyID: bodyID, blocks: blocks, paragraphs: paras)
    }
}

/// 全局正文缓存：命中即 0 成本；未命中同步构建（毫秒级）；配合 prefetch 基本永远命中。
final class ArticleBodyCache: @unchecked Sendable {
    static let shared = ArticleBodyCache()
    private let cache = NSCache<NSString, PreparedArticleBody>()
    private init() { cache.countLimit = 16 }

    static func key(articleID: UUID, english: Bool, fontSize: Double) -> String {
        "\(articleID.uuidString)|\(english ? 1 : 0)|\(Int(fontSize))"
    }

    /// 同步获取（命中缓存直接返回，否则当场构建并入缓存）
    func body(for article: Article, english: Bool, fontSize: Double) -> PreparedArticleBody {
        let k = Self.key(articleID: article.id, english: english, fontSize: fontSize)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        let built = ArticleBodyBuilder.build(article: article,
                                            english: english,
                                            fontSize: CGFloat(fontSize),
                                            bodyID: k)
        cache.setObject(built, forKey: k as NSString)
        return built
    }

    /// 后台预热（列表点击瞬间 / 预取下一篇时调用）
    func prefetch(article: Article, english: Bool, fontSize: Double) {
        let k = Self.key(articleID: article.id, english: english, fontSize: fontSize)
        if cache.object(forKey: k as NSString) != nil { return }
        Task.detached(priority: .userInitiated) { [cache] in
            let built = ArticleBodyBuilder.build(article: article,
                                                 english: english,
                                                 fontSize: CGFloat(fontSize),
                                                 bodyID: k)
            cache.setObject(built, forKey: k as NSString)
        }
    }

    /// 便捷版：自动读取当前语言/字号偏好
    @MainActor
    func prefetch(article: Article) {
        let english = UserDefaults.standard.bool(forKey: "isGlobalEnglishMode")
        let raw = UserDefaults.standard.double(forKey: "articleBodyFontSize")
        prefetch(article: article, english: english, fontSize: raw > 0 ? raw : 25)
    }

    func purge() { cache.removeAllObjects() }
}

/// 文本块高度缓存：让 sizeThatFits 命中时 0 排版（滚动/复用/回退都不再重排）
final class TextHeightCache: @unchecked Sendable {
    static let shared = TextHeightCache()
    private let cache = NSCache<NSString, NSNumber>()
    private init() { cache.countLimit = 600 }
    func height(_ key: String) -> CGFloat? {
        guard let n = cache.object(forKey: key as NSString) else { return nil }
        return CGFloat(n.doubleValue)
    }
    func set(_ h: CGFloat, _ key: String) {
        cache.setObject(NSNumber(value: Double(h)), forKey: key as NSString)
    }
}

// ============================================================================
// MARK: - ImageLoader（降采样解码 + 有上限的缓存 + 宽高比记录）
// ============================================================================

/// 记录图片宽高比，用于占位时预留正确高度 → 图片到位不跳版
final class ImageAspectStore: @unchecked Sendable {
    static let shared = ImageAspectStore()
    private var map: [String: CGFloat] = [:]      // path -> height/width
    private let lock = NSLock()
    func ratio(for path: String) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        return map[path]
    }
    func set(_ r: CGFloat, for path: String) {
        guard r.isFinite, r > 0 else { return }
        lock.lock(); map[path] = r; lock.unlock()
    }
}

@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    @Published var isFailed = false

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        c.totalCostLimit = 80 * 1024 * 1024      // ★ 关键：给缓存上限，避免内存压力抖动
        return c
    }()

    /// 目标像素宽（按屏幕物理像素，避免解码 4000px 大图）
    private static let targetPixelWidth: CGFloat = {
        UIScreen.main.bounds.width * UIScreen.main.scale
    }()

    init(imagePath: String? = nil) {
        if let path = imagePath, let cached = Self.cache.object(forKey: path as NSString) {
            self.image = cached
        }
    }

    func load(from path: String) async -> Bool {
        let cacheKey = path as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            self.image = cached
            self.isFailed = false
            return true
        }

        isLoading = true
        isFailed = false

        let maxPixel = Self.targetPixelWidth
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            Self.decodeDownsampled(path: path, maxPixelWidth: maxPixel)
        }.value

        isLoading = false

        if let img = loaded {
            let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
            Self.cache.setObject(img, forKey: cacheKey, cost: cost)
            if img.size.width > 0 {
                ImageAspectStore.shared.set(img.size.height / img.size.width, for: path)
            }
            self.image = img
            return true
        } else {
            self.isFailed = true
            return false
        }
    }

    /// ImageIO 降采样：只解码到屏幕需要的尺寸，CPU/内存都省一大截
    nonisolated private static func decodeDownsampled(path: String, maxPixelWidth: CGFloat) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // 先取原始尺寸，记录宽高比（即使解码失败也能预留高度）
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 {
            ImageAspectStore.shared.set(h / w, for: path)
        }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,          // 提前解码，滚动时不再解
            kCGImageSourceThumbnailMaxPixelSize: max(600, maxPixelWidth)
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(contentsOfFile: path)
    }

    static func clearCache() {
        cache.removeAllObjects()
        ArticleBodyCache.shared.purge()
    }
}

// ============================================================================
// MARK: - ArticleDetailView
// ============================================================================
struct ArticleDetailView: View {
    let article: Article
    let sourceName: String
    /// 由容器算好（中/英），详情页不再持有 NewsViewModel → 彻底断开 @Published 风暴
    let sourceDisplayName: String
    let unreadCountForGroup: Int
    let totalUnreadCount: Int
    @Binding var isEnglishMode: Bool
    /// 是否启用吸顶标题（只有后门 VIP 才为 true；false 时完全不挂滚动探针）
    let showStickyTitle: Bool
    var requestNextArticle: () async -> Void

    @Environment(\.appNavPath) private var appNavPath

    @State private var showNewsPromoSheet = false
    @State private var showCustomShareSheet = false
    @State private var showSystemActivitySheet = false
    @State private var showWeChatGuideSheet = false
    @State private var showFontAdjustment = false
    @State private var isTitleVisible = true

    @AppStorage("articleBodyFontSize") private var articleBodyFontSize: Double = 25

    // MARK: 正文（同步取缓存，命中即 0 成本；无 @State、无占位、无二次布局）
    private var prepared: PreparedArticleBody {
        ArticleBodyCache.shared.body(for: article,
                                     english: isEnglishMode,
                                     fontSize: articleBodyFontSize)
    }

    private var hasEnglishVersion: Bool {
        guard let t = article.topic_eng, !t.isEmpty,
              let a = article.article_eng, !a.isEmpty else { return false }
        return true
    }

    private var displayTopic: String {
        (isEnglishMode && hasEnglishVersion) ? (article.topic_eng ?? article.topic) : article.topic
    }

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f
    }()
    private static let longDateFormatter = DateFormatter()
    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"; return f
    }()

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    // ★ Equatable 包裹：只要 bodyID 不变，正文这一整棵子树绝不重算
                    ArticleBodyContentView(prepared: prepared, timestamp: article.timestamp)
                        .equatable()
                    footer
                }
                .padding(.vertical)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "Scroll")
            // 仅 VIP 才付出滚动监听成本
            .modifier(StickyTitleObserver(enabled: showStickyTitle) { visible in
                guard visible != isTitleVisible else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isTitleVisible = visible }
            })

            if showStickyTitle && !isTitleVisible {
                stickyBar
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    NextArticleFloatingButton { Task { await requestNextArticle() } }
                }
            }
            .zIndex(100)
        }
        .toolbar { toolbarContent }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCustomShareSheet) {
            CustomShareSheet(
                onWeChatAction: {
                    UIPasteboard.general.string = createShareText()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showWeChatGuideSheet = true }
                },
                onSystemShareAction: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showSystemActivitySheet = true }
                }
            )
        }
        .sheet(isPresented: $showWeChatGuideSheet) { WeChatGuideView() }
        .sheet(isPresented: $showSystemActivitySheet) {
            ActivityView(activityItems: [createShareText()])
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNewsPromoSheet) {
            NewsPromoView(onOpenAction: {
                showNewsPromoSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    openApp(scheme: "globalnews://", appId: "6754904170")
                }
            })
        }
        .sheet(isPresented: $showFontAdjustment) {
            FontAdjustmentView().presentationDetents([.large])
        }
        // 语言/字号变更时预热新版本，避免下一帧同步构建
        .onChange(of: isEnglishMode) { _, newValue in
            ArticleBodyCache.shared.prefetch(article: article,
                                            english: newValue,
                                            fontSize: articleBodyFontSize)
        }
        .onChange(of: articleBodyFontSize) { _, newValue in
            ArticleBodyCache.shared.prefetch(article: article,
                                            english: isEnglishMode,
                                            fontSize: newValue)
        }
    }

    // MARK: - 头部
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(formatDate(from: article.timestamp))
                    .font(.caption).foregroundColor(.gray)
                if let urlString = article.url, let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(spacing: 2) {
                            Text(Localized.originalLink)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.caption).foregroundColor(.blue)
                    }
                }
            }
            Text(displayTopic)
                .font(.system(.title, design: .serif)).fontWeight(.bold)
                .animation(.none, value: isEnglishMode)
        }
        .padding(.horizontal, 20)
        .id("Header-\(article.id)")
    }

    // MARK: - 尾部（下一篇按钮 + 推广）
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { Task { await requestNextArticle() } }) {
                HStack {
                    Text(Localized.readNext).fontWeight(.bold)
                    Image(systemName: "arrow.right.circle.fill")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .cornerRadius(12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 12) {
                Text(Localized.isEnglish ? "More from Developer" : "“毛遂自荐”博主另一款精品应用")
                    .font(.footnote).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    Spacer()
                    PromoCardView(
                        title: Localized.isEnglish ? "US Stock Elf" : "美股精灵",
                        subtitle: Localized.isEnglish ? "AI Stock Picks" : "AI算法每日荐股，全球财经数据一站搞定，炒美股必备伴侣。",
                        imageName: "logo_stock_elf_small",
                        isSystemIcon: false,
                        colors: [.blue, .purple]
                    ) { showNewsPromoSheet = true }
                    .frame(width: 220)
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 100)
        }
    }

    private var stickyBar: some View {
        Text(displayTopic)
            .font(.subheadline).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .top))
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(10)
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(sourceDisplayName.replacingOccurrences(of: "_", with: " "))
                    .font(.headline)
                    .animation(.none, value: isEnglishMode)
                HStack(spacing: 8) {
                    if unreadCountForGroup == totalUnreadCount {
                        Text("\(totalUnreadCount)")
                    } else {
                        Text("\(unreadCountForGroup) | \(totalUnreadCount)")
                    }
                    Text(formatMonthDay(from: article.timestamp))
                }
                .font(.caption).foregroundColor(.secondary)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if hasEnglishVersion {
                    Button(action: { withAnimation(.spring()) { isEnglishMode.toggle() } }) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 1.5)
                                .background(!isEnglishMode ? Color.primary : Color.clear)
                                .clipShape(Circle())
                            Text(isEnglishMode ? "中" : "英")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(!isEnglishMode ? Color.viewBackground : Color.primary)
                        }
                        .frame(width: 24, height: 24)
                    }
                }

                Button(action: { showCustomShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                }

                Menu {
                    Button(action: { showFontAdjustment = true }) {
                        Label(Localized.isEnglish ? "Font Size" : "字体大小", systemImage: "textformat.size")
                    }
                    Button(action: { appNavPath?.wrappedValue.append(NavigationTarget.videoSearch) }) {
                        Label(Localized.isEnglish ? "Video Search" : "视频检索", systemImage: "magnifyingglass")
                    }
                    Button(action: { appNavPath?.wrappedValue.append(NavigationTarget.videoModule) }) {
                        Label(Localized.isEnglish ? "Video Library" : "影视频道", systemImage: "play.rectangle.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .foregroundColor(.primary)
        }
    }

    // MARK: - Helpers
    private func createShareText() -> String {
        let limit = 7
        let paras = prepared.paragraphs
        var bodyText = paras.prefix(limit).joined(separator: "\n\n")
        if paras.count > limit { bodyText += Localized.shareFooter }
        return displayTopic + "\n\n" + bodyText
    }

    private func openApp(scheme: String, appId: String) {
        if let appUrl = URL(string: scheme), UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl)
        } else if let storeUrl = URL(string: "https://apps.apple.com/cn/app/id\(appId)") {
            UIApplication.shared.open(storeUrl)
        }
    }

    private func formatMonthDay(from timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp }
        Self.monthDayFormatter.locale = Localized.currentLocale
        return Self.monthDayFormatter.string(from: date)
    }

    private func formatDate(from timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp.uppercased() }
        Self.longDateFormatter.dateFormat = Localized.dateFormatFull
        Self.longDateFormatter.locale = Localized.currentLocale
        return Self.longDateFormatter.string(from: date).uppercased()
    }
}

// MARK: - 正文子树（Equatable：bodyID 不变就完全跳过重算）
private struct ArticleBodyContentView: View, Equatable {
    let prepared: PreparedArticleBody
    let timestamp: String

    static func == (l: ArticleBodyContentView, r: ArticleBodyContentView) -> Bool {
        l.prepared.bodyID == r.prepared.bodyID && l.timestamp == r.timestamp
    }

    var body: some View {
        // 块数量很少（图片数+1），用 VStack 即可：一次成型、绝不跳版
        VStack(alignment: .leading, spacing: 16) {
            ForEach(prepared.blocks) { block in
                switch block.content {
                case .text(let attr):
                    NativeParagraphView(attributedText: attr, identity: block.id)
                        .padding(.horizontal, 18)
                case .image(let name):
                    ArticleImageView(imageName: name, timestamp: timestamp)
                }
            }
        }
    }
}

// MARK: - 吸顶探针（VIP 专用；非 VIP 时零成本）
private struct StickyTitleObserver: ViewModifier {
    let enabled: Bool
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollOffsetPreferenceKey.self,
                                               value: geo.frame(in: .named("Scroll")).minY)
                    }
                    .frame(height: 1), alignment: .top
                )
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { onChange($0 > -80) }
        } else {
            content
        }
    }
}

// ============================================================================
// MARK: - 高性能原生文本块（TextKit1 + 身份化高度缓存）
// ============================================================================
struct NativeParagraphView: UIViewRepresentable {
    let attributedText: NSAttributedString
    /// 稳定身份（bodyID#index）：用于判断"内容是否真的换了"和高度缓存键，
    /// 比 hashValue 更安全（无碰撞风险），比内容比较更快（O(1) 字符串比较）。
    var identity: String = ""

    final class Coordinator {
        var appliedIdentity: String = ""
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    // ---- 字体 / 段落样式（供 Builder 在后台线程复用）----
    static let paragraphFont: UIFont = makeFont(size: 25)

    static func makeFont(size: CGFloat) -> UIFont {
        if let f = UIFont(name: "NewYork-Regular", size: size) { return f }
        let d = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        if let serif = d.withDesign(.serif) { return UIFont(descriptor: serif, size: size) }
        return UIFont.systemFont(ofSize: size)
    }

    static let paragraphStyle: NSParagraphStyle = makeParagraphStyle(for: 25)

    static func makeParagraphStyle(for fontSize: CGFloat) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.lineSpacing = round(fontSize * 0.48)
        // ★ 段间距用 paragraphSpacing 表达，从而把多段合并进 1 个 UITextView
        s.paragraphSpacing = round(fontSize * 0.95)
        s.lineBreakMode = .byWordWrapping
        return s
    }

    static func makeTextView() -> UITextView {
        let tv: UITextView
        if #available(iOS 16.0, *) {
            // 静态长文用 TextKit 1 的高度计算更快更稳（TextKit 2 的 viewport 布局在
            // isScrollEnabled = false 时会做额外的 fragment 往返）
            tv = UITextView(usingTextLayoutManager: false)
        } else {
            tv = UITextView()
        }
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true                  // 原生长按选词 / 复制 / 翻译
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.dataDetectorTypes = []
        tv.adjustsFontForContentSizeCategory = false
        tv.textDragInteraction?.isEnabled = false
        tv.clipsToBounds = false
        tv.layoutManager.allowsNonContiguousLayout = false
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tv
    }

    func makeUIView(context: Context) -> UITextView { Self.makeTextView() }

    func updateUIView(_ tv: UITextView, context: Context) {
        apply(tv, context.coordinator)
    }

    private func apply(_ tv: UITextView, _ coord: Coordinator) {
        let key = identity.isEmpty ? "\(attributedText.length)" : identity
        guard coord.appliedIdentity != key else { return }
        tv.attributedText = attributedText
        coord.appliedIdentity = key
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 10 else { return nil }
        let w = (width * 2).rounded() / 2
        let cacheKey = "\(identity)|\(w)"

        if let h = TextHeightCache.shared.height(cacheKey) {
            return CGSize(width: width, height: h)
        }
        apply(uiView, context.coordinator)      // 确保测量前内容已就位
        let h = ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        TextHeightCache.shared.set(h, cacheKey)
        return CGSize(width: width, height: h)
    }
}

// ============================================================================
// MARK: - ArticleImageView（预留高度 + 网络自愈）
// ============================================================================
struct ArticleImageView: View {
    let imageName: String
    let timestamp: String

    @StateObject private var imageLoader: ImageLoader
    @State private var isShowingZoomView = false
    @EnvironmentObject var resourceManager: ResourceManager
    @AppStorage("imageCaptionFontSize") private var captionFontSize: Double = 12

    @State private var recoveryTask: Task<Void, Never>? = nil
    @State private var isRecovering = false

    private let horizontalPadding: CGFloat = 20

    private var imagePath: String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }

    init(imageName: String, timestamp: String) {
        self.imageName = imageName
        self.timestamp = timestamp
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = dir.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
        self._imageLoader = StateObject(wrappedValue: ImageLoader(imagePath: path))
    }

    /// 占位高度：已知宽高比 → 精确预留，图片到位不跳版
    private var placeholderHeight: CGFloat {
        let contentWidth = UIScreen.main.bounds.width - horizontalPadding * 2
        if let r = ImageAspectStore.shared.ratio(for: imagePath) {
            return min(max(contentWidth * r, 120), 620)
        }
        return 220
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let uiImage = imageLoader.image {
                    Button(action: { isShowingZoomView = true }) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlainButtonStyle())

                } else if imageLoader.isLoading || isRecovering {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(waitingHintText).font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: placeholderHeight)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, horizontalPadding)

                } else {
                    Button(action: { manualRetry() }) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.largeTitle).foregroundColor(.gray)
                            Text(Localized.isEnglish ? "Tap to retry" : "图片加载失败，点击重试")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: placeholderHeight)
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
        .onAppear { startInitialLoad() }
        .onDisappear {
            recoveryTask?.cancel(); recoveryTask = nil; isRecovering = false
        }
        .onChange(of: resourceManager.isNetworkAvailable) { _, available in
            if available && imageLoader.image == nil { startRecovery() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .articleImageDidDownload)) { note in
            guard imageLoader.image == nil,
                  let path = note.userInfo?["path"] as? String, path == imagePath else { return }
            Task {
                if await imageLoader.load(from: imagePath) {
                    recoveryTask?.cancel(); isRecovering = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if imageLoader.image == nil { startRecovery() }
        }
    }

    private var waitingHintText: String {
        if !resourceManager.isNetworkAvailable {
            return Localized.isEnglish ? "Waiting for network…" : "等待网络连接，图片将自动加载…"
        }
        return Localized.isEnglish ? "Loading image…" : "图片加载中…"
    }

    private func startInitialLoad() {
        if imageLoader.image != nil { return }
        Task {
            let ok = await imageLoader.load(from: imagePath)
            if !ok { startRecovery() }
        }
    }

    private func startRecovery() {
        guard imageLoader.image == nil else { return }
        recoveryTask?.cancel()
        isRecovering = true

        recoveryTask = Task {
            resourceManager.enqueueImageDownloads(timestamp: timestamp,
                                                  imageNames: [imageName], priority: true)
            var delayMs: UInt64 = 600
            for _ in 0..<25 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(Int(delayMs)))
                if Task.isCancelled { return }
                if imageLoader.image != nil { isRecovering = false; return }

                if FileManager.default.fileExists(atPath: imagePath) {
                    if await imageLoader.load(from: imagePath) {
                        isRecovering = false; return
                    } else {
                        try? FileManager.default.removeItem(atPath: imagePath)
                    }
                }
                if resourceManager.isNetworkAvailable {
                    resourceManager.enqueueImageDownloads(timestamp: timestamp,
                                                          imageNames: [imageName], priority: true)
                }
                delayMs = min(delayMs * 2, 5000)
            }
            isRecovering = false
        }
    }

    private func manualRetry() {
        if FileManager.default.fileExists(atPath: imagePath),
           UIImage(contentsOfFile: imagePath) == nil {
            try? FileManager.default.removeItem(atPath: imagePath)
        }
        startRecovery()
    }
}

// ============================================================================
// MARK: - 以下为原样保留的组件
// ============================================================================
struct ZoomableImageView: View {
    let imageName: String
    let timestamp: String
    @Binding var isPresented: Bool
    @State private var showSaveAlert = false
    @State private var saveAlertMessage = ""

    private var imagePath: String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            ZoomableScrollView(imageName: imageName, timestamp: timestamp)
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle)
                            .foregroundColor(.white.opacity(0.7))
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
                        Image(systemName: "arrow.down.circle.fill").font(.largeTitle)
                            .foregroundColor(.white.opacity(0.7))
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
        let requestAuth: (@escaping (PHAuthorizationStatus) -> Void) -> Void = { cb in
            if #available(iOS 14, *) { PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: cb) }
            else { PHPhotoLibrary.requestAuthorization(cb) }
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
                            saveAlertMessage = success ? Localized.saveToAlbum
                                : "\(Localized.saveFailed): \(error?.localizedDescription ?? "")"
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

struct ZoomableScrollView: UIViewRepresentable {
    let imageName: String
    let timestamp: String
    func makeUIView(context: Context) -> UIScrollView {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imagePath = dir.appendingPathComponent("news_images_\(timestamp)/\(imageName)").path
        guard let image = UIImage(contentsOfFile: imagePath) else { return UIScrollView() }

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
        let dt = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.handleDoubleTap))
        dt.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(dt)
        return scrollView
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        var imageView: UIImageView?
        init(_ parent: ZoomableScrollView) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let p = g.location(in: imageView)
                sv.zoom(to: zoomRect(for: sv, with: p, scale: sv.maximumZoomScale / 2), animated: true)
            }
        }
        private func zoomRect(for sv: UIScrollView, with p: CGPoint, scale: CGFloat) -> CGRect {
            let size = CGSize(width: sv.frame.width / scale, height: sv.frame.height / scale)
            return CGRect(origin: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), size: size)
        }
    }
}

struct NewsPromoView: View {
    var onOpenAction: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.1), Color(UIColor.systemBackground)]),
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            VStack(spacing: 25) {
                Capsule().fill(Color.secondary.opacity(0.3))
                    .frame(width: 40, height: 5).padding(.top, 10)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 25) {
                        VStack(spacing: 15) {
                            Image("logo_stock_elf_small")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            Text(Localized.promoTitle)
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.primary).multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)

                        VStack(spacing: 10) {
                            Text(Localized.promoFeature).font(.subheadline)
                                .foregroundColor(.secondary).textCase(.uppercase)
                            let brands = Localized.isEnglish ?
                                ["Earnings", "Economy", "Options", "ETF", "Commodity", "FX", "Exchanges", "Bonds", "..."] :
                                ["美股财报", "美国经济数据", "期权分析", "ETF榜单", "大宗商品", "货币汇率", "全球交易所", "各国债券", "..."]
                            FlowLayoutView(items: brands)
                        }
                        .padding(.vertical, 20)

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

            VStack {
                Spacer()
                Button(action: onOpenAction) {
                    HStack {
                        Image(systemName: "app.badge.fill")
                        Text(Localized.downloadInStore).fontWeight(.bold)
                    }
                    .font(.title3).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(28)
                    .shadow(color: .blue.opacity(0.4), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
    }
}

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
        Text(text).font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue).cornerRadius(8)
    }
}

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

struct PromoCardView: View {
    let title: String
    let subtitle: String
    let imageName: String
    let isSystemIcon: Bool
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Group {
                        if isSystemIcon {
                            Image(systemName: imageName).font(.title2)
                                .foregroundStyle(.linearGradient(colors: colors,
                                                                 startPoint: .topLeading,
                                                                 endPoint: .bottomTrailing))
                        } else {
                            Image(imageName).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: colors.first!.opacity(0.2), radius: 5, x: 0, y: 2)

                    Text(title).font(.subheadline).fontWeight(.bold)
                        .foregroundColor(.primary).lineLimit(1)
                }
                Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(Localized.isEnglish ? "Body Font" : "正文字号")
                                .font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            Text("\(Int(bodyFontSize)) pt").font(.subheadline)
                                .foregroundColor(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller").foregroundColor(.secondary)
                            Slider(value: $bodyFontSize, in: bodyRange, step: 1).tint(.blue)
                            Image(systemName: "textformat.size.larger").foregroundColor(.secondary)
                        }
                        Text(Localized.isEnglish
                             ? "This is a preview of the body text at the selected size."
                             : "这是一段示例正文，用来预览当前字体大小的实际效果。")
                            .font(.system(size: bodyFontSize, design: .serif))
                            .lineSpacing(bodyFontSize * 0.48)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(Localized.isEnglish ? "Caption Font" : "图注字号")
                                .font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            Text("\(Int(captionFontSize)) pt").font(.subheadline)
                                .foregroundColor(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller").font(.caption2).foregroundColor(.secondary)
                            Slider(value: $captionFontSize, in: captionRange, step: 1).tint(.blue)
                            Image(systemName: "textformat.size.larger").font(.caption2).foregroundColor(.secondary)
                        }
                        Text(Localized.isEnglish ? "Sample image caption text" : "示例图片说明文字")
                            .font(.system(size: captionFontSize)).foregroundColor(.secondary)
                            .padding(14).frame(maxWidth: .infinity, alignment: .center)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                    }

                    Spacer(minLength: 20)

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            bodyFontSize = defaultBodySize
                            captionFontSize = defaultCaptionSize
                        }
                    }) {
                        Text(Localized.isEnglish ? "Reset to Default" : "恢复默认")
                            .font(.subheadline).foregroundColor(.blue)
                            .padding(.vertical, 12).frame(maxWidth: .infinity)
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

struct NextArticleFloatingButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color.primary)
                .frame(width: 44, height: 44)
                .background(Color(UIColor.systemBackground))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 30)
    }
}