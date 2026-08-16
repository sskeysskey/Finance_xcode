import SwiftUI
import AVKit
import Combine

struct PlayPayload: Codable, Hashable, Identifiable {
    var id: String { episodeKey }
    var seriesTitle: String
    var episodeName: String
    var episodeKey: String
    var sourceURL: String?
    var cover: String?
    var channelName: String?
    var episodes: [EpisodeItem]
    var playSource: String?
}

enum SpeedStore {
    private static let key = "GW_PlaybackRate"
    static var rate: Float {
        get { let v = UserDefaults.standard.float(forKey: key); return (v > 0 && v <= 3) ? v : 1 }
        set { UserDefaults.standard.set(min(max(newValue, 0.5), 3), forKey: key) }
    }
}

enum PositionStore {
    private static func k(_ s: String) -> String { "GW_Pos_" + s }
    static func save(_ sec: Double, _ key: String) {
        guard sec > 5 else { return }
        UserDefaults.standard.set(sec, forKey: k(key))
    }
    static func load(_ key: String) -> Double { UserDefaults.standard.double(forKey: k(key)) }
    static func clear(_ key: String) { UserDefaults.standard.removeObject(forKey: k(key)) }
}

/// AVPlayerView 包装（不要加 clipShape / mask，会破坏交互）
struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        v.videoGravity = .resizeAspect
        if #available(macOS 13.0, *) { v.allowsVideoFrameAnalysis = false }
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var loading = true
    @Published var error: String?
    @Published var current: EpisodeItem?
    @Published var isLocal = false

    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    var payload: PlayPayload?
    var onEnded: (() -> Void)?

    func load(payload p: PlayPayload, episode: EpisodeItem) async {
        payload = p; current = episode
        loading = true; error = nil
        teardown()

        var target: URL?
        if let local = HLSDownloadManager.shared.localURL(forEpisodeKey: episode.url) {
            target = local; isLocal = true
        } else {
            isLocal = false
            do {
                let real = try await VideoAPI.resolveRealURL(episodeURL: episode.url)
                target = URL(string: real)
            } catch {
                self.error = error.localizedDescription
                self.loading = false
                return
            }
        }
        guard let url = target else {
            error = T("无法播放", "Unable to play"); loading = false; return
        }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if !isLocal { item.preferredForwardBufferDuration = 10 }
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = !isLocal

        let key = episode.url

        // ⭐ 先强绑定 self，再进 Task：避免「并发代码引用 weak 捕获」
        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            guard let self else { return }
            let status = observed.status
            let errText = observed.error?.localizedDescription
            Task { @MainActor in
                self.handleStatus(status, errorText: errText, episodeKey: key)
            }
        }

        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                                                 queue: .main) { t in
            PositionStore.save(t.seconds, key)
        }

        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                PositionStore.clear(key)
                self.onEnded?()
            }
        }
        recordPlayback(p, episode)
    }

    private func handleStatus(_ status: AVPlayerItem.Status, errorText: String?, episodeKey: String) {
        switch status {
        case .readyToPlay:
            loading = false
            let saved = PositionStore.load(episodeKey)
            if saved > 5 {
                player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))   // ⭐ 同步版本，避免 async 重载问题
            }
            player.play()
            player.rate = SpeedStore.rate
        case .failed:
            loading = false
            error = errorText ?? T("播放失败", "Playback failed")
        default:
            break
        }
    }

    private func recordPlayback(_ p: PlayPayload, _ ep: EpisodeItem) {
        let ident = AuthManager.shared.trackIdentity
        TrackingManager.shared.track(.play, userId: ident.id, userType: ident.type,
                                     videoURL: ep.url,
                                     videoTitle: "\(p.seriesTitle) · \(ep.name)",
                                     source: p.playSource)
        PlayRecordStore.shared.add(title: p.seriesTitle, episode: ep.name, url: ep.url,
                                   cover: p.cover, channel: p.channelName, source: p.sourceURL)
        SeriesTrackManager.shared.recordWatch(sourceURL: p.sourceURL, title: p.seriesTitle,
                                             cover: p.cover, episodeName: ep.name,
                                             channelName: p.channelName)
    }

    func setRate(_ r: Float) {
        SpeedStore.rate = r
        if player.timeControlStatus == .playing { player.rate = r }
    }
    func togglePlay() { player.timeControlStatus == .playing ? player.pause() : player.play() }
    func stop() { player.pause(); teardown(); player.replaceCurrentItem(with: nil) }

    private func teardown() {
        if let t = timeObs { player.removeTimeObserver(t); timeObs = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        statusObs?.invalidate(); statusObs = nil
    }
    // ⚠️ 不再写 deinit：@MainActor 类的 deinit 访问隔离属性在 Swift 6 是错误；
    //    视图 onDisappear 会调用 stop() 完成清理。
}

struct PlayerWindowView: View {
    let payload: PlayPayload
    @StateObject private var model = PlayerModel()
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject private var quota = QuotaManager.shared
    @AppStorage("GW_AutoNext") private var autoNext = true
    @State private var showEpisodes = false
    @State private var showReport = false
    @State private var pendingEp: EpisodeItem?
    @State private var showConsume = false
    @State private var showSubscribe = false
    @State private var rate: Float = SpeedStore.rate

    private var currentIndex: Int {
        payload.episodes.firstIndex(where: { $0.url == model.current?.url }) ?? 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MacPlayerView(player: model.player)
                .ignoresSafeArea()

            if model.loading {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let e = model.error {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40)).foregroundStyle(.orange)
                    Text(e).foregroundStyle(.white)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    HStack {
                        Button(lang.t("重试", "Retry")) {
                            if let c = model.current {
                                Task { await model.load(payload: payload, episode: c) }
                            }
                        }
                        Button(lang.t("反馈修复", "Report")) { showReport = true }
                    }
                }
                .padding(24)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .navigationTitle("\(payload.seriesTitle) · \(model.current?.name ?? payload.episodeName)")
        .toolbar {
            ToolbarItemGroup {
                if payload.episodes.count > 1 {
                    Button { showEpisodes = true } label: {
                        Label(lang.t("选集", "Episodes"), systemImage: "list.bullet")
                    }
                    .popover(isPresented: $showEpisodes) { episodePopover }

                    Button { jump(-1) } label: { Image(systemName: "backward.end.fill") }
                        .disabled(currentIndex <= 0)
                        .keyboardShortcut("[", modifiers: .command)
                    Button { jump(1) } label: { Image(systemName: "forward.end.fill") }
                        .disabled(currentIndex >= payload.episodes.count - 1)
                        .keyboardShortcut("]", modifiers: .command)
                }

                Button { model.togglePlay() } label: { Image(systemName: "playpause.fill") }
                    .keyboardShortcut("p", modifiers: .command)
                    .help(lang.t("播放 / 暂停 (⌘P)", "Play / Pause (⌘P)"))

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                        Button {
                            model.setRate(Float(r)); rate = Float(r)
                        } label: {
                            HStack {
                                Text("\(r, specifier: "%g")x")
                                if abs(rate - Float(r)) < 0.01 { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Divider()
                    Toggle(lang.t("播完自动下一集", "Auto play next"), isOn: $autoNext)
                } label: {
                    Label("\(rate, specifier: "%g")x", systemImage: "speedometer")
                }

                if model.isLocal {
                    Label(lang.t("离线", "Offline"), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                }
                Button { showReport = true } label: {
                    Label(lang.t("反馈修复", "Report"), systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .task {
            let ep = payload.episodes.first(where: { $0.url == payload.episodeKey })
                ?? EpisodeItem(number: "1", name: payload.episodeName, url: payload.episodeKey)
            model.onEnded = { if autoNext { jump(1) } }

            if HLSDownloadManager.shared.localURL(forEpisodeKey: ep.url) != nil {
                await model.load(payload: payload, episode: ep)
            } else {
                select(ep)
            }
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showReport) {
            ReportSheet(title: "\(payload.seriesTitle) · \(model.current?.name ?? "")",
                        sourceURL: payload.sourceURL ?? payload.episodeKey,
                        episodeURL: model.current?.url ?? payload.episodeKey,
                        channel: payload.channelName, episode: model.current?.name,
                        realURL: nil)
        }
        .sheet(isPresented: $showSubscribe) { SubscriptionView() }
        .alert(lang.t("使用免费点数", "Use 1 Free Pass"), isPresented: $showConsume) {
            Button(lang.t("取消", "Cancel"), role: .cancel) { pendingEp = nil }
            Button(lang.t("确认使用", "Confirm")) { Task { await consumeAndPlay() } }
        } message: {
            Text(quota.consumeNote(lang.isEnglish) + "\n" + quota.remainingSummary(lang.isEnglish))
        }
    }

    private var episodePopover: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                ForEach(payload.episodes) { ep in
                    let isCur = ep.url == model.current?.url
                    let cached = HLSDownloadManager.shared.completedKeys.contains(ep.url)
                    Button {
                        showEpisodes = false; select(ep)
                    } label: {
                        Text(ep.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(isCur ? Color.accentColor.opacity(0.85)
                                              : Color.secondary.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(isCur ? .white : .primary)
                            .overlay(alignment: .topTrailing) {
                                if cached {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 9)).foregroundStyle(.blue).padding(2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 380, height: 300)
    }

    private func jump(_ delta: Int) {
        let i = currentIndex + delta
        guard i >= 0, i < payload.episodes.count else { return }
        select(payload.episodes[i])
    }

    private func select(_ ep: EpisodeItem) {
        if HLSDownloadManager.shared.localURL(forEpisodeKey: ep.url) != nil {
            Task { await model.load(payload: payload, episode: ep) }
            return
        }
        switch decideAccess(episodeKey: ep.url, auth: auth, quota: quota) {
        case .allowed:      Task { await model.load(payload: payload, episode: ep) }
        case .needLogin:    auth.signInWithApple()
        case .needConsume:  pendingEp = ep; showConsume = true
        case .exhausted:    showSubscribe = true
        }
    }

    private func consumeAndPlay() async {
        guard let ep = pendingEp else { return }
        let uid = QuotaManager.currentUserId(auth: auth)
        let r = await quota.unlock(userId: uid, episodeKey: ep.url,
                                  title: "\(payload.seriesTitle) · \(ep.name)")
        switch r {
        case .success, .alreadyUnlocked: await model.load(payload: payload, episode: ep)
        default: showSubscribe = true
        }
        pendingEp = nil
    }
}