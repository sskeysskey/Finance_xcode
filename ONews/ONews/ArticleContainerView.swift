import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext

    @ObservedObject var viewModel: NewsViewModel

    @StateObject private var audioPlayerManager = AudioPlayerManager()

    @State private var currentArticle: Article
    @State private var currentSourceName: String

    @State private var liveUnreadCount: Int
    @State private var readArticleIDsInThisSession: Set<UUID> = []

    @State private var showNoNextToast = false
    @State private var isMiniPlayerCollapsed = false

    // MARK: - 移除点 1: 删除了未使用的 pendingAutoPlayRequestID 状态
    // @State private var pendingAutoPlayRequestID: UUID?

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    private var initialUnreadCount: Int {
        switch navigationContext {
        case .fromAllArticles:
            return viewModel.totalUnreadCount
        case .fromSource(let sourceName):
            return viewModel.sources.first { $0.name == sourceName }?.unreadCount ?? 0
        }
    }

    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel

        self._currentArticle = State(initialValue: article)
        self._currentSourceName = State(initialValue: sourceName)

        let baseCount: Int
        switch context {
        case .fromAllArticles:
            baseCount = viewModel.totalUnreadCount
        case .fromSource(let name):
            baseCount = viewModel.sources.first { $0.name == name }?.unreadCount ?? 0
        }
        self._liveUnreadCount = State(initialValue: baseCount)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ArticleDetailView(
                article: currentArticle,
                sourceName: currentSourceName,
                unreadCount: liveUnreadCount,
                viewModel: viewModel,
                audioPlayerManager: audioPlayerManager,
                requestNextArticle: {
                    self.switchToNextArticleAndStopAudio()
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
                            switchToNextArticle(shouldAutoplayNext: true)
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
        }
        // MARK: - 移除点 2: 删除了 .onAppear 中的通知注册逻辑
        .onAppear {
            audioPlayerManager.onNextRequested = {
                let shouldAutoplay = audioPlayerManager.isAutoPlayEnabled
                switchToNextArticle(shouldAutoplayNext: shouldAutoplay)
            }
            audioPlayerManager.onPlaybackFinished = {
                // 不在此触发下一篇，避免重复
            }
        }
        // MARK: - 移除点 3: 删除了 .onDisappear 中的通知移除逻辑
        .onDisappear {
            audioPlayerManager.stop()

            if !currentArticle.isRead {
                readArticleIDsInThisSession.insert(currentArticle.id)
            }
            for articleID in readArticleIDsInThisSession {
                viewModel.markAsRead(articleID: articleID)
            }
        }
        .onChange(of: currentArticle.id) { oldValue, _ in
            let oldArticle = viewModel.sources.flatMap { $0.articles }.first { $0.id == oldValue }
            if let oldArticle, !oldArticle.isRead {
                let isNewToSession = !readArticleIDsInThisSession.contains(oldValue)
                if isNewToSession {
                    liveUnreadCount = max(0, liveUnreadCount - 1)
                    readArticleIDsInThisSession.insert(oldValue)
                }
            }
        }
        .background(Color.viewBackground.ignoresSafeArea())
    }

    // MARK: - 移除点 4: 删除了 startAutoPlaybackForCurrentArticle 函数
    
    /// 此函数专门用于处理文章详情页底部的“阅读下一篇”按钮点击事件。
    /// 它会立即、彻底地停止音频播放，并切换到下一篇文章，但不会自动开始播放。
    private func switchToNextArticleAndStopAudio() {
        audioPlayerManager.stop()

        if let currentInVM = viewModel.sources.flatMap({ $0.articles }).first(where: { $0.id == currentArticle.id }) {
            let wasUnread = !currentInVM.isRead
            let isNewToSession = !readArticleIDsInThisSession.contains(currentArticle.id)
            if wasUnread && isNewToSession {
                readArticleIDsInThisSession.insert(currentArticle.id)
                if liveUnreadCount > 0 {
                    liveUnreadCount -= 1
                }
            }
        }

        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) {
            if readArticleIDsInThisSession.contains(next.article.id) {
                showToast { shouldShow in self.showNoNextToast = shouldShow }
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.currentArticle = next.article
                    self.currentSourceName = next.sourceName
                }
            }
        } else {
            showToast { shouldShow in self.showNoNextToast = shouldShow }
        }
    }
    
    /// 此函数保留，专门用于音频播放器触发的“下一篇”操作（包括手动点击和自动连播）。
    /// 它使用 prepareForNextTransition 实现平滑过渡，并根据参数决定是否自动播放。
    private func switchToNextArticle(shouldAutoplayNext: Bool) {
        audioPlayerManager.prepareForNextTransition()

        if let currentInVM = viewModel.sources.flatMap({ $0.articles }).first(where: { $0.id == currentArticle.id }) {
            let wasUnread = !currentInVM.isRead
            let isNewToSession = !readArticleIDsInThisSession.contains(currentArticle.id)
            if wasUnread && isNewToSession {
                readArticleIDsInThisSession.insert(currentArticle.id)
                if liveUnreadCount > 0 {
                    liveUnreadCount -= 1
                }
            }
        }

        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) {
            if readArticleIDsInThisSession.contains(next.article.id) {
                showToast { shouldShow in self.showNoNextToast = shouldShow }
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.currentArticle = next.article
                    self.currentSourceName = next.sourceName
                }
                if shouldAutoplayNext {
                    DispatchQueue.main.async {
                        let paragraphs = next.article.article
                            .components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        let fullText = paragraphs.joined(separator: "\n\n")
                        self.audioPlayerManager.startPlayback(text: fullText, title: next.article.topic)
                    }
                }
            }
        } else {
            showToast { shouldShow in self.showNoNextToast = shouldShow }
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

// MARK: - 移除点 5: 删除了 Notification.Name 的扩展
