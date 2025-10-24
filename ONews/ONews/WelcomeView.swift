import SwiftUI

struct WelcomeView: View {
    // 【修改 1/2】: 彻底移除旧的 onComplete 闭包属性
    // var onComplete: () -> Void  <-- 删除这一行

    // 【保留】: 这个 Binding 是与 MainAppView 连接的唯一桥梁
    @Binding var hasCompletedInitialSetup: Bool
    
    // 从环境中接收共享的 ResourceManager，不再自己创建
    @EnvironmentObject var resourceManager: ResourceManager

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    @State private var showAddSourceView = false
    @State private var ripple = false

    // 新增：统一尺寸参数
    private let fabSize: CGFloat = 56     // 圆形按钮直径
    private let fabIconSize: CGFloat = 24 // 图标字号
    private let fabPadding: CGFloat = 20  // 距离安全区边距

    var body: some View {
        ZStack {
            NavigationStack {
                ZStack {
                    Image("welcome_background")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(Color.black.opacity(0.4))

                    VStack {
                        Spacer()
                            .frame(height: 80)

                        Text("欢迎来到 ONews")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.bottom, 20)

                        Text("点击右下方按钮\n开始添加您感兴趣的新闻源")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))

                        Spacer()
                    }
                }
                .navigationBarHidden(true)
                .navigationDestination(isPresented: $showAddSourceView) {
                    // 【修改 2/2】: 为 AddSourceView 创建一个新的 onComplete 闭包。
                    // 当 AddSourceView 调用这个闭包时，我们修改从 MainAppView 传来的 Binding。
                    // 这样做是安全的，因为它是在 View 的 body 内部定义的。
                    AddSourceView(isFirstTimeSetup: true, onComplete: {
                        self.hasCompletedInitialSetup = true
                    })
                    .environmentObject(resourceManager)
                }
            }
            .tint(.white)
            .onAppear {
                Task { await syncInitialResources() }
            }
            .alert("", isPresented: $showErrorAlert, actions: {
                Button("好的", role: .cancel) { }
            }, message: {
                Text(errorMessage)
            })

            // 左下角刷新按钮（同尺寸）
            if !resourceManager.isSyncing && !showAddSourceView {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: {
                            Task { await syncInitialResources() }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: fabIconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: fabSize, height: fabSize)
                                .background(Color.black.opacity(0.3))
                                .clipShape(Circle())
                                .shadow(radius: 10)
                        }
                        .padding(.leading, fabPadding)
                        .padding(.bottom, fabPadding)
                        Spacer()
                    }
                }
            }

            // 右下角添加按钮 + 光韵动画（去除未使用的 radius 变量）
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
                                    .stroke(Color.white.opacity(ripple ? 0 : 0.8), lineWidth: 2)
                                    .frame(width: fabSize, height: fabSize)
                                    .scaleEffect(ripple ? 1.4 : 1.0)
                                    .opacity(ripple ? 0 : 1)

                                Image(systemName: "plus")
                                    .font(.system(size: fabIconSize, weight: .light))
                                    .foregroundColor(.white)
                                    .frame(width: fabSize, height: fabSize)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .shadow(radius: 10)
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
                .background(Color.black.opacity(0.7))
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle())
            }
        }
    }

    private func syncInitialResources() async {
        do {
            try await resourceManager.checkAndDownloadAllNewsManifests()
        } catch {
            self.errorMessage = "下载新闻源失败\n请点击左下角刷新↻按钮。"
            self.showErrorAlert = true
            print("WelcomeView 同步失败: \(error)")
        }
    }
}
