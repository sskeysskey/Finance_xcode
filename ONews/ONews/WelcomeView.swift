import SwiftUI

struct FloatingWord: Identifiable {
    let id = UUID()
    let text: String
    var x: CGFloat      // 屏幕横向位置 (-1 到 1)
    var y: CGFloat      // 屏幕纵向位置 (-1 到 1)
    var z: CGFloat      // 深度 (0.0 最远, 1.0 最近)
    let color: Color
    let speed: CGFloat
    let angle: Double   // 飞行的角度
}

struct FloatingWordsView: View {
    @EnvironmentObject var resourceManager: ResourceManager
    @State private var words: [FloatingWord] = []
    @State private var sourceNames: [String] = []
    @State private var isActive = false
    
    // 颜色池：选择鲜艳且在黑白背景下都清晰的颜色
    private let colors: [Color] = [
        .blue, .purple, .pink, .orange, .mint, .teal, .indigo, .red
    ]
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 使用 TimelineView 实现流畅的 60fps 动画
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        for word in words {
                            // 计算透视效果
                            // 深度越深(z越小)，scale越小
                            let scale = 0.2 + (word.z * 2.5) // 0.2 -> 1.7 倍大小
                            
                            // 模拟径向飞行：从中心向外扩散
                            // z 越大，离中心越远
                            let perspectiveFactor = word.z * 300 // 扩散范围
                            let drawX = (size.width / 2) + (CGFloat(cos(word.angle)) * perspectiveFactor * word.x)
                            let drawY = (size.height / 2) + (CGFloat(sin(word.angle)) * perspectiveFactor * word.y)
                            
                            // 透明度逻辑：
                            // 刚出现时(z=0)透明度低，中间(z=0.5)最清楚，
                            // 撞向屏幕前(z>0.9)迅速消失以免遮挡视线
                            let opacity: Double
                            if word.z < 0.2 {
                                opacity = word.z * 5 // 淡入
                            } else if word.z > 0.8 {
                                opacity = 1.0 - ((word.z - 0.8) * 5) // 淡出
                            } else {
                                opacity = 1.0
                            }
                            
                            // 绘制文字
                            if opacity > 0.01 {
                                var resolvedText = context.resolve(Text(word.text).fontWeight(.bold))
                                resolvedText.shading = .color(word.color)
                                
                                context.opacity = opacity
                                context.draw(
                                    resolvedText,
                                    at: CGPoint(x: drawX, y: drawY),
                                    anchor: .center
                                )
                                context.transform = .init(scaleX: scale, y: scale)
                                // 注意：Canvas 的 transform 是累加的，这里简化处理，直接利用循环重绘
                            }
                        }
                    }
                }
            }
            .onAppear {
                isActive = true
                startAnimationLoop()
            }
            .onDisappear {
                isActive = false
            }
            .task {
                // 每次出现都去服务器拿最新的名字
                let names = await resourceManager.fetchSourceNames()
                await MainActor.run {
                    self.sourceNames = names
                }
            }
        }
        // 忽略点击，让用户可以点击穿透到底下的按钮（如果有重叠）
        .allowsHitTesting(false) 
    }
    
    private func startAnimationLoop() {
        // 使用 Timer 驱动数据更新（Canvas 负责绘图，这里负责逻辑）
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            guard isActive else {
                timer.invalidate()
                return
            }
            updateParticles()
        }
    }
    
    private func updateParticles() {
        // 1. 更新现有粒子位置
        var newWords: [FloatingWord] = []
        
        for var word in words {
            word.z += word.speed // 向前飞
            
            if word.z < 1.0 { // 还没飞出屏幕
                newWords.append(word)
            }
        }
        
        // 2. 生成新粒子 (如果当前粒子较少，且有数据源)
        if newWords.count < 12 && !sourceNames.isEmpty {
            // 随机决定是否生成，制造“参差不齐”的感觉
            if Double.random(in: 0...1) > 0.95 {
                let randomText = sourceNames.randomElement() ?? "ONews"
                let randomColor = colors.randomElement() ?? .blue
                
                // 随机生成飞行角度和起始偏移
                let randomAngle = Double.random(in: 0...(2 * .pi))
                
                let newWord = FloatingWord(
                    text: randomText,
                    x: CGFloat.random(in: 0.5...1.5), // 扩散幅度因子
                    y: CGFloat.random(in: 0.5...1.5),
                    z: 0.0, // 从最远处开始
                    color: randomColor,
                    speed: CGFloat.random(in: 0.002...0.006), // 速度差异
                    angle: randomAngle
                )
                newWords.append(newWord)
            }
        }
        
        self.words = newWords
    }
}

struct WelcomeView: View {
    // 【保留】: 这两个属性保持不变
    @Binding var hasCompletedInitialSetup: Bool
    @EnvironmentObject var resourceManager: ResourceManager

    // 【保留】: 状态变量保持不变
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showAddSourceView = false
    @State private var ripple = false
    
    // 【保留】: 用于控制“已是最新”弹窗的本地状态
    @State private var showAlreadyUpToDateAlert = false

    // 【保留】: 引入 scenePhase 来监控 App 的生命周期状态
    @Environment(\.scenePhase) private var scenePhase
    
    // 【保留】: 一个状态标志，确保初始同步只执行一次
    @State private var hasAttemptedInitialSync = false
    
    private let fabSize: CGFloat = 60
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.viewBackground.ignoresSafeArea()
                
                // 特效层
                VStack {
                    Spacer().frame(height: 120)
                    FloatingWordsView()
                        .environmentObject(resourceManager)
                        .frame(height: 400)
                        .mask(LinearGradient(gradient: Gradient(colors: [.clear, .black, .black, .clear]), startPoint: .top, endPoint: .bottom))
                    Spacer()
                }
                
                // 文字层
                VStack(spacing: 0) {
                    Spacer().frame(height: 100)
                    Text("ONews")
                        .font(.system(size: 60, weight: .black, design: .rounded))
                        .foregroundColor(.blue)
                        .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                    
                    Text("可以听的海外资讯")
                        .font(.title2.bold())
                        .foregroundColor(.primary.opacity(0.8))
                        .padding(.top, 10)
                    
                    Spacer()
                    
                    Text("点击右下角按钮\n定制您的专属新闻源")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 140) // 避开底部按钮区域
                }
                
                // 底部按钮层 (Action Area)
                if !showAddSourceView {
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            // 刷新按钮 (左下角)
                            if !resourceManager.isSyncing {
                                Button(action: { Task { await syncInitialResources(isManual: true) } }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, height: 50)
                                        .background(Material.thinMaterial) // 毛玻璃
                                        .clipShape(Circle())
                                }
                                .padding(.leading, 30)
                            }
                            
                            Spacer()
                            
                            // 添加按钮 (右下角主操作)
                            Button(action: { showAddSourceView = true }) {
                                ZStack {
                                    // 涟漪效果
                                    Circle()
                                        .stroke(Color.blue.opacity(ripple ? 0 : 0.5), lineWidth: 2)
                                        .frame(width: fabSize, height: fabSize)
                                        .scaleEffect(ripple ? 1.5 : 1.0)
                                        .opacity(ripple ? 0 : 1)
                                    
                                    Image(systemName: "plus")
                                        .font(.system(size: 28, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: fabSize, height: fabSize)
                                        .background(
                                            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        )
                                        .clipShape(Circle())
                                        .shadow(color: .blue.opacity(0.4), radius: 8, x: 0, y: 4)
                                }
                            }
                            .padding(.trailing, 30)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) { ripple.toggle() }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }
                
                // 同步遮罩
                if resourceManager.isSyncing {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text(resourceManager.syncMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showAddSourceView) {
                AddSourceView(isFirstTimeSetup: true, onComplete: { self.hasCompletedInitialSetup = true })
                    .environmentObject(resourceManager)
            }
        }
        .tint(.blue)
        .alert("获取失败", isPresented: $showErrorAlert, actions: { Button("好的", role: .cancel) { } }, message: { Text(errorMessage) })
        .alert("", isPresented: $showAlreadyUpToDateAlert) { Button("好的", role: .cancel) {} } message: { Text("网络连接正常，请点击右下角“+”按钮来选择你喜欢的新闻源。") }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && !hasAttemptedInitialSync {
                hasAttemptedInitialSync = true
                Task { await syncInitialResources(isManual: false) }
            }
        }
        .onChange(of: resourceManager.showAlreadyUpToDateAlert) { _, newValue in
            if newValue { self.showAlreadyUpToDateAlert = true; resourceManager.showAlreadyUpToDateAlert = false }
        }
    }

    // 【修改】: 增加 isManual 参数以区分调用来源
    private func syncInitialResources(isManual: Bool = false) async {
        do { try await resourceManager.checkAndDownloadAllNewsManifests(isManual: isManual) }
        catch { self.errorMessage = "同步失败，请重试。"; self.showErrorAlert = true }
    }
}
