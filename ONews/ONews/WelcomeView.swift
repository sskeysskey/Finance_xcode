import SwiftUI

// FloatingWord 结构体保持不变
struct FloatingWord: Identifiable {
    let id = UUID()
    let text: String
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    let color: Color
    let speed: CGFloat
    let angle: Double
}

struct FloatingWordsView: View {
    @EnvironmentObject var resourceManager: ResourceManager
    @State private var words: [FloatingWord] = []
    @State private var sourceNames: [String] = []
    @State private var isActive = false

    private let colors: [Color] = [.blue, .purple, .pink, .orange, .mint, .teal, .indigo, .red]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        for word in words {
                            let scale = 0.2 + (word.z * 2.5)
                            let perspectiveFactor = word.z * 300
                            let drawX = (size.width / 2) + (CGFloat(cos(word.angle)) * perspectiveFactor * word.x)
                            let drawY = (size.height / 2) + (CGFloat(sin(word.angle)) * perspectiveFactor * word.y)

                            let opacity: Double
                            if word.z < 0.2 { opacity = word.z * 5 }
                            else if word.z > 0.8 { opacity = 1.0 - ((word.z - 0.8) * 5) }
                            else { opacity = 1.0 }

                            if opacity > 0.01 {
                                var resolvedText = context.resolve(Text(word.text).fontWeight(.bold))
                                resolvedText.shading = .color(word.color)
                                context.opacity = opacity
                                context.draw(resolvedText, at: CGPoint(x: drawX, y: drawY), anchor: .center)
                                context.transform = .init(scaleX: scale, y: scale)
                            }
                        }
                    }
                }
            }
            .onAppear { isActive = true; startAnimationLoop() }
            .onDisappear { isActive = false }
            .task {
                let names = await resourceManager.fetchSourceNames()
                await MainActor.run { self.sourceNames = names }
            }
        }
        .allowsHitTesting(false)
    }

    private func startAnimationLoop() {
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            guard isActive else { timer.invalidate(); return }
            updateParticles()
        }
    }

    private func updateParticles() {
        var newWords: [FloatingWord] = []
        for var word in words {
            word.z += word.speed
            if word.z < 1.0 { newWords.append(word) }
        }
        if newWords.count < 12 && !sourceNames.isEmpty {
            if Double.random(in: 0...1) > 0.95 {
                let randomText = sourceNames.randomElement() ?? "ONews"
                let randomColor = colors.randomElement() ?? .blue
                let randomAngle = Double.random(in: 0...(2 * .pi))
                newWords.append(FloatingWord(
                    text: randomText,
                    x: CGFloat.random(in: 0.5...1.5),
                    y: CGFloat.random(in: 0.5...1.5),
                    z: 0.0,
                    color: randomColor,
                    speed: CGFloat.random(in: 0.002...0.006),
                    angle: randomAngle
                ))
            }
        }
        self.words = newWords
    }
}

// MARK: - 【新增】非审核模式：整齐排列的内容展示墙
struct SourceShowcaseView: View {
    @EnvironmentObject var resourceManager: ResourceManager
    @AppStorage("isGlobalEnglishMode") private var isEnglish = false

    @State private var newsRaw: [String] = []
    @State private var videoRaw: [String] = []
    @State private var appeared = false

    private let newsColors: [Color] = [.blue, .indigo, .teal, .cyan, .purple]
    private let videoColors: [Color] = [.pink, .orange, .red, .purple]

    private func display(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "|")
        if isEnglish, parts.count > 1 {
            let en = parts[1].trimmingCharacters(in: .whitespaces)
            if !en.isEmpty { return en }
        }
        return parts.first?.trimmingCharacters(in: .whitespaces) ?? raw
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                if !videoRaw.isEmpty {
                    section(
                        icon: "play.rectangle.fill",
                        tint: .pink,
                        title: isEnglish ? "Video Channels" : "影视频道",
                        subtitle: isEnglish ? "Movies · Drama · Variety · Anime" : "电影 · 美剧 · 韩剧 · 综艺 · 动漫",
                        items: videoRaw,
                        palette: videoColors
                    )
                }
                if !newsRaw.isEmpty {
                    section(
                        icon: "newspaper.fill",
                        tint: .blue,
                        title: isEnglish ? "Global Newsrooms" : "全球一线新闻源",
                        subtitle: isEnglish ? "Bilingual · Original photos" : "中英双语 · 原版配图",
                        items: newsRaw,
                        palette: newsColors
                    )
                }
                if newsRaw.isEmpty && videoRaw.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isEnglish ? "Loading channels…" : "正在获取内容清单…")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.easeOut(duration: 0.45), value: appeared)
        }
        .task {
            let r = await resourceManager.fetchShowcaseMappings()
            await MainActor.run {
                self.newsRaw = r.news
                self.videoRaw = r.video
                self.appeared = true
            }
        }
    }

    private func section(icon: String, tint: Color, title: String, subtitle: String,
                         items: [String], palette: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .heavy)).foregroundColor(.primary)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(tint)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.12)))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, raw in
                    let c = palette[idx % palette.count]
                    Text(display(raw))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.cardBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(c.opacity(0.35), lineWidth: 1)
                        )
                        .overlay(alignment: .leading) {
                            Rectangle().fill(c).frame(width: 3)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground).opacity(0.6))
        )
    }
}

struct WelcomeView: View {
    @Binding var hasCompletedInitialSetup: Bool
    @EnvironmentObject var resourceManager: ResourceManager

    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showAddSourceView = false
    @State private var ripple = false
    @State private var showAlreadyUpToDateAlert = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var hasAttemptedInitialSync = false
    @State private var hasSyncedSuccessfully = false

    private let fabSize: CGFloat = 60

    private var hasLocalNewsData: Bool {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.viewBackground.ignoresSafeArea()

                // 【核心改动】审核模式 → 字串飞屏；正式模式 → 整齐展示墙
                VStack(spacing: 0) {
                    Spacer().frame(height: 32)

                    Text(Localized.welcomeInstruction)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    if resourceManager.serverReviewMode {
                        FloatingWordsView()
                            .environmentObject(resourceManager)
                            .frame(height: 380)
                            .mask(LinearGradient(gradient: Gradient(colors: [.clear, .black, .black, .clear]),
                                                 startPoint: .top, endPoint: .bottom))
                        Spacer()
                    } else {
                        SourceShowcaseView()
                            .environmentObject(resourceManager)
                            .padding(.top, 4)
                        Spacer(minLength: 32)
                    }
                }

                // 底部按钮层
                if !showAddSourceView {
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
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

                            Button(action: {
                                guard !resourceManager.isSyncing else { return }
                                Task {
                                    if !hasSyncedSuccessfully && !hasLocalNewsData {
                                        do {
                                            try await resourceManager.checkAndDownloadAllNewsManifests(isManual: true)
                                            hasSyncedSuccessfully = true
                                            resourceManager.showAlreadyUpToDateAlert = false
                                            showAlreadyUpToDateAlert = false
                                            showAddSourceView = true
                                        } catch {
                                            errorMessage = Localized.syncFailed
                                            showErrorAlert = true
                                        }
                                    } else {
                                        showAddSourceView = true
                                    }
                                }
                            }) {
                                ZStack {
                                    Circle()
                                        .stroke(Color.blue.opacity(ripple ? 0 : 0.5), lineWidth: 2)
                                        .frame(width: fabSize, height: fabSize)
                                        .scaleEffect(ripple ? 1.5 : 1.0)
                                        .opacity(ripple ? 0 : 1)

                                    Image(systemName: "plus")
                                        .font(.system(size: 28, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: fabSize, height: fabSize)
                                        .background(LinearGradient(colors: [.blue, .purple],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .clipShape(Circle())
                                        .shadow(color: .blue.opacity(0.4), radius: 8, x: 0, y: 4)
                                }
                            }
                            .disabled(resourceManager.isSyncing)
                            .padding(.trailing, 30)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) { ripple.toggle() }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }

                if resourceManager.isSyncing {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text(resourceManager.syncMessage)
                                .font(.headline).foregroundColor(.white)
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showAddSourceView) {
                AddSourceView(isFirstTimeSetup: true, onComplete: {
                    UserDefaults.standard.set(resourceManager.serverReviewMode,
                                              forKey: "setupCompletedDuringReviewMode")
                    self.hasCompletedInitialSetup = true
                })
                .environmentObject(resourceManager)
            }
        }
        .tint(.blue)
        .alert(Localized.fetchFailed, isPresented: $showErrorAlert, actions: {
            Button(Localized.ok, role: .cancel) { }
        }, message: { Text(errorMessage) })
        .alert("", isPresented: $showAlreadyUpToDateAlert) {
            Button(Localized.ok, role: .cancel) {}
        } message: { Text(Localized.upToDateMessage) }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active && !hasSyncedSuccessfully && !resourceManager.isSyncing {
                if !hasAttemptedInitialSync {
                    hasAttemptedInitialSync = true
                    Task { await autoSyncWithRetries() }
                } else {
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !hasSyncedSuccessfully && !resourceManager.isSyncing else { return }
                        await syncInitialResources(isManual: false)
                    }
                }
            }
        }
        .onChange(of: resourceManager.isNetworkAvailable) { isAvailable in
            if isAvailable && !hasSyncedSuccessfully && !resourceManager.isSyncing {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !hasSyncedSuccessfully && !resourceManager.isSyncing else { return }
                    await syncInitialResources(isManual: false)
                }
            }
        }
        .onChange(of: resourceManager.showAlreadyUpToDateAlert) { newValue in
            if newValue {
                if !showAddSourceView { self.showAlreadyUpToDateAlert = true }
                resourceManager.showAlreadyUpToDateAlert = false
            }
        }
    }

    private func autoSyncWithRetries() async {
        let retryDelays: [UInt64] = [0, 3, 8]
        for (index, delay) in retryDelays.enumerated() {
            guard !hasSyncedSuccessfully else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !hasSyncedSuccessfully && !resourceManager.isSyncing else { return }
            }
            print("WelcomeView: 自动同步尝试 #\(index + 1)")
            await syncInitialResources(isManual: false)
        }
        if !hasSyncedSuccessfully {
            print("WelcomeView: 自动同步多次尝试后仍未成功。")
        }
    }

    private func syncInitialResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadAllNewsManifests(isManual: isManual)
            hasSyncedSuccessfully = true
        } catch {
            if isManual {
                self.errorMessage = Localized.syncFailed
                self.showErrorAlert = true
            }
        }
    }
}