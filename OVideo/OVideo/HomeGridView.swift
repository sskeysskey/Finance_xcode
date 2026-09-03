import SwiftUI

struct HomeGridView: View {
    let category: String
    @EnvironmentObject var data: VideoDataManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var app = AppState.shared
    @ObservedObject var config = AppConfigManager.shared
    @AppStorage("GW_CardSize") private var cardSize: Double = 180

    private var items: [VideoItem] { data.items(category, app.sort) }
    private var errorText: String? { data.lastError ?? config.lastError }

    var body: some View {
        VStack(spacing: 0) {
            if let n = config.notification {
                NoticeBar(text: n) { config.dismissNotification() }
            }
            if let e = errorText, !items.isEmpty {
                ErrorBar(text: e) { retry() }
            }
            if config.useReviewDisguise {
                ReviewArchiveBanner(year: config.reviewMaxYear, offline: !config.didFetch)
            }
            VideoGrid(items: items,
                      cardWidth: cardSize,
                      loading: data.isLoading(category, app.sort),
                      errorText: items.isEmpty ? errorText : nil,
                      hasMore: data.hasMorePages(category, app.sort),
                      onRetry: { retry() },
                      onReachEnd: {
                          Task { await data.loadNextPage(category, app.sort, userId: auth.userIdentifier) }
                      })
        }
        .navigationTitle(config.categoryDisplayName(category, english: lang.isEnglish))
        .navigationSubtitle(config.updateTime.isEmpty ? "" :
            lang.t("更新于 \(config.updateTime)", "Updated \(config.updateTime)"))
        .toolbar {
            ToolbarItemGroup {
                Picker("", selection: $app.sort) {
                    ForEach(VideoSortOption.allCases, id: \.self) { s in
                        Text(s.name(lang.isEnglish)).tag(s)
                    }
                }
                .pickerStyle(.segmented).frame(width: 260)

                Slider(value: $cardSize, in: 140...260).frame(width: 90)
                    .help(lang.t("调整封面大小", "Card size"))

                Button { retry() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        // ⭐ 把 cacheEpoch 纳入 id：任何一次 resetCache 之后都会强制重新拉取（修复冷启动空白）
        .task(id: "\(category)|\(app.sort.rawValue)|\(config.effectiveMaxYear ?? -1)|\(data.cacheEpoch)") {
            await data.loadFirstPageIfNeeded(category, app.sort, userId: auth.userIdentifier)
        }
    }

    private func retry() {
        Task {
            if !config.didFetch || config.lastError != nil { await config.refresh(retries: 1) }
            await data.reload(category, app.sort, userId: auth.userIdentifier)
        }
    }
}

struct ErrorBar: View {
    let text: String
    let onRetry: () -> Void
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(lang.t("加载失败：\(text)", "Load failed: \(text)"))
                .font(.callout).lineLimit(2)
            Spacer()
            Button(lang.t("重试", "Retry")) { onRetry() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }
}

struct ReviewArchiveBanner: View {
    let year: Int
    var offline: Bool = false
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: offline ? "wifi.exclamationmark" : "building.columns")
                .foregroundStyle(.secondary)
            Text(offline
                 ? lang.t("尚未取到服务器配置，暂以 \(year) 年前资料展示。",
                          "Server config not loaded yet; showing pre-\(year) archive only.")
                 : lang.t("本馆仅收录 \(year) 年以前的经典影像资料，供研究与怀旧欣赏。",
                          "This archive only contains classic footage released before \(year)."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.quaternary.opacity(0.4))
    }
}

struct NoticeBar: View {
    let text: String
    let onClose: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }
}

// MARK: - 网格
struct VideoGrid: View {
    let items: [VideoItem]
    var cardWidth: Double = 180
    var loading: Bool = false
    var errorText: String? = nil
    var hasMore: Bool = false
    var onRetry: (() -> Void)? = nil
    var onItemTap: ((VideoItem) -> Void)? = nil
    var onReachEnd: (() -> Void)? = nil            // ⚠️ 必须放最后：trailing closure 绑定到它

    @EnvironmentObject var lang: LanguageManager
    /// 距列表底部还剩这么多个 item 时就预加载，避免"只有最后一个 onAppear 才触发"的卡死
    private let prefetchThreshold = 8

    var body: some View {
        ScrollView {
            if items.isEmpty {
                if loading {
                    ProgressView().padding(.top, 80)
                } else if let e = errorText {
                    VStack(spacing: 14) {
                        ContentUnavailableViewCompat(
                            title: lang.t("无法连接服务器", "Cannot reach server"),
                            message: e, systemImage: "wifi.slash")
                        if let onRetry {
                            Button(lang.t("重新加载", "Reload")) { onRetry() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(height: 360)
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableViewCompat(title: lang.t("暂无内容", "Nothing here"),
                                                     message: "", systemImage: "tray")
                        if let onRetry {
                            Button(lang.t("刷新试试", "Reload")) { onRetry() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(height: 340)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 18)],
                          alignment: .leading, spacing: 22) {
                    ForEach(Array(items.enumerated()), id: \.element.url) { idx, item in
                        NavigationLink(value: Route.detail(item)) { VideoCard(item: item) }
                            .buttonStyle(.plain)
                            // ⭐ 点击结果也算一次"有效搜索"，供搜索历史记录使用
                            .simultaneousGesture(TapGesture().onEnded { onItemTap?(item) })
                            .onAppear {
                                if idx >= items.count - prefetchThreshold { onReachEnd?() }
                            }
                    }
                }
                .padding(20)

                if loading {
                    ProgressView().padding(.bottom, 24)
                } else if hasMore {
                    // ⭐ 兜底：即使 onAppear 没触发，用户也能手动继续加载
                    Button(lang.t("加载更多", "Load more")) { onReachEnd?() }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 26)
                }
            }
        }
        .background(Color.winBG)
    }
}

// MARK: - 卡片（固定 2:3 封面 + 固定文字区高度，彻底解决高低不齐/重叠）
struct VideoCard: View {
    let item: VideoItem
    @State private var hover = false

    private var yearRegion: String {
        var parts: [String] = []
        if let d = item.date, !d.isEmpty {
            parts.append(d.split(separator: "(").first.map(String.init) ?? d)
        }
        if let r = item.region, !r.isEmpty { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            poster
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
            Text(yearRegion)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15, alignment: .topLeading)
        }
        .onHover { hover = $0 }
        .contentShape(Rectangle())
    }

    private var poster: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)      // ⭐ 统一 2:3，行高必然一致
            .overlay { CachedImage(url: VideoAPI.coverURL(item.image), contentMode: .fill) }
            .overlay(alignment: .topLeading) {
                if item.bestRating > 0 {
                    Text(String(format: "%.1f", item.bestRating))
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.94), in: Capsule())
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let info = item.info, !info.isEmpty {
                    Text(info)
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.68), in: Capsule())
                        .padding(7)
                }
            }
            .overlay {
                if hover {
                    ZStack {
                        Color.black.opacity(0.26)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 38)).foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(hover ? 0.28 : 0.12), radius: hover ? 12 : 5, y: 4)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.16), value: hover)
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 600; cache.totalCostLimit = 320 * 1024 * 1024 }
    func get(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func set(_ img: NSImage, _ url: URL) {
        cache.setObject(img, forKey: url as NSURL,
                        cost: Int(img.size.width * img.size.height * 4))
    }
    func clear() { cache.removeAllObjects() }
}

/// ⭐ 关键修复：图片始终"填满 + 裁切"到父容器给定的尺寸，绝不会顶出布局
struct CachedImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: min(geo.size.width, geo.size.height) * 0.24))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()                     // ⭐ 就是这一句以前少了
            .contentShape(Rectangle())
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let c = ImageCache.shared.get(url) { image = c; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        ImageCache.shared.set(img, url)
        image = img
    }
}