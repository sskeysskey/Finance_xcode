import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext

    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager

    @StateObject private var audioPlayerManager = AudioPlayerManager()

    @State private var currentArticle: Article
    @State private var currentSourceName: String

    @State private var unreadCountForGroup: Int = 0
    @State private var totalUnreadCountForContext: Int = 0

    @State private var showNoNextToast = false
    @State private var isMiniPlayerCollapsed = false

    @State private var didCommitOnDisappear = false
    
    // 【修改】更新图片下载状态变量以支持详细进度
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel, resourceManager: ResourceManager) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        self.resourceManager = resourceManager
        
        self._currentArticle = State(initialValue: article)
        self._currentSourceName = State(initialValue: sourceName)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ArticleDetailView(
                article: currentArticle,
                sourceName: currentSourceName,
                unreadCountForGroup: unreadCountForGroup,
                totalUnreadCount: totalUnreadCountForContext,
                viewModel: viewModel,
                audioPlayerManager: audioPlayerManager,
                requestNextArticle: {
                    Task {
                        await self.switchToNextArticleAndStopAudio()
                    }
                }
            )
            .id(currentArticle.id)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
            )
            
            if showNoNextToast {
                ToastView(message: "该分组内已无更多文章")
            }
            
            if audioPlayerManager.isPlaybackActive {
                if isMiniPlayerCollapsed {
                    MiniAudioBubbleView(
                        isCollapsed: $isMiniPlayerCollapsed,
                        isPlaying: audioPlayerManager.isPlaying
                    )
                    .padding(.bottom, 10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
                } else {
                    AudioPlayerView(
                        playerManager: audioPlayerManager,
                        playNextAndStart: {
                            Task {
                                await switchToNextArticle(shouldAutoplayNext: true)
                            }
                        },
                        toggleCollapse: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                                isMiniPlayerCollapsed = true
                            }
                        }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            
            // 【修改】更新图片下载遮罩层UI以显示详细进度
            if isDownloadingImages {
                VStack(spacing: 12) {
                    Text("正在加载图片...")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .white))
                        .padding(.horizontal, 40)
                    
                    Text(downloadProgressText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.75))
                .edgesIgnoringSafeArea(.all)
                .zIndex(3)
            }
        }
        .onAppear {
            didCommitOnDisappear = false
            updateUnreadCounts()
            
            Task {
                await preDownloadNextArticleImages()
            }
            
            audioPlayerManager.onNextRequested = {
                Task {
                    await self.switchToNextArticle(shouldAutoplayNext: true)
                }
            }
            audioPlayerManager.onPlaybackFinished = { }
        }
        .onDisappear {
            guard !didCommitOnDisappear else { return }
            didCommitOnDisappear = true
            
            audioPlayerManager.stop()
            _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
            viewModel.commitPendingReads()
        }
        .onChange(of: currentArticle) { _, newArticle in
            updateUnreadCounts()
            Task {
                await preDownloadNextArticleImages()
            }
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }

    private func updateUnreadCounts() {
        let sourceNameToUse: String?
        switch navigationContext {
        case .fromSource(let name):
            sourceNameToUse = name
        case .fromAllArticles:
            sourceNameToUse = nil
        }

        self.unreadCountForGroup = viewModel.getUnreadCountForDateGroup(
            timestamp: currentArticle.timestamp,
            inSource: sourceNameToUse
        )
        self.totalUnreadCountForContext = viewModel.getEffectiveUnreadCount(
            inSource: sourceNameToUse
        )
    }

    private func switchToNextArticleAndStopAudio() async {
        audioPlayerManager.stop()
        await switchToNextArticle(shouldAutoplayNext: false)
    }

    private func switchToNextArticle(shouldAutoplayNext: Bool) async {
        if shouldAutoplayNext {
            audioPlayerManager.prepareForNextTransition()
        }
        
        _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
        
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }
        
        guard let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) else {
            await MainActor.run {
                showToast { shouldShow in self.showNoNextToast = shouldShow }
                audioPlayerManager.stop()
            }
            return
        }
        
        if !next.article.images.isEmpty {
            let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
                timestamp: next.article.timestamp,
                imageNames: next.article.images
            )
            
            if !imagesAlreadyExist {
                // 1. 设置下载状态的初始值
                await MainActor.run {
                    isDownloadingImages = true
                    downloadProgress = 0.0
                    downloadProgressText = "准备中..."
                }
                
                do {
                    // 2. 【核心修正】调用新的下载方法，并传入一个闭包来处理进度更新
                    try await resourceManager.downloadImagesForArticle(
                        timestamp: next.article.timestamp,
                        imageNames: next.article.images,
                        progressHandler: { current, total in
                            // 这个闭包会在 MainActor 上被调用，可以直接更新UI状态
                            self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                            self.downloadProgressText = "已下载 \(current) / \(total)"
                        }
                    )
                } catch {
                    await MainActor.run {
                        isDownloadingImages = false
                        errorMessage = "图片下载失败: \(error.localizedDescription)"
                        showErrorAlert = true
                        audioPlayerManager.stop()
                    }
                    return // 下载失败，中断切换
                }
                
                // 3. 下载成功后，隐藏遮罩
                await MainActor.run {
                    isDownloadingImages = false
                }
            }
        }
        
        // 切换文章的动画
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentArticle = next.article
                self.currentSourceName = next.sourceName
            }
        }
        
        if shouldAutoplayNext {
            await MainActor.run {
                let paragraphs = next.article.article
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let fullText = paragraphs.joined(separator: "\n\n")
                self.audioPlayerManager.startPlayback(text: fullText, title: next.article.topic)
            }
        }
    }
    
    private func preDownloadNextArticleImages() async {
        print("开始检查并预下载下一篇文章的图片...")
        
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }
        
        guard let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) else {
            print("没有找到下一篇未读文章，无需预下载。")
            return
        }
        
        guard !next.article.images.isEmpty else {
            print("下一篇文章 '\(next.article.topic)' 没有图片，无需预下载。")
            return
        }
        
        do {
            try await resourceManager.preDownloadImagesForArticleSilently(
                timestamp: next.article.timestamp,
                imageNames: next.article.images
            )
        } catch {
            print("静默预下载下一篇文章的图片失败: \(error.localizedDescription)")
        }
    }

    private func showToast(setter: @escaping (Bool) -> Void) {
        setter(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                setter(false)
            }
        }
    }

    struct ToastView: View {
        let message: String
        
        var body: some View {
            Text(message)
                .font(.subheadline)
                .padding()
                .background(Color.black.opacity(0.75))
                .foregroundColor(.white)
                .cornerRadius(10)
                .padding(.bottom, 50)
                .transition(.opacity.animation(.easeInOut))
        }
    }
}
