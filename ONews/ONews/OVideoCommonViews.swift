// 图片缓存 / 瀑布流 / 卡片 / 首页 Pager（分页无限滚动版）

import SwiftUI

// MARK: - 图片内存缓存（不变）
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

// MARK: - 带缓存异步图片（不变）
struct CachedAsyncImage<Content: View>: View {
    let url: URL
    let content: (AsyncImagePhase) -> Content
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url; self.content = content
    }
    var body: some View {
        Group {
            if let img = uiImage { content(.success(Image(uiImage: img))) }
            else { content(.empty) }
        }
        .task(id: url) { await load() }
    }
    private func load() async {
        if uiImage != nil { return }
        if let cached = OImageCache.shared.image(for: url) { self.uiImage = cached; return }
        isLoading = true; defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                OImageCache.shared.set(img, for: url)
                self.uiImage = img
            }
        } catch { }
    }
}

// MARK: - 瀑布流（带触底回调）
struct WaterfallGridView: View {
    let items: [OVideoItem]
    @ObservedObject var dataManager: OVideoDataManager
    var onReachEnd: (() -> Void)? = nil      // ⭐ 触底加载下一页

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
                    .onAppear {
                        if item.url == items.last?.url { onReachEnd?() }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - 卡片（不变）
struct VideoCardView: View {
    let item: OVideoItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomTrailing) {
                        coverImage
                        if item.bestRating > 0 {
                            VStack {
                                HStack {
                                    Text(String(format: "%.1f", item.bestRating))
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

            if let date = item.date, !date.isEmpty {
                Text(date.split(separator: "(").first.map(String.init) ?? date)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            } else if let types = item.types, !types.isEmpty {
                Text(types.joined(separator: " / "))
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .padding(.bottom, 8)
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
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "film").foregroundColor(.secondary).font(.title2)
            }
        }
    }
}

// MARK: - 频道主题（不变）
enum VideoCategoryTheme {
    static func color(for key: String) -> Color {
        switch key {
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
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @AppStorage("OVideo_SortOption") private var sortOptionRaw: String = VideoSortOption.date.rawValue
    @AppStorage("OVideo_SelectedCategoryIndex") private var selectedCategoryIndex: Int = 0
    @AppStorage("hasSeenVideoSwipeGuide") private var hasSeenVideoSwipeGuide = false

    private var sortBinding: Binding<VideoSortOption> {
        Binding(get: { VideoSortOption(rawValue: sortOptionRaw) ?? .date },
                set: { sortOptionRaw = $0.rawValue })
    }
    private var categoryIndexBinding: Binding<Int> {
        Binding(get: { selectedCategoryIndex }, set: { selectedCategoryIndex = $0 })
    }

    var body: some View {
        ZStack {
            VideoBrowseView(dataManager: dataManager,
                            selectedCategoryIndex: categoryIndexBinding,
                            sortOption: sortBinding)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VideoBottomBar(dataManager: dataManager, isLoading: false)
                }
            if !hasSeenVideoSwipeGuide {
                VideoSwipeGuideView(hasSeenGuide: $hasSeenVideoSwipeGuide)
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .task {
            await dataManager.bootstrap(userId: authManager.userIdentifier)
            await FreeQuotaManager.shared.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
        }
    }
}

// MARK: - 底部栏（按钮始终可用：分类/搜索不再依赖完整加载）
struct VideoBottomBar: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    let isLoading: Bool
    @State private var activeTab: Tab = .home
    enum Tab: Hashable { case home, filter, search, cache }

    var body: some View {
        HStack(spacing: 4) {
            Button { activeTab = .home } label: {
                BarItemView(icon: "square.grid.2x2.fill", zh: "首页", en: "Home",
                            tint: Color(red: 0.20, green: 0.72, blue: 0.45),
                            isActive: activeTab == .home, isEnabled: true,
                            isLoading: false, isEnglish: isGlobalEnglishMode)
            }.buttonStyle(.plain)

            NavigationLink { VideoFilterView(dataManager: dataManager) } label: {
                BarItemView(icon: "line.3.horizontal.decrease.circle.fill", zh: "分类", en: "Filter",
                            tint: Color(red: 0.62, green: 0.36, blue: 0.85),
                            isActive: false, isEnabled: true, isLoading: false,
                            isEnglish: isGlobalEnglishMode)
            }.buttonStyle(.plain)

            NavigationLink { VideoSearchTabView(dataManager: dataManager) } label: {
                BarItemView(icon: "magnifyingglass.circle.fill", zh: "搜索", en: "Search",
                            tint: Color(red: 0.25, green: 0.55, blue: 0.95),
                            isActive: false, isEnabled: true, isLoading: false,
                            isEnglish: isGlobalEnglishMode)
            }.buttonStyle(.plain)

            NavigationLink { VideoCacheView() } label: {
                BarItemView(icon: "arrow.down.circle.fill", zh: "缓存", en: "Cache",
                            tint: Color(red: 0.98, green: 0.55, blue: 0.20),
                            isActive: false, isEnabled: true, isLoading: false,
                            isEnglish: isGlobalEnglishMode)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Color.primary.opacity(0.04), Color.clear],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.primary.opacity(0.0), Color.primary.opacity(0.18), Color.primary.opacity(0.0)],
                               startPoint: .leading, endPoint: .trailing).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        )
        .background(.ultraThinMaterial.opacity(0.001))
    }
}

private struct BarItemView: View {
    let icon: String; let zh: String; let en: String; let tint: Color
    let isActive: Bool; let isEnabled: Bool; let isLoading: Bool; let isEnglish: Bool
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: isEnabled ? [tint.opacity(0.95), tint.opacity(0.70)]
                                          : [Color.secondary.opacity(0.22), Color.secondary.opacity(0.14)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 50, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isEnabled ? 0.25 : 0), lineWidth: 0.5))
                    .shadow(color: isEnabled ? tint.opacity(0.40) : .clear, radius: 6, x: 0, y: 3)
                    .scaleEffect(isActive ? 1.06 : 1.0)
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(.secondary)
                } else {
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white).symbolRenderingMode(.hierarchical)
                }
            }
            Text(isEnglish ? en : zh).font(.system(size: 12, weight: .semibold))
                .foregroundColor(isEnabled ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1.0 : 0.55)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isActive)
    }
}

// MARK: - 单个分类列表（分页 + 无限滚动）
struct CategoryVideoListView: View {
    let categoryName: String
    let sortOption: VideoSortOption
    @ObservedObject var dataManager: OVideoDataManager
    let userId: String?

    var body: some View {
        let items = dataManager.items(category: categoryName, sort: sortOption)
        let loading = dataManager.isLoadingPage(category: categoryName, sort: sortOption)

        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("top_anchor")

                if items.isEmpty && loading {
                    ProgressView().padding(.top, 80)
                } else {
                    WaterfallGridView(items: items, dataManager: dataManager, onReachEnd: {
                        Task { await dataManager.loadNextPage(category: categoryName,
                                                              sort: sortOption, userId: userId) }
                    })
                    .padding(.top, 10)

                    if loading && !items.isEmpty {
                        ProgressView().padding(.vertical, 16)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .onChange(of: sortOption) { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo("top_anchor", anchor: .top)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        // ⭐ 首次出现 / 排序变化时按需加载第一页
        .task(id: "\(categoryName)|\(sortOption.rawValue)") {
            await dataManager.loadFirstPageIfNeeded(category: categoryName,
                                                    sort: sortOption, userId: userId)
        }
    }
}

// MARK: - 无限循环 Pager（按名称）
struct InfinitePageViewController: UIViewControllerRepresentable {
    var categories: [String]
    @Binding var selectedIndex: Int
    var sortOption: VideoSortOption
    var dataManager: OVideoDataManager
    var userId: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll,
                                      navigationOrientation: .horizontal, options: nil)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        if !categories.isEmpty {
            let safe = min(max(0, selectedIndex), categories.count - 1)
            pvc.setViewControllers([context.coordinator.viewController(for: safe)],
                                   direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard !categories.isEmpty else { return }

        let signature = categories.joined(separator: ",")
        let sortChanged = context.coordinator.lastSortOption != sortOption
        let dataChanged = context.coordinator.lastCategoriesSignature != signature

        if sortChanged || dataChanged {
            for (index, vc) in context.coordinator.controllers where index < categories.count {
                vc.rootView = CategoryVideoListView(categoryName: categories[index],
                                                    sortOption: sortOption,
                                                    dataManager: dataManager, userId: userId)
            }
            context.coordinator.lastSortOption = sortOption
            context.coordinator.lastCategoriesSignature = signature
        }

        let safeTarget = min(max(0, selectedIndex), categories.count - 1)
        if context.coordinator.currentIndex != safeTarget {
            let count = categories.count
            let current = context.coordinator.currentIndex
            var diff = safeTarget - current
            if diff > count / 2 { diff -= count } else if diff < -count / 2 { diff += count }
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
        var lastSortOption: VideoSortOption?
        var lastCategoriesSignature: String = ""

        init(_ parent: InfinitePageViewController) {
            self.parent = parent
            self.currentIndex = parent.selectedIndex
        }

        func viewController(for index: Int) -> UIViewController {
            if let cached = controllers[index] { return cached }
            let view = CategoryVideoListView(categoryName: parent.categories[index],
                                             sortOption: parent.sortOption,
                                             dataManager: parent.dataManager, userId: parent.userId)
            let vc = UIHostingController(rootView: view)
            vc.view.backgroundColor = .clear
            controllers[index] = vc
            return vc
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard !parent.categories.isEmpty,
                  let host = vc as? UIHostingController<CategoryVideoListView>,
                  let index = controllers.first(where: { $0.value == host })?.key else { return nil }
            return viewController(for: (index - 1 + parent.categories.count) % parent.categories.count)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard !parent.categories.isEmpty,
                  let host = vc as? UIHostingController<CategoryVideoListView>,
                  let index = controllers.first(where: { $0.value == host })?.key else { return nil }
            return viewController(for: (index + 1) % parent.categories.count)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed,
               let visible = pvc.viewControllers?.first as? UIHostingController<CategoryVideoListView>,
               let index = controllers.first(where: { $0.value == visible })?.key {
                currentIndex = index
                DispatchQueue.main.async {
                    if self.parent.selectedIndex != index { self.parent.selectedIndex = index }
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
    @EnvironmentObject var authManager: AuthManager

    private var userId: String? { authManager.userIdentifier }

    private var currentCategoryKey: String {
        let names = dataManager.categoryNames
        if selectedCategoryIndex >= 0, selectedCategoryIndex < names.count {
            return names[selectedCategoryIndex]
        }
        return ""
    }
    private var currentCategoryDisplay: String {
        let key = currentCategoryKey
        guard !key.isEmpty else { return isGlobalEnglishMode ? "Video" : "影视" }
        return categoryDisplayName(key)
    }
    private var currentCategoryColor: Color { VideoCategoryTheme.color(for: currentCategoryKey) }
    private var currentCategoryIcon: String { VideoCategoryTheme.icon(for: currentCategoryKey) }

    var body: some View {
        Group {
            if dataManager.categoryNames.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InfinitePageViewController(categories: dataManager.categoryNames,
                                           selectedIndex: $selectedCategoryIndex,
                                           sortOption: sortOption,
                                           dataManager: dataManager,
                                           userId: userId)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(Array(dataManager.categoryNames.enumerated()), id: \.offset) { idx, cat in
                        Button { selectedCategoryIndex = idx } label: {
                            if idx == selectedCategoryIndex {
                                Label(categoryDisplayName(cat), systemImage: "checkmark")
                            } else {
                                Label(categoryDisplayName(cat),
                                      systemImage: VideoCategoryTheme.icon(for: cat))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: currentCategoryIcon)
                            .font(.system(size: 13, weight: .bold)).foregroundColor(currentCategoryColor)
                        Text(currentCategoryDisplay)
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(currentCategoryColor.opacity(0.8))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(currentCategoryColor.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(currentCategoryColor.opacity(0.45), lineWidth: 1))
                    .animation(.easeInOut(duration: 0.25), value: selectedCategoryIndex)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
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
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .semibold))
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
}

// MARK: - 新手引导（不变）
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
                    Text(isGlobalEnglishMode ? "Movies / Dramas / Shows / Anime" : "电影 / 电视剧 / 综艺 / 动漫")
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