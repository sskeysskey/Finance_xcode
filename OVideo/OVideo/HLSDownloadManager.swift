import Foundation
import SwiftUI
import AppKit
import Combine

struct DownloadItem: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, preparing, downloading, paused, completed, failed }
    var id: String
    var episodeKey: String       // 原始播放页 URL（解锁/去重判断）
    var mediaURL: String         // 解析后的 m3u8
    var title: String            // "剧名 · 第01集"
    var seriesTitle: String
    var episodeName: String
    var cover: String?
    var sourceURL: String?
    var folder: String
    var total: Int = 0
    var done: Int = 0
    var bytes: Int64 = 0
    var state: State = .queued
    var createdAt: Date = Date()
    var errorText: String?

    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var groupKey: String { seriesTitle.isEmpty ? "u:" + id : "s:" + seriesTitle }
}

/// 分片描述（Sendable，可安全跨并发边界传递）
private struct HLSSegment: Sendable {
    let url: URL
    let file: String
}

/// 纯网络工具：不属于任何 actor，保证下载不占用主线程
private enum HLSNet {
    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
                   forHTTPHeaderField: "User-Agent")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        return r
    }
    static func data(_ url: URL) async throws -> Data {
        let (d, resp) = try await URLSession.shared.data(for: request(url))
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
        return d
    }
    static func text(_ url: URL) async throws -> String {
        let d = try await data(url)
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }
}

/// m3u8 文本解析（纯函数，无隔离）
private enum M3U8 {
    static func pickVariant(_ text: String, base: URL) -> URL? {
        var best: (Int, URL)?
        let lines = text.components(separatedBy: .newlines)
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
            var bw = 0
            if let r = l.range(of: "BANDWIDTH=") {
                let tail = l[r.upperBound...].prefix { $0.isNumber }
                bw = Int(tail) ?? 0
            }
            var j = i + 1
            while j < lines.count,
                  lines[j].trimmingCharacters(in: .whitespaces).isEmpty || lines[j].hasPrefix("#") { j += 1 }
            guard j < lines.count,
                  let u = URL(string: lines[j].trimmingCharacters(in: .whitespaces),
                              relativeTo: base)?.absoluteURL else { continue }
            if best == nil || bw > best!.0 { best = (bw, u) }
        }
        return best?.1
    }
    static func extractURI(_ line: String) -> String? {
        guard let r = line.range(of: "URI=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<e])
    }
    static func replaceURI(_ line: String, with local: String) -> String {
        guard let uri = extractURI(line) else { return line }
        return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(local)\"")
    }
}

@MainActor
final class HLSDownloadManager: ObservableObject {
    static let shared = HLSDownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var speeds: [String: Double] = [:]

    private var running: Set<String> = []
    private var cancelFlags: Set<String> = []
    private var lastBytes: [String: Int64] = [:]
    private var activity: NSObjectProtocol?
    private var timer: Timer?

    private let maxConcurrentDownloads = 2
    private var maxSegmentConcurrency: Int {
        let v = UserDefaults.standard.integer(forKey: "GW_SegConcurrency")
        return max(2, min(12, v == 0 ? 6 : v))
    }

    // MARK: 路径（nonisolated，后台线程也能安全取）
    nonisolated private var rootDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "GWVideo")
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    nonisolated private var stateFile: URL { rootDir.appendingPathComponent("state.json") }
    nonisolated func folderURL(_ item: DownloadItem) -> URL { rootDir.appendingPathComponent(item.folder) }
    nonisolated func playlistURL(_ item: DownloadItem) -> URL { folderURL(item).appendingPathComponent("local.m3u8") }
    nonisolated var storageRoot: URL { rootDir }

    private init() {
        load()
        for i in items.indices where items[i].state == .downloading || items[i].state == .preparing {
            items[i].state = .queued
        }
        save()
        // ⭐ 先强绑定 self，再进 Task，避免「捕获的 weak self 在并发代码中被引用」
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pump()
    }

    // MARK: 查询
    func item(forEpisodeKey key: String) -> DownloadItem? { items.first { $0.episodeKey == key } }
    func isQueuedOrDone(_ key: String) -> Bool { item(forEpisodeKey: key) != nil }
    func localURL(forEpisodeKey key: String) -> URL? {
        guard let it = item(forEpisodeKey: key), it.state == .completed else { return nil }
        let u = playlistURL(it)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var completedKeys: Set<String> { Set(items.filter { $0.state == .completed }.map(\.episodeKey)) }
    var totalDiskUsage: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: 对外操作
    func start(episodeKey: String, mediaURL: String, title: String, seriesTitle: String,
               episodeName: String, cover: String?, sourceURL: String?) {
        if let i = items.firstIndex(where: { $0.episodeKey == episodeKey }) {
            if items[i].state == .paused || items[i].state == .failed {
                items[i].state = .queued; items[i].errorText = nil; save(); pump()
            }
            return
        }
        let it = DownloadItem(id: UUID().uuidString, episodeKey: episodeKey, mediaURL: mediaURL,
                              title: title, seriesTitle: seriesTitle, episodeName: episodeName,
                              cover: cover, sourceURL: sourceURL, folder: UUID().uuidString)
        items.append(it)
        try? FileManager.default.createDirectory(at: folderURL(it), withIntermediateDirectories: true)
        save(); pump()
        let id = AuthManager.shared.trackIdentity
        TrackingManager.shared.track(.downloadStart, userId: id.id, userType: id.type,
                                     videoURL: episodeKey, videoTitle: title)
    }

    func pause(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        cancelFlags.insert(id)
        items[i].state = .paused
        running.remove(id); speeds[id] = 0
        save(); pump()
    }
    func resume(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              items[i].state == .paused || items[i].state == .failed else { return }
        cancelFlags.remove(id)
        items[i].state = .queued; items[i].errorText = nil
        save(); pump()
    }
    func pauseAll() {
        items.filter { $0.state == .downloading || $0.state == .queued || $0.state == .preparing }
             .forEach { pause($0.id) }
    }
    func resumeAll() { items.filter { $0.state == .paused || $0.state == .failed }.forEach { resume($0.id) } }

    func delete(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        cancelFlags.insert(id); running.remove(id)
        try? FileManager.default.removeItem(at: folderURL(items[i]))
        items.remove(at: i)
        speeds[id] = nil; lastBytes[id] = nil
        save(); pump()
    }
    func revealInFinder(_ id: String) {
        guard let it = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL(it)])
    }

    // MARK: 调度
    private func pump() {
        updateActivity()
        while running.count < maxConcurrentDownloads,
              let next = items.first(where: { $0.state == .queued && !running.contains($0.id) }) {
            running.insert(next.id)
            let id = next.id
            Task { await self.run(id) }
        }
    }

    private func run(_ id: String) async {
        // run 本身在 MainActor 上，defer 直接同步执行即可
        defer {
            running.remove(id)
            speeds[id] = 0
            pump()
        }
        guard let it = items.first(where: { $0.id == id }) else { return }
        setState(id, .preparing)
        do {
            let segs = try await prepare(it)
            if cancelFlags.contains(id) { return }
            setState(id, .downloading)
            try await downloadSegments(id: id, folder: folderURL(it), segments: segs)
            if cancelFlags.contains(id) { return }
            setState(id, .completed)
            save()
            let ident = AuthManager.shared.trackIdentity
            TrackingManager.shared.track(.downloadComplete, userId: ident.id, userType: ident.type,
                                         videoURL: it.episodeKey, videoTitle: it.title)
        } catch is CancellationError {
            // 用户暂停
        } catch {
            if !cancelFlags.contains(id), let i = items.firstIndex(where: { $0.id == id }) {
                items[i].state = .failed
                items[i].errorText = error.localizedDescription
                save()
            }
        }
    }

    private func setState(_ id: String, _ s: DownloadItem.State) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = s; save()
    }

    private func setCounts(id: String, total: Int, done: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].total = total
        items[i].done = min(done, total)
        save()
    }

    private func isCancelled(_ id: String) -> Bool { cancelFlags.contains(id) }

    private func bump(_ id: String, bytes: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done = min(items[i].total, items[i].done + 1)
        items[i].bytes += bytes
    }

    // MARK: 准备：拉 m3u8 → 选码率 → 重写为本地播放列表（nonisolated，不卡 UI）
    nonisolated private func prepare(_ it: DownloadItem) async throws -> [HLSSegment] {
        let dir = folderURL(it)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("segments"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("keys"), withIntermediateDirectories: true)

        // 已准备过 → 直接读缓存清单（断点续传）
        let manifest = dir.appendingPathComponent("segments.json")
        if let d = try? Data(contentsOf: manifest),
           let arr = try? JSONDecoder().decode([[String]].self, from: d), !arr.isEmpty {
            let segs = arr.compactMap { p -> HLSSegment? in
                guard p.count == 2, let u = URL(string: p[0]) else { return nil }
                return HLSSegment(url: u, file: p[1])
            }
            if !segs.isEmpty {
                await setCounts(id: it.id, total: segs.count, done: Self.countExisting(dir, segs))
                return segs
            }
        }

        guard var playlistURL = URL(string: it.mediaURL) else { throw URLError(.badURL) }
        var text = try await HLSNet.text(playlistURL)

        // Master playlist → 选最高码率
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = M3U8.pickVariant(text, base: playlistURL) else { throw URLError(.cannotParseResponse) }
            playlistURL = variant
            text = try await HLSNet.text(playlistURL)
        }

        var out: [String] = []
        var segs: [HLSSegment] = []
        var urlToFile: [String: String] = [:]
        var keyIdx = 0, mapIdx = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-KEY"), let uri = M3U8.extractURI(line),
                   let abs = URL(string: uri, relativeTo: playlistURL)?.absoluteURL {
                    let name = "keys/key_\(keyIdx).key"; keyIdx += 1
                    let data = try await HLSNet.data(abs)
                    try data.write(to: dir.appendingPathComponent(name))
                    out.append(M3U8.replaceURI(line, with: name))
                } else if line.hasPrefix("#EXT-X-MAP"), let uri = M3U8.extractURI(line),
                          let abs = URL(string: uri, relativeTo: playlistURL)?.absoluteURL {
                    let ext = abs.pathExtension.isEmpty ? "mp4" : abs.pathExtension
                    let name = "segments/init_\(mapIdx).\(ext)"; mapIdx += 1
                    let data = try await HLSNet.data(abs)
                    try data.write(to: dir.appendingPathComponent(name))
                    out.append(M3U8.replaceURI(line, with: name))
                } else if line.hasPrefix("#EXT-X-ENDLIST") {
                    continue
                } else {
                    out.append(line)
                }
                continue
            }
            guard let abs = URL(string: line, relativeTo: playlistURL)?.absoluteURL else { continue }
            if let existing = urlToFile[abs.absoluteString] {
                out.append(existing)
            } else {
                let ext = abs.pathExtension.isEmpty ? "ts" : abs.pathExtension
                let name = String(format: "segments/%05d.%@", segs.count, ext)
                urlToFile[abs.absoluteString] = name
                segs.append(HLSSegment(url: abs, file: name))
                out.append(name)
            }
        }

        guard !segs.isEmpty else { throw URLError(.zeroByteResource) }
        if !out.contains(where: { $0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }) {
            if let i = out.firstIndex(where: { $0.hasPrefix("#EXT-X-TARGETDURATION") }) {
                out.insert("#EXT-X-PLAYLIST-TYPE:VOD", at: i + 1)
            } else { out.insert("#EXT-X-PLAYLIST-TYPE:VOD", at: min(1, out.count)) }
        }
        out.append("#EXT-X-ENDLIST")
        try out.joined(separator: "\n").write(to: dir.appendingPathComponent("local.m3u8"),
                                              atomically: true, encoding: .utf8)
        let dump = segs.map { [$0.url.absoluteString, $0.file] }
        try JSONEncoder().encode(dump).write(to: manifest)

        await setCounts(id: it.id, total: segs.count, done: Self.countExisting(dir, segs))
        return segs
    }

    nonisolated private static func countExisting(_ dir: URL, _ segs: [HLSSegment]) -> Int {
        segs.reduce(0) { acc, s in
            let p = dir.appendingPathComponent(s.file).path
            let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            let sz = (attrs?[.size] as? Int) ?? 0     // ⭐ 修复多余的 ??
            return acc + (sz > 0 ? 1 : 0)
        }
    }

    // MARK: 分片并发下载（滑动窗口）
    private func downloadSegments(id: String, folder: URL, segments: [HLSSegment]) async throws {
        let limit = maxSegmentConcurrency
        var next = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            while next < segments.count, next < limit {
                let seg = segments[next]; next += 1
                group.addTask { try await self.processSegment(id: id, folder: folder, seg: seg) }
            }
            while try await group.next() != nil {
                if isCancelled(id) { group.cancelAll(); throw CancellationError() }   // ⭐ 去掉多余 await
                if next < segments.count {
                    let seg = segments[next]; next += 1
                    group.addTask { try await self.processSegment(id: id, folder: folder, seg: seg) }
                }
            }
        }
    }

    nonisolated private func processSegment(id: String, folder: URL, seg: HLSSegment) async throws {
        if await isCancelled(id) { throw CancellationError() }
        let fm = FileManager.default
        let dest = folder.appendingPathComponent(seg.file)
        if let attrs = try? fm.attributesOfItem(atPath: dest.path),
           let sz = attrs[.size] as? Int, sz > 0 {
            return                                   // 已存在（续传时已计入 done）
        }
        var lastErr: Error?
        for attempt in 0..<3 {
            if await isCancelled(id) { throw CancellationError() }
            do {
                let data = try await HLSNet.data(seg.url)
                try data.write(to: dest, options: .atomic)
                await bump(id, bytes: Int64(data.count))
                return
            } catch {
                lastErr = error
                try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
            }
        }
        throw lastErr ?? URLError(.unknown)
    }

    // MARK: 每秒 tick：测速 + 持久化
    private func tick() {
        for it in items where it.state == .downloading {
            let prev = lastBytes[it.id] ?? it.bytes
            speeds[it.id] = Double(max(0, it.bytes - prev))
            lastBytes[it.id] = it.bytes
        }
        if items.contains(where: { $0.state == .downloading }) { save(throttled: true) }
        updateActivity()
    }

    /// 下载时禁止 App Nap 与系统休眠
    private func updateActivity() {
        let busy = items.contains { $0.state == .downloading || $0.state == .preparing }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading video")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    // MARK: 持久化
    private var lastSave = Date.distantPast
    private func save(throttled: Bool = false) {
        if throttled, Date().timeIntervalSince(lastSave) < 2 { return }
        lastSave = Date()
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: stateFile, options: .atomic) }
    }
    private func load() {
        guard let d = try? Data(contentsOf: stateFile),
              let a = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return }
        items = a
    }
}