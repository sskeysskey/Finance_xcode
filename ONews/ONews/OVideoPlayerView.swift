// /Users/yanzhang/Coding/Xcode/ONews/ONews/OVideoPlayerView.swift

import SwiftUI
import AVKit
import MediaPlayer
import CoreMedia   // ⭐ kCMMetadataBaseDataType_JPEG

// MARK: - ⭐️ 主线程跳板
// 所有来自系统（KVO / AVFoundation / UIKit / NotificationCenter）的回调都先过这里。
// ⚠️ 本文件所有类刻意「不加 @MainActor」：加了之后系统回调闭包会被隐式推断成
//    MainActor 隔离，一旦系统从别的线程回调就会触发
//    "Incorrect actor executor assumption" 直接崩溃（点全屏必崩的真凶）。
@inline(__always)
private func onMainThread(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}

// MARK: - ⭐ 扣点服务：在线播放「真正开始播放」/ 下载「真正下载成功」后才扣点
enum VideoChargeOutcome: Equatable {
    case charged          // 已扣点 / 已解锁 / 会员无需扣点
    case quotaExceeded    // 服务器明确返回点数不足
    case failed           // 网络等原因暂时扣不了
}

@MainActor
enum VideoChargeService {
    /// 扣 1 点（同集当天已解锁 / 会员 → 直接视为成功）。网络失败自动重试 3 次
    static func charge(episodeKey: String, title: String, auth: AuthManager) async -> VideoChargeOutcome {
        let quota = FreeQuotaManager.shared
        if auth.isSubscribed || auth.isPermanentVIP || quota.isUnlocked(episodeKey) { return .charged }
        let uid = FreeQuotaManager.currentUserId(auth: auth)
        for attempt in 0..<3 {
            let r = await quota.unlock(userId: uid, episodeKey: episodeKey, videoTitle: title)
            switch r {
            case .success, .alreadyUnlocked:
                return .charged
            case .quotaExceeded:
                return .quotaExceeded
            case .failed:
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
                }
            }
        }
        return .failed
    }

    static func playNote(english: Bool) -> String {
        english ? "The pass is only used once the video actually starts playing. No charge if it fails to play."
                : "视频真正开始播放后才扣点，未能播放不扣点"
    }

    static func downloadNote(english: Bool) -> String {
        english ? "Passes are only used after the download completes. No charge if it fails or is canceled."
                : "下载成功后才扣点，下载失败或取消不扣点"
    }
}

// MARK: - 倍速记忆
enum PlaybackSpeedStore {
    private static let key = "ONews_PlaybackSpeed"
    static var rate: Float {
        get {
            let v = UserDefaults.standard.float(forKey: key)
            return (v > 0 && v <= 2.0) ? v : 1.0
        }
        set {
            let clamped = min(max(newValue, 0.5), 2.0)
            UserDefaults.standard.set(clamped, forKey: key)
        }
    }
}

// MARK: - 播放进度记忆（LRU）
enum PlaybackPositionStore {
    private static let prefix = "ONews_Pos_"
    private static let indexKey = "ONews_PosIndex"
    private static let maxEntries = 300

    private static func storageKey(_ raw: String) -> String { prefix + raw }

    static func save(_ seconds: Double, forKey raw: String) {
        guard seconds.isFinite, seconds > 0, !raw.isEmpty else { return }
        let d = UserDefaults.standard
        let k = storageKey(raw)
        d.set(seconds, forKey: k)

        var index = d.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == k }
        index.append(k)
        if index.count > maxEntries {
            let overflow = index.count - maxEntries
            for old in index.prefix(overflow) { d.removeObject(forKey: old) }
            index.removeFirst(overflow)
        }
        d.set(index, forKey: indexKey)
    }

    static func load(forKey raw: String) -> Double {
        guard !raw.isEmpty else { return 0 }
        return UserDefaults.standard.double(forKey: storageKey(raw))
    }

    static func clear(forKey raw: String) {
        guard !raw.isEmpty else { return }
        let d = UserDefaults.standard
        let k = storageKey(raw)
        d.removeObject(forKey: k)
        var index = d.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == k }
        d.set(index, forKey: indexKey)
    }

    static func save(_ seconds: Double, for url: URL) { save(seconds, forKey: url.absoluteString) }
    static func load(for url: URL) -> Double { load(forKey: url.absoluteString) }
    static func clear(for url: URL) { clear(forKey: url.absoluteString) }
}

// MARK: - 广告防骗固定提示条
struct AdWarningBanner: View {
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
            Text(isGlobalEnglishMode
                 ? "Ads in the video are NOT from our platform. Do not tap them, to avoid being scammed."
                 : "视频内广告链接非本平台植入，切勿点击，防止被骗")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - ⭐️ 统一播放引擎（只在主线程访问；系统回调统一经 onMainThread 跳板）
final class OVideoPlayerEngine: ObservableObject, @unchecked Sendable {

    enum Phase: Equatable { case idle, loading, playing, buffering, paused, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var showBusySpinner = false
    @Published private(set) var slowNetwork = false
    @Published private(set) var offerManualRetry = false
    @Published private(set) var hasStartedPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var errorText: String?
    @Published private(set) var playerGeneration = 0
    @Published private(set) var controlsRefreshToken = 0
    /// ⭐ 「画面连续真实走动 ≥ confirmSeconds」后被设为当前 positionKey（扣点 / 追剧追平的唯一依据）
    @Published private(set) var playbackConfirmedKey: String?

    /// ⚠️ 刻意不是 @Published：AVKit 全屏转场中改这两个值绝不能触发 SwiftUI 重新布局
    var isFullScreen = false
    var isPiPActive = false
    /// ⭐ 宿主页面是否可见。页面已离开时，异步解析回来的 prepare 只记住会话，不真正播放
    var hostVisible = true

    private(set) var player = AVPlayer()
    var resolver: (@Sendable () async throws -> String)?

    private(set) var isLocal = false
    private(set) var currentAssetURL: URL?
    private var positionKey = ""

    // ⭐ 拆除 / 复活：拆除后引擎进入「冬眠」，任何系统回调都不得把它唤醒
    private struct LastSession {
        let url: URL
        let key: String
        let isLocal: Bool
        let wasPlaying: Bool
    }
    private(set) var isTornDown = false
    private var lastSession: LastSession?
    private var autoPlayWhenReady = true

    // ⭐ 扣点失败时冻结播放（拦截 AVKit 播放键）
    private(set) var playbackHold = false

    // ⭐ 播放确认
    private var confirmAnchor: Double?
    private let confirmSeconds: Double = 2.0

    // 锁屏 / 控制中心元数据
    private var npTitle: String?
    private var npSubtitle: String?
    private var npArtworkSource: String?
    private var npArtworkData: Data?
    private var artworkTask: Task<Void, Never>?
    private static let artworkCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 20
        return c
    }()

    private var currentTime: Double = 0
    private var duration: Double = 0
    private var lastSaved: Double = -100
    private var pendingStart: Double?
    private var wasPlayingBeforeBackground = true

    // KVO
    private var statusObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var keepUpObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var waitObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var defaultRateObs: NSKeyValueObservation?
    private var periodicObs: Any?
    private var itemNotes: [NSObjectProtocol] = []

    // 监督器
    private var supervisor: Timer?
    private var busySince: Date?
    private var didAutoRecoverForThisBusy = false
    private var recoveryAttempts = 0
    private var lastRecoveryAt = Date.distantPast
    private var isRecovering = false
    private var lastProgressTime: Double = -1
    private var lastProgressAt = Date()

    // ⭐ 网络活动探测（"数据还在进来就耐心等"，这是下载能成而播放失败的关键差异）
    private var lastActivityAt = Date()
    private var lastLoadedEnd: Double = 0
    private var lastAccessBytes: Int64 = 0
    private var activityTick = 0

    // ⭐ 码率降级：每次硬重载降一档，先播起来再说
    private var peakBitRateStep = 0
    private static let peakBitRates: [Double] = [0, 2_500_000, 1_200_000]

    private let spinnerDelay: TimeInterval        = 0.35
    private let slowHintDelay: TimeInterval       = 6
    private let autoRecoverIdle: TimeInterval     = 12    // 连续 12s 一个字节都没进来 → 自愈
    private let autoRecoverCeiling: TimeInterval  = 40    // 或总忙碌 40s
    private let manualRetryIdle: TimeInterval     = 25
    private let manualRetryCeiling: TimeInterval  = 75
    private let localRecoverDelay: TimeInterval   = 8
    private let localManualDelay: TimeInterval    = 20
    private let networkForwardBuffer: TimeInterval = 10

    private var isEnglish: Bool { UserDefaults.standard.bool(forKey: "isGlobalEnglishMode") }

    init() {
        attachPlayerObservers()
        registerLifecycleObservers()
        startSupervisor()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for n in itemNotes { NotificationCenter.default.removeObserver(n) }
        supervisor?.invalidate()
        artworkTask?.cancel()
        if let t = periodicObs { player.removeTimeObserver(t) }
        statusObs?.invalidate(); bufferEmptyObs?.invalidate(); keepUpObs?.invalidate()
        tcsObs?.invalidate(); waitObs?.invalidate()
        rateObs?.invalidate(); defaultRateObs?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private static let audioQueue = DispatchQueue(label: "ovideo.audiosession", qos: .userInitiated)

    private func configureAudioSession() {
        Self.audioQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }

    // MARK: 锁屏元数据
    func setNowPlaying(title: String, subtitle: String?, artwork: String?) {
        npTitle = title
        npSubtitle = subtitle
        let art = (artwork?.isEmpty == false) ? artwork : nil
        if art != npArtworkSource {
            npArtworkSource = art
            npArtworkData = nil
            loadArtwork()
        }
        if let item = player.currentItem { applyNowPlayingMetadata(to: item) }
    }

    private func loadArtwork() {
        artworkTask?.cancel(); artworkTask = nil
        guard let src = npArtworkSource else { return }
        if let cached = OVideoPlayerEngine.artworkCache.object(forKey: src as NSString) {
            npArtworkData = cached as Data
            return
        }
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            guard let data = await OVideoPlayerEngine.fetchArtworkData(src), !Task.isCancelled else { return }
            OVideoPlayerEngine.artworkCache.setObject(data as NSData, forKey: src as NSString)
            onMainThread {
                guard let self = self, self.npArtworkSource == src, !self.isTornDown else { return }
                self.npArtworkData = data
                if let item = self.player.currentItem { self.applyNowPlayingMetadata(to: item) }
            }
        }
    }

    private static func fetchArtworkData(_ src: String) async -> Data? {
        var raw: Data?
        if src.hasPrefix("/") {
            raw = FileManager.default.contents(atPath: src)
        } else if let u = URL(string: src) {
            if u.isFileURL {
                raw = try? Data(contentsOf: u)
            } else if u.scheme?.lowercased().hasPrefix("http") == true {
                let req = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
                raw = try? await URLSession.shared.data(for: req).0
            }
        }
        guard let raw = raw, let img = UIImage(data: raw) else { return nil }
        let longest = max(img.size.width, img.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 600 / longest)
        let size = CGSize(width: floor(img.size.width * scale), height: floor(img.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: 0.85)
    }

    private func applyNowPlayingMetadata(to item: AVPlayerItem) {
        guard let title = npTitle, !title.isEmpty else { return }
        var list: [AVMetadataItem] = [Self.metadataItem(.commonIdentifierTitle, title as NSString)]
        if let sub = npSubtitle, !sub.isEmpty {
            list.append(Self.metadataItem(.iTunesMetadataTrackSubTitle, sub as NSString))
            list.append(Self.metadataItem(.commonIdentifierArtist, sub as NSString))
        }
        if let d = npArtworkData {
            list.append(Self.metadataItem(.commonIdentifierArtwork, d as NSData,
                                          dataType: kCMMetadataBaseDataType_JPEG as String))
        }
        item.externalMetadata = list
    }

    private static func metadataItem(_ id: AVMetadataIdentifier,
                                     _ value: NSCopying & NSObjectProtocol,
                                     dataType: String? = nil) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value
        m.extendedLanguageTag = "und"
        if let dataType = dataType { m.dataType = dataType }
        return (m.copy() as? AVMetadataItem) ?? m
    }

    private func currentPeakBitRate() -> Double {
        Self.peakBitRates[min(peakBitRateStep, Self.peakBitRates.count - 1)]
    }

    // MARK: 准备播放
    func prepare(url: URL,
                 positionKey: String,
                 isLocal: Bool,
                 resolver: (@Sendable () async throws -> String)? = nil,
                 startAt: Double? = nil,
                 resetRecovery: Bool = true,
                 autoPlay: Bool = true) {

        if !hostVisible {
            if resolver != nil { self.resolver = resolver }
            lastSession = LastSession(url: url, key: positionKey, isLocal: isLocal, wasPlaying: autoPlay)
            return
        }
        teardownItemObservers()

        isTornDown = false
        autoPlayWhenReady = autoPlay
        playbackHold = false
        configureAudioSession()

        self.currentAssetURL = url
        self.positionKey = positionKey
        self.isLocal = isLocal
        if resolver != nil { self.resolver = resolver }

        errorText = nil
        isPreparing = true
        hasStartedPlaying = false
        if playbackConfirmedKey != nil { playbackConfirmedKey = nil }
        confirmAnchor = nil
        currentTime = startAt ?? 0
        duration = 0
        lastSaved = -100
        pendingStart = startAt
        lastProgressTime = -1
        lastProgressAt = Date()
        busySince = Date()
        lastActivityAt = Date()
        lastLoadedEnd = 0
        lastAccessBytes = 0
        didAutoRecoverForThisBusy = false
        offerManualRetry = false
        slowNetwork = false
        showBusySpinner = true
        if resetRecovery { recoveryAttempts = 0; peakBitRateStep = 0 }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if !isLocal {
            item.preferredForwardBufferDuration = networkForwardBuffer
            item.preferredPeakBitRate = currentPeakBitRate()
        }
        applyNowPlayingMetadata(to: item)

        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = !isLocal
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        if #available(iOS 16.0, *) { player.defaultRate = PlaybackSpeedStore.rate }

        player.replaceCurrentItem(with: item)
        attachItemObservers(item)
        recomputePhase()
    }

    func beginSwitching() {
        player.pause()
        saveProgress()
        errorText = nil
        isPreparing = true
        showBusySpinner = true
        busySince = Date()
        lastActivityAt = Date()
        didAutoRecoverForThisBusy = false
        offerManualRetry = false
        slowNetwork = false
        recomputePhase()
    }

    // MARK: ⭐ 扣点冻结
    func holdPlayback() {
        playbackHold = true
        player.pause()
        saveProgress()
    }

    func releaseHold(resume: Bool) {
        guard playbackHold else { return }
        playbackHold = false
        if resume, !isTornDown, player.currentItem != nil { playAtPreferredRate() }
    }

    // MARK: Player 级监听
    private func attachPlayerObservers() {
        tcsObs = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] _, _ in
            onMainThread { self?.recomputePhase() }
        }
        waitObs = player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
            onMainThread { self?.recomputePhase() }
        }
        rateObs = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            if let r = change.newValue, r > 0, r <= 2.0 { PlaybackSpeedStore.rate = r }
            if let r = change.newValue, r > 0 {
                onMainThread {
                    guard let self = self, self.playbackHold else { return }
                    self.player.pause()           // ⭐ 冻结期间 AVKit 播放键也无效
                }
            }
        }
        if #available(iOS 16.0, *) {
            defaultRateObs = player.observe(\.defaultRate, options: [.new]) { _, change in
                if let r = change.newValue, r > 0, r <= 2.0 { PlaybackSpeedStore.rate = r }
            }
        }
        periodicObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main) { [weak self] t in
                self?.tick(t.seconds)
            }
    }

    private func teardownPlayerObservers() {
        if let t = periodicObs { player.removeTimeObserver(t); periodicObs = nil }
        tcsObs?.invalidate(); tcsObs = nil
        waitObs?.invalidate(); waitObs = nil
        rateObs?.invalidate(); rateObs = nil
        defaultRateObs?.invalidate(); defaultRateObs = nil
    }

    // MARK: Item 级监听
    private func attachItemObservers(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            let s = observed.status
            let msg = observed.error?.localizedDescription
            onMainThread { self?.handleStatus(s, message: msg) }
        }
        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            onMainThread { self?.recomputePhase() }
        }
        keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            onMainThread { self?.recomputePhase() }
        }

        let nc = NotificationCenter.default
        let key = positionKey

        itemNotes.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                        object: item, queue: .main) { [weak self] _ in
            PlaybackPositionStore.clear(forKey: key)
            self?.recomputePhase()
        })

        itemNotes.append(nc.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                        object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isLocal { self.recoverNow(hard: false) } else { self.recomputePhase() }
        })

        itemNotes.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                        object: item, queue: .main) { [weak self] note in
            guard let self = self else { return }
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            if self.recoveryAttempts < 2 {
                self.recoverNow(hard: true)
            } else {
                self.fail(with: msg ?? (self.isEnglish ? "Playback interrupted" : "播放中断"))
            }
        })
    }

    private func teardownItemObservers() {
        statusObs?.invalidate(); statusObs = nil
        bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
        keepUpObs?.invalidate(); keepUpObs = nil
        for n in itemNotes { NotificationCenter.default.removeObserver(n) }
        itemNotes.removeAll()
    }

    private func handleStatus(_ status: AVPlayerItem.Status, message: String?) {
        guard !isTornDown else { return }
        switch status {
        case .readyToPlay:
            isPreparing = false
            if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }

            let saved = PlaybackPositionStore.load(forKey: positionKey)
            var start = pendingStart ?? (saved > 5 ? saved : 0)
            pendingStart = nil
            if duration > 0, start > duration - 10 { start = 0 }
            if start > 1 {
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                currentTime = start
            }
            if autoPlayWhenReady {
                playAtPreferredRate()
            } else {
                autoPlayWhenReady = true
            }
            recomputePhase()

        case .failed:
            if !isLocal, recoveryAttempts < 2 {
                recoverNow(hard: true)
            } else {
                fail(with: message ?? (isEnglish ? "Playback failed" : "视频播放失败"))
            }

        default:
            recomputePhase()
        }
    }

    private func fail(with msg: String) {
        isPreparing = false
        errorText = msg
        resetBusyFlags()
        recomputePhase()
    }

    private func playAtPreferredRate() {
        guard !playbackHold else { return }
        if #available(iOS 16.0, *) {
            player.defaultRate = PlaybackSpeedStore.rate
            player.play()
        } else {
            player.play()
            let r = PlaybackSpeedStore.rate
            if r != 1.0 { player.rate = r }
        }
    }

    // MARK: 状态机
    private func recomputePhase() {
        if isTornDown {
            if phase != .idle { phase = .idle }
            if isBuffering { isBuffering = false }
            return
        }

        let newPhase: Phase
        if errorText != nil {
            newPhase = .failed
        } else if isPreparing {
            newPhase = .loading
        } else {
            switch player.timeControlStatus {
            case .playing:                          newPhase = .playing
            case .waitingToPlayAtSpecifiedRate:     newPhase = .buffering
            case .paused:                           newPhase = .paused
            @unknown default:                       newPhase = .paused
            }
        }

        if phase != newPhase { phase = newPhase }
        if newPhase == .playing, !hasStartedPlaying { hasStartedPlaying = true }

        let b = (newPhase == .buffering)
        if isBuffering != b { isBuffering = b }

        if !b, !isPreparing { resetBusyFlags() }
    }

    private var isBusyNow: Bool { errorText == nil && (isPreparing || phase == .buffering) }

    private func resetBusyFlags() {
        busySince = nil
        didAutoRecoverForThisBusy = false
        if showBusySpinner { showBusySpinner = false }
        if slowNetwork { slowNetwork = false }
        if offerManualRetry { offerManualRetry = false }
    }

    // MARK: 监督器（0.5s / 主线程 RunLoop）
    private func startSupervisor() {
        supervisor?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.supervisorTick()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        supervisor = t
    }

    /// ⭐ 采样"数据是否还在进来"：已缓冲区间在增长 / accessLog 字节数在增长
    private func sampleNetworkActivity(_ now: Date) {
        guard let item = player.currentItem else { return }
        var end = 0.0
        for v in item.loadedTimeRanges {
            let e = CMTimeGetSeconds(CMTimeRangeGetEnd(v.timeRangeValue))
            if e.isFinite { end = max(end, e) }
        }
        if end > lastLoadedEnd + 0.05 { lastActivityAt = now }
        lastLoadedEnd = end

        activityTick &+= 1
        if activityTick % 2 == 0, let log = item.accessLog() {
            var bytes: Int64 = 0
            for ev in log.events where ev.numberOfBytesTransferred > 0 { bytes += ev.numberOfBytesTransferred }
            if bytes > lastAccessBytes { lastActivityAt = now }
            lastAccessBytes = bytes
        }
    }

    private func supervisorTick() {
        guard !isTornDown, errorText == nil else { return }

        if isBusyNow {
            let now = Date()
            if busySince == nil {
                busySince = now
                didAutoRecoverForThisBusy = false
                lastActivityAt = now
            }
            sampleNetworkActivity(now)
            let since = busySince ?? now
            let e = now.timeIntervalSince(since)
            let idle = now.timeIntervalSince(max(since, lastActivityAt))

            if e >= spinnerDelay, !showBusySpinner { showBusySpinner = true }
            if e >= slowHintDelay, !slowNetwork, !isLocal { slowNetwork = true }

            // ⭐ 数据在流动就耐心等（旧版 15s 一刀切重载 = 把下了一半的数据扔掉重来）
            let recoverDue = isLocal ? (e >= localRecoverDelay)
                                     : (idle >= autoRecoverIdle || e >= autoRecoverCeiling)
            if recoverDue, !didAutoRecoverForThisBusy {
                didAutoRecoverForThisBusy = true
                recoverNow(hard: isPreparing || recoveryAttempts >= 1)
            }
            let manualDue = isLocal ? (e >= localManualDelay)
                                    : (idle >= manualRetryIdle || e >= manualRetryCeiling)
            if manualDue, !offerManualRetry { offerManualRetry = true }
        } else {
            resetBusyFlags()
        }

        stallCheck()
    }

    private func stallCheck() {
        guard errorText == nil, player.currentItem != nil else { return }
        guard player.timeControlStatus == .playing else {
            lastProgressTime = player.currentTime().seconds
            lastProgressAt = Date()
            return
        }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        if duration > 0, now >= duration - 0.5 { return }

        if lastProgressTime >= 0, abs(now - lastProgressTime) < 0.05 {
            if Date().timeIntervalSince(lastProgressAt) > 2.5 {
                lastProgressAt = Date()
                recoverNow(hard: recoveryAttempts >= 2)
            }
        } else {
            lastProgressTime = now
            lastProgressAt = Date()
            let sinceRecovery = Date().timeIntervalSince(lastRecoveryAt)
            if recoveryAttempts > 0, sinceRecovery > 20 { recoveryAttempts = 0 }
            // ⭐ 流畅播放 90s 后恢复不限码率，ABR 自己会往上爬
            if peakBitRateStep > 0, sinceRecovery > 90 {
                peakBitRateStep = 0
                player.currentItem?.preferredPeakBitRate = 0
            }
        }
    }

    // MARK: 自愈
    private func recoverNow(hard: Bool) {
        guard !isTornDown, !isRecovering, errorText == nil, recoveryAttempts < 3,
              currentAssetURL != nil, phase != .idle else { return }
        isRecovering = true
        recoveryAttempts += 1
        lastRecoveryAt = Date()
        let at = max(0, currentTime)

        if hard {
            hardReload(startAt: at)
            isRecovering = false
        } else {
            player.pause()
            player.seek(to: CMTime(seconds: at, preferredTimescale: 600)) { [weak self] _ in
                onMainThread {
                    guard let self = self else { return }
                    self.isRecovering = false
                    guard !self.isTornDown else { return }
                    self.playAtPreferredRate()
                    self.recomputePhase()
                }
            }
        }
    }

    private func hardReload(startAt: Double) {
        let key = positionKey
        let local = isLocal
        let fallback = currentAssetURL
        if !local { peakBitRateStep += 1 }      // ⭐ 每次硬重载降一档码率

        if !local, let r = resolver {
            Task { [weak self] in
                let resolved = try? await r()
                onMainThread {
                    guard let self = self, !self.isTornDown else { return }
                    if let resolved = resolved, let u = URL(string: resolved) {
                        self.prepare(url: u, positionKey: key, isLocal: false,
                                     startAt: startAt, resetRecovery: false)
                    } else if let u = fallback {
                        self.prepare(url: u, positionKey: key, isLocal: local,
                                     startAt: startAt, resetRecovery: false)
                    }
                    self.bumpControlsRefresh()
                }
            }
            return
        }

        if let u = fallback {
            prepare(url: u, positionKey: key, isLocal: local,
                    startAt: startAt, resetRecovery: false)
            bumpControlsRefresh()
        }
    }

    func bumpControlsRefresh() {
        guard !isFullScreen, !isPiPActive else { return }
        controlsRefreshToken += 1
    }

    func retryNow() {
        if isTornDown { reviveIfNeeded(); return }
        errorText = nil
        offerManualRetry = false
        recoveryAttempts = 0
        busySince = Date()
        showBusySpinner = true
        hardReload(startAt: max(0, currentTime))
    }

    // MARK: 进度
    private func tick(_ sec: Double) {
        guard !isTornDown, sec.isFinite, sec >= 0 else { return }
        currentTime = sec
        if sec > 0, !hasStartedPlaying { hasStartedPlaying = true }

        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
        }
        if abs(sec - lastSaved) >= 5 {
            lastSaved = sec
            PlaybackPositionStore.save(sec, forKey: positionKey)
        }
        if duration > 0, sec >= duration - 3 {
            PlaybackPositionStore.clear(forKey: positionKey)
        }
        updatePlaybackConfirmation(sec)
    }

    /// ⭐ 真正播放判定：处于 playing 且画面连续走动 ≥ confirmSeconds（seek 跳跃不算）
    private func updatePlaybackConfirmation(_ sec: Double) {
        guard playbackConfirmedKey == nil else { return }
        guard !isPreparing, errorText == nil, !playbackHold,
              player.timeControlStatus == .playing, player.rate > 0 else {
            confirmAnchor = nil
            return
        }
        guard let a = confirmAnchor else { confirmAnchor = sec; return }
        let d = sec - a
        if d < 0 || d > confirmSeconds + 3 { confirmAnchor = sec; return }
        if d >= confirmSeconds { playbackConfirmedKey = positionKey }
    }

    private func saveProgress() {
        guard player.currentItem != nil else { return }
        let t = player.currentTime().seconds
        if t.isFinite, t > 0 { PlaybackPositionStore.save(t, forKey: positionKey) }
    }

    // MARK: 生命周期
    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaServicesWereReset),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        onMainThread { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            self.wasPlayingBeforeBackground = (self.player.timeControlStatus != .paused)
            self.saveProgress()
        }
    }

    @objc private func appWillEnterForeground() {
        onMainThread { [weak self] in
            guard let self = self, !self.isTornDown, !self.isPiPActive,
                  self.currentAssetURL != nil, self.phase != .idle else { return }
            self.configureAudioSession()

            let item = self.player.currentItem
            let broken = (item == nil) || (item?.status == .failed)
                || (item?.error != nil) || (self.player.error != nil)
            if broken {
                self.recoverNow(hard: true)
                return
            }
            if self.wasPlayingBeforeBackground, self.player.timeControlStatus == .paused {
                self.playAtPreferredRate()
            }
            self.recomputePhase()
        }
    }

    @objc private func mediaServicesWereReset() {
        onMainThread { [weak self] in
            guard let self = self else { return }
            let at = max(0, self.currentTime)
            self.teardownItemObservers()
            self.teardownPlayerObservers()
            self.player.replaceCurrentItem(with: nil)
            self.player = AVPlayer()
            self.attachPlayerObservers()
            self.playerGeneration += 1
            guard !self.isTornDown, let u = self.currentAssetURL else { return }
            self.configureAudioSession()
            self.prepare(url: u, positionKey: self.positionKey,
                         isLocal: self.isLocal, startAt: at, resetRecovery: false)
        }
    }

    func pauseForDisappear() {
        guard !isPiPActive, !isFullScreen else { return }
        player.pause()
        saveProgress()
    }

    func teardown(force: Bool = false) {
        if !force { guard !isPiPActive, !isFullScreen else { return } }
        guard !isTornDown else { return }

        let wasPlaying = player.timeControlStatus != .paused
        saveProgress()
        if let u = currentAssetURL {
            lastSession = LastSession(url: u, key: positionKey, isLocal: isLocal, wasPlaying: wasPlaying)
        }

        isTornDown = true
        player.pause()
        resetBusyFlags()
        teardownItemObservers()
        player.currentItem?.externalMetadata = []
        player.replaceCurrentItem(with: nil)
        currentAssetURL = nil
        isPreparing = false
        if isBuffering { isBuffering = false }
        if phase != .idle { phase = .idle }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Self.audioQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    @discardableResult
    func reviveIfNeeded() -> Bool {
        guard isTornDown, let s = lastSession else { return false }
        prepare(url: s.url, positionKey: s.key, isLocal: s.isLocal, autoPlay: s.wasPlaying)
        return true
    }

    // MARK: UI 便利属性
    var isBusyForUI: Bool { errorText == nil && (isPreparing || showBusySpinner) }

    var busyText: String {
        if isPreparing { return isEnglish ? "Loading…" : "正在加载…" }
        if offerManualRetry {
            return isEnglish ? "Still not loading. Try reloading or report it."
                             : "一直加载不出来，可以重新加载或反馈修复"
        }
        if slowNetwork {
            return isEnglish ? "Network seems unstable, buffering…" : "网络似乎不太稳定，正在缓冲…"
        }
        return isEnglish ? "Buffering…" : "缓冲中…"
    }
}

// MARK: - 生命周期可感知的播放控制器
final class LifecycleAVPlayerViewController: AVPlayerViewController {
    var onWillDisappear: (() -> Void)?
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onWillDisappear?()
    }
}

// MARK: - ⭐️ 播放画面（刻意不加 @MainActor / @preconcurrency）
struct OVideoPlayerSurface: UIViewControllerRepresentable {
    let engine: OVideoPlayerEngine
    var onFullScreenChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = LifecycleAVPlayerViewController()
        c.allowsPictureInPicturePlayback = true
        c.updatesNowPlayingInfoCenter = true
        c.delegate = context.coordinator
        c.videoGravity = .resizeAspect
        c.player = engine.player
        c.onWillDisappear = { [weak coordinator = context.coordinator] in
            coordinator?.handleWillDisappear()
        }
        context.coordinator.controller = c
        context.coordinator.installOverlay()
        context.coordinator.observeAppLifecycle()
        return c
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        if vc.player !== engine.player { vc.player = engine.player }
        context.coordinator.syncOverlay()
        context.coordinator.syncControlsRefresh(token: engine.controlsRefreshToken)
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: OVideoPlayerSurface
        weak var controller: AVPlayerViewController?

        private var overlayBox: UIView?
        private var overlayLabel: UILabel?
        private var lastControlsToken = 0
        private var orientationWork: DispatchWorkItem?
        private var targetMask: UIInterfaceOrientationMask?
        private var isDismantled = false
        private var appObservers: [NSObjectProtocol] = []
        private var wentToBackground = false

        private var engine: OVideoPlayerEngine { parent.engine }

        init(_ parent: OVideoPlayerSurface) {
            self.parent = parent
            self.lastControlsToken = parent.engine.controlsRefreshToken
        }

        func handleWillDisappear() {
            if engine.isFullScreen || engine.isPiPActive { return }
            engine.pauseForDisappear()
        }

        // MARK: ⭐ 回前台：强制重建控制层（修复"暂停→后台→前台"后控制条冻结不消失）
        func observeAppLifecycle() {
            let nc = NotificationCenter.default
            appObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
                self?.wentToBackground = true
            })
            appObservers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
                guard let self = self, self.wentToBackground else { return }
                self.wentToBackground = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.refreshControlsAfterForeground()
                }
            })
        }

        private func refreshControlsAfterForeground() {
            guard !isDismantled, let c = controller, c.viewIfLoaded?.window != nil,
                  !engine.isPiPActive else { return }
            // 全屏标志残留（实际已无全屏 presentation）→ 纠正，否则刷新永远被挡
            if engine.isFullScreen, c.presentedViewController == nil {
                setFullScreen(false)
            }
            guard !engine.isFullScreen else { return }
            forceControlsRebuild(c)
        }

        private func forceControlsRebuild(_ c: AVPlayerViewController) {
            guard c.showsPlaybackControls else { return }
            c.showsPlaybackControls = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak c] in
                c?.showsPlaybackControls = true
            }
        }

        func installOverlay() {
            guard let c = controller else { return }
            c.loadViewIfNeeded()
            guard let overlay = c.contentOverlayView else { return }

            let box = UIView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            box.layer.cornerRadius = 12
            box.isUserInteractionEnabled = false
            box.isHidden = true

            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = .white
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = UIColor.white.withAlphaComponent(0.9)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.numberOfLines = 2
            label.textAlignment = .center

            box.addSubview(spinner)
            box.addSubview(label)
            overlay.addSubview(box)

            let hug = box.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 28)
            hug.priority = UILayoutPriority(999)

            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                box.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
                hug,
                spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
                spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
                label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
            ])

            overlayBox = box
            overlayLabel = label
        }

        func syncOverlay() {
            overlayLabel?.text = engine.busyText
            overlayBox?.isHidden = !(engine.isFullScreen && engine.isBusyForUI)
        }

        func syncControlsRefresh(token: Int) {
            guard token != lastControlsToken else { return }
            lastControlsToken = token
            guard let c = controller, !engine.isFullScreen, !engine.isPiPActive else { return }
            forceControlsRebuild(c)
        }

        func cleanup() {
            isDismantled = true
            orientationWork?.cancel()
            for o in appObservers { NotificationCenter.default.removeObserver(o) }
            appObservers.removeAll()
            overlayBox?.removeFromSuperview()
            overlayBox = nil; overlayLabel = nil
            if !engine.isPiPActive {
                engine.isFullScreen = false
                engine.teardown(force: true)
                controller?.player = nil
                AppDelegate.orientationLock = .portrait
                performRotation(mask: .portrait)
            }
        }

        // MARK: 全屏代理
        func playerViewController(_ pvc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator
                                  coordinator: UIViewControllerTransitionCoordinator) {
            setFullScreen(true)
            coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                guard let self = self else { return }
                let ok = !ctx.isCancelled
                self.setFullScreen(ok)
                self.applyOrientation(fullScreen: ok)
            }
        }

        func playerViewController(_ pvc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator
                                  coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                guard let self = self else { return }
                let stillFull = ctx.isCancelled
                self.setFullScreen(stillFull)
                self.applyOrientation(fullScreen: stillFull)
            }
        }

        private func setFullScreen(_ v: Bool) {
            guard engine.isFullScreen != v else { return }
            engine.isFullScreen = v
            syncOverlay()
            let cb = parent.onFullScreenChanged
            DispatchQueue.main.async { cb?(v) }
        }

        // MARK: 画中画代理
        func playerViewControllerWillStartPictureInPicture(_ pvc: AVPlayerViewController) {
            engine.isPiPActive = true
            if engine.isFullScreen { setFullScreen(false) }
            AppDelegate.orientationLock = .portrait
        }

        func playerViewControllerDidStopPictureInPicture(_ pvc: AVPlayerViewController) {
            engine.isPiPActive = false
            if isDismantled || pvc.viewIfLoaded?.window == nil {
                engine.isFullScreen = false
                engine.teardown(force: true)
                pvc.player = nil
                return
            }
            if !engine.isFullScreen {
                DispatchQueue.main.async { [weak self] in
                    self?.applyOrientation(fullScreen: false)
                }
            }
        }

        func playerViewController(_ pvc: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                  completionHandler: @escaping (Bool) -> Void) {
            setFullScreen(false)
            applyOrientation(fullScreen: false)
            completionHandler(!isDismantled)
        }

        // MARK: 旋转
        private func applyOrientation(fullScreen: Bool) {
            let mask: UIInterfaceOrientationMask = fullScreen ? .landscape : .portrait
            AppDelegate.orientationLock = mask
            targetMask = mask
            orientationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let m = self.targetMask else { return }
                self.performRotation(mask: m)
            }
            orientationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        func performRotation(mask: UIInterfaceOrientationMask) {
            if #available(iOS 16.0, *) {
                guard let scene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                else { return }
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
                    #if DEBUG
                    print("requestGeometryUpdate: \(error.localizedDescription)")
                    #endif
                }
            } else {
                let o: UIInterfaceOrientation = (mask == .landscape) ? .landscapeRight : .portrait
                UIDevice.current.setValue(o.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }
    }
}

// MARK: - 旧签名兼容壳
struct VideoPlayerView: View {
    let videoURL: URL
    @Binding var isBuffering: Bool
    @Binding var hasStartedPlaying: Bool
    var onPlaybackFailed: ((String) -> Void)? = nil
    var onFullScreenChanged: ((Bool) -> Void)? = nil

    @StateObject private var engine = OVideoPlayerEngine()

    var body: some View {
        OVideoPlayerSurface(engine: engine, onFullScreenChanged: onFullScreenChanged)
            .onAppear {
                if engine.currentAssetURL != videoURL {
                    engine.prepare(url: videoURL,
                                   positionKey: videoURL.absoluteString,
                                   isLocal: videoURL.isFileURL)
                }
            }
            .onDisappear { engine.teardown() }
            .onChange(of: engine.isBusyForUI) { _, v in isBuffering = v }
            .onChange(of: engine.hasStartedPlaying) { _, v in hasStartedPlaying = v }
            .onChange(of: engine.errorText) { _, v in if let v = v { onPlaybackFailed?(v) } }
    }
}

// MARK: - 缓冲指示器
struct PlayerLoadingIndicator: View {
    var text: String? = nil
    @State private var rotate = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                        .frame(width: 46, height: 46)
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(AngularGradient(gradient: Gradient(colors: [.white.opacity(0.0), .white]),
                                                center: .center),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(rotate ? 360 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotate)
                }
                Text(text ?? "缓冲中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
                    .shadow(radius: 2)
            }
        }
        .allowsHitTesting(false)
        .onAppear { rotate = true }
        .transition(.opacity)
    }
}

// MARK: - 局部观察下载进度的宿主
private struct CacheCardHost: View {
    let realURL: String
    let videoTitle: String
    let coverImage: String?
    let seriesTitle: String
    let episodeName: String?
    let episodeKey: String
    let sourceURL: String?

    var body: some View {
        CacheCard(realURL: realURL,
                  videoTitle: videoTitle,
                  coverImage: coverImage,
                  seriesTitle: seriesTitle,
                  episodeName: episodeName,
                  episodeKey: episodeKey,
                  sourceURL: sourceURL)
    }
}

private struct DeleteCacheButton: View {
    private let dm = HLSDownloadManager.shared
    @ObservedObject private var index = HLSDownloadManager.shared.statusIndex
    let activeKey: String
    let onDeleted: () -> Void
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    private var cacheKey: String? {
        if dm.localBookmarks[activeKey] != nil { return activeKey }
        for (key, meta) in dm.cacheMetadata
        where meta.originalEpisodeURL == activeKey && dm.localBookmarks[key] != nil {
            return key
        }
        return nil
    }

    var body: some View {
        if let key = cacheKey {
            Button(role: .destructive) {
                dm.deleteDownload(urlString: key)
                onDeleted()
            } label: {
                Label(isGlobalEnglishMode ? "Delete Cache" : "删除视频", systemImage: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.12)))
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - 在线播放页
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []
    var playSource: String? = nil
    /// ⭐ 不为 nil：这一集尚未扣点，等视频真正开始播放后再扣
    var chargeOnPlayKey: String? = nil

    private let downloadManager = HLSDownloadManager.shared
    private let network = NetworkMonitor.shared

    @StateObject private var engine = OVideoPlayerEngine()

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("hasWarnedCellularOnlinePlay") private var hasWarnedCellularOnlinePlay = false
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true

    @State private var showFirstPlayCellularAlert = false
    @State private var cellularPlayBlocked = false

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @Environment(\.appNavPath) var appNavPath
    @Environment(\.dismiss) private var dismiss

    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    @State private var showLoginAlert = false

    @State private var showRepairSheet = false
    @State private var showReportSheet = false
    @State private var resolveTimeoutWork: DispatchWorkItem? = nil

    @State private var isPlayerFullScreen = false
    @State private var pendingRepairPrompt = false

    @State private var showEpisodeConsumeConfirm = false
    @State private var episodeConsumeRemaining = 0
    @State private var pendingEpisodeForSwitch: VideoEpisodeItem? = nil

    @State private var showEpisodePicker = false
    @State private var overrideEpisodeURL: String? = nil
    @State private var overrideEpisodeName: String? = nil
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil
    @State private var pendingOnlineResolvedURL: String? = nil
    @State private var showEpisodeCellularAlert = false
    @State private var loadedEpisodes: [VideoEpisodeItem] = []

    // ⭐ 播放后扣点
    @State private var pendingChargeKey: String? = nil
    @State private var didSeedCharge = false
    @State private var isCharging = false
    @State private var showChargeFailedAlert = false
    @State private var showChargeQuotaAlert = false

    private var activeEpisodes: [VideoEpisodeItem] {
        episodes.isEmpty ? loadedEpisodes : episodes
    }
    private var seriesBaseTitle: String {
        videoTitle.components(separatedBy: " · ").first ?? videoTitle
    }
    private var activeEpisodeURL: String { overrideEpisodeURL ?? episodeURL }
    private var activeEpisodeName: String? { overrideEpisodeName ?? episodeName }
    private var displayTitle: String {
        if let ep = activeEpisodeName, !ep.isEmpty { return "\(seriesBaseTitle) · \(ep)" }
        return videoTitle
    }
    private var hasAccess: Bool {
        authManager.isSubscribed
            || FreeQuotaManager.shared.isUnlocked(activeEpisodeURL)
            || pendingChargeKey == activeEpisodeURL
    }

    private func cachedOriginalURLs() -> Set<String> { downloadManager.statusIndex.cachedKeys }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground),
                                    Color.accentColor.opacity(0.06),
                                    Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                playerArea
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                AdWarningBanner()
                    .fullScreenCover(isPresented: $showReportSheet) {
                        ReportSheet(videoTitle: displayTitle,
                                    sourceURL: sourceURL ?? activeEpisodeURL,
                                    episodeURL: activeEpisodeURL,
                                    channelName: channelName,
                                    episodeName: activeEpisodeName,
                                    realURL: realURL ?? activeEpisodeURL)
                    }
                    .sheet(isPresented: $showRepairSheet) {
                        PlaybackRepairSheet(videoTitle: displayTitle,
                                            sourceURL: sourceURL ?? activeEpisodeURL,
                                            episodeURL: activeEpisodeURL,
                                            channelName: channelName,
                                            episodeName: activeEpisodeName,
                                            realURL: realURL ?? activeEpisodeURL,
                                            onRetry: {
                                                showRepairSheet = false
                                                retryCurrent()
                                            })
                        .presentationDetents([.medium, .large])
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleCard
                        if let real = realURL {
                            CacheCardHost(realURL: real,
                                          videoTitle: displayTitle,
                                          coverImage: coverImage,
                                          seriesTitle: seriesBaseTitle,
                                          episodeName: activeEpisodeName,
                                          episodeKey: activeEpisodeURL,
                                          sourceURL: sourceURL)
                        }
                    }
                    .padding(.top, 16)
                }
                // ⭐ 扣点结果弹窗
                .alert(isGlobalEnglishMode ? "Couldn't use your pass" : "扣点失败",
                       isPresented: $showChargeFailedAlert) {
                    Button(isGlobalEnglishMode ? "Leave" : "退出", role: .cancel) { dismiss() }
                    Button(isGlobalEnglishMode ? "Retry" : "重试") {
                        if let k = pendingChargeKey { performCharge(k) }
                    }
                } message: {
                    Text(isGlobalEnglishMode
                         ? "Network error while using your pass. Playback is paused until it succeeds."
                         : "网络异常，扣点未成功，扣点成功后才能继续播放。")
                }
                .alert(isGlobalEnglishMode ? "Not Enough Passes" : "免费点数不足",
                       isPresented: $showChargeQuotaAlert) {
                    Button(isGlobalEnglishMode ? "Leave" : "退出", role: .cancel) { dismiss() }
                    Button(isGlobalEnglishMode ? "Subscribe" : "订阅") { showSubscriptionSheet = true }
                } message: {
                    Text(isGlobalEnglishMode
                         ? "You have no passes left. Subscribe for unlimited access, or come back tomorrow."
                         : "当前点数已用完，订阅后即可无限畅享，或明天再来领取每日免费点数。")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: engine.offerManualRetry) { _, offer in
            if offer { requestRepairSheet() }
        }
        .onChange(of: engine.errorText) { _, msg in
            if let msg = msg {
                resolveError = msg
                requestRepairSheet()
            }
        }
        // ⭐ 真正开始播放：扣点 + 追剧追平
        .onChange(of: engine.playbackConfirmedKey) { _, key in
            guard let key = key else { return }
            recordSeriesWatch()
            if key == pendingChargeKey { performCharge(key) }
        }
        .onChange(of: isPlayerFullScreen) { _, full in
            if !full, pendingRepairPrompt {
                pendingRepairPrompt = false
                AppDelegate.orientationLock = .portrait
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showRepairSheet = true }
            }
        }
        .task {
            if !didSeedCharge {
                didSeedCharge = true
                if let k = chargeOnPlayKey, !k.isEmpty { pendingChargeKey = k }
            }
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            if hasAccess && realURL == nil { await resolve() }

            if episodes.isEmpty, loadedEpisodes.isEmpty,
               let src = sourceURL, !src.isEmpty {
                let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
                let chosen = channels.first { $0.name == channelName } ?? channels.first
                if let ch = chosen { loadedEpisodes = ch.episodeItems(ascending: isEpisodeAscending) }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onChange(of: authManager.isSubscribed) { _, newValue in
            if newValue {
                pendingChargeKey = nil
                showChargeQuotaAlert = false
                showChargeFailedAlert = false
                engine.releaseHold(resume: true)
                if realURL == nil { Task { await resolve() } }
            }
        }
        .onAppear {
            NotificationPermissionManager.shared.suppress(true)
            engine.hostVisible = true
            engine.reviveIfNeeded()
        }
        .onDisappear {
            NotificationPermissionManager.shared.suppress(false)
            ReviewManager.shared.recordVideoInteraction()
            resolveTimeoutWork?.cancel(); resolveTimeoutWork = nil
            engine.teardown()
            if engine.isTornDown { engine.hostVisible = false }
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showEpisodeCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingOnlineEpisode = nil; pendingOnlineResolvedURL = nil
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                if let ep = pendingOnlineEpisode {
                    switchToEpisode(ep, resolvedURL: pendingOnlineResolvedURL)
                }
                pendingOnlineEpisode = nil; pendingOnlineResolvedURL = nil
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .alert(isGlobalEnglishMode ? "Use 1 Free Pass" : "使用免费点数",
               isPresented: $showEpisodeConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                pendingEpisodeForSwitch = nil
            }
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndSwitchEpisode() }
            }
        } message: {
            Text(quotaManager.consumeSourceNote(english: isGlobalEnglishMode)
                 + "\n" + quotaManager.remainingSummary(english: isGlobalEnglishMode)
                 + "\n" + VideoChargeService.playNote(english: isGlobalEnglishMode))
        }
        .alert(isGlobalEnglishMode ? "Sign in to Watch Free" : "登录后免费观看",
               isPresented: $showLoginAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Sign in with Apple" : "登录") {
                authManager.signInWithApple()
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "Sign in (free, no purchase needed) to unlock your free daily passes."
                 : "登录后即可获得每日免费观看点数，登录无需付费。")
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showFirstPlayCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                resolveError = isGlobalEnglishMode ? "Playback canceled on cellular network" : "已取消蜂窝网络播放"
                cellularPlayBlocked = false
            }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                cellularPlayBlocked = false
                if let real = realURL { startPlayback(real: real) }
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .onChange(of: authManager.isLoggedIn) { _, loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
    }

    // MARK: 播放器主区
    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Color.black

            if realURL != nil, !cellularPlayBlocked {
                OVideoPlayerSurface(engine: engine,
                                    onFullScreenChanged: { full in isPlayerFullScreen = full })
            }

            errorOverlay

            PlayerLoadingIndicator(text: loadingText)
                .opacity(showLoadingIndicator ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: showLoadingIndicator)
    }

    private var errorOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36)).foregroundColor(.orange)
            Text(resolveError ?? "")
                .foregroundColor(.white).font(.subheadline)
                .multilineTextAlignment(.center).padding(.horizontal)
            HStack(spacing: 10) {
                Button(isGlobalEnglishMode ? "Retry" : "重试") { retryCurrent() }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.white.opacity(0.9))
                    .foregroundColor(.black).cornerRadius(16)
                Button(isGlobalEnglishMode ? "Report" : "反馈修复") { showReportSheet = true }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .foregroundColor(.white).cornerRadius(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .opacity(resolveError == nil ? 0 : 1)
        .allowsHitTesting(resolveError != nil)
    }

    private var showLoadingIndicator: Bool {
        if cellularPlayBlocked { return false }
        if resolveError != nil { return false }
        if isResolving { return true }
        if realURL == nil { return true }
        return engine.isBusyForUI
    }

    private var loadingText: String {
        if isResolving || realURL == nil {
            return isGlobalEnglishMode ? "Loading…" : "正在加载…"
        }
        return engine.busyText
    }

    // MARK: 标题 / 选集
    private var titleCard: some View {
        HStack(spacing: 10) {
            Text(displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(3)
            Spacer()
            if activeEpisodes.count > 1 { episodeSelectorButton }
        }
        .padding(.horizontal, 16)
    }

    private var episodeSelectorButton: some View {
        Button { showEpisodePicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill")
                Text(isGlobalEnglishMode ? "Episodes" : "选集")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerView(episodes: activeEpisodes,
                              currentURL: activeEpisodeURL,
                              cachedOriginalURLs: cachedOriginalURLs(),
                              onSelect: { ep in handleEpisodeSelection(ep) },
                              seriesTitle: seriesBaseTitle,
                              batchContext: EpisodeBatchContext.make(seriesTitle: seriesBaseTitle,
                                                                     sourceURL: sourceURL,
                                                                     cover: coverImage,
                                                                     channelName: channelName,
                                                                     episodes: activeEpisodes))
                .presentationDetents([.medium, .large])
        }
    }

    private func requestRepairSheet() {
        if isPlayerFullScreen || engine.isPiPActive { pendingRepairPrompt = true; return }
        AppDelegate.orientationLock = .portrait
        showRepairSheet = true
    }

    /// ⭐ 解析接口单次超时 15s × 2 + 1.5s 间隔，原 25s 会在第二次请求还没结束时就误弹
    private func scheduleResolveTimeout() {
        resolveTimeoutWork?.cancel()
        let work = DispatchWorkItem {
            if isResolving, realURL == nil { requestRepairSheet() }
        }
        resolveTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: work)
    }

    private func retryCurrent() {
        resolveError = nil
        if realURL != nil {
            engine.retryNow()
        } else {
            Task { await resolve() }
        }
    }

    // MARK: ⭐ 播放后扣点
    private func performCharge(_ key: String) {
        guard !isCharging else { return }
        isCharging = true
        let title = "\(seriesBaseTitle) · \(activeEpisodeName ?? "")"
        Task {
            let outcome = await VideoChargeService.charge(episodeKey: key, title: title, auth: authManager)
            isCharging = false
            switch outcome {
            case .charged:
                if pendingChargeKey == key { pendingChargeKey = nil }
                engine.releaseHold(resume: true)
            case .quotaExceeded:
                guard activeEpisodeURL == key else { return }
                engine.holdPlayback()
                showChargeQuotaAlert = true
            case .failed:
                guard activeEpisodeURL == key else { return }
                engine.holdPlayback()
                showChargeFailedAlert = true
            }
        }
    }

    private func handleEpisodeSelection(_ ep: VideoEpisodeItem) {
        guard ep.url != activeEpisodeURL else { showEpisodePicker = false; return }
        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            proceedToSwitch(episode: ep)
        case .needLogin:
            showEpisodePicker = false; showLoginAlert = true
        case .needConsume(let r):
            pendingEpisodeForSwitch = ep
            episodeConsumeRemaining = r
            showEpisodeConsumeConfirm = true
            showEpisodePicker = false
        case .exhausted:
            showEpisodePicker = false; showSubscriptionSheet = true
        }
    }

    /// ⭐ 不再立即扣点：标记"播放成功后扣"
    private func consumeAndSwitchEpisode() async {
        guard let ep = pendingEpisodeForSwitch else { return }
        pendingChargeKey = ep.url
        pendingEpisodeForSwitch = nil
        proceedToSwitch(episode: ep)
    }

    private func proceedToSwitch(episode ep: VideoEpisodeItem) {
        showEpisodePicker = false
        isResolving = true
        resolveError = nil
        engine.beginSwitching()
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                isResolving = false
                let realKey = resolved ?? ep.url
                let cached = (resolved != nil) && (downloadManager.localBookmarks[realKey] != nil)
                if cached {
                    switchToEpisode(ep, resolvedURL: realKey)
                } else if !network.isWiFi && !hasWarnedCellularOnlinePlay {
                    pendingOnlineEpisode = ep
                    pendingOnlineResolvedURL = resolved
                    showEpisodeCellularAlert = true
                } else {
                    switchToEpisode(ep, resolvedURL: resolved)
                }
            }
        }
    }

    private func switchToEpisode(_ ep: VideoEpisodeItem, resolvedURL: String?) {
        overrideEpisodeURL = ep.url
        overrideEpisodeName = ep.name
        resolveError = nil
        if let resolved = resolvedURL {
            isResolving = false
            realURL = resolved
            startPlayback(real: resolved)
            recordPlayback(real: resolved)
        } else {
            realURL = nil
            Task { await resolve() }
        }
    }

    private func resolve() async {
        isResolving = true
        resolveError = nil
        scheduleResolveTimeout()
        do {
            let url: String
            do {
                url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            } catch {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                url = try await OVideoAPI.resolveRealURL(episodeURL: activeEpisodeURL)
            }
            self.realURL = url
            self.resolveTimeoutWork?.cancel()
            self.evaluateCellularGate(real: url)
            if !cellularPlayBlocked { startPlayback(real: url) }
            recordPlayback(real: url)
        } catch {
            self.resolveError = error.localizedDescription
            self.requestRepairSheet()
            self.resolveTimeoutWork?.cancel()
        }
        isResolving = false
    }

    private func startPlayback(real: String) {
        engine.setNowPlaying(title: seriesBaseTitle, subtitle: activeEpisodeName, artwork: coverImage)
        let key = activeEpisodeURL
        if let local = downloadManager.getLocalURL(for: real) {
            engine.prepare(url: local, positionKey: key, isLocal: true, resolver: nil)
            return
        }
        guard let u = URL(string: real) else {
            resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
            requestRepairSheet()
            return
        }
        engine.prepare(url: u, positionKey: key, isLocal: false,
                       resolver: { try await OVideoAPI.resolveRealURL(episodeURL: key) })
    }

    private func evaluateCellularGate(real: String) {
        let isCached = downloadManager.localBookmarks[real] != nil
        if !isCached && !network.isWiFi && !hasWarnedCellularOnlinePlay {
            cellularPlayBlocked = true
            showFirstPlayCellularAlert = true
        }
    }

    private func recordPlayback(real: String) {
        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty { return (appleId, "apple") }
            if let idfv = UIDevice.current.identifierForVendor?.uuidString { return ("dev_" + idfv, "device") }
            return ("guest_user", "device")
        }()

        TrackingManager.shared.track(event: .play,
                                     userId: trackUserId,
                                     userType: trackUserType,
                                     videoURL: activeEpisodeURL,
                                     videoTitle: displayTitle,
                                     source: playSource)

        VideoPlayRecordManager.shared.addRecord(videoTitle: seriesBaseTitle,
                                                episodeName: activeEpisodeName ?? (isGlobalEnglishMode ? "Play" : "播放"),
                                                videoURL: activeEpisodeURL,
                                                coverImage: coverImage,
                                                channelName: channelName,
                                                sourceURL: sourceURL)
    }

    /// ⭐ 追剧"追平"只在真正播放后记录（原来解析成功就记，播放失败也会被追平）
    private func recordSeriesWatch() {
        SeriesTrackManager.shared.recordWatch(sourceURL: sourceURL,
                                              title: seriesBaseTitle,
                                              cover: coverImage,
                                              episodeName: activeEpisodeName,
                                              channelName: channelName)
    }
}

// MARK: - 离线下载播放器
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    var channelName: String? = nil
    var episodeName: String? = nil
    var sourceURL: String? = nil
    var episodes: [VideoEpisodeItem] = []

    private let downloadManager = HLSDownloadManager.shared
    private let network = NetworkMonitor.shared

    @StateObject private var engine = OVideoPlayerEngine()

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true
    @AppStorage("hasWarnedCellularOnlinePlay") private var hasWarnedCellularOnlinePlay = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appNavPath) var appNavPath
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showSubscriptionSheet = false

    @State private var allEpisodes: [VideoEpisodeItem] = []
    @State private var activeKey: String = ""
    @State private var activeName: String? = nil
    @State private var hasPlayable = false
    @State private var isResolvingOnline = false
    @State private var resolveError: String? = nil
    @State private var didInit = false

    @State private var showRepairSheet = false
    @State private var showReportSheet = false
    @State private var isPlayerFullScreen = false
    @State private var pendingRepairPrompt = false

    @State private var showEpisodePicker = false
    @State private var showLoginAlert = false
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var pendingEpisode: VideoEpisodeItem? = nil
    @State private var showQuotaExhausted = false
    @State private var showCellularAlert = false
    @State private var pendingOnlineEpisode: VideoEpisodeItem? = nil

    // ⭐ 播放后扣点（在线切集）
    @State private var pendingChargeKey: String? = nil
    @State private var isCharging = false
    @State private var showChargeFailedAlert = false

    private var pickerEpisodes: [VideoEpisodeItem] { allEpisodes.isEmpty ? episodes : allEpisodes }
    private var baseTitle: String { title.components(separatedBy: " · ").first ?? title }
    private var displayTitle: String {
        if let ep = activeName, !ep.isEmpty { return "\(baseTitle) · \(ep)" }
        return title
    }

    private func cachedOriginalURLs() -> Set<String> { downloadManager.statusIndex.cachedKeys }

    private var showSpinner: Bool {
        resolveError == nil && (isResolvingOnline || engine.isBusyForUI)
    }
    private var spinnerText: String {
        isResolvingOnline ? (isGlobalEnglishMode ? "Loading…" : "正在加载…") : engine.busyText
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground), Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Color.black

                    if hasPlayable {
                        OVideoPlayerSurface(engine: engine,
                                            onFullScreenChanged: { full in isPlayerFullScreen = full })
                    } else if resolveError == nil && !isResolvingOnline {
                        Text(isGlobalEnglishMode ? "Unable to play" : "无法播放")
                            .foregroundColor(.white)
                    }

                    errorOverlay

                    PlayerLoadingIndicator(text: spinnerText)
                        .opacity(showSpinner ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .animation(.easeInOut(duration: 0.2), value: showSpinner)

                AdWarningBanner()
                    .fullScreenCover(isPresented: $showReportSheet) {
                        ReportSheet(videoTitle: displayTitle,
                                    sourceURL: sourceURL ?? activeKey,
                                    episodeURL: activeKey,
                                    channelName: channelName,
                                    episodeName: activeName,
                                    realURL: activeKey)
                    }
                    // ⭐ 修复：原来只设置 showRepairSheet 却没有挂 sheet，"反馈修复"点了没反应
                    .sheet(isPresented: $showRepairSheet) {
                        PlaybackRepairSheet(videoTitle: displayTitle,
                                            sourceURL: sourceURL ?? activeKey,
                                            episodeURL: activeKey,
                                            channelName: channelName,
                                            episodeName: activeName,
                                            realURL: activeKey,
                                            onRetry: {
                                                showRepairSheet = false
                                                retryCurrent()
                                            })
                        .presentationDetents([.medium, .large])
                    }
                    .sheet(isPresented: $showEpisodePicker) {
                        EpisodePickerView(episodes: pickerEpisodes,
                                        currentURL: activeKey,
                                        cachedOriginalURLs: cachedOriginalURLs(),
                                        onSelect: { ep in selectEpisode(ep) },
                                        seriesTitle: baseTitle,
                                        batchContext: allEpisodes.isEmpty ? nil
                                            : EpisodeBatchContext.make(seriesTitle: baseTitle,
                                                                    sourceURL: sourceURL,
                                                                    cover: downloadManager.cacheMetadata[realURL]?.coverImage,
                                                                    channelName: channelName,
                                                                    episodes: allEpisodes))
                            .presentationDetents([.medium, .large])
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Text(displayTitle)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.primary).lineLimit(3)
                            Spacer()
                            if pickerEpisodes.count > 1 { episodeSelectorButton }
                        }
                        .padding(.horizontal, 16).padding(.top, 16)

                        DeleteCacheButton(activeKey: activeKey, onDeleted: { dismiss() })

                        Button(action: { appNavPath?.wrappedValue.append(NavigationTarget.allArticles) }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.blue.opacity(0.1)).frame(width: 40, height: 40)
                                    Image(systemName: "newspaper.fill")
                                        .font(.system(size: 18)).foregroundColor(.blue)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isGlobalEnglishMode ? "Back to News" : "返回新闻阅读")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(isGlobalEnglishMode ? "Read all subscribed articles" : "阅读所有订阅文章")
                                        .font(.system(size: 12)).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(UIColor.secondarySystemGroupedBackground)))
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer(minLength: 30)
                    }
                }
                .alert(isGlobalEnglishMode ? "Couldn't use your pass" : "扣点失败",
                       isPresented: $showChargeFailedAlert) {
                    Button(isGlobalEnglishMode ? "Leave" : "退出", role: .cancel) { dismiss() }
                    Button(isGlobalEnglishMode ? "Retry" : "重试") {
                        if let k = pendingChargeKey { performCharge(k) }
                    }
                } message: {
                    Text(isGlobalEnglishMode
                         ? "Network error while using your pass. Playback is paused until it succeeds."
                         : "网络异常，扣点未成功，扣点成功后才能继续播放。")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        // ⭐ 修复：删除了这里重复绑定 showEpisodePicker 的第二个 .sheet
        .alert(isGlobalEnglishMode ? "Use Free Pass (\(consumeRemaining) left)"
                                   : "今日免费赠送还剩\(consumeRemaining)点",
               isPresented: $showConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") { Task { await consumeAndPlay() } }
        } message: {
            Text(quotaManager.consumeSourceNote(english: isGlobalEnglishMode)
                 + "\n" + quotaManager.remainingSummary(english: isGlobalEnglishMode)
                 + "\n" + VideoChargeService.playNote(english: isGlobalEnglishMode))
        }
        .alert(isGlobalEnglishMode ? "Free Passes Used Up (0 left)" : "今日免费额度不足",
               isPresented: $showQuotaExhausted) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") { showSubscriptionSheet = true }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You've used all your free passes for today. Subscribe for unlimited access."
                 : "您今天的免费额度已用完，订阅后即可无限畅享所有视频。")
        }
        .alert(isGlobalEnglishMode ? "Sign in to Watch Free" : "登录后免费观看",
               isPresented: $showLoginAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Sign in with Apple" : "登录") { authManager.signInWithApple() }
        } message: {
            Text(isGlobalEnglishMode
                 ? "Sign in (free) to unlock your free daily passes."
                 : "登录后即可获得每日免费观看点数，登录无需付费。")
        }
        .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
               isPresented: $showCellularAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) { pendingOnlineEpisode = nil }
            Button(isGlobalEnglishMode ? "Play Anyway" : "允许并播放") {
                hasWarnedCellularOnlinePlay = true
                if let ep = pendingOnlineEpisode { resolveAndPlayOnline(ep) }
                pendingOnlineEpisode = nil
            }
        } message: {
            Text(isGlobalEnglishMode
                 ? "You are on a cellular network. Online playback will use mobile data. Continue?"
                 : "当前处于蜂窝网络，在线播放将消耗流量，是否继续？")
        }
        .onAppear {
            NotificationPermissionManager.shared.suppress(true)
            engine.hostVisible = true
            if !engine.reviveIfNeeded() { startInitialPlaybackIfNeeded() }
        }
        .onChange(of: engine.offerManualRetry) { _, offer in
            if offer, !engine.isLocal { requestRepairSheet() }
        }
        .onChange(of: engine.errorText) { _, msg in
            if let msg = msg { resolveError = msg; requestRepairSheet() }
        }
        .onChange(of: engine.playbackConfirmedKey) { _, key in
            guard let key = key else { return }
            recordSeriesWatch()
            if key == pendingChargeKey { performCharge(key) }
        }
        .onChange(of: authManager.isSubscribed) { _, sub in
            if sub {
                pendingChargeKey = nil
                showChargeFailedAlert = false
                engine.releaseHold(resume: true)
            }
        }
        .onChange(of: isPlayerFullScreen) { _, full in
            if !full, pendingRepairPrompt {
                pendingRepairPrompt = false
                AppDelegate.orientationLock = .portrait
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showRepairSheet = true }
            }
        }
        .onDisappear {
            NotificationPermissionManager.shared.suppress(false)
            engine.teardown()
            if engine.isTornDown { engine.hostVisible = false }
        }
        .onChange(of: authManager.isLoggedIn) { _, loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            await loadAllEpisodes()
        }
    }

    private var errorOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36)).foregroundColor(.orange)
            Text(resolveError ?? "")
                .foregroundColor(.white).font(.subheadline)
                .multilineTextAlignment(.center).padding(.horizontal)
            HStack(spacing: 10) {
                Button(isGlobalEnglishMode ? "Retry" : "重试") { retryCurrent() }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.white.opacity(0.9))
                    .foregroundColor(.black).cornerRadius(16)
                Button(isGlobalEnglishMode ? "Report" : "反馈修复") { requestRepairSheet() }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .foregroundColor(.white).cornerRadius(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .opacity(resolveError == nil ? 0 : 1)
        .allowsHitTesting(resolveError != nil)
    }

    private var episodeSelectorButton: some View {
        Button { showEpisodePicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill")
                Text(isGlobalEnglishMode ? "Episodes" : "选集")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func requestRepairSheet() {
        if isPlayerFullScreen || engine.isPiPActive { pendingRepairPrompt = true; return }
        AppDelegate.orientationLock = .portrait
        showRepairSheet = true
    }

    private func retryCurrent() {
        resolveError = nil
        if let entry = localEntry(forOriginal: activeKey) {
            playLocal(entry.url, positionKey: activeKey, cacheKey: entry.key)
            return
        }
        if let ep = pickerEpisodes.first(where: { $0.url == activeKey }) {
            resolveAndPlayOnline(ep)
        } else {
            engine.retryNow()
        }
    }

    /// ⭐ 本地文件播放：若该下载"完成时没扣成点"，先补扣；仅服务器明确点数不足才拦截（断网照常播放，联网后补扣）
    private func playLocal(_ local: URL, positionKey: String, cacheKey: String) {
        let start = {
            hasPlayable = true
            updateNowPlaying()
            engine.prepare(url: local, positionKey: positionKey, isLocal: true, resolver: nil)
            recordPlayback()
        }
        guard downloadManager.needsCharge(cacheKey) else { start(); return }
        isResolvingOnline = true
        Task {
            let outcome = await downloadManager.settleCharge(for: cacheKey)
            isResolvingOnline = false
            if outcome == .quotaExceeded {
                resolveError = isGlobalEnglishMode
                    ? "Points ran out when this download finished. 1 pass is required to watch it."
                    : "该视频下载完成时点数不足，观看需消耗 1 点。可订阅或明天领取点数后再看。"
                showQuotaExhausted = true
                return
            }
            start()
        }
    }

    private func startInitialPlaybackIfNeeded() {
        guard !didInit else { return }
        didInit = true
        activeName = episodeName
        activeKey = realURL
        let posKey = downloadManager.cacheMetadata[realURL]?.originalEpisodeURL ?? realURL

        if let local = downloadManager.getLocalURL(for: realURL) {
            playLocal(local, positionKey: posKey, cacheKey: realURL)
        } else if let u = URL(string: realURL) {
            hasPlayable = true
            updateNowPlaying()
            engine.prepare(url: u, positionKey: posKey, isLocal: false,
                           resolver: { try await OVideoAPI.resolveRealURL(episodeURL: posKey) })
            recordPlayback()
        } else {
            hasPlayable = false
            resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
            requestRepairSheet()
        }
    }

    private func loadAllEpisodes() async {
        guard allEpisodes.isEmpty, let src = sourceURL, !src.isEmpty else { return }
        let channels = (try? await OVideoAPI.fetchPlaylist(url: src)) ?? []
        guard let best = optimalSortedChannels(channels, itemName: baseTitle).first else { return }
        let items = best.episodeItems(ascending: isEpisodeAscending)
        await MainActor.run {
            self.allEpisodes = items
            let orig = downloadManager.cacheMetadata[realURL]?.originalEpisodeURL ?? realURL
            if items.contains(where: { $0.url == orig }) { self.activeKey = orig }
        }
    }

    private func selectEpisode(_ ep: VideoEpisodeItem) {
        showEpisodePicker = false
        guard ep.url != activeKey else { return }

        if let entry = localEntry(forOriginal: ep.url) {
            activeKey = ep.url; activeName = ep.name; resolveError = nil
            playLocal(entry.url, positionKey: ep.url, cacheKey: entry.key)
            return
        }

        switch decideVideoAccess(episodeKey: ep.url, auth: authManager, quota: quotaManager) {
        case .allowed:            startOnline(ep)
        case .needLogin:          showLoginAlert = true
        case .needConsume(let r): pendingEpisode = ep; consumeRemaining = r; showConsumeConfirm = true
        case .exhausted:          showQuotaExhausted = true
        }
    }

    private func startOnline(_ ep: VideoEpisodeItem) {
        if !network.isWiFi && !hasWarnedCellularOnlinePlay {
            pendingOnlineEpisode = ep
            showCellularAlert = true
        } else {
            resolveAndPlayOnline(ep)
        }
    }

    private func resolveAndPlayOnline(_ ep: VideoEpisodeItem) {
        activeKey = ep.url; activeName = ep.name
        resolveError = nil
        engine.beginSwitching()
        isResolvingOnline = true
        Task {
            let resolved = try? await OVideoAPI.resolveRealURL(episodeURL: ep.url)
            await MainActor.run {
                isResolvingOnline = false
                if let resolved = resolved, let u = URL(string: resolved) {
                    hasPlayable = true
                    updateNowPlaying()
                    engine.prepare(url: u, positionKey: ep.url, isLocal: false,
                                   resolver: { try await OVideoAPI.resolveRealURL(episodeURL: ep.url) })
                    recordPlayback()
                } else {
                    resolveError = isGlobalEnglishMode ? "Unable to play" : "无法播放"
                    requestRepairSheet()
                }
            }
        }
    }

    /// ⭐ 不再立即扣点：标记"播放成功后扣"
    private func consumeAndPlay() async {
        guard let ep = pendingEpisode else { return }
        pendingChargeKey = ep.url
        pendingEpisode = nil
        startOnline(ep)
    }

    private func performCharge(_ key: String) {
        guard !isCharging else { return }
        isCharging = true
        let title = "\(baseTitle) · \(activeName ?? "")"
        Task {
            let outcome = await VideoChargeService.charge(episodeKey: key, title: title, auth: authManager)
            isCharging = false
            switch outcome {
            case .charged:
                if pendingChargeKey == key { pendingChargeKey = nil }
                engine.releaseHold(resume: true)
            case .quotaExceeded:
                guard activeKey == key else { return }
                engine.holdPlayback()
                showQuotaExhausted = true
            case .failed:
                guard activeKey == key else { return }
                engine.holdPlayback()
                showChargeFailedAlert = true
            }
        }
    }

    private func localEntry(forOriginal original: String) -> (url: URL, key: String)? {
        if let u = downloadManager.getLocalURL(for: original) { return (u, original) }
        for (key, meta) in downloadManager.cacheMetadata where meta.originalEpisodeURL == original {
            if let u = downloadManager.getLocalURL(for: key) { return (u, key) }
        }
        return nil
    }

    private func updateNowPlaying() {
        let cover = downloadManager.cacheMetadata[activeKey]?.coverImage
            ?? downloadManager.cacheMetadata[realURL]?.coverImage
        engine.setNowPlaying(title: baseTitle, subtitle: activeName, artwork: cover)
    }

    private func recordPlayback() {
        let (trackUserId, trackUserType): (String, String) = {
            if let appleId = authManager.userIdentifier, !appleId.isEmpty { return (appleId, "apple") }
            if let idfv = UIDevice.current.identifierForVendor?.uuidString { return ("dev_" + idfv, "device") }
            return ("guest_user", "device")
        }()

        TrackingManager.shared.track(event: .play,
                                     userId: trackUserId,
                                     userType: trackUserType,
                                     videoURL: activeKey,
                                     videoTitle: displayTitle)

        let originalKey = downloadManager.cacheMetadata[activeKey]?.originalEpisodeURL ?? activeKey
        VideoPlayRecordManager.shared.addRecord(videoTitle: baseTitle,
                                               episodeName: activeName ?? "",
                                               videoURL: originalKey,
                                               coverImage: downloadManager.cacheMetadata[activeKey]?.coverImage,
                                               channelName: channelName,
                                               sourceURL: sourceURL)
    }

    private func recordSeriesWatch() {
        SeriesTrackManager.shared.recordWatch(sourceURL: sourceURL,
                                              title: baseTitle,
                                              cover: downloadManager.cacheMetadata[activeKey]?.coverImage
                                                  ?? downloadManager.cacheMetadata[realURL]?.coverImage,
                                              episodeName: activeName,
                                              channelName: channelName)
    }
}

// MARK: - 选集数据模型
struct VideoEpisodeItem: Identifiable, Hashable {
    var id: String { url }
    let number: String
    let name: String
    let url: String
}

extension OVideoChannel {
    func episodeItems(ascending: Bool = true) -> [VideoEpisodeItem] {
        sortedEpisodes(ascending: ascending).enumerated().map { index, kv in
            VideoEpisodeItem(number: Self.shortNumber(from: kv.name, fallbackIndex: index),
                             name: kv.name,
                             url: kv.url)
        }
    }

    private static func shortNumber(from name: String, fallbackIndex: Int) -> String {
        let digits = name.filter { $0.isNumber }
        if !digits.isEmpty, digits.count <= 4, let n = Int(digits) { return String(n) }
        return String(fallbackIndex + 1)
    }
}

// MARK: - ⭐ 选集弹窗内「批量下载」所需上下文
struct EpisodeBatchContext {
    let item: OVideoItem
    let channel: OVideoChannel
    let channelDisplayName: String

    static func make(seriesTitle: String, sourceURL: String?, cover: String?,
                     channelName: String?, episodes: [VideoEpisodeItem]) -> EpisodeBatchContext? {
        guard let src = sourceURL, !src.isEmpty, !episodes.isEmpty else { return nil }
        var dict: [String: String] = [:]
        var order: [String] = []
        for ep in episodes where dict[ep.name] == nil {
            dict[ep.name] = ep.url
            order.append(ep.name)
        }
        let channel = OVideoChannel(name: channelName ?? "", episodes: dict, episodeOrder: order)
        let en = UserDefaults.standard.bool(forKey: "isGlobalEnglishMode")
        return EpisodeBatchContext(item: OVideoItem(seriesName: seriesTitle, sourceURL: src, cover: cover),
                                   channel: channel,
                                   channelDisplayName: en ? "Current Line" : "当前线路")
    }
}

// MARK: - 选集弹窗
struct EpisodePickerView: View {
    let episodes: [VideoEpisodeItem]
    let currentURL: String
    var cachedOriginalURLs: Set<String> = []
    let onSelect: (VideoEpisodeItem) -> Void
    var seriesTitle: String? = nil
    var batchContext: EpisodeBatchContext? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var index = HLSDownloadManager.shared.statusIndex
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var showBatchDownload = false
    @State private var showQueuedToast = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private func downloadStatus(_ ep: VideoEpisodeItem) -> DownloadStatusIndex.Status? {
        if cachedOriginalURLs.contains(ep.url) || index.cachedKeys.contains(ep.url) { return .cached }
        guard let s = seriesTitle, !s.isEmpty else { return nil }
        return index.statusByTitle["\(s) · \(ep.name)"]
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if batchContext != nil { headerRow }

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(episodes) { ep in cell(ep) }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, showQueuedToast ? 50 : 0)
                }

                if showQueuedToast {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text(isGlobalEnglishMode
                             ? "Added to download queue. Check progress in Cache."
                             : "已加入下载队列，可在「下载管理」查看进度")
                            .foregroundColor(.primary)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(isGlobalEnglishMode ? "Episodes" : "选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isGlobalEnglishMode ? "Done" : "完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showBatchDownload) {
            if let ctx = batchContext {
                BatchDownloadView(item: ctx.item,
                                  channel: ctx.channel,
                                  channelDisplayName: ctx.channelDisplayName,
                                  isAscending: true,
                                  onStartDownloads: { flashQueuedToast() })
                    .environmentObject(authManager)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text(isGlobalEnglishMode ? "\(episodes.count) episodes" : "共 \(episodes.count) 集")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button { showBatchDownload = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down.fill").font(.system(size: 13))
                    Text(isGlobalEnglishMode ? "Batch" : "批量下载")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(
                    LinearGradient(colors: [Color.orange, Color.pink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: Color.orange.opacity(0.35), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func cell(_ ep: VideoEpisodeItem) -> some View {
        let isCurrent = ep.url == currentURL
        let status = downloadStatus(ep)
        let isUnlocked = quotaManager.isUnlocked(ep.url)
        let hasQuota = quotaManager.remaining > 0

        return Button {
            onSelect(ep)
            dismiss()
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15))
                    .frame(height: 50)
                    .overlay(
                        Text(ep.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .foregroundColor(isCurrent ? .white : .primary)
                            .padding(.horizontal, 4)
                    )

                if status == .cached {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12)).foregroundColor(.white)
                        .padding(2).background(Circle().fill(Color.blue)).padding(3)
                } else if status == .downloading {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                        .padding(3).background(Circle().fill(Color.orange)).padding(3)
                } else if !authManager.isSubscribed {
                    if isUnlocked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.green).padding(3)
                    } else if !hasQuota {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8)).foregroundColor(.white)
                            .padding(3).background(Circle().fill(Color.orange))
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func flashQueuedToast() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showQueuedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut) { showQueuedToast = false }
        }
    }
}

// MARK: - 无法播放 / 持续卡顿的「反馈修复」弹窗
struct PlaybackRepairSheet: View {
    let videoTitle: String
    let sourceURL: String
    let episodeURL: String
    var channelName: String? = nil
    var episodeName: String? = nil
    let realURL: String
    var onRetry: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.12)).frame(width: 64, height: 64)
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 26)).foregroundColor(.blue)
                        }
                        Text(isGlobalEnglishMode ? "Can't play this video?" : "视频无法播放？")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                    }
                    .padding(.top, 8).padding(.horizontal, 16)

                    if let onRetry = onRetry {
                        Button(action: onRetry) {
                            Label(isGlobalEnglishMode ? "Reload" : "重新加载",
                                  systemImage: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12)))
                        }
                        .padding(.horizontal, 16)
                    }

                    Spacer()

                    ReportLinkCard(videoTitle: videoTitle,
                                   sourceURL: sourceURL,
                                   episodeURL: episodeURL,
                                   channelName: channelName,
                                   episodeName: episodeName,
                                   realURL: realURL)
                }
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isGlobalEnglishMode ? "Close" : "关闭") { dismiss() }
                }
            }
        }
    }
}