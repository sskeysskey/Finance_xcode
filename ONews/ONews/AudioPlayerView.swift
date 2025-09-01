import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer

@MainActor
class AudioPlayerManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    
    // MARK: - Published Properties for UI
    @Published var isPlaybackActive = false
    @Published var isPlaying = false
    @Published var isSynthesizing = false
    
    @Published var progress: Double = 0.0
    @Published var currentTimeString: String = "00:00"
    @Published var durationString: String = "00:00"

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
            // 启用命令
                commandCenter.playCommand.isEnabled = true
                commandCenter.pauseCommand.isEnabled = true
                commandCenter.stopCommand.isEnabled = true
            
            // 播放命令
            commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if !self.isPlaying {
                    self.playPause()
                    return .success
                }
                return .commandFailed
            }
            
            // 暂停命令
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if self.isPlaying {
                    self.playPause()
                    return .success
                }
                return .commandFailed
            }
            
            // 停止命令
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
                // 音频被中断（如来电）
                if isPlaying {
                    playPause()
                }
            case .ended:
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // 中断结束，可以恢复播放
                    if !isPlaying {
                        playPause()
                    }
                }
            @unknown default:
                break
            }
        }

    // MARK: - Public Control Methods
    
    func startPlayback(text: String) {
        if isPlaybackActive {
            stop()
        }
        
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handleError("文本内容为空，无法播放。")
            return
        }

        isSynthesizing = true
        isPlaybackActive = true
        
        let utterance = AVSpeechUtterance(string: text)
        
        // 优先使用高质量的Ting-Ting语音,如果没有则回退到其他中文语音
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let voice = voices.first(where: { $0.language == "zh-CN" && $0.quality == .enhanced })
            ?? voices.first(where: { $0.language == "zh-CN" && $0.name.contains("Ting-Ting") })
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.voice = voice
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        utterance.pitchMultiplier = 1.1
        utterance.postUtteranceDelay = 0.2
        utterance.preUtteranceDelay = 0.1 // 添加句前停顿
        utterance.postUtteranceDelay = 0.3 // 增加句后停顿到0.3秒

        // 修改临时文件的创建方式
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".caf"
        temporaryAudioFileURL = tempDir.appendingPathComponent(fileName)
        
        // --- 核心修改 2: 不再提前创建 audioFile ---
        // 我们将在收到第一个音频数据块时，根据它的格式来创建文件。
        
        speechSynthesizer.write(utterance) { [weak self] (buffer) in
            guard let self = self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                self.handleError("无法获取 PCM 缓冲。")
                return
            }
            
            if pcmBuffer.frameLength == 0 {
                self.synthesisToFileCompleted()
            } else {
                // --- 核心修改 3: 动态创建音频文件 ---
                // 如果 audioFile 尚未创建（即这是第一个数据块）
                if self.audioFile == nil {
                    do {
                        // 使用 pcmBuffer 的格式来创建文件，确保采样率完全匹配！
                        self.audioFile = try AVAudioFile(forWriting: self.temporaryAudioFileURL!, settings: pcmBuffer.format.settings)
                    } catch {
                        self.handleError("根据音频数据格式创建文件失败: \(error)")
                        return
                    }
                }
                // ------------------------------------
                
                // 将数据块写入文件
                self.appendBufferToFile(buffer: pcmBuffer)
            }
        }
    }
    
    func playPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopDisplayLink()
        } else {
            do {
                try setupAudioSession()
                player.play()
                isPlaying = true
                startDisplayLink()
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
        
        // 清理锁屏界面信息
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        
        // 禁用远程控制命令
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        
        stopDisplayLink()
        cleanupTemporaryFile()
        deactivateAudioSession()
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
            
        } catch {
            handleError("创建或播放 AVAudioPlayer 失败: \(error)")
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
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
            
            // 更新锁屏界面进度
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
        
        // 更新锁屏界面信息
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "正在播放的文章"
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = audioPlayer?.duration ?? 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("音频会话已成功释放。")
        } catch {
            print("释放音频会话失败: \(error)")
        }
    }
    
    private func handleError(_ message: String) {
        print("错误: \(message)")
        DispatchQueue.main.async {
            self.stop()
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
}

struct AudioPlayerView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var sliderValue: Double = 0.0
    @State private var isEditingSlider = false

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
        .offset(y: 50) // 向下偏移100点，你可以根据需要调整这个值
        .padding(.horizontal) // 添加水平内边距确保不会太靠近屏幕边缘
        .onChange(of: playerManager.progress) { _, newValue in
            // 只有在用户没有拖动滑块时，才更新滑块位置
            if !isEditingSlider {
                self.sliderValue = newValue
            }
        }
    }
}
