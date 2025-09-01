import SwiftUI

struct AudioPlayerView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var sliderValue: Double = 0.0
    @State private var isEditingSlider = false

    var body: some View {
        VStack(spacing: 10) {
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
        .padding(EdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20))
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
        .onChange(of: playerManager.progress) { _, newValue in
            // 只有在用户没有拖动滑块时，才更新滑块位置
            if !isEditingSlider {
                self.sliderValue = newValue
            }
        }
    }
}
