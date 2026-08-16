import SwiftUI

// MARK: - 兼容工具

/// macOS 13 安全的日期显示（不依赖 .formatted(date:time:) 的重载推断）
private let gwDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

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

// MARK: - 观看记录

struct HistoryView: View {
    @ObservedObject var store = PlayRecordStore.shared
    @EnvironmentObject var lang: LanguageManager
    @EnvironmentObject var auth: AuthManager
    @ObservedObject var quota = QuotaManager.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showSubscribe = false

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableViewCompat(
                    title: lang.t("暂无观看记录", "No history"),
                    message: "",
                    systemImage: "clock.badge.questionmark")
            } else {
                List {
                    // ⭐ 关键修复：显式 id，不再依赖 PlayRecord: Identifiable
                    ForEach(store.records, id: \.videoURL) { r in
                        row(for: r)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(lang.t("观看记录", "History"))
        .toolbar {
            if !store.records.isEmpty {
                Button(lang.t("清空", "Clear All"), role: .destructive) { store.clear() }
            }
        }
        .sheet(isPresented: $showSubscribe) { SubscriptionView() }
    }

    @ViewBuilder
    private func row(for r: PlayRecord) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: VideoAPI.coverURL(r.coverImage))
                .frame(width: 42, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(r.videoTitle).font(.callout.weight(.semibold))
                // ⭐ .accent 是 macOS 14+，这里用 Color.accentColor
                Text(r.episodeName).font(.caption).foregroundStyle(Color.accentColor)
                Text(gwDateFormatter.string(from: r.playTime))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            Button { play(r) } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)

            Button { store.remove(r) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 3)
    }

    private func play(_ r: PlayRecord) {
        Task {
            switch decideAccess(episodeKey: r.videoURL, auth: auth, quota: quota) {
            case .allowed:
                break
            case .needLogin:
                auth.signInWithApple(); return
            case .needConsume:
                let uid = QuotaManager.currentUserId(auth: auth)
                let res = await quota.unlock(userId: uid, episodeKey: r.videoURL,
                                             title: "\(r.videoTitle) · \(r.episodeName)")
                if case .quotaExceeded = res { showSubscribe = true; return }
                if case .failed = res { showSubscribe = true; return }
            case .exhausted:
                showSubscribe = true; return
            }

            let fallback = EpisodeItem(number: "1", name: r.episodeName, url: r.videoURL)
            var eps: [EpisodeItem] = [fallback]
            if let src = r.sourceURL, !src.isEmpty,
               let best = optimalChannels((try? await VideoAPI.fetchPlaylist(url: src)) ?? []).first {
                let list = best.episodeItems()
                // ⭐ 只有列表里确实包含当前这一集，才用整条线路（否则上/下一集索引会错乱）
                eps = list.contains(where: { $0.url == r.videoURL }) ? list : [fallback]
            }

            openWindow(id: "player", value: PlayPayload(
                seriesTitle: r.videoTitle, episodeName: r.episodeName, episodeKey: r.videoURL,
                sourceURL: r.sourceURL, cover: r.coverImage, channelName: r.channelName,
                episodes: eps, playSource: "history"))
        }
    }
}

// MARK: - 举报 / 反馈修复

/// ⭐ Swift 不支持 \.0 这种元组 KeyPath，改成结构体
private struct ReportKind: Identifiable, Hashable {
    let id: String
    let zh: String
    let en: String
}

private let gwReportKinds: [ReportKind] = [
    .init(id: "playback_failed",  zh: "无法播放",       en: "Can't play"),
    .init(id: "download_failed",  zh: "无法下载",       en: "Can't download"),
    .init(id: "media_error",      zh: "画面或声音异常", en: "Audio/Video issue"),
    .init(id: "content_mismatch", zh: "内容与简介不符", en: "Wrong content"),
    .init(id: "other",            zh: "其他问题",       en: "Other")
]

struct ReportSheet: View {
    let title: String
    let sourceURL: String
    let episodeURL: String
    let channel: String?
    let episode: String?
    let realURL: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @State private var type = "playback_failed"
    @State private var note = ""
    @State private var working = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.t("反馈修复", "Report an issue")).font(.headline)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(2)

            Picker(lang.t("问题类型", "Issue"), selection: $type) {
                ForEach(gwReportKinds) { k in
                    Text(lang.t(k.zh, k.en)).tag(k.id)
                }
            }

            // ⭐ 用 TextEditor 代替 TextField(axis:)，彻底避开重载歧义
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("补充说明（选填）", "Note (optional)"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 68)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            if let r = result {
                Text(r).font(.caption).foregroundStyle(ok ? .green : .orange)
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(lang.t("关闭", "Close")) { dismiss() }
                Button(lang.t("提交", "Submit")) { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || ok)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() async {
        working = true; result = nil
        let r = await ReportManager.shared.submit(
            title: title, sourceURL: sourceURL, episodeURL: episodeURL,
            channel: channel, episode: episode, realURL: realURL,
            type: type, note: note, userId: auth.userIdentifier)
        working = false
        switch r {
        case .success:
            ok = true
            result = lang.t("已收到，我们会尽快核实修复", "Received, we'll fix it soon")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { dismiss() }
        case .failure(let e):
            ok = false
            result = e.localizedDescription
        }
    }
}