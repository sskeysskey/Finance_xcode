import Foundation
import AVFoundation
import Combine
import SwiftUI

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
    
    // --- 核心修改 1: 持有对临时文件和写入文件的引用 ---
    private var temporaryAudioFileURL: URL?
    private var audioFile: AVAudioFile?
    // ---------------------------------------------

    override init() {
        super.init()
        self.speechSynthesizer.delegate = self
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
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        // --- 核心修改 2: 准备文件路径和 AVAudioFile 对象 ---
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".caf"
        temporaryAudioFileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            // 在合成开始前，就基于第一个数据块的格式创建好用于写入的文件
            // 注意：这里的 settings 只是一个占位符，将在收到第一个 buffer 时被真实格式覆盖
            let settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100]
            audioFile = try AVAudioFile(forWriting: temporaryAudioFileURL!, settings: settings)
        } catch {
            handleError("创建音频文件失败: \(error)")
            return
        }
        // -------------------------------------------------

        speechSynthesizer.write(utterance) { [weak self] (buffer) in
            guard let self = self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                self.handleError("无法获取 PCM 缓冲。")
                return
            }
            
            if pcmBuffer.frameLength == 0 {
                self.synthesisToFileCompleted()
            } else {
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
    
    // --- 核心修改 3: 简化 append 方法，直接写入已打开的文件 ---
    private func appendBufferToFile(buffer: AVAudioPCMBuffer) {
        do {
            // 确保 audioFile 存在，然后直接写入
            try self.audioFile?.write(from: buffer)
        } catch {
            handleError("写入音频文件失败: \(error)")
        }
    }
    // -----------------------------------------------------
    
    // --- 核心修改 4: 合成结束后，关闭文件并准备播放 ---
    private func synthesisToFileCompleted() {
        // 写入完成，将 audioFile 设置为 nil 来关闭它
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
    // ------------------------------------------------
    
    private func cleanupTemporaryFile() {
        // --- 核心修改 5: 清理时也要确保关闭文件引用 ---
        audioFile = nil // 关闭文件句柄
        if let url = temporaryAudioFileURL {
            try? FileManager.default.removeItem(at: url)
            temporaryAudioFileURL = nil
        }
        // ------------------------------------------
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
    }

    // MARK: - Audio Session and Error Handling
    
    private func setupAudioSession() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        print("音频会话已成功激活。")
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
