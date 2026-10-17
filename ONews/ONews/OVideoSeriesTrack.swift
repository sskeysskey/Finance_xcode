//  OVideoSeriesTrack.swift
//  追剧功能：数据模型 / 管理器 / 半屏列表页
//  ⭐ v2：
//   1) 「有更新」改用只增不减的 highestCount 判定 → 服务器集数临时波动不再让条目消失又出现
//   2) 有更新的条目绝不被容量淘汰
//   3) 状态查询按 200 条分批（服务器单次上限 400）
//   4) 下载完成只"加入追踪"，不再视为"已追平"

import SwiftUI

// MARK: - 服务器返回模型
struct SeriesStatus: Codable {
    let url: String
    let category: String?
    let name: String?
    let image: String?
    let info: String?
    let update: String?
    let episode_count: Int
    let unavailable: Bool?
}
private struct SeriesStatusResponse: Codable { let items: [SeriesStatus] }
private struct SeriesDetailResponse: Codable { let item: OVideoItem }

// MARK: - API 扩展
extension OVideoAPI {
    private static let seriesStatusChunk = 200

    private static func postSeriesStatus(_ urls: [String]) async -> [SeriesStatus]? {
        guard !urls.isEmpty,
              let url = URL(string: "\(baseURL)/track_series/status") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["urls": urls])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return (try? JSONDecoder().decode(SeriesStatusResponse.self, from: data))?.items
    }

    /// 分批查询；任一批失败返回 nil（用于"服务器查不到就删除"这种需要完整结果的场景）
    static func fetchSeriesStatusChecked(urls: [String]) async -> [SeriesStatus]? {
        var seen = Set<String>()
        let clean = urls.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !clean.isEmpty else { return [] }
        var out: [SeriesStatus] = []
        var i = 0
        while i < clean.count {
            let part = Array(clean[i..<min(i + seriesStatusChunk, clean.count)])
            guard let r = await postSeriesStatus(part) else { return nil }
            out += r
            i += seriesStatusChunk
        }
        return out
    }

    /// 分批查询；失败的批次跳过（返回部分结果）
    static func fetchSeriesStatus(urls: [String]) async -> [SeriesStatus] {
        var seen = Set<String>()
        let clean = urls.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !clean.isEmpty else { return [] }
        var out: [SeriesStatus] = []
        var i = 0
        while i < clean.count {
            let part = Array(clean[i..<min(i + seriesStatusChunk, clean.count)])
            if let r = await postSeriesStatus(part) { out += r }
            i += seriesStatusChunk
        }
        return out
    }

    /// 按 url 拉取完整剧集详情（追剧列表跳详情页用）
    static func fetchDetail(url itemURL: String) async -> OVideoItem? {
        guard let enc = itemURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "\(baseURL)/detail?url=\(enc)") else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONDecoder().decode(SeriesDetailResponse.self, from: data))?.item
    }
}

// MARK: - 本地追剧记录
struct TrackedSeries: Codable, Identifiable, Hashable {
    var id: String { sourceURL }
    var sourceURL: String
    var title: String
    var coverImage: String?
    var category: String
    var baselineCount: Int           // 上次"看过/追平"时的集数
    var notifiedCount: Int           // 已在角标里提示过的集数
    var latestCount: Int             // 服务器最近一次返回的有效集数（可能临时波动）
    var latestUpdate: String
    var latestInfo: String?
    var lastWatchedEpisode: String?
    var channelName: String?
    var lastWatchedAt: Date
    var isMuted: Bool
    var unavailable: Bool
    /// ⭐ 自上次追平以来观测到的最大集数（只增不减；老数据为 nil 时回退 latestCount）
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
    var catchUp: Bool? = nil        // nil = 旧数据（视为观看）
}

// MARK: - 追剧管理器
@MainActor
final class SeriesTrackManager: ObservableObject {
    static let shared = SeriesTrackManager()

    @Published private(set) var items: [TrackedSeries] = []
    @Published var showSheet = false
    @Published private(set) var isRefreshing = false

    private var pending: [String: PendingWatch] = [:]
    private let storageKey = "ONews_SeriesTrack_v1"
    private let pendingKey = "ONews_SeriesTrack_Pending_v1"
    /// 软上限：只淘汰"已取消追剧"和"当前没有更新"的旧条目，有更新的绝不淘汰
    private let softCap = 300
    private var lastRefreshAt: Date? = nil

    private init() { load() }

    // MARK: 对外只读视图
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

    // MARK: 记录一次观看（真正开始播放后调用）/ 下载完成（catchUp: false，仅加入追踪）
    func recordWatch(sourceURL: String?, title: String,
                     cover: String?, episodeName: String?, channelName: String?,
                     catchUp: Bool = true) {
        let src = (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, src.lowercased().hasPrefix("http") else { return }
        let cleanTitle = title.components(separatedBy: " · ").first ?? title

        Task {
            let list = await OVideoAPI.fetchSeriesStatus(urls: [src])
            if let s = list.first {
                guard (s.category ?? "") != "Movie" else { return }
                self.applyWatch(s, title: cleanTitle, cover: cover,
                                ep: episodeName, ch: channelName, at: Date(), catchUp: catchUp)
                self.pending.removeValue(forKey: src)
                self.save(); self.savePending()
            } else {
                // 离线：先记 pending；已有"观看"的 pending 不被"下载"覆盖成更弱的语义
                let mergedCatchUp = catchUp || (self.pending[src]?.catchUp ?? false)
                self.pending[src] = PendingWatch(sourceURL: src, title: cleanTitle,
                                                 cover: cover, episodeName: episodeName,
                                                 channelName: channelName, at: Date(),
                                                 catchUp: mergedCatchUp)
                self.savePending()
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
                it.baselineCount = max(count, it.baselineCount)   // 追平到当前
                it.highestCount = it.baselineCount                // 重置粘性峰值
                it.notifiedCount = it.baselineCount
                it.lastWatchedEpisode = ep ?? it.lastWatchedEpisode
                it.channelName = ch ?? it.channelName
                it.lastWatchedAt = at
                it.isMuted = false                                // 再次观看 → 自动解除黑名单
            } else {
                it.highestCount = max(it.peakCount, count)        // 下载：只更新最新集数
            }
            items[idx] = it
        } else {
            let it = TrackedSeries(sourceURL: s.url,
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
                                   highestCount: count)
            items.append(it)
        }
        trimIfNeeded()
    }

    // MARK: 刷新
    func refresh(force: Bool = false) async {
        if isRefreshing { return }
        if !force, let last = lastRefreshAt, Date().timeIntervalSince(last) < 60 { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 1) 补齐离线时缓存的观看记录（必须拿到完整结果才删除"查不到的"）
        if !pending.isEmpty {
            let urls = Array(pending.keys)
            if let list = await OVideoAPI.fetchSeriesStatusChecked(urls: urls) {
                let returned = Set(list.map { $0.url })
                for s in list {
                    guard let p = pending[s.url] else { continue }
                    if (s.category ?? "") != "Movie" {
                        applyWatch(s, title: p.title, cover: p.cover,
                                   ep: p.episodeName, ch: p.channelName, at: p.at,
                                   catchUp: p.catchUp ?? true)
                    }
                    pending.removeValue(forKey: s.url)
                }
                for k in urls where !returned.contains(k) { pending.removeValue(forKey: k) }
                savePending()
            }
        }

        // 2) 刷新已追踪剧集（分批，部分失败不影响其它）
        let urls = items.map { $0.sourceURL }
        guard !urls.isEmpty else { lastRefreshAt = Date(); save(); return }
        let list = await OVideoAPI.fetchSeriesStatus(urls: urls)
        guard !list.isEmpty else { return }
        let map = Dictionary(list.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices {
            guard let s = map[items[i].sourceURL] else { continue }
            if s.episode_count > 0 {
                items[i].latestCount = s.episode_count
                // ⭐ 只增不减：服务器集数临时变少（线路失效 / mapping 更新中）不会让条目消失
                items[i].highestCount = max(items[i].peakCount, s.episode_count)
            }
            if let u = s.update, !u.isEmpty { items[i].latestUpdate = u }
            if let n = s.name, !n.isEmpty { items[i].title = n }
            if let img = s.image, !img.isEmpty { items[i].coverImage = img }
            items[i].latestInfo = s.info ?? items[i].latestInfo
            items[i].unavailable = s.unavailable ?? false
        }
        lastRefreshAt = Date()
        save()
    }

    // MARK: 用户操作
    func markAllSeen() {
        var changed = false
        for i in items.indices where !items[i].isMuted && items[i].isUnseen {
            items[i].notifiedCount = items[i].peakCount
            changed = true
        }
        if changed { save() }
    }

    /// 临时清除：视为已追平到当前
    func markWatched(_ sourceURL: String) {
        guard let i = items.firstIndex(where: { $0.sourceURL == sourceURL }) else { return }
        let p = items[i].peakCount
        items[i].baselineCount = max(items[i].baselineCount, p)
        items[i].highestCount = items[i].baselineCount
        items[i].notifiedCount = items[i].baselineCount
        items[i].lastWatchedAt = Date()
        save()
    }

    /// 取消追剧（黑名单）
    func mute(_ sourceURL: String) {
        guard let i = items.firstIndex(where: { $0.sourceURL == sourceURL }) else { return }
        items[i].isMuted = true
        items[i].notifiedCount = items[i].peakCount
        save()
    }

    func clearAll() { items.removeAll(); pending.removeAll(); save(); savePending() }

    // MARK: 持久化
    /// ⭐ 淘汰顺序：已取消追剧(最旧优先) → 当前无更新(最旧优先)；列表中"有更新"的永不淘汰
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
            drop.insert(it.sourceURL)
            overflow -= 1
        }
        if !drop.isEmpty { items.removeAll { drop.contains($0.sourceURL) } }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: storageKey)
        }
    }
    private func savePending() {
        if let d = try? JSONEncoder().encode(Array(pending.values)) {
            UserDefaults.standard.set(d, forKey: pendingKey)
        }
    }
    private func load() {
        if let d = UserDefaults.standard.data(forKey: storageKey),
           let arr = try? JSONDecoder().decode([TrackedSeries].self, from: d) {
            // 去重（同一 sourceURL 只保留最近观看的那条）
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

// MARK: - 追剧列表（半屏 sheet）
struct SeriesTrackListView: View {
    @EnvironmentObject private var dataManager: OVideoDataManager
    @ObservedObject private var manager = SeriesTrackManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("OVideo_TrackNoAutoPopup") private var noAutoPopup = false
    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @State private var loadingURL: String? = nil
    @State private var detent: PresentationDetent = .medium
    @State private var failMessage: String? = nil
    @State private var showMuteOptions = false
    @State private var seriesToMute: TrackedSeries? = nil

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if manager.updatedList.isEmpty {
                    emptyView
                } else {
                    listView
                }
                Divider()
                footer
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle(isGlobalEnglishMode ? "New Episodes" : "您追的剧，有更新了！")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .navigationDestination(for: OVideoItem.self) { item in
                VideoDetailView(item: item, dataManager: dataManager, playSource: "tracking")
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear { manager.markAllSeen() }
        .alert(isGlobalEnglishMode ? "Failed to open" : "打开失败",
               isPresented: Binding(get: { failMessage != nil },
                                    set: { if !$0 { failMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failMessage ?? "") }
        .confirmationDialog(
            isGlobalEnglishMode ? "If you cancel tracking, you won't be notified of future updates!" : "取消追剧后，不会再提醒您后续的更新了！",
            isPresented: $showMuteOptions,
            titleVisibility: .visible,
            presenting: seriesToMute
        ) { s in
            Button(isGlobalEnglishMode ? "Temporarily Clear" : "临时清除") {
                withAnimation { manager.markWatched(s.sourceURL) }
            }
            Button(isGlobalEnglishMode ? "Cancel Tracking" : "取消追剧", role: .destructive) {
                withAnimation { manager.mute(s.sourceURL) }
            }
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
        }
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(manager.updatedList) { s in row(s) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func row(_ s: TrackedSeries) -> some View {
        HStack(spacing: 12) {
            cover(s)

            VStack(alignment: .leading, spacing: 5) {
                Text(s.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(isGlobalEnglishMode ? "+\(s.newEpisodeCount) new" : "新增 \(s.newEpisodeCount) 集")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.9)))
                    if let info = s.latestInfo, !info.isEmpty {
                        Text(info)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                if let ep = s.lastWatchedEpisode, !ep.isEmpty {
                    Text((isGlobalEnglishMode ? "Watched: " : "上次看到：") + ep)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !s.latestUpdate.isEmpty {
                    Text((isGlobalEnglishMode ? "Updated " : "更新于 ")
                         + String(s.latestUpdate.prefix(16)))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                }

                if s.unavailable {
                    Text(isGlobalEnglishMode ? "Source unavailable" : "资源暂不可用")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            Spacer(minLength: 4)

            if loadingURL == s.sourceURL {
                ProgressView().padding(.trailing, 4)
            } else {
                Button {
                    seriesToMute = s
                    showMuteOptions = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture { open(s) }
    }

    @ViewBuilder
    private func cover(_ s: TrackedSeries) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
            if let img = s.coverImage, !img.isEmpty,
               let url = OVideoAPI.coverURL(for: img) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Image(systemName: "film").foregroundColor(.secondary)
                    }
                }
            } else {
                Image(systemName: "film").foregroundColor(.secondary)
            }
        }
        .frame(width: 58, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.slash")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.35))
            Text(isGlobalEnglishMode ? "No new episodes yet" : "暂无剧集更新")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
            Text(isGlobalEnglishMode
                 ? "Following \(manager.trackedCount) series. We'll notify you when new episodes arrive."
                 : "已在追 \(manager.trackedCount) 部剧，有新集数时会在这里提醒你")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        Toggle(isOn: $noAutoPopup) {
            Text(isGlobalEnglishMode ? "Don't pop up automatically" : "以后不再主动弹出")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
    }

    private func open(_ s: TrackedSeries) {
        guard loadingURL == nil else { return }
        loadingURL = s.sourceURL
        Task {
            let item = await OVideoAPI.fetchDetail(url: s.sourceURL)
            loadingURL = nil
            guard let item = item else {
                failMessage = isGlobalEnglishMode
                    ? "This series is no longer available."
                    : "该剧集资源已不可用"
                return
            }
            detent = .large
            path.append(item)
        }
    }
}