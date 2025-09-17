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
                // “读取下一篇”按钮：停止并跳转（不自动播放）
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
                            // 播放器“双箭头”：跳转并自动播放
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
        .onAppear {
            // 远程“下一曲”（锁屏/控制中心）或耳机上的下一曲按钮
            audioPlayerManager.onNextRequested = {
                // 用户主动请求下一曲：无条件跳转并自动播放
                self.switchToNextArticle(shouldAutoplayNext: true)
            }
            // 自然结束：行为在 AudioPlayerManager.finishNaturally 内部已根据 isAutoPlayEnabled 处理
            audioPlayerManager.onPlaybackFinished = {
                // 已在 manager 内处理，无需重复
            }
        }
        .onDisappear {
            // 离开详情页才彻底停止与反激活会话
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

    // MARK: - 新增函数
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
                // 不自动播放
            }
        } else {
            showToast { shouldShow in self.showNoNextToast = shouldShow }
        }
    }

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
