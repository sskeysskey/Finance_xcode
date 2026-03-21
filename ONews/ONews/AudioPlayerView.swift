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
    private let autoPlayEnabledKey = "audio.autoPlayEnabled"
    private var remoteCommandsRegistered = false
    private var nowPlayingTitle: String = Localized.playingArticle
    private var synthesisWatchdogTimer: Timer?
    private var synthesisLastWriteAt: Date?

    // ▶ 新增：分块流式合成相关属性
    private var textChunks: [String] = []
    private var chunkFileURLs: [URL?] = []         // nil = 尚未合成完毕
    private var chunkDurations: [TimeInterval] = [] // 0 = 尚未获取
    private var currentPlayingChunkIndex = 0
    private var currentSynthesizingChunkIndex = 0
    private var isAllSynthesized = false
    private var waitingForChunk = false
    private var selectedVoice: AVSpeechSynthesisVoice?
    private var currentChunkAudioFile: AVAudioFile?
    private var currentChunkFileURL: URL?
    private var synthesisGeneration: Int = 0        // 防止旧的合成回调干扰新播放

    // ▶ 新增：计算属性 - 估算总时长
    private var totalEstimatedDuration: TimeInterval {
        let knownDuration = chunkDurations.reduce(0, +)
        guard !textChunks.isEmpty else { return knownDuration }
        if isAllSynthesized { return knownDuration }

        // 用已知块的「时长/字符数」比值来估算未合成块的时长
        let synthesizedIndices = chunkDurations.enumerated().filter { $0.element > 0 }
        guard !synthesizedIndices.isEmpty else { return 0 }

        let synthesizedCharCount = synthesizedIndices.reduce(0) { $0 + textChunks[$1.offset].count }
        guard synthesizedCharCount > 0 else { return knownDuration }
        let avgDurationPerChar = knownDuration / Double(synthesizedCharCount)

        let remainingCharCount = textChunks.enumerated()
            .filter { chunkDurations[$0.offset] == 0 }
            .reduce(0) { $0 + $1.element.count }

        return knownDuration + avgDurationPerChar * Double(remainingCharCount)
    }

    // ▶ 新增：安全重置语音合成器，防止中断 write 导致的底层死锁
    private func resetSpeechSynthesizer() {
        // 先关闭当前正在进行的操作并解除代理
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.delegate = nil
        
        // 重新初始化一个干净的实例
        speechSynthesizer = AVSpeechSynthesizer()
        speechSynthesizer.delegate = self
    }

    // ▶ 新增：当前播放块之前所有块的累计时长
    private var elapsedTimeBeforeCurrentChunk: TimeInterval {
        guard currentPlayingChunkIndex > 0 else { return 0 }
        return chunkDurations.prefix(currentPlayingChunkIndex).reduce(0, +)
    }

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
        for url in chunkFileURLs {
            if let url = url { try? FileManager.default.removeItem(at: url) }
        }
        Task { @MainActor [weak self] in
            self?.invalidateSynthesisWatchdog()
        }
    }

    func prepareForNextTransition() {
        synthesisGeneration += 1
        resetSpeechSynthesizer() // <--- 替换原有的 stopSpeaking
        
        audioPlayer?.stop()
        isPlaying = false
        isSynthesizing = false
        waitingForChunk = false
        isAllSynthesized = false
        
        stopDisplayLink()
        cleanupAllChunkFiles()
        invalidateSynthesisWatchdog()
        
        textChunks = []
        chunkDurations = []
        currentPlayingChunkIndex = 0
        currentSynthesizingChunkIndex = 0
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
            let overallTime = elapsedTimeBeforeCurrentChunk + player.currentTime
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = overallTime
            info[MPMediaItemPropertyPlaybackDuration] = totalEstimatedDuration
            info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? Double(playbackRate) : 0.0
        }
        info[MPMediaItemPropertyArtist] = isAutoPlayEnabled ? Localized.autoPlay : Localized.singlePlay
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingInfo(playbackRate explicitRate: Double? = nil) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = nowPlayingTitle

        let speedText = String(format: "%.2fx", playbackRate).replacingOccurrences(of: ".00", with: "x")
        let modeText = isAutoPlayEnabled ? Localized.autoPlay : Localized.singlePlay
        info[MPMediaItemPropertyArtist] = "\(modeText) • \(speedText)"
        info[MPMediaItemPropertyAlbumTitle] = "Speed \(speedText)"

        let totalDur = totalEstimatedDuration
        if let player = audioPlayer {
            let overallTime = elapsedTimeBeforeCurrentChunk + player.currentTime
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = overallTime
            info[MPMediaItemPropertyPlaybackDuration] = totalDur
            let rate: Double
            if let explicitRate = explicitRate {
                rate = explicitRate
            } else {
                rate = player.isPlaying ? Double(self.playbackRate) : 0.0
            }
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
            info[MPMediaItemPropertyPlaybackDuration] = totalDur
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

    // MARK: - ▶ 分块文本拆分
    private func splitIntoChunks(_ text: String) -> [String] {
        let firstChunkTarget = 300    // 第一块目标较小，确保快速开始播放
        let normalChunkTarget = 800   // 后续块较大，减少块间衔接

        guard text.count > firstChunkTarget else { return [text] }

        // 按句子边界拆分
        let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if sentenceEnders.contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(current)
                    current = ""
                }
            } else if char == "\n" {
                // 换行也作为断点
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
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

        for sentence in sentences {
            let target = chunks.isEmpty ? firstChunkTarget : normalChunkTarget
            if currentChunk.count + sentence.count > target && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = sentence
            } else {
                currentChunk += sentence
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    // MARK: - ▶ 核心：流式分块播放入口
    func startPlayback(text: String, title: String? = nil, language: String = "zh-CN") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handleError(Localized.errEmptyText)
            return
        }

        // 清理上一次播放状态
        synthesisGeneration += 1
        resetSpeechSynthesizer() // <--- 替换原有的 stopSpeaking
        
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        stopDisplayLink()
        cleanupAllChunkFiles()
        invalidateSynthesisWatchdog()

        self.nowPlayingTitle = title?.isEmpty == false ? title! : Localized.playingArticle
        // self.speechSynthesizer.delegate = self <--- 这一行删掉，reset方法里已经赋过值了

        // 确定语音
        if language.starts(with: "en") {
            selectedVoice = AVSpeechSynthesisVoice(language: "en-US")
        } else {
            selectedVoice = getBestVoice(for: text)
        }

        // 预处理文本并拆分为块
        let processedText = preprocessText(text, language: language)
        textChunks = splitIntoChunks(processedText)
        chunkFileURLs = Array(repeating: nil, count: textChunks.count)
        chunkDurations = Array(repeating: 0.0, count: textChunks.count)
        currentPlayingChunkIndex = 0
        currentSynthesizingChunkIndex = 0
        isAllSynthesized = false
        waitingForChunk = false

        isSynthesizing = true
        isPlaybackActive = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true, options: [])
        } catch {
            print("\(Localized.errSessionFailed): \(error.localizedDescription)")
        }

        refreshNowPlayingInfo(playbackRate: 0.0)

        // 开始合成第一个块
        synthesizeChunk(at: 0)
    }

    // MARK: - ▶ 合成单个块
    private func synthesizeChunk(at index: Int) {
        guard index < textChunks.count else {
            isAllSynthesized = true
            invalidateSynthesisWatchdog()
            // 更新为精确总时长
            durationString = formatTime(totalEstimatedDuration)
            return
        }

        currentSynthesizingChunkIndex = index
        let chunkText = textChunks[index]
        let generation = synthesisGeneration

        let utterance = AVSpeechUtterance(string: chunkText)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05
        utterance.preUtteranceDelay = 0.05

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "chunk_\(index)_\(UUID().uuidString).caf"
        let fileURL = tempDir.appendingPathComponent(fileName)
        currentChunkFileURL = fileURL
        currentChunkAudioFile = nil

        synthesisLastWriteAt = Date()
        if index == 0 { startSynthesisWatchdog() }

        speechSynthesizer.write(utterance) { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 防止旧的合成回调干扰新的播放
                guard self.synthesisGeneration == generation else { return }

                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    self.handleError(Localized.errPCMBuffer)
                    return
                }

                self.synthesisLastWriteAt = Date()

                if pcmBuffer.frameLength == 0 {
                    // 当前块合成完毕
                    self.onChunkSynthesisComplete(at: index, fileURL: fileURL)
                } else {
                    if self.currentChunkAudioFile == nil {
                        do {
                            self.currentChunkAudioFile = try AVAudioFile(forWriting: fileURL, settings: pcmBuffer.format.settings)
                        } catch {
                            self.handleError("\(Localized.errPlayerFailed): \(error)")
                            return
                        }
                    }
                    do {
                        try self.currentChunkAudioFile?.write(from: pcmBuffer)
                    } catch {
                        self.handleError("\(Localized.unknownError): \(error)")
                    }
                }
            }
        }
    }

    // MARK: - ▶ 单块合成完成回调
    private func onChunkSynthesisComplete(at index: Int, fileURL: URL) {
        currentChunkAudioFile = nil
        chunkFileURLs[index] = fileURL

        // 获取此块的精确时长
        if let tempPlayer = try? AVAudioPlayer(contentsOf: fileURL) {
            chunkDurations[index] = tempPlayer.duration
        }

        // 更新总时长显示
        durationString = formatTime(totalEstimatedDuration)

        // 如果这正是等待播放的块，立即开始播放
        if index == currentPlayingChunkIndex && (!isPlaying || waitingForChunk) {
            waitingForChunk = false
            isSynthesizing = false
            startPlayingCurrentChunk()
        }

        // 继续合成下一个块
        let nextIndex = index + 1
        if nextIndex < textChunks.count {
            synthesizeChunk(at: nextIndex)
        } else {
            isAllSynthesized = true
            invalidateSynthesisWatchdog()
            durationString = formatTime(totalEstimatedDuration)
        }
    }

    // MARK: - ▶ 播放当前块
    private func startPlayingCurrentChunk() {
        guard currentPlayingChunkIndex < chunkFileURLs.count,
              let url = chunkFileURLs[currentPlayingChunkIndex] else {
            // 该块尚未合成完毕，进入等待状态
            waitingForChunk = true
            isSynthesizing = true
            return
        }

        do {
            try setupAudioSession()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
            applyPlaybackRate()
            audioPlayer?.play()
            isPlaying = true
            isSynthesizing = false
            startDisplayLink()

            setupRemoteTransportControls()
            enableRemoteCommandsForActivePlayback()
            refreshNowPlayingInfo(playbackRate: 1.0)
        } catch {
            handleError("\(Localized.errPlayerFailed): \(error)")
        }
    }

    private func getBestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let textForDetection = text.replacingOccurrences(of: "https?://[^\\s]+", with: "", options: .regularExpression)
        let hasChineseChar = textForDetection.range(of: "\\p{Han}", options: .regularExpression) != nil

        var finalLanguageCode = "zh-CN"

        if hasChineseChar {
            finalLanguageCode = "zh-CN"
        } else {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(textForDetection)
            if let detected = recognizer.dominantLanguage?.rawValue {
                finalLanguageCode = detected
            } else {
                finalLanguageCode = Locale.current.language.languageCode?.identifier ?? "zh-CN"
            }
        }

        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matches = voices.filter { $0.language.starts(with: finalLanguageCode) }
        if let v = matches.first(where: { $0.quality == .premium }) { return v }
        if let v = matches.first(where: { $0.quality == .enhanced }) { return v }
        if let v = matches.first { return v }
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
                handleError("\(Localized.errPlayerFailed): \(error)")
            }
        }
    }

    func stop() {
        synthesisGeneration += 1
        resetSpeechSynthesizer() // <--- 替换原有的 stopSpeaking
        
        audioPlayer?.stop()

        isPlaying = false
        isPlaybackActive = false
        isSynthesizing = false
        waitingForChunk = false
        isAllSynthesized = false

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
        cleanupAllChunkFiles()
        deactivateAudioSession()
        invalidateSynthesisWatchdog()

        audioPlayer?.delegate = nil
        audioPlayer = nil
        
        // speechSynthesizer.delegate = nil <--- 这一行删掉，reset方法里处理过了
        
        textChunks = []
        chunkFileURLs = []
        chunkDurations = []
        currentPlayingChunkIndex = 0
        currentSynthesizingChunkIndex = 0
    }

    // ▶ 修改：自然结束——当前块播完后衔接下一块
    private func finishNaturally() {
        audioPlayer?.stop()
        isPlaying = false
        isSynthesizing = false
        stopDisplayLink()

        progress = 1.0
        currentTimeString = formatTime(totalEstimatedDuration)
        refreshNowPlayingInfo(playbackRate: 0.0)
        enableRemoteCommandsForActivePlayback()

        if isAutoPlayEnabled {
            onNextRequested?()
        }
        onPlaybackFinished?()
    }

    // ▶ 修改：跨块 seek
    func seek(to value: Double) {
        let totalDur = totalEstimatedDuration
        guard totalDur > 0 else { return }
        let targetTime = totalDur * value

        // 找到目标块
        var cumulative: TimeInterval = 0
        var targetChunk = 0
        var timeWithinChunk: TimeInterval = 0

        for i in 0..<chunkDurations.count {
            let dur = chunkDurations[i]
            if dur <= 0 { break } // 未合成的块不能 seek
            if cumulative + dur > targetTime {
                targetChunk = i
                timeWithinChunk = targetTime - cumulative
                break
            }
            cumulative += dur
            if i == chunkDurations.count - 1 {
                targetChunk = i
                timeWithinChunk = min(dur, targetTime - cumulative + dur)
            }
        }

        // 只能 seek 到已合成的块
        guard chunkFileURLs[targetChunk] != nil else { return }

        if targetChunk == currentPlayingChunkIndex {
            // 同一块内 seek
            audioPlayer?.currentTime = timeWithinChunk
            updateProgress()
        } else {
            // 切换到不同的块
            audioPlayer?.stop()
            stopDisplayLink()
            currentPlayingChunkIndex = targetChunk
            startPlayingCurrentChunk()
            audioPlayer?.currentTime = timeWithinChunk
            updateProgress()
        }
    }

    // ▶ 修改：块合成完毕后的文件清理
    private func cleanupAllChunkFiles() {
        currentChunkAudioFile = nil
        for url in chunkFileURLs {
            if let url = url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        chunkFileURLs = []
        if let url = currentChunkFileURL {
            try? FileManager.default.removeItem(at: url)
            currentChunkFileURL = nil
        }
    }

    private func startSynthesisWatchdog(timeout: TimeInterval = 15) {
        invalidateSynthesisWatchdog()
        synthesisWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isSynthesizing || self.currentSynthesizingChunkIndex < self.textChunks.count else {
                    self.invalidateSynthesisWatchdog()
                    return
                }
                guard let last = self.synthesisLastWriteAt else { return }
                let elapsed = Date().timeIntervalSince(last)
                if elapsed > timeout {
                    self.handleError(Localized.errSynthesisTimeout)
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

    private func enableRemoteCommandsForActivePlayback() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
    }

    // ▶ 修改：播放完当前块 → 衔接下一块 / 全部完成
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentPlayingChunkIndex += 1

        if currentPlayingChunkIndex < textChunks.count {
            // 还有后续块
            if chunkFileURLs.indices.contains(currentPlayingChunkIndex),
               chunkFileURLs[currentPlayingChunkIndex] != nil {
                // 下一块已就绪，无缝衔接
                startPlayingCurrentChunk()
            } else {
                // 下一块尚未合成完，进入等待
                waitingForChunk = true
                isSynthesizing = true
                isPlaying = false
                stopDisplayLink()
            }
        } else {
            // 全部播放完毕
            finishNaturally()
        }
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

    // ▶ 修改：进度更新使用全局多块视角
    @objc private func updateProgress() {
        guard let player = audioPlayer, player.duration > 0 else { return }
        let totalDur = totalEstimatedDuration
        guard totalDur > 0 else { return }

        let overallTime = elapsedTimeBeforeCurrentChunk + player.currentTime
        progress = min(overallTime / totalDur, 1.0)
        currentTimeString = formatTime(overallTime)
        durationString = formatTime(totalDur)
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

    // MARK: - 以下所有文本预处理方法保持不变

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

    private func normalizeDash(_ text: String) -> String {
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

    private func readChineseNumber(_ n: Int) -> String {
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

    private func replaceYearMentionsForChinese(_ text: String) -> String {
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

    private func preprocessText(_ text: String, language: String) -> String {
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

    private func insertDotForDecimalBeforePercentageWords(_ text: String) -> String {
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

    private func processEnglishText(_ input: String) -> String {
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

// MARK: - AudioPlayerView (UI 不变)
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
                    Text(Localized.synthesizing)
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
                        .accessibilityLabel(playerManager.isAutoPlayEnabled ? Localized.autoPlay : Localized.singlePlay)
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
                        .accessibilityLabel("\(Localized.playbackSpeed) \(rateLabel)")
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
        // 1. 将最小化按钮（minus）移到右上角：alignment 改为 .topTrailing
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
        // 2. 将关闭按钮（xmark）移到左上角：alignment 改为 .topLeading
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
        .onChange(of: playerManager.progress) { newValue in
            if !isEditingSlider { self.sliderValue = newValue }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 0)
        }
    }
}

struct MiniAudioBubbleView: View {
    let isPlaybackActive: Bool
    let onTap: () -> Void
    @State private var isPulsing = false

    var body: some View {
        VStack {
            Spacer()
            Button(action: onTap) {
                Image(systemName: isPlaybackActive ? "headphones.circle" : "headphones.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                    .scaleEffect(isPulsing && isPlaybackActive ? 1.1 : 1.0)
                    .animation(
                        isPlaybackActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                        value: isPulsing
                    )
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .onAppear {
                self.isPulsing = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
    }
}
