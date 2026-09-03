import SwiftUI
import Combine

struct TrackedSeries: Codable, Identifiable, Hashable {
    var id: String { sourceURL }
    var sourceURL: String
    var title: String
    var coverImage: String?
    var category: String
    var baselineCount: Int
    var notifiedCount: Int
    var latestCount: Int
    var latestUpdate: String
    var latestInfo: String?
    var lastWatchedEpisode: String?
    var channelName: String?
    var lastWatchedAt: Date
    var isMuted: Bool
    var unavailable: Bool

    var hasUpdate: Bool { latestCount > baselineCount }
    var isUnseen: Bool { latestCount > max(baselineCount, notifiedCount) }
    var newEpisodeCount: Int { max(0, latestCount - baselineCount) }
}

@MainActor
final class SeriesTrackManager: ObservableObject {
    static let shared = SeriesTrackManager()
    @Published private(set) var items: [TrackedSeries] = []
    private let key = "GW_SeriesTrack"
    private var lastRefresh: Date?
    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let a = try? JSONDecoder().decode([TrackedSeries].self, from: d) { items = a }
    }

    var updatedList: [TrackedSeries] {
        items.filter { !$0.isMuted && $0.hasUpdate }
             .sorted { $0.latestUpdate != $1.latestUpdate ? $0.latestUpdate > $1.latestUpdate
                                                          : $0.lastWatchedAt > $1.lastWatchedAt }
    }
    var unseenCount: Int { items.filter { !$0.isMuted && $0.isUnseen }.count }
    var trackedCount: Int { items.filter { !$0.isMuted }.count }

    func recordWatch(sourceURL: String?, title: String, cover: String?,
                     episodeName: String?, channelName: String?) {
        let src = (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard src.lowercased().hasPrefix("http") else { return }
        let clean = title.components(separatedBy: " · ").first ?? title
        Task {
            guard let s = await VideoAPI.fetchSeriesStatus(urls: [src]).first,
                  (s.category ?? "") != "Movie" else { return }
            apply(s, fallbackTitle: clean, cover: cover, ep: episodeName, ch: channelName)
            save()
        }
    }

    private func apply(_ s: SeriesStatus, fallbackTitle: String, cover: String?,
                       ep: String?, ch: String?) {
        let count = max(0, s.episode_count)
        if let i = items.firstIndex(where: { $0.sourceURL == s.url }) {
            var it = items[i]
            it.title = s.name?.isEmpty == false ? s.name! : it.title
            it.coverImage = s.image ?? cover ?? it.coverImage
            it.category = s.category ?? it.category
            it.baselineCount = max(count, it.baselineCount)
            it.notifiedCount = it.baselineCount
            it.latestCount = count
            it.latestUpdate = s.update ?? it.latestUpdate
            it.latestInfo = s.info ?? it.latestInfo
            it.lastWatchedEpisode = ep ?? it.lastWatchedEpisode
            it.channelName = ch ?? it.channelName
            it.lastWatchedAt = Date(); it.isMuted = false
            it.unavailable = s.unavailable ?? false
            items[i] = it
        } else {
            items.append(.init(sourceURL: s.url,
                title: s.name?.isEmpty == false ? s.name! : fallbackTitle,
                coverImage: s.image ?? cover, category: s.category ?? "Drama",
                baselineCount: count, notifiedCount: count, latestCount: count,
                latestUpdate: s.update ?? "", latestInfo: s.info,
                lastWatchedEpisode: ep, channelName: ch, lastWatchedAt: Date(),
                isMuted: false, unavailable: s.unavailable ?? false))
        }
        if items.count > 200 {
            items.sort { $0.lastWatchedAt > $1.lastWatchedAt }
            items = Array(items.prefix(200))
        }
    }

    func refresh(force: Bool = false) async {
        if !force, let l = lastRefresh, Date().timeIntervalSince(l) < 60 { return }
        let urls = items.map(\.sourceURL); guard !urls.isEmpty else { lastRefresh = Date(); return }
        let list = await VideoAPI.fetchSeriesStatus(urls: urls)
        guard !list.isEmpty else { return }
        let map = Dictionary(list.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices {
            guard let s = map[items[i].sourceURL] else { continue }
            if s.episode_count > 0 { items[i].latestCount = s.episode_count }
            if let u = s.update, !u.isEmpty { items[i].latestUpdate = u }
            if let n = s.name, !n.isEmpty { items[i].title = n }
            if let g = s.image, !g.isEmpty { items[i].coverImage = g }
            items[i].latestInfo = s.info ?? items[i].latestInfo
            items[i].unavailable = s.unavailable ?? false
        }
        lastRefresh = Date(); save()
    }

    func markAllSeen() {
        var ch = false
        for i in items.indices where !items[i].isMuted && items[i].isUnseen {
            items[i].notifiedCount = items[i].latestCount; ch = true
        }
        if ch { save() }
    }
    func markWatched(_ url: String) {
        guard let i = items.firstIndex(where: { $0.sourceURL == url }) else { return }
        items[i].baselineCount = items[i].latestCount
        items[i].notifiedCount = items[i].latestCount
        items[i].lastWatchedAt = Date(); save()
    }
    func mute(_ url: String) {
        guard let i = items.firstIndex(where: { $0.sourceURL == url }) else { return }
        items[i].isMuted = true; items[i].notifiedCount = items[i].latestCount; save()
    }
    func clearAll() { items.removeAll(); save() }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - 追剧提醒
struct FollowView: View {
    @ObservedObject var track = SeriesTrackManager.shared
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var app = AppState.shared
    @State private var loadingURL: String?

    var body: some View {
        Group {
            if track.updatedList.isEmpty {
                ContentUnavailableViewCompat(
                    title: lang.t("暂无剧集更新", "No new episodes"),
                    message: lang.t("已在追 \(track.trackedCount) 部，有更新会在这里提醒你。",
                                    "Following \(track.trackedCount) series."),
                    systemImage: "bell.slash")
            } else {
                List {
                    // ⭐ 显式 id，避免依赖 Identifiable 推断
                    ForEach(track.updatedList, id: \.sourceURL) { s in
                        row(for: s)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(lang.t("追剧提醒", "Following"))
        .toolbar {
            Button {
                Task { await track.refresh(force: true) }
            } label: { Image(systemName: "arrow.clockwise") }
        }
        .onAppear { track.markAllSeen() }
        .task { await track.refresh() }
    }

    @ViewBuilder
    private func row(for s: TrackedSeries) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: VideoAPI.coverURL(s.coverImage))
                .frame(width: 48, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    Text(lang.t("新增 \(s.newEpisodeCount) 集", "+\(s.newEpisodeCount) new"))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                    if let i = s.latestInfo, !i.isEmpty {
                        Text(i).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let e = s.lastWatchedEpisode, !e.isEmpty {
                    Text(lang.t("上次看到：", "Watched: ") + e)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if loadingURL == s.sourceURL { ProgressView().controlSize(.small) }

            Menu {
                Button(lang.t("临时清除", "Clear once")) { track.markWatched(s.sourceURL) }
                Button(lang.t("取消追剧", "Stop following"), role: .destructive) {
                    track.mute(s.sourceURL)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { open(s) }
    }

    private func open(_ s: TrackedSeries) {
        guard loadingURL == nil else { return }
        loadingURL = s.sourceURL
        Task {
            let item = await VideoAPI.fetchDetail(url: s.sourceURL)
            loadingURL = nil
            if let item { app.path.append(Route.detail(item)) }
        }
    }
}
