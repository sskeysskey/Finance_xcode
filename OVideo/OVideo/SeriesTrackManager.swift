import SwiftUI
import Combine

// MARK: - 本地追剧记录
struct TrackedSeries: Codable, Identifiable, Hashable {
    var id: String { sourceURL }
    var sourceURL: String
    var title: String
    var coverImage: String?
    var category: String
    var baselineCount: Int           // 上次"追平"时的集数
    var notifiedCount: Int           // 已提示过的集数
    var latestCount: Int             // 服务器最近一次返回的集数（可能临时波动）
    var latestUpdate: String
    var latestInfo: String?
    var lastWatchedEpisode: String?
    var channelName: String?
    var lastWatchedAt: Date
    var isMuted: Bool
    var unavailable: Bool
    /// 自上次追平以来观测到的最大集数（只增不减；老数据为 nil）
    var highestCount: Int? = nil

    var peakCount: Int { max(highestCount ?? latestCount, latestCount) }
    var hasUpdate: Bool { peakCount > baselineCount }
    var isUnseen: Bool { peakCount > max(baselineCount, notifiedCount) }
    var newEpisodeCount: Int { max(0, peakCount - baselineCount) }
}

private struct PendingWatch: Codable {
    let sourceURL: String
    let title: String
    let cover: String?
    let episodeName: String?
    let channelName: String?
    let at: Date
    var catchUp: Bool? = nil        // nil = 旧数据，视为观看
}

@MainActor
final class SeriesTrackManager: ObservableObject {
    static let shared = SeriesTrackManager()

    @Published private(set) var items: [TrackedSeries] = []
    @Published private(set) var isRefreshing = false

    private var pending: [String: PendingWatch] = [:]
    private let storageKey = "GW_SeriesTrack"               // 保持 Mac 原 key
    private let pendingKey = "GW_SeriesTrack_Pending_v1"
    private let softCap = 300
    private var lastRefresh: Date?

    private init() { load() }

    // MARK: 只读视图
    var updatedList: [TrackedSeries] {
        items.filter { !$0.isMuted && $0.hasUpdate }
            .sorted { a, b in
                if a.latestUpdate != b.latestUpdate { return a.latestUpdate > b.latestUpdate }
                if a.lastWatchedAt != b.lastWatchedAt { return a.lastWatchedAt > b.lastWatchedAt }
                return a.sourceURL < b.sourceURL
            }
    }
    var unseenCount: Int { items.filter { !$0.isMuted && $0.isUnseen }.count }
    var trackedCount: Int { items.filter { !$0.isMuted }.count }

    // MARK: 记录观看 / 下载
    /// 播放时用默认 catchUp: true（追平）；下载完成请传 catchUp: false（仅加入追踪）
    func recordWatch(sourceURL: String?, title: String, cover: String?,
                     episodeName: String?, channelName: String?, catchUp: Bool = true) {
        let src = (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, src.lowercased().hasPrefix("http") else { return }
        let cleanTitle = title.components(separatedBy: " · ").first ?? title

        Task {
            let list = await VideoAPI.fetchSeriesStatus(urls: [src])
            if let s = list.first {
                guard (s.category ?? "") != "Movie" else { return }
                applyWatch(s, title: cleanTitle, cover: cover, ep: episodeName,
                           ch: channelName, at: Date(), catchUp: catchUp)
                pending.removeValue(forKey: src)
                save(); savePending()
            } else {
                // 离线：已有"观看"语义的 pending 不被"下载"降级
                let merged = catchUp || (pending[src]?.catchUp ?? false)
                pending[src] = PendingWatch(sourceURL: src, title: cleanTitle, cover: cover,
                                            episodeName: episodeName, channelName: channelName,
                                            at: Date(), catchUp: merged)
                savePending()
            }
        }
    }

    private func applyWatch(_ s: SeriesStatus, title: String, cover: String?,
                            ep: String?, ch: String?, at: Date, catchUp: Bool) {
        let count = max(0, s.episode_count)
        if let idx = items.firstIndex(where: { $0.sourceURL == s.url }) {
            var it = items[idx]
            it.title = s.name?.isEmpty == false ? s.name! : (it.title.isEmpty ? title : it.title)
            it.coverImage = s.image ?? cover ?? it.coverImage
            it.category = s.category ?? it.category
            if count > 0 { it.latestCount = count }
            it.latestUpdate = s.update ?? it.latestUpdate
            it.latestInfo = s.info ?? it.latestInfo
            it.unavailable = s.unavailable ?? false
            if catchUp {
                it.baselineCount = max(count, it.baselineCount)
                it.highestCount = it.baselineCount
                it.notifiedCount = it.baselineCount
                it.lastWatchedEpisode = ep ?? it.lastWatchedEpisode
                it.channelName = ch ?? it.channelName
                it.lastWatchedAt = at
                it.isMuted = false                                // 再次观看自动解除取消
            } else {
                it.highestCount = max(it.peakCount, count)
            }
            items[idx] = it
        } else {
            items.append(TrackedSeries(
                sourceURL: s.url,
                title: s.name?.isEmpty == false ? s.name! : title,
                coverImage: s.image ?? cover,
                category: s.category ?? "Drama",
                baselineCount: count,
                notifiedCount: count,
                latestCount: count,
                latestUpdate: s.update ?? "",
                latestInfo: s.info,
                lastWatchedEpisode: ep,
                channelName: ch,
                lastWatchedAt: at,
                isMuted: false,
                unavailable: s.unavailable ?? false,
                highestCount: count))
        }
        trimIfNeeded()
    }

    // MARK: 刷新
    func refresh(force: Bool = false) async {
        if isRefreshing { return }
        if !force, let l = lastRefresh, Date().timeIntervalSince(l) < 60 { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 1) 补齐离线记录（必须拿到完整结果才删除"查不到的"）
        if !pending.isEmpty {
            let urls = Array(pending.keys)
            if let list = await VideoAPI.fetchSeriesStatusChecked(urls: urls) {
                let returned = Set(list.map(\.url))
                for s in list {
                    guard let p = pending[s.url] else { continue }
                    if (s.category ?? "") != "Movie" {
                        applyWatch(s, title: p.title, cover: p.cover, ep: p.episodeName,
                                   ch: p.channelName, at: p.at, catchUp: p.catchUp ?? true)
                    }
                    pending.removeValue(forKey: s.url)
                }
                for k in urls where !returned.contains(k) { pending.removeValue(forKey: k) }
                savePending()
            }
        }

        // 2) 刷新已追踪剧集
        let urls = items.map(\.sourceURL)
        guard !urls.isEmpty else { lastRefresh = Date(); save(); return }
        let list = await VideoAPI.fetchSeriesStatus(urls: urls)
        guard !list.isEmpty else { return }
        let map = Dictionary(list.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices {
            guard let s = map[items[i].sourceURL] else { continue }
            if s.episode_count > 0 {
                items[i].latestCount = s.episode_count
                items[i].highestCount = max(items[i].peakCount, s.episode_count)   // 只增不减
            }
            if let u = s.update, !u.isEmpty { items[i].latestUpdate = u }
            if let n = s.name, !n.isEmpty { items[i].title = n }
            if let g = s.image, !g.isEmpty { items[i].coverImage = g }
            items[i].latestInfo = s.info ?? items[i].latestInfo
            items[i].unavailable = s.unavailable ?? false
        }
        lastRefresh = Date()
        save()
    }

    // MARK: 用户操作
    func markAllSeen() {
        var ch = false
        for i in items.indices where !items[i].isMuted && items[i].isUnseen {
            items[i].notifiedCount = items[i].peakCount; ch = true
        }
        if ch { save() }
    }

    /// 临时清除：视为已追平到当前峰值
    func markWatched(_ url: String) {
        guard let i = items.firstIndex(where: { $0.sourceURL == url }) else { return }
        items[i].baselineCount = max(items[i].baselineCount, items[i].peakCount)
        items[i].highestCount = items[i].baselineCount
        items[i].notifiedCount = items[i].baselineCount
        items[i].lastWatchedAt = Date()
        save()
    }

    /// 取消追剧
    func mute(_ url: String) {
        guard let i = items.firstIndex(where: { $0.sourceURL == url }) else { return }
        items[i].isMuted = true
        items[i].notifiedCount = items[i].peakCount
        save()
    }

    func clearAll() { items.removeAll(); pending.removeAll(); save(); savePending() }

    // MARK: 淘汰 / 持久化
    /// 只淘汰"已取消"和"无更新"的旧条目；有更新的永不淘汰
    private func trimIfNeeded() {
        guard items.count > softCap else { return }
        var overflow = items.count - softCap
        let candidates = items
            .filter { $0.isMuted || !$0.hasUpdate }
            .sorted { a, b in
                if a.isMuted != b.isMuted { return a.isMuted }
                return a.lastWatchedAt < b.lastWatchedAt
            }
        var drop = Set<String>()
        for it in candidates {
            if overflow <= 0 { break }
            drop.insert(it.sourceURL); overflow -= 1
        }
        if !drop.isEmpty { items.removeAll { drop.contains($0.sourceURL) } }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: storageKey) }
    }
    private func savePending() {
        if let d = try? JSONEncoder().encode(Array(pending.values)) {
            UserDefaults.standard.set(d, forKey: pendingKey)
        }
    }
    private func load() {
        if let d = UserDefaults.standard.data(forKey: storageKey),
           let arr = try? JSONDecoder().decode([TrackedSeries].self, from: d) {
            var byURL: [String: TrackedSeries] = [:]
            for it in arr {
                if let e = byURL[it.sourceURL], e.lastWatchedAt >= it.lastWatchedAt { continue }
                byURL[it.sourceURL] = it
            }
            items = Array(byURL.values)
        }
        if let d = UserDefaults.standard.data(forKey: pendingKey),
           let arr = try? JSONDecoder().decode([PendingWatch].self, from: d) {
            pending = Dictionary(arr.map { ($0.sourceURL, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

// MARK: - 追剧提醒
struct FollowView: View {
    @ObservedObject var track = SeriesTrackManager.shared
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var app = AppState.shared
    @State private var loadingURL: String?
    @State private var failMessage: String?

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
                    ForEach(track.updatedList, id: \.sourceURL) { s in
                        row(for: s)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(lang.t("追剧提醒", "Following"))
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await track.refresh(force: true) }
                } label: {
                    if track.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(track.isRefreshing)
            }
        }
        .onAppear { track.markAllSeen() }
        .task { await track.refresh() }
        .alert(lang.t("打开失败", "Failed to open"),
               isPresented: Binding(get: { failMessage != nil },
                                    set: { if !$0 { failMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failMessage ?? "")
        }
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
                        .padding(.horizontal, 6).padding(.vertical, 1)
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
            if let item {
                app.path.append(Route.detail(item))
            } else {
                failMessage = lang.t("该剧集资源已不可用", "This series is no longer available.")
            }
        }
    }
}