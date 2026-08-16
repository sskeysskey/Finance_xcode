import SwiftUI
import AppKit

struct DownloadsView: View {
    @ObservedObject var dm = HLSDownloadManager.shared
    @EnvironmentObject var lang: LanguageManager
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDeleteGroup: String?

    private var groups: [(key: String, title: String, items: [DownloadItem])] {
        Dictionary(grouping: dm.items, by: \.groupKey).map { k, v in
            (k, v.first?.seriesTitle.isEmpty == false ? v.first!.seriesTitle : (v.first?.title ?? k),
             v.sorted { $0.episodeName.localizedStandardCompare($1.episodeName) == .orderedAscending })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if dm.items.isEmpty {
                ContentUnavailableViewCompat(
                    title: lang.t("还没有下载内容", "No downloads yet"),
                    message: lang.t("下载后即可离线观看，不受网络影响。",
                                    "Downloaded videos play offline anytime."),
                    systemImage: "icloud.and.arrow.down")
            } else {
                List {
                    ForEach(groups, id: \.key) { g in
                        Section {
                            ForEach(g.items) { it in row(it) }
                        } header: {
                            HStack {
                                Text(g.title).font(.headline)
                                Text("\(g.items.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(lang.t("全部删除", "Delete All")) { pendingDeleteGroup = g.key }
                                    .buttonStyle(.borderless).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(lang.t("下载管理", "Downloads"))
        .navigationSubtitle(lang.t("占用 \(formatBytes(dm.totalDiskUsage))",
                                   "Using \(formatBytes(dm.totalDiskUsage))"))
        .toolbar {
            ToolbarItemGroup {
                Button { dm.resumeAll() } label: { Label(lang.t("全部继续", "Resume All"), systemImage: "play.fill") }
                Button { dm.pauseAll() } label: { Label(lang.t("全部暂停", "Pause All"), systemImage: "pause.fill") }
                Button { NSWorkspace.shared.open(dm.storageRoot) } label: {
                    Label(lang.t("打开文件夹", "Reveal"), systemImage: "folder")
                }
            }
        }
        .alert(lang.t("确认删除该剧全部下载？", "Delete all downloads for this title?"),
           isPresented: Binding(get: { pendingDeleteGroup != nil },
                                set: { if !$0 { pendingDeleteGroup = nil } })) {
        Button(lang.t("取消", "Cancel"), role: .cancel) { pendingDeleteGroup = nil }
        Button(lang.t("删除", "Delete"), role: .destructive) {
            if let k = pendingDeleteGroup {
                dm.items.filter { $0.groupKey == k }.forEach { dm.delete($0.id) }
            }
            pendingDeleteGroup = nil
        }
    }
    }

    private func row(_ it: DownloadItem) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: VideoAPI.coverURL(it.cover))
                .frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(it.episodeName.isEmpty ? it.title : it.episodeName).font(.callout.weight(.medium))
                if it.state != .completed {
                    ProgressView(value: it.progress).frame(maxWidth: 320)
                }
                HStack(spacing: 8) {
                    Text(statusText(it)).font(.caption).foregroundStyle(statusColor(it))
                    if it.state == .downloading, let s = dm.speeds[it.id], s > 0 {
                        Text(formatSpeed(s)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if it.bytes > 0 {
                        Text(formatBytes(it.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if it.state == .completed {
                Button {
                    openWindow(id: "player", value: PlayPayload(
                        seriesTitle: it.seriesTitle, episodeName: it.episodeName,
                        episodeKey: it.episodeKey, sourceURL: it.sourceURL, cover: it.cover,
                        channelName: nil,
                        episodes: [EpisodeItem(number: "1", name: it.episodeName, url: it.episodeKey)],
                        playSource: "downloads"))
                } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
            } else if it.state == .paused || it.state == .failed {
                Button { dm.resume(it.id) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless)
            } else {
                Button { dm.pause(it.id) } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless)
            }
            Button { dm.delete(it.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.red)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(lang.t("在 Finder 中显示", "Show in Finder")) { dm.revealInFinder(it.id) }
            Button(lang.t("删除", "Delete"), role: .destructive) { dm.delete(it.id) }
        }
    }

    private func statusText(_ it: DownloadItem) -> String {
        switch it.state {
        case .queued:      return lang.t("排队中", "Queued")
        case .preparing:   return lang.t("解析中…", "Preparing…")
        case .downloading: return "\(Int(it.progress * 100))% · \(it.done)/\(it.total)"
        case .paused:      return lang.t("已暂停 \(Int(it.progress * 100))%", "Paused \(Int(it.progress * 100))%")
        case .completed:   return lang.t("已完成 · 可离线播放", "Completed · offline ready")
        case .failed:      return lang.t("失败：", "Failed: ") + (it.errorText ?? "")
        }
    }
    private func statusColor(_ it: DownloadItem) -> Color {
        switch it.state {
        case .completed: return .green
        case .failed:    return .red
        case .paused:    return .orange
        case .queued:    return .blue
        default:         return .secondary
        }
    }
}