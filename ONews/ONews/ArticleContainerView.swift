// ArticleContainerView.swift

import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext

    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager // 新增: 引入 ResourceManager

    @StateObject private var audioPlayerManager = AudioPlayerManager()

    @State private var currentArticle: Article
    @State private var currentSourceName: String

    @State private var unreadCountForGroup: Int = 0
    @State private var totalUnreadCountForContext: Int = 0

    @State private var showNoNextToast = false
    @State private var isMiniPlayerCollapsed = false

    @State private var didCommitOnDisappear = false
    
    // 图片下载状态
    @State private var isDownloadingImages = false
    @State private var downloadingMessage = ""
    
    // 错误提示
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    // 修改: 更新 init 方法
    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel, resourceManager: ResourceManager) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        self.resourceManager = resourceManager // 新增
        
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
            
            // 图片下载遮罩层
            if isDownloadingImages {
                VStack(spacing: 15) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    
                    Text(downloadingMessage)
                        .padding(.top, 10)
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.6))
                .edgesIgnoringSafeArea(.all)
                .zIndex(3)
            }
        }
        .onAppear {
            didCommitOnDisappear = false
            updateUnreadCounts()
            
            // 新增: 启动静默预下载任务
            Task {
                await preDownloadNextArticleImages()
            }
            
            audioPlayerManager.onNextRequested = {
                Task {
                    await self.switchToNextArticle(shouldAutoplayNext: true)
                }
            }
            audioPlayerManager.onPlaybackFinished = {
                // 行为已在 AudioPlayerManager 内部处理
            }
        }
        .onDisappear {
            guard !didCommitOnDisappear else { return }
            didCommitOnDisappear = true
            
            audioPlayerManager.stop()
            _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
            viewModel.commitPendingReads()
        }
        .onChange(of: currentArticle) { _, newArticle in // 修改: 监听文章变化，预载下一篇
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
        
        // 如果下一篇文章有图片,先下载 (这个逻辑保持不变，作为预下载失败的后备方案)
        if !next.article.images.isEmpty {
            await MainActor.run {
                isDownloadingImages = true
                downloadingMessage = "正在加载图片..."
            }
            
            do {
                // 这个调用现在会很快完成（如果预下载成功）
                try await resourceManager.downloadImagesForArticle(
                    timestamp: next.article.timestamp,
                    imageNames: next.article.images
                )
            } catch {
                await MainActor.run {
                    isDownloadingImages = false
                    errorMessage = "图片下载失败: \(error.localizedDescription)"
                    showErrorAlert = true
                    audioPlayerManager.stop()
                }
                return
            }
            
            await MainActor.run {
                isDownloadingImages = false
            }
        }
        
        // 下载完成后再切换文章
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
    
    // 新增: 静默预下载下一篇文章的图片
    private func preDownloadNextArticleImages() async {
        print("开始检查并预下载下一篇文章的图片...")
        
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }
        
        // 找到下一篇未读文章
        guard let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) else {
            print("没有找到下一篇未读文章，无需预下载。")
            return
        }
        
        // 如果下一篇文章没有图片，则无需操作
        guard !next.article.images.isEmpty else {
            print("下一篇文章 '\(next.article.topic)' 没有图片，无需预下载。")
            return
        }
        
        // 执行静默下载
        do {
            try await resourceManager.preDownloadImagesForArticleSilently(
                timestamp: next.article.timestamp,
                imageNames: next.article.images
            )
        } catch {
            // 静默下载失败时，只在控制台打印错误，不打扰用户
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
