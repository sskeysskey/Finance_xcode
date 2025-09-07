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

    // 防重复注册 Remote Commands 的标志
    private var remoteCommandsRegistered = false

    // 当前播放项的标题（用于锁屏展示）
    private var nowPlayingTitle: String = "正在播放的文章"

    // 合成阶段看门狗（防止在锁屏后台卡死）
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
        // 其余完整清理由外部 stop() 负责
    }

    // 仅用于“切到下一篇”时的轻量清理：不反激活 AudioSession，不拆 Remote Commands
    func prepareForNextTransition() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        isPlaying = false
        isSynthesizing = false
        stopDisplayLink()
        cleanupTemporaryFile()
        invalidateSynthesisWatchdog()
        // 保持 isPlaybackActive = true，让播放器面板维持（如果你想隐藏可自行改）
        // 保持 AudioSession 活跃，避免后台/锁屏时下一篇激活失败
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
            self.prepareForNextTransition()
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

        // 清理旧状态（轻量）
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        stopDisplayLink()
        cleanupTemporaryFile()
        invalidateSynthesisWatchdog()

        // 更新标题
        self.nowPlayingTitle = title?.isEmpty == false ? title! : "正在播放的文章"

        // 重新绑定 delegate
        self.speechSynthesizer.delegate = self

        let processedText = preprocessText(text)

        isSynthesizing = true
        isPlaybackActive = true

        // 确保音频会话处于可用状态：先设置分类，再尝试激活（若已激活则此调用幂等）
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            if !session.isOtherAudioPlaying {
                try session.setActive(true, options: [])
            } else {
                try session.setActive(true, options: [])
            }
        } catch {
            print("激活音频会话警告: \(error.localizedDescription)")
        }

        // 合成阶段刷新 NowPlaying
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

        // 启动合成看门狗
        synthesisLastWriteAt = Date()
        startSynthesisWatchdog()

        // AVSpeechSynthesizer.write 的闭包是 Sendable 语境，切回主 actor 访问/更新状态
        speechSynthesizer.write(utterance) { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    self.handleError("无法获取 PCM 缓冲。")
                    return
                }

                // 喂狗
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
        // 彻底停止：用于用户显式停止或页面消失
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()

        isPlaying = false
        isPlaybackActive = false
        isSynthesizing = false

        progress = 0.0
        currentTimeString = "00:00"
        durationString = "00:00"

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // 禁用并移除 Remote Commands
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        teardownRemoteTransportControls()

        stopDisplayLink()
        cleanupTemporaryFile()
        deactivateAudioSession()
        invalidateSynthesisWatchdog()

        // 彻底释放播放器与合成器
        audioPlayer?.delegate = nil
        audioPlayer = nil
        speechSynthesizer.delegate = nil
    }

    // 自然结束时的收尾，不隐藏面板，不反激活会话
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

        onNextRequested?()
        onPlaybackFinished?()
    }

    func seek(to value: Double) {
        guard let player = audioPlayer else { return }
        let newTime = player.duration * value
        player.currentTime = newTime
        updateProgress()
    }

    // MARK: - Synthesis and File Handling
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

    // MARK: - Watchdog for synthesis (MainActor)
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

    // MARK: - AVAudioPlayer Setup and Delegate
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

    // MARK: - Progress Update (CADisplayLink)
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

    // MARK: - Audio Session and Error Handling
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

    private func preprocessText(_ text: String) -> String {
        let processedSpecialTerms = processEnglishText(text)
        let pattern = "([\\u4e00-\\u9fa5])(\\s*[a-zA-Z]+\\s*)([\\u4e00-\\u9fa5])"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(processedSpecialTerms.startIndex..<processedSpecialTerms.endIndex, in: processedSpecialTerms)
        let modifiedText = regex?.stringByReplacingMatches(
            in: processedSpecialTerms,
            options: [],
            range: range,
            withTemplate: "$1, $2, $3"
        ) ?? processedSpecialTerms
        return modifiedText
    }

    private func processEnglishText(_ text: String) -> String {
        var processed = text

        processed = processed
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "\"", with: "")

        // 可选：若不想匹配“3-”（缺失右侧数字），把正则改为 (\\d+)-(\\d+)
        let hyphenPattern = "(\\d+)-(\\d*)"
        let regex = try? NSRegularExpression(pattern: hyphenPattern, options: [])
        let range = NSRange(processed.startIndex..<processed.endIndex, in: processed)
        processed = regex?.stringByReplacingMatches(
            in: processed,
            options: [],
            range: range,
            withTemplate: "$1到$2"
        ) ?? processed

        let replacements = [
            "API": "A.P.I",
            "URL": "U.R.L",
            "HTTP": "H.T.T.P",
            "JSON": "Jason",
            "HTML": "H.T.M.L",
            "CSS": "C.S.S",
            "JS": "J.S",
            "AI": "A.I",
            "SDK": "S.D.K",
            "iOS": "i O S",
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
            "vs": "versus",
            "etc": "等等",
            "i.e": "也就是说",
            "e.g": "举例来说",
            "&": "and",
            "+": "plus",
            "=": "等于",
            "@": "at",
            "#": "hash",
            "~": "tilde",
            "^": "caret",
            "|": "vertical bar",
            "\\": "backslash",
            "/": "每",
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
    private var autoModeIconName: String {
        playerManager.isAutoPlayEnabled ? "repeat.circle.fill" : "repeat.1.circle.fill"
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
        VStack(spacing: 16) {
            HStack(spacing: 12) {
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
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在合成语音，请稍候...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ZStack {
                    Button(action: { playerManager.playPause() }) {
                        Image(systemName: playPauseIconName)
                            .font(.system(size: 54, weight: .regular))
                    }
                    .disabled(playerManager.isSynthesizing || !playerManager.isPlaybackActive)
                    .opacity(playerManager.isSynthesizing || !playerManager.isPlaybackActive ? 0.6 : 1.0)
                }
                .frame(height: 70)

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
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
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
                                .font(.system(size: 22, weight: .semibold))
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
        .padding(EdgeInsets(top: 35, leading: 20, bottom: 15, trailing: 20))
        .background(.black.opacity(0.8))
        .cornerRadius(20)
        .overlay(
            Button(action: { toggleCollapse?() }) {
                Image(systemName: "minus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .clipShape(Circle())
                    .accessibilityLabel("最小化播放器")
            }
            .padding(8),
            alignment: .topLeading
        )
        .overlay(
            Button(action: { playerManager.stop() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(6)
                    .background(Color.white.opacity(0.8))
                    .clipShape(Circle())
            }
            .padding(8),
            alignment: .topTrailing
        )
        .offset(y: -50)
        .padding(.horizontal)
        .onChange(of: playerManager.progress) { _, newValue in
            if !isEditingSlider { self.sliderValue = newValue }
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
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.8))
                .clipShape(Capsule())
                .shadow(radius: 6)
            }
            .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(true)
    }
}
