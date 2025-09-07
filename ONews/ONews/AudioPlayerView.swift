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

    // MARK: - Private Properties
    private var speechSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    
    private var temporaryAudioFileURL: URL?
    private var audioFile: AVAudioFile?

    override init() {
        super.init()
        self.speechSynthesizer.delegate = self
        setupRemoteTransportControls()
        setupNotifications()
    }
    
    // 设置远程控制
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying { self.playPause(); return .success }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.playPause(); return .success }
            return .commandFailed
        }
        
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
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

    // MARK: - Public Control Methods
    
    func startPlayback(text: String) {
        if isPlaybackActive { stop() }
        
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
            updateNowPlayingInfo(playbackRate: 0.0, elapsed: player.currentTime, duration: player.duration)
        } else {
            do {
                try setupAudioSession()
                player.play()
                isPlaying = true
                startDisplayLink()
                // NEW: 播放继续 -> playbackRate = 1，且确保命令启用
                enableRemoteCommandsForActivePlayback()
                updateNowPlayingInfo(playbackRate: 1.0, elapsed: player.currentTime, duration: player.duration)
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
    private func finishNaturally() {
        audioPlayer?.stop()
        isPlaying = false
        // 保留 isPlaybackActive = true，以便 UI 继续显示面板和“下一篇”按钮
        isSynthesizing = false
        stopDisplayLink()
        
        // 可选：将进度归终点
        if let player = audioPlayer {
        progress = 1.0
        currentTimeString = formatTime(player.duration)
            // NEW: 标记为已播完，速率 0，进度到尾
            updateNowPlayingInfo(playbackRate: 0.0, elapsed: player.duration, duration: player.duration)
            // 保持命令启用，允许锁屏上“播放”重启（如果你的设计允许）
            enableRemoteCommandsForActivePlayback()
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
            audioPlayer?.prepareToPlay()
            durationString = formatTime(audioPlayer?.duration ?? 0)
            audioPlayer?.play()
            isPlaying = true
            startDisplayLink()
            // NEW: 每次开始播放时，确保远程命令启用
             enableRemoteCommandsForActivePlayback()
             
             // NEW: 刷新 NowPlayingInfo，尤其是 PlaybackRate
             updateNowPlayingInfo(playbackRate: 1.0, elapsed: audioPlayer?.currentTime ?? 0, duration: audioPlayer?.duration ?? 0)
        } catch {
            handleError("创建或播放 AVAudioPlayer 失败: \(error)")
        }
    }
    
    private func enableRemoteCommandsForActivePlayback() {
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.stopCommand.isEnabled = true
    }
    
    private func updateNowPlayingInfo(playbackRate: Double, elapsed: TimeInterval, duration: TimeInterval) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyTitle] = "正在播放的文章"
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    info[MPMediaItemPropertyPlaybackDuration] = duration
    info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
        
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
        .replacingOccurrences(of: "「", with: "")
        .replacingOccurrences(of: "」", with: "")
        
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
    // NEW: 从上层注入“播放下一篇并自动朗读”的动作
    var playNextAndStart: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            if playerManager.isSynthesizing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在合成语音，请稍候...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                // 进度条和时间
                HStack(spacing: 12) {
                    Text(playerManager.currentTimeString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    
                    Slider(value: $sliderValue, in: 0...1, onEditingChanged: { editing in
                        self.isEditingSlider = editing
                        if !editing {
                            // 当用户松手时，更新播放进度
                            playerManager.seek(to: sliderValue)
                        }
                    })
                    .accentColor(.white)
                    
                    Text(playerManager.durationString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                
                // 控制按钮
                HStack(spacing: 40) {
                    Spacer()
                    Button(action: {
                        playerManager.playPause()
                    }) {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                    }
                    Spacer()
                }
                // NEW: 播放完毕后显示“播放下一篇”按钮
                if playerManager.isPlaybackActive && !playerManager.isSynthesizing && !playerManager.isPlaying {
                    Button(action: {
                        playNextAndStart?()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.forward.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                            Text("播放下一篇")
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.black)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .cornerRadius(12)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .foregroundColor(.white)
        .padding(EdgeInsets(top: 35, leading: 20, bottom: 15, trailing: 20))
        .background(.black.opacity(0.8))
        .cornerRadius(20)
        .overlay(
            // 关闭按钮
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
        .offset(y: -50) // 向下偏移100点，你可以根据需要调整这个值
        .padding(.horizontal) // 添加水平内边距确保不会太靠近屏幕边缘
        .onChange(of: playerManager.progress) { _, newValue in
            // 只有在用户没有拖动滑块时，才更新滑块位置
            if !isEditingSlider {
                self.sliderValue = newValue
            }
        }
    }
}
