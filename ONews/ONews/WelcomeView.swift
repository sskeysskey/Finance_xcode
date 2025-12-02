import SwiftUI

struct WelcomeView: View {
    // 【保留】: 这两个属性保持不变
    @Binding var hasCompletedInitialSetup: Bool
    @EnvironmentObject var resourceManager: ResourceManager

    // 【保留】: 状态变量保持不变
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showAddSourceView = false
    @State private var ripple = false
    
    // 【新增】: 用于控制“已是最新”弹窗的本地状态
    @State private var showAlreadyUpToDateAlert = false

    // 【保留】: 引入 scenePhase 来监控 App 的生命周期状态
    @Environment(\.scenePhase) private var scenePhase
    
    // 【保留】: 一个状态标志，确保初始同步只执行一次
    @State private var hasAttemptedInitialSync = false

    // 【保留】: 尺寸参数保持不变
    private let fabSize: CGFloat = 56
    private let fabIconSize: CGFloat = 24
    private let fabPadding: CGFloat = 20

    var body: some View {
        ZStack {
            NavigationStack {
                ZStack {
                    // 【修改】移除背景图片，使用自适应背景色
                    Color.viewBackground
                        .ignoresSafeArea()

                    VStack {
                        Spacer()
                            .frame(height: 80)

                        Text("欢迎来到 ONews")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            // 【修改】使用系统主色（黑/白自动切换）
                            .foregroundColor(.primary)
                            .padding(.bottom, 20)

                        Text("点击右下方按钮\n开始添加您感兴趣的新闻源")
                            .font(.headline)
                            // 【修改】使用次级颜色
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Spacer()
                    }
                }
                // 移除 navigationBarHidden(true) 有时能解决布局问题，但在欢迎页隐藏通常没问题
                // 如果需要显示标题栏颜色，可以移除 .navigationBarHidden(true)
                .navigationDestination(isPresented: $showAddSourceView) {
                    AddSourceView(isFirstTimeSetup: true, onComplete: {
                        self.hasCompletedInitialSetup = true
                    })
                    .environmentObject(resourceManager)
                }
            }
            // 【修改】移除 .tint(.white)，使用默认蓝色或自定义主题色
            .tint(.blue)
            .alert("获取失败", isPresented: $showErrorAlert, actions: {
                Button("好的", role: .cancel) { }
            }, message: {
                Text(errorMessage)
            })
            // 【新增】: 用于显示“已是最新”的弹窗
            .alert("", isPresented: $showAlreadyUpToDateAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("网络连接正常，请点击右下角“+”按钮来选择你喜欢的新闻源。")
            }
            // 【修改】: 使用 onChange 监听 scenePhase 的变化
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active && !hasAttemptedInitialSync {
                    print("App is now active, attempting initial resource sync.")
                    hasAttemptedInitialSync = true
                    Task {
                        // 自动同步，isManual为false
                        await syncInitialResources(isManual: false)
                    }
                }
            }
            // 【新增】: 监听来自 ResourceManager 的弹窗信号
            .onChange(of: resourceManager.showAlreadyUpToDateAlert) { _, newValue in
                if newValue {
                    self.showAlreadyUpToDateAlert = true
                    // 重置信号，以便下次可以再次触发
                    resourceManager.showAlreadyUpToDateAlert = false
                }
            }

            // 左下角刷新按钮
            if !resourceManager.isSyncing && !showAddSourceView {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: {
                            // 手动同步，isManual为true
                            Task { await syncInitialResources(isManual: true) }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: fabIconSize, weight: .regular))
                                .foregroundColor(.white) // 按钮图标保持白色
                                .frame(width: fabSize, height: fabSize)
                                .background(Color.blue) // 改为蓝色背景，更符合系统风格
                                .clipShape(Circle())
                                .shadow(radius: 5)
                        }
                        .padding(.leading, fabPadding)
                        .padding(.bottom, fabPadding)
                        Spacer()
                    }
                }
            }

            // 右下角添加按钮 + 光韵动画（逻辑不变）
            if !showAddSourceView {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: {
                            showAddSourceView = true
                        }) {
                            ZStack {
                                Circle()
                                    .stroke(Color.blue.opacity(ripple ? 0 : 0.8), lineWidth: 2)
                                    .frame(width: fabSize, height: fabSize)
                                    .scaleEffect(ripple ? 1.4 : 1.0)
                                    .opacity(ripple ? 0 : 1)

                                Image(systemName: "plus")
                                    .font(.system(size: fabIconSize, weight: .light))
                                    .foregroundColor(.white)
                                    .frame(width: fabSize, height: fabSize)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .shadow(radius: 5)
                            }
                        }
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                                ripple.toggle()
                            }
                        }
                        .padding(.trailing, fabPadding)
                        .padding(.bottom, fabPadding)
                    }
                }
            }

            // 同步遮罩
            if resourceManager.isSyncing {
                VStack(spacing: 15) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)

                    Text(resourceManager.syncMessage)
                        .padding(.top, 10)
                        .foregroundColor(.white)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 遮罩层保持半透明黑色，以突显加载状态
                .background(Color.black.opacity(0.6))
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
            }
        }
    }

    // 【修改】: 增加 isManual 参数以区分调用来源
    private func syncInitialResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadAllNewsManifests(isManual: isManual)
        } catch {
            self.errorMessage = "下载新闻源失败\n请检查网络连接后，点击左下角刷新↻按钮重试。"
            self.showErrorAlert = true
            print("WelcomeView 同步失败: \(error)")
        }
    }
}
