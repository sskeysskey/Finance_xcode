// 图片缓存 / 瀑布流 / 卡片 / 首页 Pager（分页无限滚动 · 性能优化版）

import SwiftUI
import UIKit
import ImageIO

// ⭐ 分类显示名统一辅助（卡片标签 + 首页菜单共用）
func videoCategoryDisplayName(_ key: String, english: Bool) -> String {
    if english { return key }
    switch key {
    case "Featured": return "最新"
    case "Movie":    return "电影"
    case "Drama":    return "剧集"
    case "Show":     return "综艺"
    case "Anime":    return "动漫"
    default:         return key
    }
}

// MARK: - 图片内存缓存
final class OImageCache {
    static let shared = OImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 160 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.cache.removeAllObjects()
            }
    }
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) {
        let cost: Int
        if let cg = image.cgImage { cost = cg.bytesPerRow * cg.height }
        else { cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4) }
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

// MARK: - ⭐ 图片加载管线：后台下载 + ImageIO 降采样（解码不上主线程）+ 同 URL 请求合并
@MainActor
final class OImageLoader {
    static let shared = OImageLoader()
    private var inflight: [NSURL: Task<UIImage?, Never>] = [:]

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                              diskCapacity: 200 * 1024 * 1024,
                              diskPath: "ovideo_covers")
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// 卡片 2 列 × 3x 屏，最长边 900px 足够清晰
    private let maxPixel: CGFloat = 900

    func load(_ url: URL) async -> UIImage? {
        if let c = OImageCache.shared.image(for: url) { return c }
        let key = url as NSURL
        if let t = inflight[key] { return await t.value }

        let session = self.session
        let maxPixel = self.maxPixel
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let (data, resp) = try? await session.data(from: url) else { return nil }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return OImageLoader.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { OImageCache.shared.set(img, for: url) }
        return img
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,        // ⭐ 在后台线程完成解码
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) { return UIImage(cgImage: cg) }
        return UIImage(data: data)
    }
}

fileprivate struct OLoadedImage {
    let url: URL
    let image: UIImage
}

// MARK: - 带缓存异步图片（⭐ 首帧命中内存缓存不闪占位 / URL 变化不串图 / 失败有 failure 态）
struct CachedAsyncImage<Content: View>: View {
    let url: URL
    let content: (AsyncImagePhase) -> Content
    @State private var loaded: OLoadedImage?
    @State private var failedURL: URL?

    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        _loaded = State(initialValue: OImageCache.shared.image(for: url).map { OLoadedImage(url: url, image: $0) })
    }

    var body: some View {
        Group {
            if let l = loaded, l.url == url {
                content(.success(Image(uiImage: l.image)))
            } else if failedURL == url {
                content(.failure(URLError(.cannotDecodeContentData)))
            } else {
                content(.empty)
            }
        }
        .task(id: url) {
            if loaded?.url == url { return }
            if let c = OImageCache.shared.image(for: url) {
                loaded = OLoadedImage(url: url, image: c); return
            }
            let img = await OImageLoader.shared.load(url)
            if Task.isCancelled { return }
            if let img {
                loaded = OLoadedImage(url: url, image: img)
                failedURL = nil
            } else {
                failedURL = url
            }
        }
    }
}

// MARK: - 瀑布流（⭐ 提前 6 个触发下一页；不再整页监听 dataManager）
struct WaterfallGridView: View {
    let items: [OVideoItem]
    let dataManager: OVideoDataManager
    var playSource: String = "unknown"
    var onReachEnd: (() -> Void)? = nil

    private static let prefetchDistance = 6
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        if items.isEmpty {
            Text("暂无内容")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            let triggerURLs: Set<String> = onReachEnd == nil
                ? [] : Set(items.suffix(Self.prefetchDistance).map(\.url))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        VideoDetailView(item: item, dataManager: dataManager, playSource: playSource)
                    } label: {
                        VideoCardView(item: item).equatable()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onAppear {
                        if triggerURLs.contains(item.url) { onReachEnd?() }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - 卡片（⭐ Equatable：内容不变不重绘；内容变了一定重绘）
struct VideoCardView: View, Equatable {
    let item: OVideoItem

    static func == (l: VideoCardView, r: VideoCardView) -> Bool {
        l.item.hasSameContent(as: r.item)
    }

    var body: some View {
        let rating = item.bestRating
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomTrailing) {
                        coverImage
                        if rating > 0 {
                            VStack {
                                HStack {
                                    Text(String(format: "%.1f", rating))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                                        .padding(12)
                                    Spacer()
                                }
                                Spacer()
                            }
                        }
                        if let info = item.info, !info.isEmpty {
                            Text(info)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .padding(12)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.top, 2)

            HStack(spacing: 10) {
                if let date = item.date, !date.isEmpty {
                    Text(date.split(separator: "(").first.map(String.init) ?? date)
                        .font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                    if let region = item.region, !region.isEmpty {
                        Text(region).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                    }
                } else if let region = item.region, !region.isEmpty {
                    Text(region).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                } else if let types = item.types, !types.isEmpty {
                    Text(types.joined(separator: " / "))
                        .font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var coverImage: some View {
        if let imageName = item.image, !imageName.isEmpty,
           let url = OVideoAPI.coverURL(for: imageName) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack { Rectangle().fill(Color.secondary.opacity(0.12)); ProgressView() }
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                        Image(systemName: "photo").foregroundColor(.secondary)
                    }
                @unknown default:
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "film").foregroundColor(.secondary).font(.title2)
            }
        }
    }
}

// MARK: - 频道主题
enum VideoCategoryTheme {
    static func color(for key: String) -> Color {
        switch key {
        case "Featured": return Color(red: 0.95, green: 0.30, blue: 0.45)
        case "Movie": return Color(red: 0.25, green: 0.55, blue: 0.95)
        case "Drama": return Color(red: 0.62, green: 0.36, blue: 0.85)
        case "Show":  return Color(red: 0.98, green: 0.55, blue: 0.20)
        case "Anime": return Color(red: 0.95, green: 0.35, blue: 0.58)
        case "TV":    return Color(red: 0.20, green: 0.72, blue: 0.45)
        default:      return Color(red: 0.45, green: 0.50, blue: 0.58)
        }
    }
    static func icon(for key: String) -> String {
        switch key {
        case "Featured": return "flame.fill"
        case "Movie": return "film.fill"
        case "Drama": return "theatermasks.fill"
        case "Show":  return "sparkles"
        case "Anime": return "star.bubble.fill"
        case "TV":    return "tv.fill"
        default:      return "square.stack.fill"
        }
    }
}

// MARK: - 顶层入口
struct VideoModuleView: View {
    @EnvironmentObject private var dataManager: OVideoDataManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var resourceManager: ResourceManager
    @ObservedObject private var seriesTrack = SeriesTrackManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("OVideo_TrackNoAutoPopup") private var noAutoPopup = false

    @AppStorage("OVideo_SortOption") private var sortOptionRaw: String = VideoSortOption.date.rawValue
    @AppStorage("OVideo_SelectedCategoryIndex") private var selectedCategoryIndex: Int = 0
    @AppStorage("hasSeenVideoSwipeGuide") private var hasSeenVideoSwipeGuide = false

    var showBackButton: Bool = true
    @State private var didAppearOnce = false

    private var sortBinding: Binding<VideoSortOption> {
        Binding(get: { VideoSortOption(rawValue: sortOptionRaw) ?? .date },
                set: { sortOptionRaw = $0.rawValue })
    }
    private var categoryIndexBinding: Binding<Int> {
        Binding(get: { selectedCategoryIndex }, set: { selectedCategoryIndex = $0 })
    }

    /// ⭐ 值没变就不赋值：@Published 每次 set 都会广播
    private func applyReviewYear() {
        let y = resourceManager.effectiveReviewVideoMaxYear
        if dataManager.reviewMaxYear != y { dataManager.reviewMaxYear = y }
    }

    var body: some View {
        ZStack {
            VideoBrowseView(dataManager: dataManager,
                            selectedCategoryIndex: categoryIndexBinding,
                            sortOption: sortBinding,
                            showBackButton: showBackButton)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VideoBottomBar(dataManager: dataManager, isLoading: false)
                }
            if !hasSeenVideoSwipeGuide {
                VideoSwipeGuideView(hasSeenGuide: $hasSeenVideoSwipeGuide)
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .supportBubble(userId: SupportIdentity.userId(appleId: authManager.userIdentifier))
        .sheet(isPresented: $seriesTrack.showSheet) {
            SeriesTrackListView()
                .environmentObject(dataManager)
                .environmentObject(authManager)
                .environmentObject(resourceManager)
        }
        .onAppear {
            applyReviewYear()
            let returning = didAppearOnce
            if returning {
                NotificationPermissionManager.shared.record(.videoHomeReturn)
            } else {
                didAppearOnce = true
            }
            Task {
                await resourceManager.refreshServerConfig(minInterval: 120)
                applyReviewYear()          // ⭐ 修复：配置刷新后审核年份要立刻生效
                await dataManager.silentRefreshCurrentSelection(
                    userId: authManager.userIdentifier, minInterval: 45)
                if returning { await seriesTrack.refresh() }   // 首次由 .task 负责，避免重复请求
            }
        }
        .task {
            // ⭐ 三路并行，互不阻塞
            Task { await FreeQuotaManager.shared.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            async let boot: Void = dataManager.bootstrap(userId: authManager.userIdentifier)
            await seriesTrack.refresh()
            if !noAutoPopup, seriesTrack.unseenCount > 0, !seriesTrack.showSheet {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled, !seriesTrack.showSheet { seriesTrack.showSheet = true }
            }
            await boot
        }
    }
}

struct VideoModuleClosedView: View {
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.35))
            Text(isGlobalEnglishMode
                 ? "The video module is temporarily closed due to copyright reasons. Thank you for your understanding."
                 : "因版权原因，视频模块暂时关闭，敬请谅解。")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - 底部栏（⭐ 不再监听 dataManager）
struct VideoBottomBar: View {
    let dataManager: OVideoDataManager
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quota = FreeQuotaManager.shared
    @ObservedObject private var pointsCoordinator = NewsPointsCoordinator.shared
    @ObservedObject private var seriesTrack = SeriesTrackManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink { VideoFilterView(dataManager: dataManager) } label: {
                BarItemView(icon: "line.3.horizontal.decrease.circle.fill", zh: "分类检索", en: "Filter",
                            isEnglish: isGlobalEnglishMode)
            }.buttonStyle(.plain)

            Button {
                seriesTrack.showSheet = true
            } label: {
                BarItemView(icon: "bell.fill", zh: "追剧", en: "Follow",
                            isEnglish: isGlobalEnglishMode,
                            badge: seriesTrack.unseenCount)
            }.buttonStyle(.plain)

            NavigationLink { VideoCacheView() } label: {
                BarItemView(icon: "arrow.down.circle.fill", zh: "下载管理", en: "Cache",
                            isEnglish: isGlobalEnglishMode)
            }.buttonStyle(.plain)

            if !authManager.isSubscribed {
                Button {
                    pointsCoordinator.authRef = authManager
                    pointsCoordinator.presentInsufficient(needLogin: !authManager.isLoggedIn,
                                                          context: .video, isShortage: false)
                } label: {
                    BarPointsItemView(points: quota.remaining, isEnglish: isGlobalEnglishMode)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .top) { Color.primary.opacity(0.15).frame(height: 0.5) }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct BarPointsItemView: View {
    let points: Int
    let isEnglish: Bool
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 24)).foregroundColor(.orange)
            Text(isEnglish ? "Points \(points)" : "免费点数\(points)")
                .font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity).contentShape(Rectangle())
    }
}

private struct BarItemView: View {
    let icon: String
    let zh: String
    let en: String
    let isEnglish: Bool
    var badge: Int = 0

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.primary)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, badge > 9 ? 4 : 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red))
                        .overlay(Capsule().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
                        .offset(x: 11, y: -6)
                }
            }
            .frame(height: 26)
            Text(isEnglish ? en : zh)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - 单个分类列表（外壳：只在分类名/审核年份变化时重算，取对应 feed）
struct CategoryVideoListView: View {
    let categoryName: String
    let sortOption: VideoSortOption
    @ObservedObject var dataManager: OVideoDataManager
    let userId: String?

    var body: some View {
        CategoryFeedListView(feed: dataManager.feed(category: categoryName, sort: sortOption),
                             categoryName: categoryName,
                             sortOption: sortOption,
                             dataManager: dataManager,
                             userId: userId)
    }
}

// MARK: - ⭐ 真正的列表：只监听自己的 feed
private struct CategoryFeedListView: View {
    @ObservedObject var feed: OVideoCategoryFeed
    let categoryName: String
    let sortOption: VideoSortOption
    let dataManager: OVideoDataManager
    let userId: String?
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        let items = feed.items
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("top_anchor")

                if items.isEmpty && feed.loadFailed && !feed.isLoading {
                    retryView.padding(.top, 80)
                } else if items.isEmpty && (feed.isLoading || !feed.didLoadFirstPage) {
                    ProgressView().padding(.top, 80)
                } else {
                    WaterfallGridView(items: items, dataManager: dataManager,
                                      playSource: "home",
                                      onReachEnd: { loadMore() })
                    .padding(.top, 10)

                    if feed.isLoading && !items.isEmpty {
                        ProgressView().padding(.vertical, 16)
                    } else if feed.loadFailed && !items.isEmpty {
                        retryView.padding(.vertical, 16)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .refreshable {
                await dataManager.silentRefreshFirstPage(category: categoryName, sort: sortOption,
                                                         userId: userId, minInterval: 3)
            }
            .onChange(of: sortOption) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo("top_anchor", anchor: .top)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .task(id: feed.key) {
            await dataManager.loadFirstPageIfNeeded(category: categoryName,
                                                    sort: sortOption, userId: userId)
        }
    }

    private func loadMore() {
        Task { await dataManager.loadNextPage(category: categoryName, sort: sortOption, userId: userId) }
    }

    private var retryView: some View {
        Button { loadMore() } label: {
            VStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 28)).foregroundColor(.accentColor)
                Text(isGlobalEnglishMode ? "Failed to load. Tap to retry" : "加载失败，点击重试")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ⭐ 支持"中间滑动切栏目 / 贴边右滑返回"的分页控制器（修复 delegate 悬空导致导航卡死）
final class EdgeSwipePageViewController: UIPageViewController, UIGestureRecognizerDelegate {
    private weak var originalPopDelegate: UIGestureRecognizerDelegate?
    private var didRequireFail = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let nav = navigationController,
              let pop = nav.interactivePopGestureRecognizer else { return }
        if pop.delegate !== self {
            originalPopDelegate = pop.delegate
            pop.delegate = self
        }
        pop.isEnabled = true
        if !didRequireFail {
            didRequireFail = true
            for sub in view.subviews {
                if let scroll = sub as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: pop)
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restorePopDelegate()      // ⭐ 离开时把系统 delegate 还回去，其它页面行为不受影响
    }

    private func restorePopDelegate() {
        guard let pop = navigationController?.interactivePopGestureRecognizer,
              pop.delegate === self else { return }
        pop.delegate = originalPopDelegate
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }
}

// MARK: - 无限循环 Pager
struct InfinitePageViewController: UIViewControllerRepresentable {
    var categories: [String]
    @Binding var selectedIndex: Int
    var sortOption: VideoSortOption
    var dataManager: OVideoDataManager
    var userId: String?

    fileprivate var signature: String { categories.joined(separator: "\u{1F}") + "|" + (userId ?? "") }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = EdgeSwipePageViewController(transitionStyle: .scroll,
                                              navigationOrientation: .horizontal, options: nil)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        context.coordinator.lastSortOption = sortOption
        context.coordinator.lastSignature = signature
        if !categories.isEmpty {
            let safe = min(max(0, selectedIndex), categories.count - 1)
            context.coordinator.currentIndex = safe
            pvc.setViewControllers([context.coordinator.viewController(for: safe)],
                                   direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard !categories.isEmpty else { return }

        let sig = signature
        let sortChanged = coord.lastSortOption != sortOption
        let dataChanged = coord.lastSignature != sig
        var forceReset = false

        if dataChanged {
            // ⭐ 分类数变少时清掉越界的缓存页，否则左右滑会卡死
            for k in coord.controllers.keys where k >= categories.count {
                coord.controllers.removeValue(forKey: k)
            }
            if coord.currentIndex >= categories.count { forceReset = true }
        }
        if sortChanged || dataChanged {
            for (index, vc) in coord.controllers { vc.rootView = coord.makeRoot(index) }
            coord.lastSortOption = sortOption
            coord.lastSignature = sig
        }

        let safeTarget = min(max(0, selectedIndex), categories.count - 1)
        if forceReset {
            pvc.setViewControllers([coord.viewController(for: safeTarget)],
                                   direction: .forward, animated: false)
            coord.currentIndex = safeTarget
            if selectedIndex != safeTarget {
                let binding = $selectedIndex
                DispatchQueue.main.async { binding.wrappedValue = safeTarget }
            }
        } else if coord.currentIndex != safeTarget {
            let count = categories.count
            var diff = safeTarget - coord.currentIndex
            if diff > count / 2 { diff -= count } else if diff < -count / 2 { diff += count }
            let direction: UIPageViewController.NavigationDirection = diff >= 0 ? .forward : .reverse
            pvc.setViewControllers([coord.viewController(for: safeTarget)],
                                   direction: direction, animated: true)
            coord.currentIndex = safeTarget
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: InfinitePageViewController
        var currentIndex: Int
        var controllers = [Int: UIHostingController<CategoryVideoListView>]()
        var lastSortOption: VideoSortOption?
        var lastSignature: String = ""

        init(_ parent: InfinitePageViewController) {
            self.parent = parent
            self.currentIndex = parent.selectedIndex
        }

        func makeRoot(_ index: Int) -> CategoryVideoListView {
            CategoryVideoListView(categoryName: parent.categories[index],
                                  sortOption: parent.sortOption,
                                  dataManager: parent.dataManager,
                                  userId: parent.userId)
        }

        func viewController(for index: Int) -> UIViewController {
            if let cached = controllers[index] { return cached }
            let vc = UIHostingController(rootView: makeRoot(index))
            vc.view.backgroundColor = .clear
            controllers[index] = vc
            return vc
        }

        private func index(of vc: UIViewController) -> Int? {
            guard let host = vc as? UIHostingController<CategoryVideoListView> else { return nil }
            return controllers.first(where: { $0.value === host })?.key
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            let n = parent.categories.count
            guard n > 0, let i = index(of: vc) else { return nil }
            return viewController(for: (i - 1 + n) % n)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            let n = parent.categories.count
            guard n > 0, let i = index(of: vc) else { return nil }
            return viewController(for: (i + 1) % n)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let visible = pvc.viewControllers?.first, let i = index(of: visible) else { return }
            currentIndex = i
            DispatchQueue.main.async {
                if self.parent.selectedIndex != i { self.parent.selectedIndex = i }
            }
        }
    }
}

// MARK: - 横向分类栏
struct CategoryTabBar: View {
    let categories: [String]
    @Binding var selectedIndex: Int
    let isEnglish: Bool
    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                        let isSelected = idx == selectedIndex
                        let theme = VideoCategoryTheme.color(for: cat)
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedIndex = idx
                            }
                        } label: {
                            VStack(spacing: 5) {
                                HStack(spacing: 4) {
                                    if isSelected {
                                        Image(systemName: VideoCategoryTheme.icon(for: cat))
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(theme)
                                    }
                                    Text(videoCategoryDisplayName(cat, english: isEnglish))
                                        .font(.system(size: isSelected ? 17 : 15,
                                                      weight: isSelected ? .bold : .medium))
                                        .foregroundColor(isSelected ? .primary : .secondary)
                                }
                                ZStack {
                                    if isSelected {
                                        Capsule().fill(theme)
                                            .matchedGeometryEffect(id: "tab_underline", in: ns)
                                            .frame(width: 24, height: 3)
                                    } else {
                                        Capsule().fill(Color.clear).frame(width: 24, height: 3)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(idx)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedIndex) { _, newIdx in
                withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
            }
        }
    }
}

// MARK: - 首页
struct VideoBrowseView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @Binding var selectedCategoryIndex: Int
    @Binding var sortOption: VideoSortOption
    var showBackButton: Bool = true
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    private var userId: String? { authManager.userIdentifier }

    var body: some View {
        Group {
            if dataManager.categoryNames.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if showBackButton {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(.leading, 16)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 10)
                            }
                        }

                        CategoryTabBar(categories: dataManager.categoryNames,
                                       selectedIndex: $selectedCategoryIndex,
                                       isEnglish: isGlobalEnglishMode)
                            .frame(maxWidth: .infinity)
                            .padding(.leading, showBackButton ? 0 : 8)

                        NavigationLink {
                            VideoSearchTabView(dataManager: dataManager)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .offset(y: -2)
                    }
                    .background(.ultraThinMaterial)

                    Divider().opacity(0.4)

                    ZStack(alignment: .topTrailing) {
                        InfinitePageViewController(categories: dataManager.categoryNames,
                                                   selectedIndex: $selectedCategoryIndex,
                                                   sortOption: sortOption,
                                                   dataManager: dataManager,
                                                   userId: userId)
                            .ignoresSafeArea(edges: .bottom)

                        floatingSortButton
                            .padding(.trailing, 12)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedCategoryIndex) { _, idx in
            guard idx >= 0, idx < dataManager.categoryNames.count else { return }
            let cat = dataManager.categoryNames[idx]
            Task {
                await dataManager.silentRefreshFirstPage(
                    category: cat, sort: sortOption, userId: userId, minInterval: 90)
            }
        }
        .onChange(of: sortOption) { _, newSort in
            let idx = selectedCategoryIndex
            guard idx >= 0, idx < dataManager.categoryNames.count else { return }
            let cat = dataManager.categoryNames[idx]
            Task {
                await dataManager.silentRefreshFirstPage(
                    category: cat, sort: newSort, userId: userId, minInterval: 90)
            }
        }
    }

    private var floatingSortButton: some View {
        Menu {
            ForEach(VideoSortOption.allCases, id: \.self) { opt in
                Button { withAnimation { sortOption = opt } } label: {
                    if opt == sortOption {
                        Label(opt.displayName(isGlobalEnglishMode), systemImage: "checkmark")
                    } else {
                        Text(opt.displayName(isGlobalEnglishMode))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sortOption.shortName(isGlobalEnglishMode))
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.2), value: sortOption)
        }
    }
}

// MARK: - 新手引导
struct VideoSwipeGuideView: View {
    @Binding var hasSeenGuide: Bool
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var iconOffset: CGFloat = 40
    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 65)).foregroundColor(.white)
                    .offset(x: iconOffset)
                    .onAppear {
                        withAnimation(Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            iconOffset = -40
                        }
                    }
                VStack(spacing: 12) {
                    Text(isGlobalEnglishMode ? "Swipe to switch channels" : "左右滑动切换频道")
                        .font(.title2.bold()).foregroundColor(.white)
                    Text(isGlobalEnglishMode ? "Featured / Movies / Dramas / Shows / Anime" : "最新 / 电影 / 剧集 / 综艺 / 动漫")
                        .font(.subheadline).foregroundColor(.white.opacity(0.8))
                }
                Button {
                    withAnimation(.easeInOut) { hasSeenGuide = true }
                } label: {
                    Text(isGlobalEnglishMode ? "Got it" : "知道了")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 40).padding(.vertical, 14)
                        .background(Color.white).clipShape(Capsule())
                }
                .padding(.top, 20)
            }
        }
    }
}