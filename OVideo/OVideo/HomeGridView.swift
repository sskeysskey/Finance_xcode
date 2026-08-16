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
            if let e = errorText {
                ErrorBar(text: e) { retry() }
            }
            if config.useReviewDisguise {
                ReviewArchiveBanner(year: config.reviewMaxYear,
                                    offline: !config.didFetch)
            }
            VideoGrid(items: items,
                      cardWidth: cardSize,
                      loading: data.isLoading(category, app.sort),
                      errorText: errorText,
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
        .task(id: "\(category)|\(app.sort.rawValue)|\(config.effectiveMaxYear ?? -1)") {
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

/// 顶部错误条：把静默失败暴露出来
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
                 ? lang.t("尚未取到服务器配置，暂以 \(year) 年前资料展示（连上服务器后自动恢复全部内容）。",
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

struct VideoGrid: View {
    let items: [VideoItem]
    var cardWidth: Double = 180
    var loading: Bool = false
    var errorText: String? = nil
    var onRetry: (() -> Void)? = nil
    var onReachEnd: (() -> Void)? = nil
    @EnvironmentObject var lang: LanguageManager

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
                    ContentUnavailableViewCompat(title: lang.t("暂无内容", "Nothing here"),
                                                 message: "", systemImage: "tray")
                        .frame(height: 320)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 18)], spacing: 22) {
                    ForEach(items) { item in
                        NavigationLink(value: Route.detail(item)) { VideoCard(item: item) }
                            .buttonStyle(.plain)
                            .onAppear { if item.url == items.last?.url { onReachEnd?() } }
                    }
                }
                .padding(20)
                if loading { ProgressView().padding(.bottom, 20) }
            }
        }
        .background(Color.winBG)
    }
}

struct VideoCard: View {
    let item: VideoItem
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CachedImage(url: VideoAPI.coverURL(item.image))
                    .aspectRatio(2.0/3.0, contentMode: .fill)
                    .clipped()
                if item.bestRating > 0 {
                    Text(String(format: "%.1f", item.bestRating))
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.92), in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let info = item.info, !info.isEmpty {
                    Text(info).font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(8)
                }
                if hover {
                    ZStack {
                        Color.black.opacity(0.28)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40)).foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(hover ? 0.28 : 0.12), radius: hover ? 12 : 5, y: 4)
            .scaleEffect(hover ? 1.025 : 1)
            .animation(.easeOut(duration: 0.16), value: hover)

            Text(item.name).font(.system(size: 13, weight: .semibold))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let d = item.date, !d.isEmpty {
                    Text(d.split(separator: "(").first.map(String.init) ?? d)
                }
                if let r = item.region, !r.isEmpty { Text(r) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .onHover { hover = $0 }
        .contentShape(Rectangle())
    }
}