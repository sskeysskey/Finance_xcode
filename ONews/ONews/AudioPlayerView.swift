import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import NaturalLanguage

@MainActor
class AudioPlayerManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    // MARK: - Published Properties for UI
    @Published var isPlaybackActive = false
    @Published var isPlaying = false
    @Published var isSynthesizing = false

    @Published var progress: Double = 0.0
    @Published var currentTimeString: String = "00:00"
    @Published var durationString: String = "00:00"

    // 回调
    var onPlaybackFinished: (() -> Void)?
    var onNextRequested: (() -> Void)?
    var onToggleRepeatRequested: (() -> Void)?

    @Published var isAutoPlayEnabled = false {
        didSet {
            UserDefaults.standard.set(isAutoPlayEnabled, forKey: autoPlayEnabledKey)
            updateRepeatStateInNowPlaying()
        }
    }

    @Published var playbackRate: Float = 1.0 {
        didSet {
            if playbackRate < 0.5 { playbackRate = 0.5 }
            else if playbackRate > 2.0 { playbackRate = 2.0 }
            applyPlaybackRate()
            refreshNowPlayingInfo()
        }
    }

    // MARK: - Private Properties
    private var speechSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var displayLink: CADisplayLink?

    private var temporaryAudioFileURL: URL?
    private var audioFile: AVAudioFile?
    private let autoPlayEnabledKey = "audio.autoPlayEnabled"

    private var remoteCommandsRegistered = false
    private var nowPlayingTitle: String = "正在播放的文章"

    private var synthesisWatchdogTimer: Timer?
    private var synthesisLastWriteAt: Date?

    override init() {
        super.init()
        self.speechSynthesizer.delegate = self
        if UserDefaults.standard.object(forKey: autoPlayEnabledKey) != nil {
            self.isAutoPlayEnabled = UserDefaults.standard.bool(forKey: autoPlayEnabledKey)
        } else {
            self.isAutoPlayEnabled = false
        }
        setupRemoteTransportControls()
        setupNotifications()
    }

    deinit {
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.delegate = nil
        Task { @MainActor [weak self] in
            self?.invalidateSynthesisWatchdog()
        }
    }

    func prepareForNextTransition() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        isPlaying = false
        isSynthesizing = false
        stopDisplayLink()
        cleanupTemporaryFile()
        invalidateSynthesisWatchdog()
    }

    private func applyPlaybackRate() {
        guard let player = audioPlayer else { return }
        player.enableRate = true
        player.rate = playbackRate
    }

    // MARK: - Remote Command Center
    private func setupRemoteTransportControls() {
        guard !remoteCommandsRegistered else { return }
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = false

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.playPause()
                return .success
            }
            return .commandFailed
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying {
                self.playPause()
                return .success
            }
            return .commandFailed
        }

        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }

        // 修复点：不要在这里清理播放器状态；仅把“下一曲”意图传回 UI 层处理
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.onNextRequested?()
            return .success
        }

        remoteCommandsRegistered = true
    }

    private func teardownRemoteTransportControls() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.stopCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        remoteCommandsRegistered = false
    }

    private func updateRepeatStateInNowPlaying() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        if let player = audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? Double(playbackRate) : 0.0
        }
        info[MPMediaItemPropertyArtist] = isAutoPlayEnabled ? "自动连播" : "单次播放"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingInfo(playbackRate explicitRate: Double? = nil) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        info[MPMediaItemPropertyTitle] = nowPlayingTitle

        let speedText = String(format: "%.2fx", playbackRate).replacingOccurrences(of: ".00", with: "x")
        info[MPMediaItemPropertyArtist] = isAutoPlayEnabled ? "自动连播 • \(speedText)" : "单次播放 • \(speedText)"
        info[MPMediaItemPropertyAlbumTitle] = "Speed \(speedText)"

        if let player = audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
            let rate: Double
            if let explicitRate = explicitRate {
                rate = explicitRate
            } else {
                rate = player.isPlaying ? Double(self.playbackRate) : 0.0
            }
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
            info[MPMediaItemPropertyPlaybackDuration] = 0
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Notifications
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil)
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            if isPlaying { playPause() }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                if !isPlaying { playPause() }
            }
        @unknown default:
            break
        }
    }

    func setHasNext(_ hasNext: Bool) {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext
    }

    // MARK: - Public Control Methods
    func startPlayback(text: String, title: String? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handleError("文本内容为空，无法播放。")
            return
        }

        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        stopDisplayLink()
        cleanupTemporaryFile()
        invalidateSynthesisWatchdog()

        self.nowPlayingTitle = title?.isEmpty == false ? title! : "正在播放的文章"
        self.speechSynthesizer.delegate = self

        let processedText = preprocessText(text)

        isSynthesizing = true
        isPlaybackActive = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true, options: [])
        } catch {
            print("激活音频会话警告: \(error.localizedDescription)")
        }

        refreshNowPlayingInfo(playbackRate: 0.0)

        let utterance = AVSpeechUtterance(string: processedText)
        utterance.voice = getBestVoice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.3
        utterance.preUtteranceDelay = 0.2

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".caf"
        temporaryAudioFileURL = tempDir.appendingPathComponent(fileName)

        synthesisLastWriteAt = Date()
        startSynthesisWatchdog()

        speechSynthesizer.write(utterance) { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    self.handleError("无法获取 PCM 缓冲。")
                    return
                }

                self.synthesisLastWriteAt = Date()

                if pcmBuffer.frameLength == 0 {
                    self.synthesisToFileCompleted()
                } else {
                    if self.audioFile == nil {
                        do {
                            guard let url = self.temporaryAudioFileURL else {
                                self.handleError("无法创建音频文件：临时 URL 缺失。")
                                return
                            }
                            self.audioFile = try AVAudioFile(forWriting: url, settings: pcmBuffer.format.settings)
                        } catch {
                            self.handleError("根据音频数据格式创建文件失败: \(error)")
                            return
                        }
                    }
                    self.appendBufferToFile(buffer: pcmBuffer)
                }
            }
        }
    }

    private func getBestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let languageCode = recognizer.dominantLanguage?.rawValue else {
            return AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        }

        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matches = voices.filter { $0.language.starts(with: languageCode) }
        if let v = matches.first(where: { $0.quality == .premium }) { return v }
        if let v = matches.first(where: { $0.quality == .enhanced }) { return v }
        if let v = matches.first { return v }
        return AVSpeechSynthesisVoice(language: languageCode)
    }

    func playPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopDisplayLink()
            refreshNowPlayingInfo(playbackRate: 0.0)
        } else {
            do {
                try setupAudioSession()
                player.play()
                applyPlaybackRate()
                isPlaying = true
                startDisplayLink()
                setupRemoteTransportControls()
                enableRemoteCommandsForActivePlayback()
                refreshNowPlayingInfo(playbackRate: 1.0)
            } catch {
                handleError("恢复播放时，重新激活音频会话失败: \(error)")
            }
        }
    }

    func stop() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()

        isPlaying = false
        isPlaybackActive = false
        isSynthesizing = false

        progress = 0.0
        currentTimeString = "00:00"
        durationString = "00:00"

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        teardownRemoteTransportControls()

        stopDisplayLink()
        cleanupTemporaryFile()
        deactivateAudioSession()
        invalidateSynthesisWatchdog()

        audioPlayer?.delegate = nil
        audioPlayer = nil
        speechSynthesizer.delegate = nil
    }

    // 自然结束：仅在“自动连播开启”时请求下一篇；单次播放时不跳转
    private func finishNaturally() {
        audioPlayer?.stop()
        isPlaying = false
        isSynthesizing = false
        stopDisplayLink()

        if let player = audioPlayer {
            progress = 1.0
            currentTimeString = formatTime(player.duration)
            refreshNowPlayingInfo(playbackRate: 0.0)
            enableRemoteCommandsForActivePlayback()
        }

        // 仅当自动连播时才触发下一篇
        if isAutoPlayEnabled {
            onNextRequested?()
        }
        onPlaybackFinished?()
    }

    func seek(to value: Double) {
        guard let player = audioPlayer else { return }
        let newTime = player.duration * value
        player.currentTime = newTime
        updateProgress()
    }

    private func appendBufferToFile(buffer: AVAudioPCMBuffer) {
        do {
            try self.audioFile?.write(from: buffer)
        } catch {
            handleError("写入音频文件失败: \(error)")
        }
    }

    private func synthesisToFileCompleted() {
        self.audioFile = nil
        guard let url = self.temporaryAudioFileURL else {
            handleError("合成结束，但找不到临时文件URL。")
            return
        }
        invalidateSynthesisWatchdog()

        self.isSynthesizing = false
        self.setupAndPlayAudioPlayer(from: url)
    }

    private func cleanupTemporaryFile() {
        audioFile = nil
        if let url = temporaryAudioFileURL {
            try? FileManager.default.removeItem(at: url)
            temporaryAudioFileURL = nil
        }
    }

    private func startSynthesisWatchdog(timeout: TimeInterval = 15) {
        invalidateSynthesisWatchdog()
        synthesisWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isSynthesizing else { self.invalidateSynthesisWatchdog(); return }
                guard let last = self.synthesisLastWriteAt else { return }
                let elapsed = Date().timeIntervalSince(last)
                if elapsed > timeout {
                    self.handleError("语音合成阶段长时间无响应（可能在后台被系统限制）。已中止此次合成。")
                }
            }
        }
        RunLoop.main.add(synthesisWatchdogTimer!, forMode: .common)
    }

    private func invalidateSynthesisWatchdog() {
        synthesisWatchdogTimer?.invalidate()
        synthesisWatchdogTimer = nil
        synthesisLastWriteAt = nil
    }

    private func setupAndPlayAudioPlayer(from url: URL) {
        do {
            try setupAudioSession()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
            durationString = formatTime(audioPlayer?.duration ?? 0)
            applyPlaybackRate()
            audioPlayer?.play()
            isPlaying = true
            startDisplayLink()

            setupRemoteTransportControls()
            enableRemoteCommandsForActivePlayback()
            refreshNowPlayingInfo(playbackRate: 1.0)
        } catch {
            handleError("创建或播放 AVAudioPlayer 失败: \(error)")
        }
    }

    private func enableRemoteCommandsForActivePlayback() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishNaturally()
    }

    private func startDisplayLink() {
        stopDisplayLink()
        displayLink = CADisplayLink(target: self, selector: #selector(updateProgress))
        displayLink?.add(to: .current, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateProgress() {
        guard let player = audioPlayer, player.duration > 0 else { return }
        progress = player.currentTime / player.duration
        currentTimeString = formatTime(player.currentTime)
        refreshNowPlayingInfo()
    }

    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("释放音频会话失败: \(error)")
        }
    }

    private func handleError(_ message: String) {
        print("错误: \(message)")
        self.stop()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // --- 新增函数 ---
    private func removeCommasFromNumbers(_ text: String) -> String {
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

    private func formatYearToPinyinDigits(_ year: String) -> String {
        let map: [Character: String] = [
            "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"
        ]
        return year.compactMap { map[$0] }.joined()
    }

    private func replaceYearRangesForChinese(_ text: String) -> String {
        let pattern = #"(?<!\d)(\d{4})\s*-\s*(\d{4})(?=\s*年)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        var offset = 0

        regex.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            if let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text) {
                let leftYear = String(text[r1])
                let rightYear = String(text[r2])
                let leftDigits = formatYearToPinyinDigits(leftYear)
                let replacement = "\(leftDigits)到\(rightYear)"
                let start = result.index(result.startIndex, offsetBy: match.range.location + offset)
                let end = result.index(start, offsetBy: match.range.length)
                result.replaceSubrange(start..<end, with: replacement)
                offset += replacement.count - match.range.length
            }
        }
        return result
    }

    private func replaceModernYearsForChinese(_ text: String) -> String {
        let pattern = #"\b(20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        var result = text
        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..<result.endIndex, in: result)).reversed()

        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let yearString = String(result[range])
            let pinyinDigits = formatYearToPinyinDigits(yearString)
            result.replaceSubrange(range, with: pinyinDigits)
        }
        return result
    }

    private func preprocessText(_ text: String) -> String {
        let textWithoutCommas = removeCommasFromNumbers(text)
        let processedSpecialTerms = processEnglishText(textWithoutCommas)
        let withChineseYearRange = replaceYearRangesForChinese(processedSpecialTerms)
        let withModernYears = replaceModernYearsForChinese(withChineseYearRange)

        let pattern = "([\\u4e00-\\u9fa5])(\\s*[a-zA-Z]+\\s*)([\\u4e00-\\u9fa5])"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(withModernYears.startIndex..<withModernYears.endIndex, in: withModernYears)
        let modifiedText = regex?.stringByReplacingMatches(
            in: withModernYears,
            options: [],
            range: range,
            withTemplate: "$1, $2, $3"
        ) ?? withModernYears
        return modifiedText
    }

    private func processEnglishText(_ text: String) -> String {
        var processed = text

        processed = processed
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "\"", with: "")

        let generalRangePattern = #"(?<!\d)(\d+)\s*-\s*(\d*)(?!\d)"#

        if let generalRegex = try? NSRegularExpression(pattern: generalRangePattern, options: []) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var result = processed
            var delta = 0
            generalRegex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match else { return }
                if let leftRange = Range(match.range(at: 1), in: processed) {
                    let left = processed[leftRange]
                    var isFourFour = false
                    if match.numberOfRanges >= 3, let rightRange = Range(match.range(at: 2), in: processed) {
                        let right = processed[rightRange]
                        if left.count == 4, right.count == 4 {
                            isFourFour = true
                        }
                    }
                    if isFourFour {
                        return
                    }
                    let leftStr = String(left)
                    let rightStr: String
                    if match.numberOfRanges >= 3, let rRange = Range(match.range(at: 2), in: processed) {
                        rightStr = String(processed[rRange])
                    } else {
                        rightStr = ""
                    }
                    let replacement = "\(leftStr)到\(rightStr)"
                    let start = result.index(result.startIndex, offsetBy: match.range.location + delta)
                    let end = result.index(start, offsetBy: match.range.length)
                    result.replaceSubrange(start..<end, with: replacement)
                    delta += replacement.count - match.range.length
                }
            }
            processed = result
        }

        let replacements = [
            "API": "A.P.I",
            "URL": "U.R.L",
            "HTTP": "H.T.T.P",
            "JSON": "Jason",
            "HTML": "H.T.M.L",
            "CSS": "C.S.S",
            "JS": "J.S",
            "AI": "A.I",
            "OpenAI": "Open.A.I",
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
            "Airbnb": "Air.B.N.B"
        ]

        for (key, value) in replacements {
            processed = processed.replacingOccurrences(of: key, with: value)
        }

        return processed
    }
}

struct AudioPlayerView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var sliderValue: Double = 0.0
    @State private var isEditingSlider = false
    private let rates: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]
    var playNextAndStart: (() -> Void)?
    var toggleCollapse: (() -> Void)?

    private var playPauseIconName: String {
        playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private func nextRate(from current: Float) -> Float {
        if let idx = rates.firstIndex(of: current) {
            let next = (idx + 1) % rates.count
            return rates[next]
        }
        return 1.0
    }

    private var rateLabel: String {
        String(format: "%.2fx", playerManager.playbackRate)
            .replacingOccurrences(of: ".00", with: "")
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(playerManager.currentTimeString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))

                Slider(value: $sliderValue, in: 0...1, onEditingChanged: { editing in
                    self.isEditingSlider = editing
                    if !editing {
                        playerManager.seek(to: sliderValue)
                    }
                })
                .tint(.white)

                Text(playerManager.durationString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }

            if playerManager.isSynthesizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在合成语音，请稍候...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ZStack {
                    Button(action: { playerManager.playPause() }) {
                        Image(systemName: playPauseIconName)
                            .font(.system(size: 52, weight: .regular))
                    }
                    .disabled(playerManager.isSynthesizing || !playerManager.isPlaybackActive)
                    .opacity(playerManager.isSynthesizing || !playerManager.isPlaybackActive ? 0.6 : 1.0)
                }
                .frame(height: 66)

                HStack {
                    HStack {
                        Button(action: {
                            playerManager.isAutoPlayEnabled.toggle()
                        }) {
                            Image(systemName: playerManager.isAutoPlayEnabled ? "repeat.circle.fill" : "repeat.1.circle.fill")
                                .font(.system(size: 35, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(playerManager.isAutoPlayEnabled ? .white : .white.opacity(0.45))
                        }
                        .accessibilityLabel(playerManager.isAutoPlayEnabled ? "自动连播" : "单次播放")
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        Button(action: {
                            let newRate = nextRate(from: playerManager.playbackRate)
                            playerManager.playbackRate = newRate
                        }) {
                            Text(rateLabel)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.vertical, 7)
                                .padding(.horizontal, 12)
                                .background(Color.white.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("播放速度 \(rateLabel)")
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        Button(action: {
                            playNextAndStart?()
                        }) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .disabled(!playerManager.isPlaybackActive || playerManager.isSynthesizing)
                        .opacity((!playerManager.isPlaybackActive || playerManager.isSynthesizing) ? 0.6 : 1.0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundColor(.white)
        .padding(EdgeInsets(top: 28, leading: 16, bottom: 10, trailing: 16))
        .background(.black.opacity(0.8))
        .cornerRadius(18)
        .overlay(
            Button(action: { toggleCollapse?() }) {
                Image(systemName: "minus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .clipShape(Circle())
                    .accessibilityLabel("最小化播放器")
            }
            .padding(6),
            alignment: .topLeading
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
            .padding(6),
            alignment: .topTrailing
        )
        .offset(y: -18)
        .padding(.horizontal, 12)
        .onChange(of: playerManager.progress) { _, newValue in
            if !isEditingSlider { self.sliderValue = newValue }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 0)
        }
    }
}

struct MiniAudioBubbleView: View {
    @Binding var isCollapsed: Bool
    let isPlaying: Bool

    var body: some View {
        VStack {
            Spacer()
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                    isCollapsed = false
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isPlaying ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 22, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.8))
                .clipShape(Capsule())
                .shadow(radius: 6)
            }
            .padding(.leading, 8)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
    }
}
