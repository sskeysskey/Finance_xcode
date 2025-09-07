import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import NaturalLanguage // 确保已导入

@MainActor
class AudioPlayerManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    // MARK: - Published Properties for UI
    @Published var isPlaybackActive = false
    @Published var isPlaying = false
    @Published var isSynthesizing = false
    
    @Published var progress: Double = 0.0
    @Published var currentTimeString: String = "00:00"
    @Published var durationString: String = "00:00"
    // NEW: 播放自然结束回调（非 stop() 主动停止）
    var onPlaybackFinished: (() -> Void)?
    // 在类内添加回调占位（你可以从外部注入）
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
            refreshNowPlayingInfo() // 关键：让锁屏立即反映新的倍速文本
        }
    }

    // MARK: - Private Properties
    private var speechSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    
    private var temporaryAudioFileURL: URL?
    private var audioFile: AVAudioFile?
    private let autoPlayEnabledKey = "audio.autoPlayEnabled"

    override init() {
        super.init()
        self.speechSynthesizer.delegate = self
        // 从持久化读取（默认为 false）
        if UserDefaults.standard.object(forKey: autoPlayEnabledKey) != nil {
            self.isAutoPlayEnabled = UserDefaults.standard.bool(forKey: autoPlayEnabledKey)
        } else {
            self.isAutoPlayEnabled = false
        }
        setupRemoteTransportControls()
        setupNotifications()
    }
        
    private func prepareForNext() {
        // 停止合成和播放，但不重置 isPlaybackActive，让面板留着
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        stopDisplayLink()
        isPlaying = false
        isSynthesizing = false
        // 不清空 nowPlayingInfo，这样锁屏面板不会立刻消失
        // 不禁用 remote commands，保持可用
        // 清理临时文件，防止残留
        cleanupTemporaryFile()
    }

    private func applyPlaybackRate() {
        guard let player = audioPlayer else { return }
        player.enableRate = true
        player.rate = playbackRate
        // 如果正在播放，rate 立即生效；若暂停则等恢复时同样设置
    }
    
    // 设置远程控制
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true

        commandCenter.playCommand.addTarget(handler: { [weak self] (event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying { self.playPause(); return .success }
            return .commandFailed
        })

        commandCenter.pauseCommand.addTarget(handler: { [weak self] (event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.playPause(); return .success }
            return .commandFailed
        })

        commandCenter.stopCommand.addTarget(handler: { [weak self] (event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            self?.stop()
            return .success
        })

        // 下一篇
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
        guard let self = self else { return .commandFailed }
        // 无论是否在播/合成都先打断当前内容
        self.prepareForNext()
        // 通知上层切换
        self.onNextRequested?()
        return .success
        }

        // 不支持上一首
        commandCenter.previousTrackCommand.isEnabled = false
    }
    
    private func updateRepeatStateInNowPlaying() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = info[MPMediaItemPropertyTitle] ?? "正在播放的文章"
        if let player = audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        }
        // 这里也可以把自动连播状态编码到某个可见字段（可选）
        info[MPMediaItemPropertyArtist] = isAutoPlayEnabled ? "自动连播" : "单次播放"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func refreshNowPlayingInfo(playbackRate explicitRate: Double? = nil) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    info[MPMediaItemPropertyTitle] = "正在播放的文章"

    let speedText = String(format: "%.2fx", playbackRate).replacingOccurrences(of: ".00", with: "x")
    info[MPMediaItemPropertyArtist] = isAutoPlayEnabled ? "自动连播 • \(speedText)" : "单次播放 • \(speedText)"
    info[MPMediaItemPropertyAlbumTitle] = "Speed \(speedText)"

    if let player = audioPlayer {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPMediaItemPropertyPlaybackDuration] = player.duration

        // 显示真实倍速（暂停为 0.0；播放为当前倍速）
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
    
    // 设置通知观察
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil)
    }
    
    // 处理音频中断
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
    
    func startPlayback(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handleError("文本内容为空，无法播放。")
            return
        }
        
        // 添加文本预处理
        let processedText = preprocessText(text)

        isSynthesizing = true
        isPlaybackActive = true
        
        let utterance = AVSpeechUtterance(string: processedText)
        
        // 使用修正后的方法动态选择语音
        utterance.voice = getBestVoice(for: text)
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.3
        utterance.preUtteranceDelay = 0.2

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".caf"
            temporaryAudioFileURL = tempDir.appendingPathComponent(fileName)
            speechSynthesizer.write(utterance) { [weak self] (buffer) in
            guard let self = self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                self.handleError("无法获取 PCM 缓冲。"); return
            }
            
            if pcmBuffer.frameLength == 0 {
                self.synthesisToFileCompleted()
            } else {
                if self.audioFile == nil {
                    do {
                        self.audioFile = try AVAudioFile(forWriting: self.temporaryAudioFileURL!, settings: pcmBuffer.format.settings)
                    } catch {
                        self.handleError("根据音频数据格式创建文件失败: \(error)"); return
                    }
                }
                self.appendBufferToFile(buffer: pcmBuffer)
            }
        }
    }
    
    // --- 修正后的辅助方法 ---
    private func getBestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        
        // 1. 获取语言代码的 rawValue，而不是 bcp47
        guard let languageCode = recognizer.dominantLanguage?.rawValue else {
            return AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        }

        let voices = AVSpeechSynthesisVoice.speechVoices()
        
        // 2. 将复杂的查找逻辑分解，避免编译器超时
        // 首先，筛选出所有符合主语言的语音
        let languageSpecificVoices = voices.filter { $0.language.starts(with: languageCode) }
        
        // 然后，从这个子集中寻找最高质量的语音
        // 优先顺序: Premium -> Enhanced -> Standard
        if let voice = languageSpecificVoices.first(where: { $0.quality == .premium }) {
            print("找到 Premium 质量语音: \(voice.name) for language \(languageCode)")
            return voice
        }
        
        if let voice = languageSpecificVoices.first(where: { $0.quality == .enhanced }) {
            print("找到 Enhanced 质量语音: \(voice.name) for language \(languageCode)")
            return voice
        }
        
        // 如果没有高质量语音，就返回该语言的第一个标准语音
        if let voice = languageSpecificVoices.first {
            print("找到标准语音: \(voice.name) for language \(languageCode)")
            return voice
        }
        
        // 如果连一个匹配的语音都没有安装，则尝试直接用语言代码创建
        print("未找到已安装的语音，尝试使用代码创建: \(languageCode)")
        return AVSpeechSynthesisVoice(language: languageCode)
    }
    
    func playPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopDisplayLink()
            // NEW: 播放暂停 -> playbackRate = 0
            refreshNowPlayingInfo(playbackRate: 0.0)
        } else {
            do {
                try setupAudioSession()
                player.play()
                applyPlaybackRate() // 新增，确保恢复播放时按当前速率
                isPlaying = true
                startDisplayLink()
                // NEW: 播放继续 -> playbackRate = 1，且确保命令启用
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
        
        stopDisplayLink()
        cleanupTemporaryFile()
        deactivateAudioSession()
    }
    
    // NEW: 自然结束时的收尾，不隐藏面板
    // 在自然播放结束时：
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

            // 自动连播：触发下一篇
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
        DispatchQueue.main.async {
            self.isSynthesizing = false
            self.setupAndPlayAudioPlayer(from: url)
        }
    }
    
    private func cleanupTemporaryFile() {
        audioFile = nil
        if let url = temporaryAudioFileURL {
            try? FileManager.default.removeItem(at: url)
            temporaryAudioFileURL = nil
        }
    }

    // MARK: - AVAudioPlayer Setup and Delegate
    
    private func setupAndPlayAudioPlayer(from url: URL) {
        do {
            try setupAudioSession()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true // 新增：允许倍速
            audioPlayer?.prepareToPlay()
            durationString = formatTime(audioPlayer?.duration ?? 0)
            // 播放前应用速率
            applyPlaybackRate() // 新增
            audioPlayer?.play()
            isPlaying = true
            startDisplayLink()
            enableRemoteCommandsForActivePlayback()
            refreshNowPlayingInfo(playbackRate: 1.0)
        } catch {
            handleError("创建或播放 AVAudioPlayer 失败: (error)")
        }
    }
    
    private func enableRemoteCommandsForActivePlayback() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
    }
        
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // UPDATED: 自然播放结束时，不调用 stop()，而是保留面板并触发回调
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
        // 同步 Now Playing（仅时间，系统速率状态保持不变）
        refreshNowPlayingInfo()
    }

    // MARK: - Audio Session and Error Handling
    
    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
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
        DispatchQueue.main.async { self.stop() }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func preprocessText(_ text: String) -> String {
        // 1. 首先处理特殊词汇替换
        let processedSpecialTerms = processEnglishText(text)
        
        // 2. 添加英文片段前后的停顿
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
        
        // 先处理连字符的特殊情况
        let hyphenPattern = "(\\d+)-(\\d*)"
        let regex = try? NSRegularExpression(pattern: hyphenPattern, options: [])
        let range = NSRange(processed.startIndex..<processed.endIndex, in: processed)
        
        // 如果数字后面跟着连字符，则将连字符替换为"到"
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
            "/": "slash",
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
    // 注入“播放下一篇并自动朗读”
    var playNextAndStart: (() -> Void)?
    // 新增：切换到最小化
    var toggleCollapse: (() -> Void)?

    private var playPauseIconName: String {
        playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }
    // 自动/单次图标
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
            // 进度条和时间
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
                // 主控制区：左下自动模式切换，中间大播放/暂停，右下“下一篇”
                ZStack {
                    // 中间：放大播放/暂停按钮
                    Button(action: { playerManager.playPause() }) {
                        Image(systemName: playPauseIconName)
                            .font(.system(size: 54, weight: .regular)) // 放大
                    }
                    .disabled(playerManager.isSynthesizing || !playerManager.isPlaybackActive)
                    .opacity(playerManager.isSynthesizing || !playerManager.isPlaybackActive ? 0.6 : 1.0)
                }
                .frame(height: 70) // 给中间按钮一个合理的容器高度

                // 底部左右角控件
                HStack {
                    Button(action: {
                        playerManager.isAutoPlayEnabled.toggle()
                    }) {
                        Image(systemName: playerManager.isAutoPlayEnabled ? "repeat.circle.fill" : "repeat.1.circle.fill")
                            .font(.system(size: 35, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(playerManager.isAutoPlayEnabled ? .white : .white.opacity(0.45)) // 单次更灰
                    }
                    .accessibilityLabel(playerManager.isAutoPlayEnabled ? "自动连播" : "单次播放")

                    Spacer()
                    
                    // 倍速按钮（新增）
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

                    // 右下：“下一篇”紧凑按钮（forward.end）
                    Button(action: {
                        playNextAndStart?()
                    }) {
                        Image(systemName: "forward.end.fill") // 箭头+竖杠
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .disabled(!playerManager.isPlaybackActive || playerManager.isSynthesizing)
                    .opacity((!playerManager.isPlaybackActive || playerManager.isSynthesizing) ? 0.6 : 1.0)
                }
            }
        }
        .foregroundColor(.white)
        .padding(EdgeInsets(top: 35, leading: 20, bottom: 15, trailing: 20))
        .background(.black.opacity(0.8))
        .cornerRadius(20)
        .overlay(
            // 左上角：最小化按钮
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
            // 右上角：关闭按钮
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
