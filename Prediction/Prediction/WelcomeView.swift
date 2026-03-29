import SwiftUI

struct FloatingTopic: Identifiable {
    let id = UUID()
    let text: String
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    let color: Color
    let speed: CGFloat
    let angle: Double
}

struct FloatingTopicsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var topics: [FloatingTopic] = []
    @State private var topicTexts: [String] = []
    @State private var isActive = false
    
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                Canvas { context, size in
                    for topic in topics {
                        let scale = 0.3 + (topic.z * 2.0)
                        let spread = topic.z * 280
                        let drawX = (size.width / 2) + CGFloat(cos(topic.angle)) * spread * topic.x
                        let drawY = (size.height / 2) + CGFloat(sin(topic.angle)) * spread * topic.y
                        
                        let opacity: Double
                        if topic.z < 0.15 { opacity = topic.z * 6 }
                        else if topic.z > 0.8 { opacity = 1.0 - ((topic.z - 0.8) * 5) }
                        else { opacity = 1.0 }
                        
                        if opacity > 0.01 {
                            var text = context.resolve(
                                Text(topic.text)
                                    .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                            )
                            text.shading = .color(topic.color)
                            context.opacity = opacity
                            context.draw(text, at: CGPoint(x: drawX, y: drawY), anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear {
            isActive = true
            Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { t in
                guard isActive else { t.invalidate(); return }
                updateTopics()
            }
        }
        .onDisappear { isActive = false }
        .task {
            let fetched = await syncManager.fetchWelcomeTopics()
            self.topicTexts = fetched
        }
        .allowsHitTesting(false)
    }
    
    private func updateTopics() {
        topics = topics.compactMap { var t = $0; t.z += t.speed; return t.z < 1.0 ? t : nil }
        
        if topics.count < 15 && !topicTexts.isEmpty && Double.random(in: 0...1) > 0.93 {
            // 使用彩色池增加现代感
            let randomColor = Color.floatingColors.randomElement() ?? .indigo
            topics.append(FloatingTopic(
                text: topicTexts.randomElement()!,
                x: CGFloat.random(in: 0.5...1.5),
                y: CGFloat.random(in: 0.5...1.5),
                z: 0.0,
                color: randomColor.opacity(Double.random(in: 0.6...0.9)),
                speed: CGFloat.random(in: 0.002...0.005),
                angle: Double.random(in: 0...(2 * .pi))
            ))
        }
    }
}

struct WelcomeView: View {
    @Binding var hasCompletedOnboarding: Bool
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var prefManager: PreferenceManager
    
    @State private var showPreferenceView = false
    @State private var ripple = false
    @State private var hasAttemptedSync = false
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                
                // 背景高级光晕 (Mesh Gradient 风格)
                Circle()
                    .fill(Color.brandStart.opacity(0.15))
                    .frame(width: 300)
                    .blur(radius: 60)
                    .offset(x: -100, y: -200)
                
                Circle()
                    .fill(Color.brandEnd.opacity(0.15))
                    .frame(width: 300)
                    .blur(radius: 60)
                    .offset(x: 150, y: 200)
                
                // 飘浮话题
                VStack {
                    Spacer().frame(height: 140)
                    FloatingTopicsView()
                        .frame(height: 380)
                        .mask(
                            LinearGradient(
                                colors: [.clear, .black, .black, .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    Spacer()
                }
                
                // 主文本
                VStack(spacing: 0) {
                    Spacer().frame(height: 90)
                    
                    Image(systemName: "chart.bar.xaxis.ascending")
                        .font(.system(size: 50))
                        .foregroundStyle(LinearGradient.brandGradient)
                        .padding(.bottom, 12)
                    
                    Text("Prediction")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("洞察全球预测市场")
                        .font(.title3.bold())
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    
                    Spacer()
                    
                    // 底部按钮
                    VStack(spacing: 16) {
                        Button {
                            // 【修改】如果有数据直接进，没数据先强制同步
                            if syncManager.polymarketItems.isEmpty && syncManager.kalshiItems.isEmpty {
                                Task {
                                    // isManual 设为 true 强制越过一些静默拦截
                                    try? await syncManager.checkAndSync(isManual: true)
                                    // 下载成功后才跳转
                                    if !syncManager.polymarketItems.isEmpty || !syncManager.kalshiItems.isEmpty {
                                        showPreferenceView = true
                                    }
                                }
                            } else {
                                showPreferenceView = true
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "slider.horizontal.3")
                                Text("选择您的偏好配置")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(LinearGradient.brandGradientHorizontal)
                            .cornerRadius(16)
                            .shadow(color: Color.brandStart.opacity(0.3), radius: 10, y: 4)
                        }
                        .padding(.horizontal, 40)
                        
                        // 跳过 (用于快速进入)
                        Button("稍后设置，先看看") {
                            hasCompletedOnboarding = true
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 60)
                }
                
                // 同步遮罩
                if syncManager.isSyncing {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().tint(.white).scaleEffect(1.3)
                        Text("正在同步数据...")
                            .font(.headline).foregroundColor(.white)
                    }
                }
            }
            .navigationDestination(isPresented: $showPreferenceView) {
                PreferenceSelectionView(isOnboarding: true) {
                    hasCompletedOnboarding = true
                }
            }
        }
        .onChange(of: scenePhase) { new in
            if new == .active && !hasAttemptedSync {
                hasAttemptedSync = true
                Task { try? await syncManager.checkAndSync() }
            }
        }
    }
}