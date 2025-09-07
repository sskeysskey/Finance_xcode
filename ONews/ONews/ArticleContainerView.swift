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

    // 保留但当前不依赖通知去启动自动播放
    @State private var pendingAutoPlayRequestID: UUID?

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
                    // 详情页底部按钮：只跳转，不自动播放
                    self.switchToNextArticle(shouldAutoplayNext: false)
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
                    .padding(.bottom, 120)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
                } else {
                    AudioPlayerView(
                        playerManager: audioPlayerManager,
                        playNextAndStart: {
                            // 播放器双箭头：跳转并自动播放
                            switchToNextArticle(shouldAutoplayNext: true)
                        },
                        toggleCollapse: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                                isMiniPlayerCollapsed = true
                            }
                        }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
                }
            }
        }
        .onAppear {
            NotificationCenter.default.addObserver(forName: .onewsAutoPlayRequest, object: nil, queue: .main) { notif in
                guard let targetID = notif.userInfo?["articleID"] as? UUID else { return }
                if targetID == self.currentArticle.id {
                    startAutoPlaybackForCurrentArticle()
                }
            }

            audioPlayerManager.onNextRequested = {
                // 自然结束或远程“下一曲”，容器依据开关决定是否自动播放下一篇
                let shouldAutoplay = audioPlayerManager.isAutoPlayEnabled
                switchToNextArticle(shouldAutoplayNext: shouldAutoplay)
            }
            audioPlayerManager.onPlaybackFinished = {
                // 不在此触发下一篇，避免重复
            }
        }
        .onDisappear {
            // 离开详情页才彻底停止与反激活会话
            audioPlayerManager.stop()
            NotificationCenter.default.removeObserver(self, name: .onewsAutoPlayRequest, object: nil)

            if !currentArticle.isRead {
                readArticleIDsInThisSession.insert(currentArticle.id)
            }
            for articleID in readArticleIDsInThisSession {
                viewModel.markAsRead(articleID: articleID)
            }
        }
        .onChange(of: currentArticle.id) { oldValue, newValue in
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

    private func startAutoPlaybackForCurrentArticle() {
        let paragraphs = self.currentArticle.article
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fullText = paragraphs.joined(separator: "\n\n")
        audioPlayerManager.isAutoPlayEnabled = true
        audioPlayerManager.startPlayback(text: fullText, title: self.currentArticle.topic)
    }

    private func switchToNextArticle(shouldAutoplayNext: Bool) {
        // 关键改动：不要用 stop()，避免反激活 AudioSession
        audioPlayerManager.prepareForNextTransition()

        // 标记已读并更新计数
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

        // 搜索范围
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        // 查找下一篇未读
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

extension Notification.Name {
    static let onewsAutoPlayRequest = Notification.Name("ONews.AutoPlayRequest")
}
