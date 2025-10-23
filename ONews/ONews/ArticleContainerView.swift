// ArticleContainerView.swift

import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext

    @ObservedObject var viewModel: NewsViewModel

    @StateObject private var audioPlayerManager = AudioPlayerManager()

    @State private var currentArticle: Article
    @State private var currentSourceName: String

    @State private var unreadCountForGroup: Int = 0
    @State private var totalUnreadCountForContext: Int = 0

    @State private var showNoNextToast = false
    @State private var isMiniPlayerCollapsed = false

    @State private var didCommitOnDisappear = false
    
    // 新增:图片下载状态
    @State private var isDownloadingImages = false
    @State private var downloadingMessage = ""
    
    // 新增:错误提示
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        
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
        .onChange(of: currentArticle) { _, _ in
            updateUnreadCounts()
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
        
        // 新增:如果下一篇文章有图片,先下载
        if !next.article.images.isEmpty {
            await MainActor.run {
                isDownloadingImages = true
                downloadingMessage = "正在加载图片..."
            }
            
            do {
                // 获取 ResourceManager 实例
                let resourceManager = ResourceManager()
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
