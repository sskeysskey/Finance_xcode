import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    let autoPlayOnAppear: Bool
    @EnvironmentObject var authManager: AuthManager

    @AppStorage("isGlobalEnglishMode") private var isEnglishMode = false

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

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    init(article: Article, sourceName: String, context: NavigationContext,
         viewModel: NewsViewModel, resourceManager: ResourceManager,
         autoPlayOnAppear: Bool = false) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        self.resourceManager = resourceManager
        self.autoPlayOnAppear = autoPlayOnAppear
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
                isEnglishMode: $isEnglishMode,
                viewModel: viewModel,
                audioPlayerManager: audioPlayerManager,
                requestNextArticle: { await self.switchToNextArticleAndStopAudio() },
                onAudioToggle: { handleAudioToggle() }
            )
            .id(currentArticle.id)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
            )

            if showNoNextToast { ToastView(message: Localized.noMore) }

            MiniAudioBubbleView(
                isPlaybackActive: audioPlayerManager.isPlaybackActive,
                onTap: { handleBubbleTap() }
            )
            .padding(.bottom, 10)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .zIndex(2)

            if !isMiniPlayerCollapsed && audioPlayerManager.isPlaybackActive {
                AudioPlayerView(
                    playerManager: audioPlayerManager,
                    playNextAndStart: {
                        Task { await switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true) }
                    },
                    toggleCollapse: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                            isMiniPlayerCollapsed = true
                        }
                    }
                )
                .padding(.horizontal).padding(.bottom, 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .onAppear {
            didCommitOnDisappear = false
            // ★ 开启阅读会话（内部会置 isReadingArticle = true，并记录当前文章的稳定 topic）
            viewModel.beginReading(currentArticle)
            updateUnreadCounts()

            NewsTrackingManager.shared.track(event: .view, article: currentArticle,
                                             sourceId: currentArticle.source_id)
            NotificationPermissionManager.shared.record(.newsOpenArticle)

            noteFreeReadIfNeeded(currentArticle)
            prefetchNextArticleImages()

            audioPlayerManager.onNextRequested = {
                Task { await self.switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true) }
            }
            audioPlayerManager.onPlaybackFinished = { }

            if autoPlayOnAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !audioPlayerManager.isPlaybackActive { startPlayback() }
                }
            }
        }
        .onDisappear {
            guard !didCommitOnDisappear else { return }
            didCommitOnDisappear = true
            audioPlayerManager.stop()

            // ★★★ 关键：同步落盘 → 最后才解冻数据重建（顺序绝不能反）
            viewModel.finishReading(markCurrentAsRead: true)

            AnonymousSubscribePromptManager.shared.flushIfNeeded()
        }
        .onChange(of: currentArticle) { newArticle in
            // ★ 切到下一篇：更新阅读会话指向
            viewModel.beginReading(newArticle)
            updateUnreadCounts()
            noteFreeReadIfNeeded(newArticle)
            prefetchNextArticleImages()
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .alert("", isPresented: $showErrorAlert,
               actions: { Button(Localized.ok, role: .cancel) { } },
               message: { Text(errorMessage) })
    }

    // MARK: - 免费阅读计数
    private func noteFreeReadIfNeeded(_ article: Article) {
        guard !authManager.isLoggedIn, !authManager.isSubscribed else { return }
        guard NewsFreeBadge.isFree(timestamp: article.timestamp,
                                   auth: authManager, viewModel: viewModel) else { return }
        AnonymousSubscribePromptManager.shared.noteFreeArticleRead()
    }

    private func handleBubbleTap() {
        if !isMiniPlayerCollapsed && audioPlayerManager.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isMiniPlayerCollapsed = true }
        } else if audioPlayerManager.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isMiniPlayerCollapsed = false }
        } else {
            startPlayback()
        }
    }

    private func handleAudioToggle() {
        if audioPlayerManager.isPlaybackActive { audioPlayerManager.stop() } else { startPlayback() }
    }

    private func startPlayback() {
        isMiniPlayerCollapsed = false
        let rawText: String, title: String, language: String
        if isEnglishMode,
           let engText = currentArticle.article_eng, !engText.isEmpty,
           let engTitle = currentArticle.topic_eng {
            rawText = engText; title = engTitle; language = "en-US"
        } else {
            rawText = currentArticle.article; title = currentArticle.topic; language = "zh-CN"
        }
        let fullText = rawText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        audioPlayerManager.startPlayback(text: fullText, title: title, language: language)
        NewsTrackingManager.shared.track(event: .listen, article: currentArticle,
                                         sourceId: currentArticle.source_id)
    }

    private func updateUnreadCounts() {
        let sourceNameToUse: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToUse = name
        case .fromAllArticles: sourceNameToUse = nil
        }
        self.unreadCountForGroup = viewModel.getUnreadCountForDateGroup(
            timestamp: currentArticle.timestamp, inSource: sourceNameToUse)
        self.totalUnreadCountForContext = viewModel.getEffectiveUnreadCount(inSource: sourceNameToUse)
    }

    private func switchToNextArticleAndStopAudio() async {
        audioPlayerManager.stop()
        await switchToNextArticle(shouldAutoplayNext: false, triggerViewTrack: true)
    }

    private func switchToNextArticle(shouldAutoplayNext: Bool,
                                    triggerViewTrack: Bool = false,
                                    triggerListenTrack: Bool = false) async {
        ReviewManager.shared.recordInteraction()
        if shouldAutoplayNext { audioPlayerManager.prepareForNextTransition() }

        // ★★★ 点"下一篇"= 明确读完 → 立即落盘（不再只是暂存）
        viewModel.markArticleAsRead(currentArticle)

        Task { await resourceManager.silentRefresh(minInterval: 180, reason: "next-article") }
        NotificationPermissionManager.shared.record(.newsNextArticle)

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

        if !NewsPointsCoordinator.canAccess(next.article, auth: authManager, viewModel: viewModel) {
            let willPrompt = NewsPointsCoordinator.shared.willPromptForUnlock(
                next.article, auth: authManager, viewModel: viewModel)
            await MainActor.run {
                if willPrompt { audioPlayerManager.stop() }
                NewsPointsCoordinator.shared.attemptUnlockArticle(
                    next.article, auth: authManager, viewModel: viewModel,
                    onBlocked: { self.audioPlayerManager.stop() }
                ) {
                    Task {
                        await self.performSwitchAfterUnlock(
                            next: next,
                            shouldAutoplayNext: shouldAutoplayNext,
                            triggerViewTrack: triggerViewTrack,
                            triggerListenTrack: triggerListenTrack)
                    }
                }
            }
            return
        }

        await performSwitchAfterUnlock(next: next,
                                       shouldAutoplayNext: shouldAutoplayNext,
                                       triggerViewTrack: triggerViewTrack,
                                       triggerListenTrack: triggerListenTrack)
    }

    private func performSwitchAfterUnlock(next: (article: Article, sourceName: String),
                                          shouldAutoplayNext: Bool,
                                          triggerViewTrack: Bool,
                                          triggerListenTrack: Bool) async {
        if !next.article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: next.article.timestamp,
                                                  imageNames: next.article.images,
                                                  priority: true)
        }

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentArticle = next.article
                self.currentSourceName = next.sourceName
            }
            if triggerViewTrack {
                NewsTrackingManager.shared.track(event: .view, article: next.article,
                                                 sourceId: next.article.source_id)
            }
            if triggerListenTrack {
                NewsTrackingManager.shared.track(event: .listen, article: next.article,
                                                 sourceId: next.article.source_id)
            }
        }

        if shouldAutoplayNext {
            await MainActor.run {
                self.isMiniPlayerCollapsed = false
                let rawText: String, title: String, language: String
                let canPlayEnglish = self.isEnglishMode &&
                    (next.article.article_eng != nil && !next.article.article_eng!.isEmpty)
                if canPlayEnglish, let engText = next.article.article_eng, let engTitle = next.article.topic_eng {
                    rawText = engText; title = engTitle; language = "en-US"
                } else {
                    rawText = next.article.article; title = next.article.topic; language = "zh-CN"
                }
                let fullText = rawText.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n\n")
                self.audioPlayerManager.startPlayback(text: fullText, title: title, language: language)
            }
        }
    }

    private func prefetchNextArticleImages() {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }
        guard let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch),
              !next.article.images.isEmpty else { return }
        resourceManager.enqueueImageDownloads(timestamp: next.article.timestamp,
                                              imageNames: next.article.images)
    }

    private func showToast(setter: @escaping (Bool) -> Void) {
        setter(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { setter(false) } }
    }

    struct ToastView: View {
        let message: String
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundColor(.green)
                Text(message).font(.subheadline).fontWeight(.semibold).foregroundColor(.primary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.bottom, 350)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}