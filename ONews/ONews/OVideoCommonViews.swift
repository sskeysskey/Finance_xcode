// VideoPlayerView、CachedAsyncImage、OImageCache、WaterfallGridView、VideoCardView
// 共享复用的 UI 组件

// VideoModuleView、VideoBottomBar、VideoBrowseView
// 首页入口 + 底部栏

import SwiftUI
import AVKit

// MARK: - 播放器封装
struct VideoPlayerView: UIViewControllerRepresentable {
    let videoURL: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        player.play()
        return controller
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

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
                    NavigationLink(destination: VideoDetailView(item: item)) {
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
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomTrailing) {
                        coverImage
                        if let info = item.info, !info.isEmpty {
                            Text(info)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .padding(6)
                        }
                        if item.bestRating > 0 {
                            VStack {
                                HStack {
                                    Text(String(format: "%.1f", item.bestRating))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                                        .padding(6)
                                    Spacer()
                                }
                                Spacer()
                            }
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if let date = item.date, !date.isEmpty {
                Text(date.split(separator: "(").first.map(String.init) ?? date)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let types = item.types, !types.isEmpty {
                Text(types.joined(separator: " / "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 2)
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

// MARK: - 顶层入口
struct VideoModuleView: View {
    @StateObject private var dataManager = OVideoDataManager()
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var selectedCategoryIndex = 0
    @State private var sortOption: VideoSortOption = .date
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VideoBrowseView(dataManager: dataManager,
                            selectedCategoryIndex: $selectedCategoryIndex,
                            sortOption: $sortOption)
                .padding(.bottom, 60)
            
            VideoBottomBar(dataManager: dataManager)
        }
        .task { await dataManager.loadVideosIfNeeded() }
        .refreshable { await dataManager.loadVideos() }
    }
}

// MARK: - 底部栏
struct VideoBottomBar: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    var body: some View {
        HStack(spacing: 0) {
            barButton(icon: "square.grid.2x2.fill",
                      zh: "首页", en: "Home",
                      isActive: true) { }
            
            NavigationLink {
                VideoFilterView(dataManager: dataManager)
            } label: {
                barLabel(icon: "line.3.horizontal.decrease.circle",
                         zh: "分类", en: "Filter", isActive: false)
            }
            
            NavigationLink {
                VideoSearchTabView(dataManager: dataManager)
            } label: {
                barLabel(icon: "magnifyingglass",
                         zh: "搜索", en: "Search", isActive: false)
            }
            
            NavigationLink {
                VideoCacheView()
            } label: {
                barLabel(icon: "arrow.down.circle",
                         zh: "缓存", en: "Cache", isActive: false)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().frame(height: 0.5)
                    .foregroundColor(.secondary.opacity(0.2)), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
    
    private func barButton(icon: String, zh: String, en: String,
                           isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barLabel(icon: icon, zh: zh, en: en, isActive: isActive)
        }
    }
    
    private func barLabel(icon: String, zh: String, en: String, isActive: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
            Text(isGlobalEnglishMode ? en : zh)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(isActive ? .accentColor : .secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - 首页
struct VideoBrowseView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @Binding var selectedCategoryIndex: Int
    @Binding var sortOption: VideoSortOption
    
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    private var currentItems: [OVideoItem] {
        guard selectedCategoryIndex < dataManager.categories.count else { return [] }
        return dataManager.sortItems(dataManager.categories[selectedCategoryIndex].items,
                                     by: sortOption)
    }
    
    private var currentCategoryDisplay: String {
        guard selectedCategoryIndex < dataManager.categories.count
        else { return isGlobalEnglishMode ? "Video" : "影视" }
        return categoryDisplayName(dataManager.categories[selectedCategoryIndex].name)
    }
    
    var body: some View {
        Group {
            if dataManager.isLoading && dataManager.categories.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = dataManager.errorMessage, dataManager.categories.isEmpty {
                errorView(err)
            } else if dataManager.categories.isEmpty {
                Text(isGlobalEnglishMode ? "No content" : "暂无内容")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    WaterfallGridView(items: currentItems)
                        .padding(.top, 10)
                        .padding(.bottom, 20)
                }
                .background(Color(UIColor.systemGroupedBackground))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(Array(dataManager.categories.enumerated()), id: \.offset) { idx, cat in
                        Button {
                            withAnimation { selectedCategoryIndex = idx }
                        } label: {
                            if idx == selectedCategoryIndex {
                                Label(categoryDisplayName(cat.name), systemImage: "checkmark")
                            } else {
                                Text(categoryDisplayName(cat.name))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentCategoryDisplay)
                            .font(.system(size: 17, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(VideoSortOption.allCases, id: \.self) { opt in
                        Button {
                            withAnimation { sortOption = opt }
                        } label: {
                            if opt == sortOption {
                                Label(opt.displayName(isGlobalEnglishMode), systemImage: "checkmark")
                            } else {
                                Label(opt.displayName(isGlobalEnglishMode), systemImage: opt.icon)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 18, weight: .medium))
                }
            }
        }
    }
    
    private func categoryDisplayName(_ key: String) -> String {
        if isGlobalEnglishMode { return key }
        switch key {
        case "Movie": return "电影"
        case "Drama": return "剧集"
        case "Show":  return "综艺"
        case "Anime": return "动漫"
        case "TV":    return "电视剧"
        default:      return key
        }
    }
    
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundColor(.orange)
            Text(msg).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button(isGlobalEnglishMode ? "Retry" : "重试") {
                Task { await dataManager.loadVideos() }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color.blue).foregroundColor(.white).cornerRadius(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}