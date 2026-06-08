// VideoPlayerView、CachedAsyncImage、OImageCache、WaterfallGridView、VideoCardView
// VideoModuleView、VideoBottomBar、VideoBrowseView

import SwiftUI

// MARK: - 简易图片内存缓存
final class OImageCache {
    static let shared = OImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 200 * 1024 * 1024
    }
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL,
                        cost: Int(image.size.width * image.size.height * 4))
    }
}

// MARK: - 带缓存的异步图片
struct CachedAsyncImage<Content: View>: View {
    let url: URL
    let content: (AsyncImagePhase) -> Content
    
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    
    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }
    
    var body: some View {
        Group {
            if let img = uiImage {
                content(.success(Image(uiImage: img)))
            } else if isLoading {
                content(.empty)
            } else {
                content(.empty)
            }
        }
        .task(id: url) {
            await load()
        }
    }
    
    private func load() async {
        if uiImage != nil { return }
        if let cached = OImageCache.shared.image(for: url) {
            self.uiImage = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                OImageCache.shared.set(img, for: url)
                self.uiImage = img
            }
        } catch { }
    }
}

// MARK: - 瀑布流
struct WaterfallGridView: View {
    let items: [OVideoItem]
    @ObservedObject var dataManager: OVideoDataManager
    
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
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(destination: VideoDetailView(item: item, dataManager: dataManager)) {
                        VideoCardView(item: item)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - 卡片
struct VideoCardView: View {
    let item: OVideoItem
    
    var body: some View {
        // 增加整体间距 spacing，让文字与图片之间有更多空隙
        VStack(alignment: .leading, spacing: 10) { 
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomTrailing) {
                        coverImage
                        // 评分：左上角
                        if item.bestRating > 0 {
                            VStack {
                                HStack {
                                    Text(String(format: "%.1f", item.bestRating))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                                        .padding(12) // 关键：增加 Padding，让它远离边缘
                                    Spacer()
                                }
                                Spacer()
                            }
                        }
                        
                        // 信息：右下角
                        if let info = item.info, !info.isEmpty {
                            Text(info)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .padding(12) // 关键：增加 Padding，让它远离边缘
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            // 名字：字体调大，增加一点内边距
            // 名字：修改为两行显示
            Text(item.name)
                .font(.system(size: 16, weight: .semibold)) // 保持你调整后的字号
                .foregroundColor(.primary)
                .lineLimit(2) // 关键点：改为 2 行
                .multilineTextAlignment(.leading) // 关键点：确保多行时左对齐
                .fixedSize(horizontal: false, vertical: true) // 关键点：允许垂直方向根据内容自动撑开
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.top, 2)
            
            // 时间/类型：字体调大
            if let date = item.date, !date.isEmpty {
                Text(date.split(separator: "(").first.map(String.init) ?? date)
                    .font(.system(size: 13)) // 从 11 改为 13
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            } else if let types = item.types, !types.isEmpty {
                Text(types.joined(separator: " / "))
                    .font(.system(size: 15)) // 从 11 改为 13
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            
            // 如果你觉得空间还不够高，可以在这里添加一个 Spacer 或者固定的 padding
            // Spacer(minLength: 4) 
        }
        .padding(.bottom, 8) // 增加底部 padding，让卡片底部看起来更饱满
    }
    
    @ViewBuilder
    private var coverImage: some View {
        if let imageName = item.image, !imageName.isEmpty,
           let url = OVideoAPI.coverURL(for: imageName) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                        ProgressView()
                    }
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
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "film").foregroundColor(.secondary).font(.title2)
            }
        }
    }
}

// MARK: - 频道主题（颜色 + 图标），用于顶部视觉区分
enum VideoCategoryTheme {
    static func color(for key: String) -> Color {
        switch key {
        case "Movie": return Color(red: 0.25, green: 0.55, blue: 0.95) // 蓝
        case "Drama": return Color(red: 0.62, green: 0.36, blue: 0.85) // 紫
        case "Show":  return Color(red: 0.98, green: 0.55, blue: 0.20) // 橙
        case "Anime": return Color(red: 0.95, green: 0.35, blue: 0.58) // 粉
        case "TV":    return Color(red: 0.20, green: 0.72, blue: 0.45) // 绿
        default:      return Color(red: 0.45, green: 0.50, blue: 0.58) // 灰
        }
    }
    static func icon(for key: String) -> String {
        switch key {
        case "Movie": return "film.fill"
        case "Drama": return "theatermasks.fill"
        case "Show":  return "sparkles"
        case "Anime": return "star.bubble.fill"
        case "TV":    return "tv.fill"
        default:      return "square.stack.fill"
        }
    }
}

// MARK: - 顶层入口（排序选项持久化）
struct VideoModuleView: View {
    // 【修改】从 @StateObject 改为 @EnvironmentObject，复用全局已预加载的实例
    @EnvironmentObject private var dataManager: OVideoDataManager
    
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    // ⭐ 持久化排序状态
    @AppStorage("OVideo_SortOption") private var sortOptionRaw: String = VideoSortOption.date.rawValue
    @AppStorage("OVideo_SelectedCategoryIndex") private var selectedCategoryIndex: Int = 0
    
    // ⭐ 新增：持久化记录用户是否已经看过滑动引导
    @AppStorage("hasSeenVideoSwipeGuide") private var hasSeenVideoSwipeGuide = false
    
    // 【新增】获取 AuthManager 以读取 userId
    @EnvironmentObject var authManager: AuthManager
    
    private var sortBinding: Binding<VideoSortOption> {
        Binding(
            get: { VideoSortOption(rawValue: sortOptionRaw) ?? .date },
            set: { sortOptionRaw = $0.rawValue }
        )
    }
    
    private var categoryIndexBinding: Binding<Int> {
        Binding(
            get: { selectedCategoryIndex },
            set: { selectedCategoryIndex = $0 }
        )
    }
    
    var body: some View {
        // ⭐ 改动 1：放弃 ZStack(alignment:.bottom) + padding(.bottom,60)
        //    改为 safeAreaInset，由系统统一管理底部区域，旋转时不会错位
        ZStack {
            VideoBrowseView(dataManager: dataManager,
                            selectedCategoryIndex: categoryIndexBinding,
                            sortOption: sortBinding)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VideoBottomBar(dataManager: dataManager)
                }
            
            // ⭐ 新增：如果还没看过引导，则显示新手引导遮罩
            if !hasSeenVideoSwipeGuide {
                VideoSwipeGuideView(hasSeenGuide: $hasSeenVideoSwipeGuide)
                    .zIndex(1) // 确保引导视图在最上层，遮挡住底部栏和导航栏
                    .transition(.opacity) // 消失时带有淡出效果
            }
        }
        // 【说明】这里仍然保留 task，作为兜底。如果预加载已完成，loadVideosIfNeeded 内部应该会立即返回不重复加载
        // 【修改】传入 userId
        .task {
            await dataManager.loadVideosIfNeeded(userId: FreeQuotaManager.currentUserId(auth: authManager))
            // ⭐ 新增：进入视频模块时刷新今日免费次数
            await FreeQuotaManager.shared.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }
}

// MARK: - 底部栏
struct VideoBottomBar: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    /// 当前选中项（首页默认选中）。这里仅做高亮指示，真正的页面切换仍走 NavigationLink
    @State private var activeTab: Tab = .home
    enum Tab: Hashable { case home, filter, search, cache }
    
    var body: some View {
        HStack(spacing: 4) {
            // 首页（直接是当前页，不需要 NavigationLink）
            Button {
                activeTab = .home
            } label: {
                BarItemView(
                    icon: "square.grid.2x2.fill",
                    activeIcon: "square.grid.2x2.fill",
                    zh: "首页", en: "Home",
                    isActive: activeTab == .home,
                    isEnglish: isGlobalEnglishMode
                )
            }
            .buttonStyle(.plain)
            
            NavigationLink {
                VideoFilterView(dataManager: dataManager)
            } label: {
                BarItemView(
                    icon: "line.3.horizontal.decrease",
                    activeIcon: "line.3.horizontal.decrease.circle.fill",
                    zh: "分类", en: "Filter",
                    isActive: false,
                    isEnglish: isGlobalEnglishMode
                )
            }
            .buttonStyle(.plain)
            
            NavigationLink {
                VideoSearchTabView(dataManager: dataManager)
            } label: {
                BarItemView(
                    icon: "magnifyingglass",
                    activeIcon: "magnifyingglass.circle.fill",
                    zh: "搜索", en: "Search",
                    isActive: false,
                    isEnglish: isGlobalEnglishMode
                )
            }
            .buttonStyle(.plain)
            
            NavigationLink {
                VideoCacheView()
            } label: {
                BarItemView(
                    icon: "arrow.down.to.line",
                    activeIcon: "arrow.down.circle.fill",
                    zh: "缓存", en: "Cache",
                    isActive: false,
                    isEnglish: isGlobalEnglishMode
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4) // ⭐ 减小顶部 Padding
        .padding(.bottom, 2) // ⭐ 减小底部 Padding
        // ⭐ 现代化背景：毛玻璃 + 顶部细分隔线 + 极淡渐变
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .top) {
                // 顶部 hairline 分隔线
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.0),
                        Color.primary.opacity(0.18),
                        Color.primary.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom) // <--- 关键点：让背景忽略底部安全区
        )
        // ⭐ 让背景自然延伸到底部安全区
        .background(.ultraThinMaterial.opacity(0.001)) // 占位，避免 ignoresSafeArea 影响布局
    }
}

// MARK: - 底部栏单个按钮（现代风格、有点击放大反馈）
private struct BarItemView: View {
    let icon: String
    let activeIcon: String
    let zh: String
    let en: String
    let isActive: Bool
    let isEnglish: Bool
    
    var body: some View {
        VStack(spacing: 2) {
            // 选中态：图标外裹一个柔光胶囊背景
            ZStack {
                if isActive {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.22),
                                    Color.accentColor.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 24)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    Color.accentColor.opacity(0.35),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(
                            color: Color.accentColor.opacity(0.25),
                            radius: 4, x: 0, y: 1
                        )
                        .transition(.scale.combined(with: .opacity))
                }
                
                Image(systemName: isActive ? activeIcon : icon)
                    .font(.system(size: 25, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(
                        isActive ? Color.accentColor : Color.secondary
                    )
                    .symbolRenderingMode(.hierarchical)
                    .scaleEffect(isActive ? 1.0 : 0.96)
            }
            .frame(height: 30)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isActive)
            
            Text(isEnglish ? en : zh)
                .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - ⭐ 单个分类的视频列表 —— 直接按 sortOption 计算，消除缓存带来的错乱
struct CategoryVideoListView: View {
    let category: OVideoCategory
    let sortOption: VideoSortOption
    @ObservedObject var dataManager: OVideoDataManager
    
    var body: some View {
        // ⭐ 用 category.name 做 cacheKey，避免重复排序
        let sortedItems = dataManager.sortItems(category.items,
                                                by: sortOption,
                                                cacheKey: category.name)
        
        ScrollViewReader { proxy in
            ScrollView {
                // 1. 在最顶部放置一个高度为 0 的隐形锚点
                Color.clear
                    .frame(height: 0)
                    .id("top_anchor")
                
                WaterfallGridView(items: sortedItems, dataManager: dataManager)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
            }
            // 2. 监听排序选项的变化，一旦变化，平滑滚动回顶部
            .onChange(of: sortOption) { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo("top_anchor", anchor: .top)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}

// MARK: - ⭐️ 核心优化：丝滑无限循环 Pager (封装 UIPageViewController)
struct InfinitePageViewController: UIViewControllerRepresentable {
    var categories: [OVideoCategory]
    @Binding var selectedIndex: Int
    var sortOption: VideoSortOption
    var dataManager: OVideoDataManager

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear

        if !categories.isEmpty {
            let safeIndex = min(max(0, selectedIndex), categories.count - 1)
            let initialVC = context.coordinator.viewController(for: safeIndex)
            pageViewController.setViewControllers([initialVC], direction: .forward, animated: false)
        }

        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard !categories.isEmpty else { return }
        
        // ⭐ 只有 sortOption 或 categories 真正改变时，才重置已缓存视图的 rootView
        let signature = categories.map { "\($0.name):\($0.items.count)" }.joined(separator: ",")
        let sortChanged = context.coordinator.lastSortOption != sortOption
        let dataChanged = context.coordinator.lastCategoriesSignature != signature
        
        if sortChanged || dataChanged {
            for (index, vc) in context.coordinator.controllers where index < categories.count {
                vc.rootView = CategoryVideoListView(
                    category: categories[index],
                    sortOption: sortOption,
                    dataManager: dataManager
                )
            }
            context.coordinator.lastSortOption = sortOption
            context.coordinator.lastCategoriesSignature = signature
        }
        
        // ⭐ 处理外部索引改变（点击顶部菜单切换频道）—— 保持原逻辑
        let safeTarget = min(max(0, selectedIndex), categories.count - 1)
        if context.coordinator.currentIndex != safeTarget {
            let count = categories.count
            let current = context.coordinator.currentIndex
            var diff = safeTarget - current
            if diff > count / 2 { diff -= count }
            else if diff < -count / 2 { diff += count }
            let direction: UIPageViewController.NavigationDirection = diff >= 0 ? .forward : .reverse
            let vc = context.coordinator.viewController(for: safeTarget)
            pageViewController.setViewControllers([vc], direction: direction, animated: true)
            context.coordinator.currentIndex = safeTarget
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: InfinitePageViewController
        var currentIndex: Int
        var controllers = [Int: UIHostingController<CategoryVideoListView>]()

        // ⭐ 新增：记住上一次的 sortOption 和 categories 标识
        var lastSortOption: VideoSortOption?
        var lastCategoriesSignature: String = ""

        init(_ parent: InfinitePageViewController) {
            self.parent = parent
            self.currentIndex = parent.selectedIndex
        }

        func viewController(for index: Int) -> UIViewController {
            if let cached = controllers[index] {
                return cached    // ⭐ 直接返回，不再重新赋值 rootView
            }
            let view = CategoryVideoListView(
                category: parent.categories[index],
                sortOption: parent.sortOption,
                dataManager: parent.dataManager
            )
            let vc = UIHostingController(rootView: view)
            vc.view.backgroundColor = .clear
            controllers[index] = vc
            return vc
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard !parent.categories.isEmpty else { return nil }
            guard let hostingVC = viewController as? UIHostingController<CategoryVideoListView> else { return nil }
            guard let index = controllers.first(where: { $0.value == hostingVC })?.key else { return nil }

            let previousIndex = (index - 1 + parent.categories.count) % parent.categories.count
            return self.viewController(for: previousIndex)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard !parent.categories.isEmpty else { return nil }
            guard let hostingVC = viewController as? UIHostingController<CategoryVideoListView> else { return nil }
            guard let index = controllers.first(where: { $0.value == hostingVC })?.key else { return nil }

            let nextIndex = (index + 1) % parent.categories.count
            return self.viewController(for: nextIndex)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed,
               let visibleVC = pageViewController.viewControllers?.first as? UIHostingController<CategoryVideoListView>,
               let index = controllers.first(where: { $0.value == visibleVC })?.key {
                currentIndex = index
                DispatchQueue.main.async {
                    if self.parent.selectedIndex != index {
                        self.parent.selectedIndex = index
                    }
                }
            }
        }
    }
}

// MARK: - 首页
struct VideoBrowseView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @Binding var selectedCategoryIndex: Int
    @Binding var sortOption: VideoSortOption
    
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    // 【新增】
    @EnvironmentObject var authManager: AuthManager
    
    private var currentCategoryKey: String {
        guard selectedCategoryIndex < dataManager.categories.count else { return "" }
        return dataManager.categories[selectedCategoryIndex].name
    }
    
    private var currentCategoryDisplay: String {
        guard selectedCategoryIndex < dataManager.categories.count
        else { return isGlobalEnglishMode ? "Video" : "影视" }
        return categoryDisplayName(dataManager.categories[selectedCategoryIndex].name)
    }
    
    private var currentCategoryColor: Color {
        VideoCategoryTheme.color(for: currentCategoryKey)
    }
    
    private var currentCategoryIcon: String {
        VideoCategoryTheme.icon(for: currentCategoryKey)
    }
    
    var body: some View {
        Group {
            if dataManager.isLoading && dataManager.categories.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2) // 稍微放大一点点，视觉更舒适
                    Text(isGlobalEnglishMode ? "Loading, please wait..." : "图片加载中，请稍候...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = dataManager.errorMessage, dataManager.categories.isEmpty {
                errorView(err)
            } else if dataManager.categories.isEmpty {
                Text(isGlobalEnglishMode ? "No content" : "暂无内容")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InfinitePageViewController(
                    categories: dataManager.categories,
                    selectedIndex: $selectedCategoryIndex,
                    sortOption: sortOption,
                    dataManager: dataManager
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // ⭐ 频道指示器：根据频道切换色彩和图标，滑动时能立刻看出身处哪个频道
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(Array(dataManager.categories.enumerated()), id: \.offset) { idx, cat in
                        Button {
                            selectedCategoryIndex = idx
                        } label: {
                            if idx == selectedCategoryIndex {
                                Label(categoryDisplayName(cat.name), systemImage: "checkmark")
                            } else {
                                Label(categoryDisplayName(cat.name),
                                      systemImage: VideoCategoryTheme.icon(for: cat.name))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: currentCategoryIcon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(currentCategoryColor)
                        Text(currentCategoryDisplay)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(currentCategoryColor.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(currentCategoryColor.opacity(0.15))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(currentCategoryColor.opacity(0.45), lineWidth: 1)
                    )
                    .animation(.easeInOut(duration: 0.25), value: selectedCategoryIndex)
                }
            }
            
            // ⭐ 排序指示器：已移除背景框，统一图标在右侧，菜单内仅显示对勾
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(VideoSortOption.allCases, id: \.self) { opt in
                        Button {
                            withAnimation { sortOption = opt }
                        } label: {
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
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.primary)
                    .animation(.easeInOut(duration: 0.2), value: sortOption)
                }
            }
        }
    }
    
    private func categoryDisplayName(_ key: String) -> String {
        if isGlobalEnglishMode { return key }
        switch key {
        case "Movie": return "电影"
        case "Drama": return "电视剧"
        case "Show":  return "综艺节目"
        case "Anime": return "动漫"
        default:      return key
        }
    }
    
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundColor(.orange)
            Text(msg).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button(isGlobalEnglishMode ? "Retry" : "重试") {
                Task {
                    // 【修改】传入 userId
                    await dataManager.loadVideos(userId: authManager.userIdentifier)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color.blue).foregroundColor(.white).cornerRadius(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 新手引导视图
struct VideoSwipeGuideView: View {
    @Binding var hasSeenGuide: Bool
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    // 用于控制手势图标的左右滑动动画
    @State private var iconOffset: CGFloat = 40

    var body: some View {
        ZStack {
            // 半透明黑色背景，遮盖底层内容
            Color.black.opacity(0.75)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                // 动态滑动手势图标
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 65))
                    .foregroundColor(.white)
                    .offset(x: iconOffset)
                    .onAppear {
                        // 视图出现时，执行循环的左右平移动画
                        withAnimation(Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            iconOffset = -40
                        }
                    }
                
                // 提示文字
                VStack(spacing: 12) {
                    Text(isGlobalEnglishMode ? "Swipe to switch channels" : "左右滑动切换频道")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    Text(isGlobalEnglishMode ? "Movies / Dramas / Shows / Anime" : "电影 / 电视剧 / 综艺 / 动漫")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                // “知道了”按钮
                Button {
                    // 点击后更新状态，配合 withAnimation 让视图淡出
                    withAnimation(.easeInOut) {
                        hasSeenGuide = true
                    }
                } label: {
                    Text(isGlobalEnglishMode ? "Got it" : "知道了")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .padding(.top, 20)
            }
        }
    }
}