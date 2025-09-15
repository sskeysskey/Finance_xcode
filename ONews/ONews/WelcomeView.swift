import SwiftUI

struct WelcomeView: View {
var onComplete: () -> Void

@StateObject private var resourceManager = ResourceManager()
@State private var showErrorAlert = false
@State private var errorMessage = ""

@State private var showAddSourceView = false
@State private var ripple = false

var body: some View {
    ZStack {
        // 用 NavigationStack 取代 NavigationView
        NavigationStack {
            ZStack {
                Image("welcome_background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .edgesIgnoringSafeArea(.all)
                    .overlay(Color.black.opacity(0.4))

                VStack {
                    Spacer()
                    
                    Text("欢迎使用 ONews")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.bottom, 20)

                    Text("点击下方按钮，开始添加您感兴趣的新闻源")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()
                    
                    VStack(spacing: 8) {
                        Text("点击这里开始")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(8)
                        
                        Image(systemName: "arrow.down")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .offset(y: -20)
                    
                    Button(action: {
                        showAddSourceView = true
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(ripple ? 0 : 0.8), lineWidth: 2)
                                .scaleEffect(ripple ? 1.8 : 1.0)
                                .opacity(ripple ? 0 : 1)
                            
                            Image(systemName: "plus")
                                .font(.system(size: 44, weight: .light))
                                .foregroundColor(.white)
                                .padding(30)
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
                    .padding(.bottom, 60)
                }
            }
            .navigationBarHidden(true)
            // 新导航目的地：基于布尔值的呈现
            .navigationDestination(isPresented: $showAddSourceView) {
                AddSourceView(isFirstTimeSetup: true, onComplete: onComplete)
            }
        }
        .tint(.white) // iOS 15+ 推荐用 tint 代替 accentColor
        .onAppear {
            Task { await syncInitialResources() }
        }
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })

        if !resourceManager.isSyncing && !showAddSourceView {
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        Task { await syncInitialResources() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                    }
                    .padding(.top, 50)
                    .padding(.trailing, 20)
                }
                Spacer()
            }
        }

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
        try await resourceManager.checkAndDownloadLatestNewsManifest()
    } catch {
        self.errorMessage = "下载新闻数据失败，请点击右上角刷新↻按钮。"
        self.showErrorAlert = true
        print("WelcomeView 同步失败: \(error)")
    }
}
}
