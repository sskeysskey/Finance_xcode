import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit
import MediaPlayer
import NaturalLanguage

// ============================================================================
// MARK: - 音频会话：专用串行队列执行，绝不阻塞主线程（setActive 是跨进程调用，可能耗时几十毫秒）
// ============================================================================
enum AudioSessionController {
    private static let queue = DispatchQueue(label: "com.onews.audio.session", qos: .userInitiated)

    private static func configureAndActivate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .spokenAudio {
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
            }
            try session.setActive(true, options: [])
        } catch {
            print("🎧 [AudioSession] 激活失败: \(error.localizedDescription)")
        }
    }

    /// 异步激活（开始播放时与文本预处理并行执行）
    static func activate() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                configureAndActivate()
                cont.resume()
            }
        }
    }

    /// 同步激活（仅在被打断后恢复播放时使用，保证 play() 前会话已就绪）
    static func activateSync() {
        queue.sync { configureAndActivate() }
    }

    static func deactivate() {
        queue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("🎧 [AudioSession] 释放失败: \(error.localizedDescription)")
            }
        }
    }
}

// ============================================================================
// MARK: - 合成块写入器：在合成器回调线程里直接写文件，主线程只在"完成"时收到一次通知
// ============================================================================
final class SpeechChunkWriter: @unchecked Sendable {
    enum Event: Sendable {
        case finished(url: URL, duration: TimeInterval, hasAudio: Bool)
        case failed(String)
    }

    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var done = false
    private var _lastActivity = Date()

    init(url: URL) { self.url = url }

    var lastActivity: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastActivity
    }

    func cancel() {
        lock.lock()
        done = true
        file = nil
        lock.unlock()
    }

    /// 返回 nil 表示"继续写"，非 nil 表示需要通知主线程
    func consume(_ buffer: AVAudioBuffer) -> Event? {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return nil }
        _lastActivity = Date()

        guard let pcm = buffer as? AVAudioPCMBuffer else {
            done = true; file = nil
            return .failed(Localized.errPCMBuffer)
        }

        if pcm.frameLength == 0 {
            done = true
            file = nil   // 释放即关闭文件、刷盘
            let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
            return .finished(url: url, duration: duration, hasAudio: frames > 0)
        }

        do {
            if file == nil {
                // 处理格式与 buffer 完全一致，任何音色（Int16 / Float32）都能写
                file = try AVAudioFile(forWriting: url,
                                       settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
                sampleRate = pcm.format.sampleRate
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
            return nil
        } catch {
            done = true; file = nil
            return .failed("\(Localized.errPlayerFailed): \(error.localizedDescription)")
        }
    }
}

/// 后台预处理结果
struct PreparedSpeech: Sendable {
    let chunks: [String]
    let charCounts: [Int]
    let voiceIdentifier: String?
    let fallbackLanguage: String
}

// ============================================================================
// MARK: - 高频进度状态（独立对象：只有进度条那一行观察它）
// ============================================================================
@MainActor
final class AudioProgressState: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTimeString = "00:00"
    @Published private(set) var durationString = "00:00"
    @Published private(set) var totalSeconds: TimeInterval = 0

    private var lastCurrentSec = 0
    private var lastTotalSec = 0

    /// 值不变不写 → 不 publish；时间字符串只在"秒"变化时重新格式化
    func update(progress p: Double, currentSeconds: TimeInterval, totalSeconds total: TimeInterval) {
        let clamped = p.isFinite ? min(max(p, 0), 1) : 0
        if clamped != progress { progress = clamped }

        let cs = currentSeconds.isFinite ? max(0, Int(currentSeconds)) : 0
        if cs != lastCurrentSec {
            lastCurrentSec = cs
            currentTimeString = Self.format(cs)
        }
        let ts = total.isFinite ? max(0, Int(total)) : 0
        if ts != lastTotalSec {
            lastTotalSec = ts
            durationString = Self.format(ts)
            totalSeconds = Double(ts)
        }
    }

    func reset() {
        if progress != 0 { progress = 0 }
        lastCurrentSec = 0
        lastTotalSec = 0
        if currentTimeString != "00:00" { currentTimeString = "00:00" }
        if durationString != "00:00" { durationString = "00:00" }
        if totalSeconds != 0 { totalSeconds = 0 }
    }

    static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

// ============================================================================
// MARK: - 锁屏 / 耳机远程控制：全局只注册一次，转发给"当前播放器"
// （旧实现每次播放都 addTarget，且 teardown 漏删 skipBackward → 后退 15 秒会被叠加执行）
// ============================================================================
@MainActor
final class AudioRemoteCommandRouter {
    static let shared = AudioRemoteCommandRouter()
    private weak var owner: AudioPlayerManager?
    private var registered = false

    func activate(_ manager: AudioPlayerManager) {
        owner = manager
        registerIfNeeded()
        setEnabled(true)
    }

    func deactivate(_ manager: AudioPlayerManager) {
        guard owner == nil || owner === manager else { return }
        owner = nil
        setEnabled(false)
    }

    fileprivate func route(_ body: (AudioPlayerManager) -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
        guard let o = owner else { return .noActionableNowPlayingItem }
        return body(o)
    }

    private func setEnabled(_ on: Bool) {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = on
        cc.pauseCommand.isEnabled = on
        cc.togglePlayPauseCommand.isEnabled = on
        cc.stopCommand.isEnabled = on
        cc.nextTrackCommand.isEnabled = on
        cc.previousTrackCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = on
        cc.skipForwardCommand.isEnabled = false          // 保持原设计：锁屏右侧显示"下一篇"
        cc.changePlaybackPositionCommand.isEnabled = on  // 新增：锁屏可拖动进度
    }

    private func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        let cc = MPRemoteCommandCenter.shared()
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.preferredIntervals = [15]

        cc.playCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remotePlay() } }
        }
        cc.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remotePause() } }
        }
        cc.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remoteToggle() } }
        }
        cc.stopCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remoteStop() } }
        }
        cc.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remoteNext() } }
        }
        cc.skipBackwardCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remoteSkip(by: -15) } }
        }
        cc.skipForwardCommand.addTarget { _ in
            MainActor.assumeIsolated { AudioRemoteCommandRouter.shared.route { $0.remoteSkip(by: 15) } }
        }
        cc.changePlaybackPositionCommand.addTarget { event in
            let t = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            return MainActor.assumeIsolated {
                AudioRemoteCommandRouter.shared.route { m in
                    guard let t else { return .commandFailed }
                    return m.remoteSeek(to: t)
                }
            }
        }
    }
}

// ============================================================================
// MARK: - AudioPlayerManager
// ============================================================================
@MainActor
class AudioPlayerManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {

    // MARK: 低频 UI 状态（值不变不写）
    @Published var isPlaybackActive = false
    @Published var isPlaying = false
    @Published var isSynthesizing = false
    @Published var preferredVoiceIdentifiers: [String: String] = [:]

    /// ★ 高频进度独立出去；下面三个只读属性保持旧 API 兼容
    let progressState = AudioProgressState()
    var progress: Double { progressState.progress }
    var currentTimeString: String { progressState.currentTimeString }
    var durationString: String { progressState.durationString }

    // 回调
    var onPlaybackFinished: (() -> Void)?
    var onNextRequested: (() -> Void)?
    var onToggleRepeatRequested: (() -> Void)?

    nonisolated static let autoPlayEnabledKey = "audio.autoPlayEnabled"
    nonisolated static let playbackRateKey = "audio.playbackRate"
    private let preferredVoicesKey = "audio.preferredVoices"

    /// ★ 默认 = 连续播放（true）。用户手动切换后会被记住。
    @Published var isAutoPlayEnabled = true {
        didSet {
            guard oldValue != isAutoPlayEnabled else { return }
            UserDefaults.standard.set(isAutoPlayEnabled, forKey: Self.autoPlayEnabledKey)
            updateNowPlayingInfo()
        }
    }

    @Published var playbackRate: Float = 1.0 {
        didSet {
            if playbackRate < 0.5 { playbackRate = 0.5 }
            else if playbackRate > 2.0 { playbackRate = 2.0 }
            applyPlaybackRate()
            UserDefaults.standard.set(Double(playbackRate), forKey: Self.playbackRateKey)
            updateNowPlayingInfo()
        }
    }

    // MARK: 私有状态
    private enum ChunkState { case pending, ready(URL), empty }

    private var speechSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var preparedNext: (index: Int, player: AVAudioPlayer)?
    private var progressTimer: Timer?
    private var watchdogTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var nowPlayingTitle: String = Localized.playingArticle

    private var chunkTexts: [String] = []
    private var chunkCharCounts: [Int] = []
    private var chunkStates: [ChunkState] = []
    private var chunkDurations: [TimeInterval] = []
    private var currentPlayingChunkIndex = 0
    private var synthesizingIndex: Int?
    private var currentWriter: SpeechChunkWriter?
    private var synthesisRetryCount = 0
    private var waitingForChunk = false
    private var hasFinished = false
    private var selectedVoice: AVSpeechSynthesisVoice?
    private var synthesisGeneration = 0

    private var totalDuration: TimeInterval = 0
    private var elapsedBeforeCurrentChunk: TimeInterval = 0

    private var sessionNeedsReactivation = true
    private var resumeAfterInterruption = false
    private var isInBackground = false

    override init() {
        UserDefaults.standard.register(defaults: [
            Self.autoPlayEnabledKey: true,     // ★ 默认连续播放
            Self.playbackRateKey: 1.0
        ])
        super.init()
        speechSynthesizer.delegate = self
        isAutoPlayEnabled = UserDefaults.standard.bool(forKey: Self.autoPlayEnabledKey)
        let savedRate = Float(UserDefaults.standard.double(forKey: Self.playbackRateKey))
        playbackRate = (0.5...2.0).contains(savedRate) ? savedRate : 1.0
        if let saved = UserDefaults.standard.dictionary(forKey: preferredVoicesKey) as? [String: String] {
            preferredVoiceIdentifiers = saved
        }
        setupObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        progressTimer?.invalidate()
        watchdogTimer?.invalidate()
        currentWriter?.cancel()
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.delegate = nil
        var urls: [URL] = []
        for s in chunkStates { if case .ready(let u) = s { urls.append(u) } }
        if let w = currentWriter { urls.append(w.url) }
        if !urls.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    // MARK: - 工具
    private func setIfChanged<T: Equatable>(_ kp: ReferenceWritableKeyPath<AudioPlayerManager, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }

    private static func removeFilesInBackground(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private static func makePlayer(url: URL, rate: Float) throws -> AVAudioPlayer {
        let p = try AVAudioPlayer(contentsOf: url)
        p.enableRate = true          // 必须在 prepareToPlay 之前
        p.prepareToPlay()
        p.rate = rate
        return p
    }

    static func rateText(_ r: Float) -> String {
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "x"
    }

    private func isEmptyChunk(_ i: Int) -> Bool {
        if case .empty = chunkStates[i] { return true }
        return false
    }

    private func resetSpeechSynthesizer() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.delegate = nil
        speechSynthesizer = AVSpeechSynthesizer()
        speechSynthesizer.delegate = self
    }

    private func applyPlaybackRate() {
        audioPlayer?.rate = playbackRate
        preparedNext?.player.rate = playbackRate
    }

    // MARK: - 系统通知（打断 / 耳机拔出 / 前后台）
    private func setupObservers() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optRaw) }
        })

        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // 拔耳机 / 断开蓝牙 → 自动暂停（Apple HIG 要求）
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                   self?.isPlaying == true {
                    self?.pausePlayback()
                }
            }
        })

        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isInBackground = true
                self?.stopProgressTimer()        // 后台不需要刷 UI，锁屏由系统推算
            }
        })

        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isInBackground = false
                self.publishProgressNow()
                if self.isPlaying { self.startProgressTimer() }
            }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            sessionNeedsReactivation = true
            if isPlaying {
                resumeAfterInterruption = true
                pausePlayback()
            }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            // 只有"打断前正在播"才自动恢复；用户自己暂停的不擅自恢复
            if opts.contains(.shouldResume) && resumeAfterInterruption {
                resumePlayback()
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    func setHasNext(_ hasNext: Bool) {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
    }

    // MARK: - 远程控制入口（Router 调用）
    fileprivate func remotePlay() -> MPRemoteCommandHandlerStatus {
        guard audioPlayer != nil || hasFinished else { return .noActionableNowPlayingItem }
        if !isPlaying { resumePlayback() }
        return .success
    }
    fileprivate func remotePause() -> MPRemoteCommandHandlerStatus {
        if isPlaying { pausePlayback() }
        return .success
    }
    fileprivate func remoteToggle() -> MPRemoteCommandHandlerStatus {
        guard audioPlayer != nil || hasFinished else { return .noActionableNowPlayingItem }
        playPause()
        return .success
    }
    fileprivate func remoteStop() -> MPRemoteCommandHandlerStatus {
        stop()
        return .success
    }
    fileprivate func remoteNext() -> MPRemoteCommandHandlerStatus {
        guard let cb = onNextRequested else { return .commandFailed }
        cb()
        return .success
    }
    fileprivate func remoteSkip(by seconds: TimeInterval) -> MPRemoteCommandHandlerStatus {
        seekBy(seconds: seconds)
        return .success
    }
    fileprivate func remoteSeek(to time: TimeInterval) -> MPRemoteCommandHandlerStatus {
        seekToTime(max(0, min(time, totalDuration)))
        return .success
    }

    // MARK: - 锁屏信息（只在状态变化时写，不再逐帧写）
    private func updateNowPlayingInfo(elapsedOverride: TimeInterval? = nil) {
        guard isPlaybackActive else { return }
        var info: [String: Any] = [:]
        let speedText = Self.rateText(playbackRate)
        let modeText = isAutoPlayEnabled ? Localized.autoPlay : Localized.singlePlay
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = "\(modeText) • \(speedText)"
        info[MPMediaItemPropertyAlbumTitle] = "Speed \(speedText)"
        let elapsed = elapsedOverride ?? (elapsedBeforeCurrentChunk + (audioPlayer?.currentTime ?? 0))
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = max(totalDuration, elapsed)
        // ★ 用真实倍速，系统据此推算锁屏进度，不会漂移
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 进度刷新（4Hz，替代 60/120Hz 的 CADisplayLink）
    private func startProgressTimer() {
        guard progressTimer == nil, !isInBackground else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishProgressNow() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func publishProgressNow() {
        let total = totalDuration
        let current = elapsedBeforeCurrentChunk + (audioPlayer?.currentTime ?? 0)
        progressState.update(progress: total > 0 ? min(current / total, 1) : 0,
                             currentSeconds: current,
                             totalSeconds: max(total, current))
    }

    private func recomputeTotalDuration() {
        var known: TimeInterval = 0
        var knownChars = 0
        var unknownChars = 0
        for i in chunkStates.indices {
            switch chunkStates[i] {
            case .pending:
                unknownChars += chunkCharCounts[i]
            case .ready, .empty:
                known += chunkDurations[i]
                knownChars += chunkCharCounts[i]
            }
        }
        if unknownChars == 0 || knownChars == 0 || known <= 0 {
            totalDuration = known
        } else {
            totalDuration = known + known / Double(knownChars) * Double(unknownChars)
        }
    }

    // MARK: - 会话清理（stop / 切下一篇 / 重新开始 共用）
    private func teardownCurrentSession() {
        synthesisGeneration += 1
        var trash: [URL] = []

        let wasSynthesizing = synthesizingIndex != nil || currentWriter != nil
        if let w = currentWriter { w.cancel(); trash.append(w.url) }
        currentWriter = nil
        synthesizingIndex = nil
        invalidateWatchdog()
        // 只有真的在合成时才重建合成器（防止中断 write 导致底层死锁；空闲时无需付出这个成本）
        if wasSynthesizing { resetSpeechSynthesizer() }

        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        preparedNext = nil
        stopProgressTimer()

        for s in chunkStates { if case .ready(let u) = s { trash.append(u) } }
        chunkTexts = []
        chunkCharCounts = []
        chunkStates = []
        chunkDurations = []
        currentPlayingChunkIndex = 0
        totalDuration = 0
        elapsedBeforeCurrentChunk = 0
        waitingForChunk = false
        hasFinished = false
        synthesisRetryCount = 0

        Self.removeFilesInBackground(trash)
    }

    func prepareForNextTransition() {
        teardownCurrentSession()
        setIfChanged(\.isPlaying, false)
        setIfChanged(\.isSynthesizing, true)   // 保持播放器面板，显示"合成中"
        progressState.reset()
    }

    // MARK: - 文本分块（首块更小 → 更快出声）
    nonisolated private func splitIntoChunks(_ text: String) -> [String] {
        let firstChunkTarget = 160
        let secondChunkTarget = 450
        let normalChunkTarget = 900

        guard text.count > firstChunkTarget else { return [text] }

        let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if sentenceEnders.contains(char) || char == "\n" {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sentences.append(current)
                    current = ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(current)
        }
        guard sentences.count > 1 else { return [text] }

        var chunks: [String] = []
        var currentChunk = ""
        var currentCount = 0

        for sentence in sentences {
            let target: Int
            switch chunks.count {
            case 0: target = firstChunkTarget
            case 1: target = secondChunkTarget
            default: target = normalChunkTarget
            }
            let sCount = sentence.count
            if currentCount + sCount > target && currentCount > 0 {
                chunks.append(currentChunk)
                currentChunk = sentence
                currentCount = sCount
            } else {
                currentChunk += sentence
                currentCount += sCount
            }
        }
        if currentCount > 0 { chunks.append(currentChunk) }
        return chunks
    }

    /// 全部在后台线程：分段规整 + 读音预处理 + 分块 + 选择音色
    nonisolated private func prepareSpeechOffMain(text: String, language: String,
                                                  preferredVoices: [String: String]) -> PreparedSpeech {
        let normalized = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let processed = preprocessText(normalized, language: language)
        let chunks = splitIntoChunks(processed).filter { $0.contains { !$0.isWhitespace } }
        let voice = Self.resolveVoice(for: normalized, language: language, preferredVoices: preferredVoices)
        return PreparedSpeech(chunks: chunks,
                              charCounts: chunks.map { $0.count },
                              voiceIdentifier: voice.identifier,
                              fallbackLanguage: voice.language)
    }

    nonisolated private static func resolveVoice(for text: String, language: String,
                                                 preferredVoices: [String: String]) -> (identifier: String?, language: String) {
        if language.hasPrefix("en") {
            if let id = preferredVoices["en"], AVSpeechSynthesisVoice(identifier: id) != nil {
                return (id, "en-US")
            }
            return (AVSpeechSynthesisVoice(language: "en-US")?.identifier, "en-US")
        }

        // 语言检测只需取样，不必扫全文
        let sample = String(text.prefix(3000))
        let forDetection = sample.replacingOccurrences(of: "https?://[^\\s]+", with: "", options: .regularExpression)
        var code = "zh-CN"
        if forDetection.range(of: "\\p{Han}", options: .regularExpression) == nil {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(forDetection)
            code = recognizer.dominantLanguage?.rawValue
                ?? (Locale.current.language.languageCode?.identifier ?? "zh-CN")
        }

        let langKey = String(code.prefix(2))
        if let id = preferredVoices[langKey], AVSpeechSynthesisVoice(identifier: id) != nil {
            return (id, code)
        }
        let matches = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: code) }
        if let v = matches.first(where: { $0.quality == .premium })
            ?? matches.first(where: { $0.quality == .enhanced })
            ?? matches.first {
            return (v.identifier, code)
        }
        return (AVSpeechSynthesisVoice(language: code)?.identifier, "zh-CN")
    }

    // MARK: - ▶ 播放入口
    func startPlayback(text: String, title: String? = nil, language: String = "zh-CN") {
        guard text.contains(where: { !$0.isWhitespace }) else {
            handleError(Localized.errEmptyText)
            return
        }

        teardownCurrentSession()
        let generation = synthesisGeneration
        nowPlayingTitle = (title?.isEmpty == false) ? title! : Localized.playingArticle
        waitingForChunk = true

        // ★ 立即给 UI 反馈：面板马上出现并显示"合成中"
        setIfChanged(\.isPlaybackActive, true)
        setIfChanged(\.isSynthesizing, true)
        setIfChanged(\.isPlaying, false)
        progressState.reset()
        AudioRemoteCommandRouter.shared.activate(self)
        updateNowPlayingInfo()

        let prefs = preferredVoiceIdentifiers
        Task { @MainActor in
            // 会话激活 与 文本预处理 并行
            async let sessionReady: Void = AudioSessionController.activate()
            let prepared = await Task.detached(priority: .userInitiated) { [self] in
                self.prepareSpeechOffMain(text: text, language: language, preferredVoices: prefs)
            }.value
            await sessionReady

            // ★ 期间用户已停止 / 切换 → 丢弃（旧实现会"关掉后自己又响起来"）
            guard self.synthesisGeneration == generation else { return }
            guard !prepared.chunks.isEmpty else {
                self.handleError(Localized.errEmptyText)
                return
            }

            self.sessionNeedsReactivation = false
            if let id = prepared.voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
                self.selectedVoice = v
            } else {
                self.selectedVoice = AVSpeechSynthesisVoice(language: prepared.fallbackLanguage)
            }

            self.chunkTexts = prepared.chunks
            self.chunkCharCounts = prepared.charCounts
            self.chunkStates = Array(repeating: .pending, count: prepared.chunks.count)
            self.chunkDurations = Array(repeating: 0, count: prepared.chunks.count)
            self.currentPlayingChunkIndex = 0
            self.synthesizeChunk(at: 0)
        }
    }

    // MARK: - 合成
    nonisolated private static func makeBufferCallback(
        writer: SpeechChunkWriter,
        onEvent: @escaping @Sendable (SpeechChunkWriter.Event) -> Void
    ) -> AVSpeechSynthesizer.BufferCallback {
        return { buffer in
            if let event = writer.consume(buffer) { onEvent(event) }
        }
    }

    private func synthesizeChunk(at index: Int) {
        guard index < chunkTexts.count else {
            synthesizingIndex = nil
            invalidateWatchdog()
            return
        }

        synthesizingIndex = index
        let generation = synthesisGeneration
        let chunkText = chunkTexts[index]

        let utterance = AVSpeechUtterance(string: chunkText)
        if let voice = selectedVoice {
            utterance.voice = voice
        } else {
            let hasChinese = chunkText.range(of: "\\p{Han}", options: .regularExpression) != nil
            utterance.voice = AVSpeechSynthesisVoice(language: hasChinese ? "zh-CN" : "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05
        utterance.preUtteranceDelay = 0.05

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk_\(index)_\(UUID().uuidString).caf")
        let writer = SpeechChunkWriter(url: url)
        currentWriter = writer
        startWatchdogIfNeeded()

        let callback = Self.makeBufferCallback(writer: writer) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleWriterEvent(event, index: index, generation: generation, writer: writer)
            }
        }
        speechSynthesizer.write(utterance, toBufferCallback: callback)
    }

    private func handleWriterEvent(_ event: SpeechChunkWriter.Event, index: Int,
                                   generation: Int, writer: SpeechChunkWriter) {
        guard generation == synthesisGeneration,
              writer === currentWriter,
              index < chunkStates.count else { return }
        currentWriter = nil

        switch event {
        case .failed(let message):
            if retryChunk(index) { return }
            handleError(message)

        case .finished(let url, let duration, let hasAudio):
            synthesisRetryCount = 0
            if hasAudio {
                chunkStates[index] = .ready(url)
                chunkDurations[index] = duration
            } else {
                chunkStates[index] = .empty      // 空块直接跳过，不再整篇报错
                chunkDurations[index] = 0
                Self.removeFilesInBackground([url])
            }
            recomputeTotalDuration()

            if waitingForChunk && index == currentPlayingChunkIndex {
                playChunk(at: index, startTime: 0, shouldPlay: true)
            } else if audioPlayer != nil {
                prepareNextPlayerIfPossible()
                publishProgressNow()
                updateNowPlayingInfo()
            }
            synthesizeChunk(at: index + 1)
        }
    }

    /// 合成失败 / 超时：自动重试一次
    private func retryChunk(_ index: Int) -> Bool {
        guard synthesisRetryCount < 1 else { return false }
        synthesisRetryCount += 1
        print("🔁 [TTS] 第 \(index) 块合成异常，重试一次")
        currentWriter?.cancel()
        if let w = currentWriter { Self.removeFilesInBackground([w.url]) }
        currentWriter = nil
        resetSpeechSynthesizer()
        synthesizeChunk(at: index)
        return true
    }

    private func startWatchdogIfNeeded() {
        guard watchdogTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdogTimer = t
    }

    private func watchdogTick() {
        guard let index = synthesizingIndex, let w = currentWriter else {
            invalidateWatchdog()
            return
        }
        if Date().timeIntervalSince(w.lastActivity) > 15 {
            if retryChunk(index) { return }
            handleError(Localized.errSynthesisTimeout)
        }
    }

    private func invalidateWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - 播放
    private func playChunk(at requestedIndex: Int, startTime: TimeInterval, shouldPlay: Bool) {
        var index = requestedIndex
        while index < chunkStates.count && isEmptyChunk(index) { index += 1 }
        guard index < chunkStates.count else { finishNaturally(); return }

        currentPlayingChunkIndex = index
        elapsedBeforeCurrentChunk = chunkDurations.prefix(index).reduce(0, +)

        guard case .ready(let url) = chunkStates[index] else {
            // 该块尚未合成完 → 等待
            audioPlayer?.delegate = nil
            audioPlayer?.stop()
            audioPlayer = nil
            waitingForChunk = true
            stopProgressTimer()
            setIfChanged(\.isPlaying, false)
            setIfChanged(\.isSynthesizing, true)
            return
        }

        let player: AVAudioPlayer
        if let p = preparedNext, p.index == index {
            player = p.player                      // ★ 预热好的播放器 → 块间几乎无缝
        } else {
            do { player = try Self.makePlayer(url: url, rate: playbackRate) }
            catch { handleError("\(Localized.errPlayerFailed): \(error)"); return }
        }
        preparedNext = nil

        if let old = audioPlayer, old !== player {
            old.delegate = nil
            old.stop()
        }
        audioPlayer = player
        player.delegate = self
        player.rate = playbackRate
        player.currentTime = startTime > 0 ? min(startTime, max(0, player.duration - 0.05)) : 0

        waitingForChunk = false
        hasFinished = false

        if shouldPlay {
            if sessionNeedsReactivation {
                AudioSessionController.activateSync()
                sessionNeedsReactivation = false
            }
            player.play()
            setIfChanged(\.isPlaying, true)
            startProgressTimer()
        } else {
            setIfChanged(\.isPlaying, false)
            stopProgressTimer()
        }
        setIfChanged(\.isSynthesizing, false)

        AudioRemoteCommandRouter.shared.activate(self)
        publishProgressNow()
        updateNowPlayingInfo()
        prepareNextPlayerIfPossible()
    }

    private func prepareNextPlayerIfPossible() {
        guard !chunkStates.isEmpty else { return }
        var next = currentPlayingChunkIndex + 1
        while next < chunkStates.count && isEmptyChunk(next) { next += 1 }
        guard next < chunkStates.count, case .ready(let url) = chunkStates[next] else { return }
        if let p = preparedNext, p.index == next { return }
        if let player = try? Self.makePlayer(url: url, rate: playbackRate) {
            preparedNext = (next, player)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        let next = currentPlayingChunkIndex + 1
        if next < chunkStates.count {
            playChunk(at: next, startTime: 0, shouldPlay: true)
        } else {
            finishNaturally()
        }
    }

    // MARK: - 用户语音偏好
    nonisolated static func groupVoices() -> [(language: String, voices: [AVSpeechSynthesisVoice])] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let grouped = Dictionary(grouping: voices, by: { $0.language })
        return grouped.map { (lang, list) in
            let sorted = list.sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
            return (lang, sorted)
        }
        .sorted { lhs, rhs in
            let priority: (String) -> Int = {
                if $0.hasPrefix("zh") { return 0 }
                if $0.hasPrefix("en") { return 1 }
                return 2
            }
            let pl = priority(lhs.language), pr = priority(rhs.language)
            if pl != pr { return pl < pr }
            return lhs.language < rhs.language
        }
    }

    func availableVoicesGrouped() -> [(language: String, voices: [AVSpeechSynthesisVoice])] {
        Self.groupVoices()
    }

    func setPreferredVoice(_ voice: AVSpeechSynthesisVoice) {
        let langKey = String(voice.language.prefix(2))
        preferredVoiceIdentifiers[langKey] = voice.identifier
        UserDefaults.standard.set(preferredVoiceIdentifiers, forKey: preferredVoicesKey)
    }

    func clearPreferredVoice(forLanguagePrefix prefix: String) {
        preferredVoiceIdentifiers.removeValue(forKey: prefix)
        UserDefaults.standard.set(preferredVoiceIdentifiers, forKey: preferredVoicesKey)
    }

    func isPreferredVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let langKey = String(voice.language.prefix(2))
        return preferredVoiceIdentifiers[langKey] == voice.identifier
    }

    // MARK: - 播放控制
    func playPause() {
        if isPlaying { pausePlayback() } else { resumePlayback() }
    }

    private func pausePlayback() {
        audioPlayer?.pause()
        setIfChanged(\.isPlaying, false)
        stopProgressTimer()
        publishProgressNow()
        updateNowPlayingInfo()
    }

    private func resumePlayback() {
        if hasFinished {                       // 单篇模式播完后再点播放 → 从头重播
            playChunk(at: 0, startTime: 0, shouldPlay: true)
            return
        }
        guard let player = audioPlayer else { return }
        if sessionNeedsReactivation {
            AudioSessionController.activateSync()
            sessionNeedsReactivation = false
        }
        player.rate = playbackRate
        player.play()
        setIfChanged(\.isPlaying, true)
        startProgressTimer()
        AudioRemoteCommandRouter.shared.activate(self)
        updateNowPlayingInfo()
    }

    func stop() {
        // ★ 空闲时直接返回（旧实现每次"下一篇 / 返回列表"都会重建合成器 + 同步释放会话 → 卡顿）
        let hasWork = isPlaybackActive || isPlaying || isSynthesizing
            || audioPlayer != nil || !chunkStates.isEmpty || currentWriter != nil
        guard hasWork else { return }

        teardownCurrentSession()
        setIfChanged(\.isPlaying, false)
        setIfChanged(\.isSynthesizing, false)
        setIfChanged(\.isPlaybackActive, false)
        progressState.reset()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AudioRemoteCommandRouter.shared.deactivate(self)
        AudioSessionController.deactivate()
        sessionNeedsReactivation = true
        resumeAfterInterruption = false
    }

    private func finishNaturally() {
        audioPlayer?.stop()
        stopProgressTimer()
        hasFinished = true
        waitingForChunk = false
        setIfChanged(\.isPlaying, false)
        setIfChanged(\.isSynthesizing, false)

        let total = totalDuration
        progressState.update(progress: 1, currentSeconds: total, totalSeconds: total)
        updateNowPlayingInfo(elapsedOverride: total)

        if isAutoPlayEnabled {          // ★ 连续播放：自动下一篇
            onNextRequested?()
        }
        onPlaybackFinished?()
    }

    // MARK: - Seek
    func seek(to value: Double) {
        guard totalDuration > 0 else { return }
        seekToTime(totalDuration * min(max(value, 0), 1))
    }

    func seekBy(seconds: TimeInterval) {
        guard let player = audioPlayer, totalDuration > 0 else { return }
        let current = elapsedBeforeCurrentChunk + player.currentTime
        seekToTime(max(0, min(totalDuration, current + seconds)))
    }

    /// ★ 修复：目标位置落在"尚未合成"的区域时，停在已合成部分的末尾（旧实现会跳回开头）
    private func seekToTime(_ target: TimeInterval) {
        guard !chunkStates.isEmpty else { return }
        var cumulative: TimeInterval = 0
        var lastReady: Int?
        var i = 0
        scan: while i < chunkStates.count {
            switch chunkStates[i] {
            case .pending:
                break scan
            case .empty:
                break
            case .ready:
                let d = chunkDurations[i]
                if target < cumulative + d {
                    jump(to: i, time: max(0, target - cumulative))
                    return
                }
                cumulative += d
                lastReady = i
            }
            i += 1
        }
        if let last = lastReady {
            jump(to: last, time: max(0, chunkDurations[last] - 0.25))
        }
    }

    private func jump(to index: Int, time: TimeInterval) {
        if index == currentPlayingChunkIndex, let player = audioPlayer, !hasFinished {
            player.currentTime = time
            publishProgressNow()
            updateNowPlayingInfo()
        } else {
            playChunk(at: index, startTime: time, shouldPlay: isPlaying || waitingForChunk)
        }
    }

    private func handleError(_ message: String) {
        print("错误: \(message)")
        stop()
    }

    // ========================================================================
    // MARK: - 文本预处理（原样保留，均为 nonisolated，在后台线程执行）
    // ========================================================================
    nonisolated private func removeCommasFromNumbers(_ text: String) -> String {
        let pattern = #"(\d),(\d{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        var result = text
        while regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1$2"
            )
        }
        return result
    }

    nonisolated private func formatDigitsToChinesePerChar(_ digits: String) -> String {
        let map: [Character: String] = [
            "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"
        ]
        return digits.compactMap { map[$0] }.joined()
    }

    nonisolated private func normalizeDash(_ text: String) -> String {
        let dashes = ["—", "–", "―", "–", "－", "‑", "‒", "〜", "~", "—", "——"]
        var t = text
        for d in dashes {
            t = t.replacingOccurrences(of: d, with: "-")
        }
        while t.contains("--") {
            t = t.replacingOccurrences(of: "--", with: "-")
        }
        return t
    }

    nonisolated private func readChineseNumber(_ n: Int) -> String {
        let digits = ["零","一","二","三","四","五","六","七","八","九"]
        if n < 10 { return digits[n] }
        if n < 20 {
            if n == 10 { return "十" }
            return "十" + digits[n % 10]
        }
        if n < 100 {
            let tens = n / 10
            let ones = n % 10
            return digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
        }
        if n < 1000 {
            let hundreds = n / 100
            let rest = n % 100
            let hundredPart = digits[hundreds] + "百"
            if rest == 0 { return hundredPart }
            if rest < 10 { return hundredPart + "零" + digits[rest] }
            if rest < 20 { return hundredPart + "一十" + (rest % 10 == 0 ? "" : digits[rest % 10]) }
            let tens = (rest / 10)
            let ones = rest % 10
            return hundredPart + digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
        }
        if n < 10000 {
            let thousands = n / 1000
            let rest = n % 1000
            let thousandHead = (thousands == 2 ? "两" : digits[thousands]) + "千"
            if rest == 0 { return thousandHead }
            if rest < 100 {
                if rest < 10 { return thousandHead + "零" + digits[rest] }
                if rest < 20 {
                    if rest == 10 { return thousandHead + "零十" }
                    return thousandHead + "零十" + digits[rest % 10]
                } else {
                    let tens = rest / 10
                    let ones = rest % 10
                    return thousandHead + digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
                }
            } else {
                let hundreds = rest / 100
                let rest2 = rest % 100
                var res = thousandHead + digits[hundreds] + "百"
                if rest2 == 0 { return res }
                if rest2 < 10 { return res + "零" + digits[rest2] }
                if rest2 < 20 {
                    if rest2 == 10 { return res + "一十" }
                    return res + "一十" + digits[rest2 % 10]
                } else {
                    let tens = rest2 / 10
                    let ones = rest2 % 10
                    res += digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
                    return res
                }
            }
        }
        if n < 100000 {
            let wan = n / 10000
            let rest = n % 10000
            let head = (wan == 2 ? "两" : digits[wan]) + "万"
            if rest == 0 { return head }
            return head + readChineseNumber(rest)
        }
        return String(n).map { String($0) }.joined(separator: "")
    }

    nonisolated private func replaceYearMentionsForChinese(_ text: String) -> String {
        var result = text

        let linkedYearPattern = #"(?<!\d)(\d{4})(?=\s*(?:和|与|、)\s*\d{4}\s*(?:年|年代))"#
        if let regex = try? NSRegularExpression(pattern: linkedYearPattern, options: []) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 2 else { return }
                if let r1 = Range(match.range(at: 1), in: result) {
                    let year = String(result[r1])
                    let yearZh = formatDigitsToChinesePerChar(year)
                    replacements.append((match.range(at: 1), yearZh))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: result) {
                    result.replaceSubrange(r, with: rep)
                }
            }
        }

        let rangeWithYearPattern = #"(?<!\d)(\d{4})(?:\s*年)?\s*-\s*(\d{4})(?=\s*(?:年|年代))"#
        if let regex = try? NSRegularExpression(pattern: rangeWithYearPattern, options: []) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: result),
                   let r2 = Range(match.range(at: 2), in: result) {
                    let leftYear = String(result[r1])
                    let rightYear = String(result[r2])
                    let leftDigits = formatDigitsToChinesePerChar(leftYear)
                    let rightDigits = formatDigitsToChinesePerChar(rightYear)
                    let replacement = "\(leftDigits)到\(rightDigits)"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: result) {
                    result.replaceSubrange(r, with: rep)
                }
            }
        }

        let singleYearPattern = #"(?<!\d)(\d{4})(?=\s*(?:年|年代))"#
        if let regex = try? NSRegularExpression(pattern: singleYearPattern, options: []) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 2 else { return }
                if let r1 = Range(match.range(at: 1), in: result) {
                    let year = String(result[r1])
                    let yearZh = formatDigitsToChinesePerChar(year)
                    replacements.append((match.range(at: 1), yearZh))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: result) {
                    result.replaceSubrange(r, with: rep)
                }
            }
        }

        return result
    }

    nonisolated private func preprocessText(_ text: String, language: String) -> String {
        let textWithoutURLs = text.replacingOccurrences(of: "https?://[^\\s]+", with: Localized.linkPlaceholder, options: .regularExpression)

        if language.starts(with: "en") {
            return textWithoutURLs
        }

        let textWithoutCommas = removeCommasFromNumbers(textWithoutURLs)
        let normalized = normalizeDash(textWithoutCommas)
        let decimalBeforePercentWordFixed = insertDotForDecimalBeforePercentageWords(normalized)
        let processedSpecialTerms = processEnglishText(decimalBeforePercentWordFixed)
        let withYearFixed = replaceYearMentionsForChinese(processedSpecialTerms)

        let pattern = #"(?<!年)([\u4e00-\u9fa5])(\s*[A-Za-z]+\s*)([\u4e00-\u9fa5])(?!年)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(withYearFixed.startIndex..<withYearFixed.endIndex, in: withYearFixed)
        let modifiedText = regex?.stringByReplacingMatches(
            in: withYearFixed,
            options: [],
            range: range,
            withTemplate: "$1, $2, $3"
        ) ?? withYearFixed

        return modifiedText
    }

    nonisolated private func insertDotForDecimalBeforePercentageWords(_ text: String) -> String {
        var result = text
        let pattern = #"(?<!\d)(\d+).(\d+)\s*(个百分点|百分比|百分点)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        var replacements: [(NSRange, String)] = []

        regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 4 else { return }
            if let r1 = Range(match.range(at: 1), in: result),
               let r2 = Range(match.range(at: 2), in: result),
               let r3 = Range(match.range(at: 3), in: result) {
                let intPart = String(result[r1])
                let fracPart = String(result[r2])
                let unit = String(result[r3])
                let replacement = "\(intPart)点\(fracPart)\(unit)"
                replacements.append((match.range, replacement))
            }
        }

        for (range, rep) in replacements.reversed() {
            if let r = Range(range, in: result) {
                result.replaceSubrange(r, with: rep)
            }
        }
        return result
    }

    nonisolated private func processEnglishText(_ input: String) -> String {
        var processed = input
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\"", with: "")

        processed = normalizeDash(processed)

        let percentRangePattern = #"(?<!\d)(\d+)\s*-\s*(\d+)\s*%"#
        if let regex = try? NSRegularExpression(pattern: percentRangePattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed),
                   let leftNum = Int(processed[r1]),
                   let rightNum = Int(processed[r2]) {
                    let leftZh = self.readChineseNumber(leftNum)
                    let rightZh = self.readChineseNumber(rightNum)
                    let replacement = "百分之\(leftZh)到\(rightZh)"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let fractionPattern = #"(?<!\d)(\d+)\s*/\s*(\d+)(?!\d)"#
        if let regex = try? NSRegularExpression(pattern: fractionPattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed),
                   let numerator = Int(processed[r1]),
                   let denominator = Int(processed[r2]) {
                    let denZh = self.readChineseNumber(denominator)
                    let numZh = self.readChineseNumber(numerator)
                    let replacement = "\(denZh)分之\(numZh)"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        func toChineseUpperForAge(_ n: Int) -> String {
            let upper = ["零","壹","贰","叁","肆","伍","陆","柒","捌","玖"]
            if n < 10 { return upper[n] }
            let tens = n / 10
            let ones = n % 10
            if ones == 0 {
                if tens == 1 { return "十" }
                return upper[tens] + "十"
            } else {
                if tens == 1 { return "十" + upper[ones] }
                return upper[tens] + "十" + upper[ones]
            }
        }

        let ageRangePattern = #"(?<!\d)(\d{1,2})\s*-\s*(\d{1,2})\s*(岁|岁龄|年龄段)"#
        if let regex = try? NSRegularExpression(pattern: ageRangePattern, options: []) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 4 else { return }
                guard
                    let r1 = Range(match.range(at: 1), in: processed),
                    let r2 = Range(match.range(at: 2), in: processed),
                    let r3 = Range(match.range(at: 3), in: processed),
                    let l = Int(processed[r1]),
                    let r = Int(processed[r2]),
                    (10...99).contains(l),
                    (10...99).contains(r)
                else { return }
                let unit = String(processed[r3])
                let leftZh = toChineseUpperForAge(l)
                let rightZh = toChineseUpperForAge(r)
                let rep = "\(leftZh)到\(rightZh)\(unit)"
                replacements.append((match.range, rep))
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let academicYearPattern = #"(?<!\d)(\d{4})\s*-\s*(\d{2})(?=\s*学年)"#
        if let regex = try? NSRegularExpression(pattern: academicYearPattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed) {
                    let leftYear = String(processed[r1])
                    let rightYear = String(processed[r2])
                    let leftDigits = formatDigitsToChinesePerChar(leftYear)
                    let rightDigits = formatDigitsToChinesePerChar(rightYear)
                    let replacement = "\(leftDigits)到\(rightDigits)"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let decadeRangePattern = #"(?<!\d)(\d{4})\s*-\s*(\d{2})(?=\s*年代)"#
        if let regex = try? NSRegularExpression(pattern: decadeRangePattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed) {
                    let leftYear = String(processed[r1])
                    let rightYearSuffix = String(processed[r2])
                    let leftDigits = formatDigitsToChinesePerChar(leftYear)
                    let rightDigits = formatDigitsToChinesePerChar(rightYearSuffix)
                    let replacement = "\(leftDigits)到\(rightDigits)"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let abbreviatedYearRangePattern = #"(?<!\d)(\d{4})\s*-\s*(\d{2})(?=\s*年)"#
        if let regex = try? NSRegularExpression(pattern: abbreviatedYearRangePattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed) {
                    let leftYear = String(processed[r1])
                    let rightYearSuffix = String(processed[r2])
                    let leftDigits = formatDigitsToChinesePerChar(leftYear)
                    let rightDigits = formatDigitsToChinesePerChar(rightYearSuffix)
                    let replacement = "\(leftDigits)到\(rightDigits)"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let yearDurationRangePattern = #"(?<!\d)(\d{1,3})\s*-\s*(\d{1,3})\s*年"#
        if let regex = try? NSRegularExpression(pattern: yearDurationRangePattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed),
                   let leftNum = Int(processed[r1]),
                   let rightNum = Int(processed[r2]) {
                    let leftZh = self.readChineseNumber(leftNum)
                    let rightZh = self.readChineseNumber(rightNum)
                    let replacement = "\(leftZh)到\(rightZh)年"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let singleYearDurationPattern = #"(?<!\d)(\d{1,3})\s*年"#
        if let regex = try? NSRegularExpression(pattern: singleYearDurationPattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 2 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let num = Int(processed[r1]) {
                    let numZh = self.readChineseNumber(num)
                    let replacement = "\(numZh)年"
                    replacements.append((match.range, replacement))
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let units = "[人名位个只辆架件次条份所家台篇场例天月周小时分钟秒]"
        let numberRangeWithUnitPattern = #"(?<!\d)(\d{1,6})\s*-\s*(\d{1,6})\s*(\#(units))"#
        if let regex = try? NSRegularExpression(pattern: numberRangeWithUnitPattern, options: []) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 4 else { return }
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed),
                   let r3 = Range(match.range(at: 3), in: processed) {
                    let left = String(processed[r1])
                    let right = String(processed[r2])
                    let unit = String(processed[r3])
                    if let l = Int(left), let r = Int(right) {
                        let leftZh = readChineseNumber(l)
                        let rightZh = readChineseNumber(r)
                        let replacement = "\(leftZh)到\(rightZh)\(unit)"
                        replacements.append((match.range, replacement))
                    }
                }
            }
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        let generalRangePattern = #"(?<!\d)(\d{1,6})\s*-\s*(\d{1,6})(?!\d)(?!\s*(?:年|年代))"#
        if let generalRegex = try? NSRegularExpression(pattern: generalRangePattern, options: []) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var result = processed
            var delta = 0
            generalRegex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match else { return }
                if let leftRange = Range(match.range(at: 1), in: processed),
                   let rightRange = Range(match.range(at: 2), in: processed) {
                    let left = String(processed[leftRange])
                    let right = String(processed[rightRange])
                    let replacement = "\(left)到\(right)"
                    let start = result.index(result.startIndex, offsetBy: match.range.location + delta)
                    let end = result.index(start, offsetBy: match.range.length)
                    result.replaceSubrange(start..<end, with: replacement)
                    delta += replacement.count - match.range.length
                }
            }
            processed = result
        }

        let replacements = [
            "URL": "U.R.L",
            "HTTP": "H.T.T.P",
            "JSON": "Jason",
            "HTML": "H.T.M.L",
            "CSS": "C.S.S",
            "JS": "J.S",
            "xAI": "X.A.I",
            "AI": "A.I",
            "OpenAI": "Open.A.I",
            "openAI": "open.A.I",
            "SDK": "S.D.K",
            "iOS": "i O S",
            "PSA": "P.S.A",
            "Jeep": "吉普",
            "EV": "电动车",
            "iPhone": "i Phone",
            "iPad": "i Pad",
            "macOS": "mac O S",
            "UI": "U.I",
            "GUI": "G.U.I",
            "CLI": "C.L.I",
            "SQL": "S.Q.L",
            "NASA": "NASA",
            "JPEG": "J.PEG",
            "PNG": "P.N.G",
            "PDF": "P.D.F",
            "STEM": "S.T.E.M",
            "ID": "I.D",
            "vs": "对阵",
            "etc": "等等",
            "i.e": "也就是说",
            "e.g": "举例来说",
            "&": "和",
            "+": "加",
            "=": "等于",
            "@": "at",
            "~": "到",
            "/": "每",
            "DJI": "大疆",
            "Insta360": "Insta三六零",
            "Airbnb": "Air.B.N.B",
            "参加": "餐加",
            "K-12": "K十二",
            "K12": "K十二",
            "Covid-19": "新冠肺炎",
            "上调": "上条",
            "回调": "回条",
            "GW": "千兆瓦",
            "Labubu": "喇布布",
            "ebay": "E.Bay"
        ]

        for (key, value) in replacements {
            processed = processed.replacingOccurrences(of: key, with: value)
        }

        return processed
    }
}

// ============================================================================
// MARK: - 进度行（唯一高频重绘的视图）
// ============================================================================
private struct AudioProgressRow: View {
    @ObservedObject var state: AudioProgressState
    let onSeek: (Double) -> Void

    @State private var sliderValue: Double = 0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 10) {
            // 拖动时实时显示目标时间
            Text(isEditing
                 ? AudioProgressState.format(Int(sliderValue * state.totalSeconds))
                 : state.currentTimeString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))

            Slider(value: $sliderValue, in: 0...1, onEditingChanged: { editing in
                isEditing = editing
                if !editing { onSeek(sliderValue) }
            })
            .tint(.white)

            Text(state.durationString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .onAppear { sliderValue = state.progress }
        .onChange(of: state.progress) { _, newValue in
            if !isEditing { sliderValue = newValue }
        }
    }
}

// ============================================================================
// MARK: - AudioPlayerView（只观察低频状态）
// ============================================================================
struct AudioPlayerView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var showVoicePicker = false
    @State private var modeHint: String?
    @State private var hintTask: Task<Void, Never>?
    private let rates: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]
    var playNextAndStart: (() -> Void)?
    var toggleCollapse: (() -> Void)?

    private var controlsDisabled: Bool {
        !playerManager.isPlaybackActive || playerManager.isSynthesizing
    }

    private var playPauseIconName: String {
        playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private func nextRate(from current: Float) -> Float {
        if let idx = rates.firstIndex(of: current) {
            return rates[(idx + 1) % rates.count]
        }
        return 1.0
    }

    private var rateLabel: String { AudioPlayerManager.rateText(playerManager.playbackRate) }

    private func toggleAutoPlay() {
        playerManager.isAutoPlayEnabled.toggle()
        ONewsHaptics.selection()
        let text = playerManager.isAutoPlayEnabled ? Localized.autoPlay : Localized.singlePlay
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { modeHint = text }
        hintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { modeHint = nil }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            AudioProgressRow(state: playerManager.progressState,
                             onSeek: { playerManager.seek(to: $0) })

            if playerManager.isSynthesizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Localized.synthesizing)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 66)
            } else {
                HStack(spacing: 40) {
                    Button(action: { playerManager.seekBy(seconds: -15) }) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 32, weight: .regular))
                    }
                    .disabled(controlsDisabled)
                    .opacity(controlsDisabled ? 0.6 : 1.0)

                    Button(action: { playerManager.playPause() }) {
                        Image(systemName: playPauseIconName)
                            .font(.system(size: 52, weight: .regular))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(controlsDisabled)
                    .opacity(controlsDisabled ? 0.6 : 1.0)

                    Button(action: { playerManager.seekBy(seconds: 15) }) {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 32, weight: .regular))
                    }
                    .disabled(controlsDisabled)
                    .opacity(controlsDisabled ? 0.6 : 1.0)
                }
                .frame(height: 66)

                HStack {
                    HStack {
                        Button(action: toggleAutoPlay) {
                            // 连续播放 = repeat；单篇 = 播到头就停（不再用会被误解为"单曲循环"的 repeat.1）
                            Image(systemName: playerManager.isAutoPlayEnabled
                                  ? "repeat.circle.fill"
                                  : "arrow.right.to.line.circle.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(playerManager.isAutoPlayEnabled ? .white : .white.opacity(0.45))
                        }
                        .accessibilityLabel(playerManager.isAutoPlayEnabled ? Localized.autoPlay : Localized.singlePlay)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        Button(action: { showVoicePicker = true }) {
                            Image(systemName: "person.wave.2.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .accessibilityLabel("选择声音")
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        Button(action: {
                            playerManager.playbackRate = nextRate(from: playerManager.playbackRate)
                        }) {
                            Text(rateLabel)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.white)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color.white.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("\(Localized.playbackSpeed) \(rateLabel)")
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        Button(action: { playNextAndStart?() }) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .disabled(controlsDisabled)
                        .opacity(controlsDisabled ? 0.6 : 1.0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundColor(.white)
        .padding(EdgeInsets(top: 28, leading: 16, bottom: 10, trailing: 16))
        .background(.black.opacity(0.8))
        .cornerRadius(18)
        .overlay(alignment: .top) {
            if let hint = modeHint {
                Text(hint)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .overlay(
            Button(action: { toggleCollapse?() }) {
                Image(systemName: "minus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .clipShape(Circle())
                    .accessibilityLabel(Localized.minimizePlayer)
            }
            .padding(6),
            alignment: .topTrailing
        )
        .overlay(
            Button(action: { playerManager.stop() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .padding(6)
                    .background(Color.white.opacity(0.8))
                    .clipShape(Circle())
            }
            .padding(6)
            .accessibilityLabel(Localized.close),
            alignment: .topLeading
        )
        .offset(y: -18)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerView(playerManager: playerManager)
        }
        .onDisappear { hintTask?.cancel() }
    }
}

// ============================================================================
// MARK: - 迷你耳机气泡（系统 symbolEffect，替代手写 repeatForever 动画）
// ============================================================================
struct MiniAudioBubbleView: View {
    let isPlaybackActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: isPlaybackActive ? "headphones.circle" : "headphones.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                .symbolEffect(.pulse, options: .repeating, isActive: isPlaybackActive)
                .contentShape(Circle())
        }
        .padding(.leading, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// ============================================================================
// MARK: - 声音选择
// ============================================================================
struct VoicePickerView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(language: String, voices: [AVSpeechSynthesisVoice])] = []
    @State private var previewSynth = AVSpeechSynthesizer()

    var body: some View {
        NavigationView {
            Group {
                if groups.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.language) { group in
                            Section(header: Text(sectionTitle(for: group.language))) {
                                ForEach(group.voices, id: \.identifier) { voice in
                                    Button(action: {
                                        playerManager.setPreferredVoice(voice)
                                        preview(voice)
                                    }) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 6) {
                                                    Text(voice.name)
                                                        .font(.body)
                                                        .foregroundColor(.primary)
                                                    if let gender = genderLabel(voice) {
                                                        Text(gender)
                                                            .font(.caption2)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 1)
                                                            .background(Color.secondary.opacity(0.15))
                                                            .clipShape(Capsule())
                                                    }
                                                }
                                                Text("\(voice.language) · \(qualityLabel(voice.quality))")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            if playerManager.isPreferredVoice(voice) {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.accentColor)
                                                    .fontWeight(.semibold)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择声音")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // 先让 sheet 弹出动画跑完，再加载列表
            .task {
                if groups.isEmpty { groups = playerManager.availableVoicesGrouped() }
            }
            .onDisappear {
                previewSynth.stopSpeaking(at: .immediate)
            }
        }
    }

    private func preview(_ voice: AVSpeechSynthesisVoice) {
        previewSynth.stopSpeaking(at: .immediate)
        let sample: String
        if voice.language.hasPrefix("zh") {
            sample = "你好，这是声音预览。"
        } else if voice.language.hasPrefix("en") {
            sample = "Hello, this is a voice preview."
        } else if voice.language.hasPrefix("ja") {
            sample = "こんにちは、これは音声のプレビューです。"
        } else {
            sample = "Hello."
        }
        let u = AVSpeechUtterance(string: sample)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        previewSynth.speak(u)
    }

    private func sectionTitle(for code: String) -> String {
        let locale = Locale(identifier: code)
        let name = Locale.current.localizedString(forIdentifier: code)
            ?? locale.localizedString(forIdentifier: code)
            ?? code
        return "\(name) (\(code))"
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }

    private func genderLabel(_ voice: AVSpeechSynthesisVoice) -> String? {
        switch voice.gender {
        case .male:   return "男声"
        case .female: return "女声"
        default:      return nil
        }
    }
}