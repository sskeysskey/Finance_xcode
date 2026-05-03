import SwiftUI

// FloatingWord 结构体保持不变
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
    
    // 【修改】追踪初始同步是否已尝试过（防止 scenePhase 重复触发）
    @State private var hasAttemptedInitialSync = false
    // 【新增】追踪是否已成功同步过（用于判断是否需要重试 / "+"按钮是否需要先同步）
    @State private var hasSyncedSuccessfully = false
    
    private let fabSize: CGFloat = 60
    
    // 【新增】检查本地是否已有新闻数据文件
    private var hasLocalNewsData: Bool {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
    }
    
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
                    Text(Localized.appName)
                        .font(.system(size: 60, weight: .black, design: .rounded))
                        .foregroundColor(.blue)
                        .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                    
                    Text(Localized.appSlogan)
                        .font(.title2.bold())
                        .foregroundColor(.primary.opacity(0.8))
                        .padding(.top, 10)
                    
                    Spacer()
                    
                    Text(Localized.welcomeInstruction)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 140)
                }
                
                // 底部按钮层 (Action Area)
                if !showAddSourceView {
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            // 刷新按钮 (左下角) — 仅在不同步时显示
                            if !resourceManager.isSyncing {
                                Button(action: { Task { await syncInitialResources(isManual: true) } }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, height: 50)
                                        .background(Material.thinMaterial)
                                        .clipShape(Circle())
                                }
                                .padding(.leading, 30)
                            }
                            
                            Spacer()
                            
                            // 【核心修改】"+" 添加按钮 (右下角主操作)
                            // 点击时：如果没有本地数据，先同步；成功后再跳转
                            Button(action: {
                                guard !resourceManager.isSyncing else { return }
                                Task {
                                    // 如果本地没有新闻数据，需要先同步
                                    if !hasSyncedSuccessfully && !hasLocalNewsData {
                                        do {
                                            try await resourceManager.checkAndDownloadAllNewsManifests(isManual: true)
                                            hasSyncedSuccessfully = true
                                            // 防止 "已是最新" 弹窗干扰跳转
                                            resourceManager.showAlreadyUpToDateAlert = false
                                            showAlreadyUpToDateAlert = false
                                            showAddSourceView = true
                                        } catch {
                                            errorMessage = Localized.syncFailed
                                            showErrorAlert = true
                                        }
                                    } else {
                                        // 已有本地数据或已同步成功，直接跳转
                                        showAddSourceView = true
                                    }
                                }
                            }) {
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
                            .disabled(resourceManager.isSyncing) // 同步过程中禁用按钮
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
                AddSourceView(isFirstTimeSetup: true, onComplete: { 
                    // 【新增】在标记完成的同时，记录"是否在审核模式下完成设置"
                    UserDefaults.standard.set(
                        resourceManager.serverReviewMode, 
                        forKey: "setupCompletedDuringReviewMode"
                    )
                    self.hasCompletedInitialSetup = true 
                })
                .environmentObject(resourceManager)
            }
        }
        .tint(.blue)
        // 使用字典替换 Alert 文本
        .alert(Localized.fetchFailed, isPresented: $showErrorAlert, actions: {
            Button(Localized.ok, role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
        .alert("", isPresented: $showAlreadyUpToDateAlert) {
            Button(Localized.ok, role: .cancel) {}
        } message: {
            Text(Localized.upToDateMessage)
        }
        // 【修改】scenePhase 监听：首次 active 时发起自动同步（含重试）
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active && !hasSyncedSuccessfully && !resourceManager.isSyncing {
                if !hasAttemptedInitialSync {
                    // 首次进入前台：启动带重试的自动同步
                    hasAttemptedInitialSync = true
                    Task { await autoSyncWithRetries() }
                } else {
                    // 非首次进入前台（例如用户从设置界面切回来）：再试一次
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !hasSyncedSuccessfully && !resourceManager.isSyncing else { return }
                        await syncInitialResources(isManual: false)
                    }
                }
            }
        }
        // 【新增】监听网络可用性变化：当网络从不可用变为可用时，自动重试同步
        // 这完美覆盖了"用户在网络授权弹窗里点击允许后"的场景
        .onChange(of: resourceManager.isNetworkAvailable) { isAvailable in
            if isAvailable && !hasSyncedSuccessfully && !resourceManager.isSyncing {
                Task {
                    // 短暂延迟，给系统一点时间让网络完全就绪
                    try? await Task.sleep(for: .seconds(1))
                    guard !hasSyncedSuccessfully && !resourceManager.isSyncing else { return }
                    print("WelcomeView: 检测到网络恢复，自动重试同步...")
                    await syncInitialResources(isManual: false)
                }
            }
        }
        .onChange(of: resourceManager.showAlreadyUpToDateAlert) { newValue in
            if newValue {
                // 仅在没有正在跳转到添加源页面时才显示弹窗
                if !showAddSourceView {
                    self.showAlreadyUpToDateAlert = true
                }
                resourceManager.showAlreadyUpToDateAlert = false
            }
        }
    }

    // 【新增】带有限次数重试的自动同步
    // 首次安装时，第一次请求可能因网络权限弹窗而失败，
    // 通过延时重试（3秒后、再8秒后）覆盖用户点击"允许"后的窗口期
    private func autoSyncWithRetries() async {
        let retryDelays: [UInt64] = [0, 3, 8] // 第一次立即尝试，第二次3秒后，第三次8秒后
        
        for (index, delay) in retryDelays.enumerated() {
            guard !hasSyncedSuccessfully else { return }
            
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                // 睡醒后再次检查，避免重复发起
                guard !hasSyncedSuccessfully && !resourceManager.isSyncing else { return }
            }
            
            print("WelcomeView: 自动同步尝试 #\(index + 1)")
            await syncInitialResources(isManual: false)
        }
        
        if !hasSyncedSuccessfully {
            print("WelcomeView: 自动同步多次尝试后仍未成功，等待用户手动操作或网络变化触发。")
        }
    }

    // 【修改】同步方法：自动同步失败时不弹错误提示
    private func syncInitialResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadAllNewsManifests(isManual: isManual)
            hasSyncedSuccessfully = true
        } catch {
            if isManual {
                // 手动同步失败：向用户展示错误
                self.errorMessage = Localized.syncFailed
                self.showErrorAlert = true
            }
            // 自动同步失败：静默忽略，由重试机制和网络监听器处理
        }
    }
}