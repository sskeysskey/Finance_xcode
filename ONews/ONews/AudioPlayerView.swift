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
            self.isAutoPlayEnabled = true
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
    func startPlayback(text: String, title: String? = nil, language: String = "zh-CN") {
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

        // 【修改点】传入 language 参数给预处理函数
        let processedText = preprocessText(text, language: language)

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
        // 【修改点】使用传入的 language 来获取声音，不再完全依赖自动检测
        // 如果是英文，直接指定英文声音；如果是中文，保持原有逻辑
        if language.starts(with: "en") {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        } else {
            utterance.voice = getBestVoice(for: text)
        }
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
        // 1. 移除 URL 避免干扰（保持原逻辑）
        let textForDetection = text.replacingOccurrences(of: "https?://[^\\s]+", with: "", options: .regularExpression)
        
        // 2. 【核心修复】最高优先级：检测是否包含汉字
        // 不需要管 NLLanguageRecognizer 认为它是什么语言。
        // 只要含有汉字（\p{Han}），为了保证可读性，必须用中文引擎。
        // (除非你明确知道这是日文，但根据你的业务场景看起来是中文为主)
        let hasChineseChar = textForDetection.range(of: "\\p{Han}", options: .regularExpression) != nil
        
        var finalLanguageCode = "zh-CN"
        
        if hasChineseChar {
            // 如果有汉字，强制锁定中文
            finalLanguageCode = "zh-CN"
        } else {
            // 只有在【完全没有汉字】的情况下，才依赖自动检测
            // 这适用于纯英文、纯法文等场景
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(textForDetection)
            
            if let detected = recognizer.dominantLanguage?.rawValue {
                finalLanguageCode = detected
            } else {
                // 检测失败，兜底
                finalLanguageCode = Locale.current.language.languageCode?.identifier ?? "zh-CN"
            }
        }

        // 3. 获取对应语言的最佳语音包
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matches = voices.filter { $0.language.starts(with: finalLanguageCode) }
        
        // 优先选择高质量语音
        if let v = matches.first(where: { $0.quality == .premium }) { return v }
        if let v = matches.first(where: { $0.quality == .enhanced }) { return v }
        if let v = matches.first { return v }
        
        // 最后的兜底
        return AVSpeechSynthesisVoice(language: finalLanguageCode)
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
    
    // --- 新增/修复：数字与年份处理 ---
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

    private func formatDigitsToChinesePerChar(_ digits: String) -> String {
        let map: [Character: String] = [
            "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"
        ]
        return digits.compactMap { map[$0] }.joined()
    }

    // 将各种连字符统一为普通连字符，便于后续正则匹配
    private func normalizeDash(_ text: String) -> String {
        // 包含常见的连字符/破折号/波浪号等
        let dashes = ["—", "–", "―", "–", "－", "‑", "‒", "〜", "~", "—", "——"]
        var t = text
        for d in dashes {
            t = t.replacingOccurrences(of: d, with: "-")
        }
        // 连续多个破折号合并为单个-
        while t.contains("--") {
            t = t.replacingOccurrences(of: "--", with: "-")
        }
        return t
    }

    // 用于将阿拉伯数字按中文数值读法（非逐字年份）读出，例如：2000 -> 两千；5000 -> 五千；21 -> 二十一
    private func readChineseNumber(_ n: Int) -> String {
        // 仅覆盖到万级，满足 2000-5000 此类需求，避免引入复杂度
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
            // 按中文习惯：2千通常读作“两千”
            let thousandHead = (thousands == 2 ? "两" : digits[thousands]) + "千"
            if rest == 0 { return thousandHead }
            if rest < 100 {
                // 2001 -> 两千零一； 2010 -> 两千零一十
                if rest < 10 { return thousandHead + "零" + digits[rest] }
                // 介于 10~99
                if rest < 20 {
                    if rest == 10 { return thousandHead + "零十" }
                    return thousandHead + "零十" + digits[rest % 10]
                } else {
                    let tens = rest / 10
                    let ones = rest % 10
                    return thousandHead + digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
                }
            } else {
                // 余数 >= 100
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
        // 简化：>=10000 时粗略读法（满足一般单位场景）
        if n < 100000 {
            let wan = n / 10000
            let rest = n % 10000
            let head = (wan == 2 ? "两" : digits[wan]) + "万"
            if rest == 0 { return head }
            // 递归处理余数
            return head + readChineseNumber(rest)
        }
        // 超过本需求范围，退化为逐字
        return String(n).map { String($0) }.joined(separator: "")
    }

    // 修正：仅在“明确存在‘年’字或‘年代’”的上下文中替换年份
    private func replaceYearMentionsForChinese(_ text: String) -> String {
        var result = text
        
        // 【新增规则 0】处理并列年份：例如 "2022和2023年" 或 "1998、1999年"
        // 逻辑：匹配一个4位数字，如果它后面紧跟着（和/与/、）+（4位数字）+（年/年代），则将其视为年份
        // 这样 "2022" 会被选中，因为它后面是 "和2023年"
        let linkedYearPattern = #"(?<!\d)(\d{4})(?=\s*(?:和|与|、)\s*\d{4}\s*(?:年|年代))"#
        if let regex = try? NSRegularExpression(pattern: linkedYearPattern, options: []) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 2 else { return }
                if let r1 = Range(match.range(at: 1), in: result) {
                    let year = String(result[r1])
                    // 转换为逐字读法：二零二二
                    let yearZh = formatDigitsToChinesePerChar(year)
                    replacements.append((match.range(at: 1), yearZh))
                }
            }
            // 倒序替换，防止坐标偏移
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: result) {
                    result.replaceSubrange(r, with: rep)
                }
            }
        }

        // 1) 范围中包含“年”或“年代”的情形：如 2017-2020年 或 2017-2020年代 -> 二零一七到二零二零年/年代
        // 仅当右侧（或两端）紧跟“年”或“年代”才视为年份范围
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

        // 2) 单个年份：仅当紧随“年”或“年代”时才逐字读
        // (注：上面的"2022"被处理后，剩下的"2023年"会在这里被处理)
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

    // 调整调用顺序：先去逗号 -> 统一破折号 -> 英文/范围/单位处理 -> 年份逐字化 -> 中英间停顿
    private func preprocessText(_ text: String, language: String) -> String {
        // 移除 URL 是通用的
        let textWithoutURLs = text.replacingOccurrences(of: "https?://[^\\s]+", with: "链接", options: .regularExpression)
        
        // 【核心修改】如果是英文模式，直接返回处理过 URL 的文本
        // 跳过所有针对中文的数字、年份、破折号处理，否则英文数字会被读乱
        if language.starts(with: "en") {
            return textWithoutURLs
        }
        
        // 去掉数字中的逗号
        let textWithoutCommas = removeCommasFromNumbers(textWithoutURLs)
        // 统一破折号等
        let normalized = normalizeDash(textWithoutCommas)
        // 先在“百分点/百分比/百分点”前的带小数数字插入“点”
        let decimalBeforePercentWordFixed = insertDotForDecimalBeforePercentageWords(normalized)

        // 先处理英文与数字范围、单位（核心修复）
        let processedSpecialTerms = processEnglishText(decimalBeforePercentWordFixed)
        // 仅对带“年”的位置做年份逐字化
        let withYearFixed = replaceYearMentionsForChinese(processedSpecialTerms)

        // 中英夹杂时加停顿，但避免在“年”附近插入英文逗号
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
    
    private func insertDotForDecimalBeforePercentageWords(_ text: String) -> String {
    var result = text
    // 匹配小数紧跟“个百分点/百分比/百分点”
    // 示例：0.5个百分点 -> 0.5点个百分点（随后 TTS 会把“点”读出来，整体为“零点五个百分点”）
    // 为了兼容空格：允许小数与量词之间有可选空白
    let pattern = #"(?<!\d)(\d+).(\d+)\s*(个百分点|百分比|百分点)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

    let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
    var replacements: [(NSRange, String)] = []

    regex.enumerateMatches(in: result, options: [], range: nsRange) { match, _, _ in
        guard let match = match, match.numberOfRanges >= 4 else { return }
        if let r1 = Range(match.range(at: 1), in: result),
           let r2 = Range(match.range(at: 2), in: result),
           let r3 = Range(match.range(at: 3), in: result) {
            let intPart = String(result[r1])   // "0"
            let fracPart = String(result[r2])  // "5"
            let unit = String(result[r3])      // "个百分点"/"百分比"/"百分点"
            // 构造插入“点”的读法提示：0.5 -> 0点5
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

    // 修正与增强：
    // - 新增：优先处理 YYYY-YY年代 格式，确保年份被逐字朗读。
    // - 新增：优先处理 “数字-数字 岁/岁龄/年龄段” 的中文读法，按中文口语读“两、三、四...十/十一/十二...”，且使用大写（壹贰叁肆伍陆柒捌玖拾）以满足“贰十到贰十四岁”的期望。
    // - 先做单位范围（数字-数字 + 量词）的中文数值读法，例如 2000-5000人 -> 两千到五千人
    // - 再做一般纯数字范围（不带单位）的 X-Y -> X到Y，避免覆盖四位数被当作年份
    // - 其余英文缩写替换维持不变
    private func processEnglishText(_ input: String) -> String {
        var processed = input
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "\"", with: "")

        // 统一处理破折号
        processed = normalizeDash(processed)
        
        // --- 新增修复：优先处理百分比范围，例如 20-25% -> 百分之二十到二十五 ---
        // 【修改点 1】: 将数字直接转换为中文读法，避免TTS引擎误读“20”为“两十”
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
                    // 直接调用 readChineseNumber 将数字转为 "二十", "二十五" 等
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

        // --- 【新增】处理分数格式 X/Y -> Y分之X ---
        // 必须在最后的字典替换之前执行，因为字典里有 "/": "每" 的规则
        // 逻辑：匹配 "数字/数字"，将其转换为 "分母分之分子"
        let fractionPattern = #"(?<!\d)(\d+)\s*/\s*(\d+)(?!\d)"#
        if let regex = try? NSRegularExpression(pattern: fractionPattern) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var replacements: [(NSRange, String)] = []
            regex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                // 获取分子和分母
                if let r1 = Range(match.range(at: 1), in: processed),
                   let r2 = Range(match.range(at: 2), in: processed),
                   let numerator = Int(processed[r1]),   // 分子 (1)
                   let denominator = Int(processed[r2]) { // 分母 (6)
                    
                    // 转换为中文读法
                    let denZh = self.readChineseNumber(denominator) // 6 -> 六
                    let numZh = self.readChineseNumber(numerator)   // 1 -> 一
                    
                    // 组合成：六分之一
                    let replacement = "\(denZh)分之\(numZh)"
                    replacements.append((match.range, replacement))
                }
            }
            // 倒序替换
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }

        // --- 新增：将 20-24岁 这类“年龄段”优先转换为中文大写数字读法（贰十到贰十四岁） ---
        // 支持：20-24岁 / 20 - 24 岁 / 20-24岁龄 / 20-24年龄段（括号内外均可）
        // 只在两端都在 [10, 99] 的场景下处理（避免涉及 100+ 的异常年龄）
        func toChineseUpperForAge(_ n: Int) -> String {
            let upper = ["零","壹","贰","叁","肆","伍","陆","柒","捌","玖"]
            if n < 10 { return upper[n] }
            let tens = n / 10
            let ones = n % 10
            _ = "拾"
            // 20 -> 贰十（不读“贰拾”以避免“贰拾”/“贰十”的风格不一致，这里按你的期望保留“贰十”）
            if ones == 0 {
                // 10, 20, 30, ...
                if tens == 1 { return "十" } // 10
                return upper[tens] + "十"
            } else {
                // 11..19：十壹、十贰...
                if tens == 1 { return "十" + upper[ones] }
                // 21..99：贰十壹、叁十肆...
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
                let unit = String(processed[r3]) // 岁 / 岁龄 / 年龄段
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

        // --- 新增修复：优先处理学术年份范围 ---
        // 专门匹配 YYYY-YY学年 这样的格式，并进行逐字朗读替换
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
                    let leftDigits = formatDigitsToChinesePerChar(leftYear)  // e.g., "2024" -> "二零二四"
                    let rightDigits = formatDigitsToChinesePerChar(rightYear) // e.g., "25" -> "二五"
                    let replacement = "\(leftDigits)到\(rightDigits)"         // -> "二零二四到二五"
                    replacements.append((match.range, replacement))
                }
            }
            // 从后往前替换，避免 range 变化
            for (range, rep) in replacements.reversed() {
                if let r = Range(range, in: processed) {
                    processed.replaceSubrange(r, with: rep)
                }
            }
        }
        
        // --- 新增修复：专门处理 YYYY-YY年代 的格式 ---
        // 例如：1960-70年代 -> 一九六零到七零年代
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
        
        // --- 【新增修复 2】处理 YYYY-YY年 的缩写年份范围格式 ---
        // 例如：1968-79年 -> 一九六八到七九年
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
                    // 替换为“一九六八到七九”
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

        // --- 处理“数字-数字 年”的持续时间范围 ---
        // 例如：50-100年 -> 五十到一百年
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

        // --- 处理单个“数字 年”的持续时间 ---
        // 例如：100年 -> 一百年
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

        // 先处理“数字范围 + 量词”的读法（关键修复点）
        // 例如：2000-5000人 / 3-5名 / 10-20个 等
        // 支持的常见量词集合（可按需扩展）
        // --- 核心修复：从量词列表中移除 '年'，以避免与年份范围规则冲突 ---
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

        // 一般数值范围 X-Y -> X到Y（不带单位；不碰到“年”的逐字规则）
        // 【修改点 2】: 增加负向先行断言 (?!\s*(?:年|年代))，防止此规则错误地匹配年份范围
        let generalRangePattern = #"(?<!\d)(\d{1,6})\s*-\s*(\d{1,6})(?!\d)(?!\s*(?:年|年代))"#
        if let generalRegex = try? NSRegularExpression(pattern: generalRangePattern, options: []) {
            let nsRange = NSRange(processed.startIndex..<processed.endIndex, in: processed)
            var result = processed
            var delta = 0
            generalRegex.enumerateMatches(in: processed, options: [], range: nsRange) { match, _, _ in
                guard let match = match else { return }
                // 只做直接替换“到”，不进行中文数值读法，以免误读四位数为年份
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

        // 术语替换（保持原有映射）
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

// 【修改】重构 MiniAudioBubbleView 以适应新需求
struct MiniAudioBubbleView: View {
    // 【新增】接收播放状态，用于决定图标和动画
    let isPlaybackActive: Bool
    // 【新增】接收一个通用的点击闭包
    let onTap: () -> Void

    // 【新增】用于控制脉冲动画的状态
    @State private var isPulsing = false

    var body: some View {
        VStack {
            Spacer()
            Button(action: onTap) { // 【修改】使用传入的 onTap 闭包
                // 直接放置 Image，移除外层的 HStack（如果只有一个图标，HStack 是多余的）
                Image(systemName: isPlaybackActive ? "headphones.circle" : "headphones.circle.fill")
                    .font(.system(size: 40)) // 【可选】稍微调大一点图标尺寸，因为没有背景了
                    .foregroundColor(.white) // 图标颜色，根据您的背景调整，这里设为白色
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2) // 【新增】添加一点阴影让图标在复杂背景上更清晰
                    // 【新增】当播放激活时，应用脉冲缩放效果
                    .scaleEffect(isPulsing && isPlaybackActive ? 1.1 : 1.0)
                    // 【新增】定义脉冲动画
                    .animation(
                        isPlaybackActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                        value: isPulsing
                    )
            }
            .padding(.leading, 16) // 调整外边距位置
            .padding(.bottom, 16)
            .onAppear {
                // 视图出现时启动动画状态切换
                self.isPulsing = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
    }
}
