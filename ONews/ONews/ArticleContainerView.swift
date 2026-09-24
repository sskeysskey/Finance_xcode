import SwiftUI

// ============================================================================
// MARK: - 音频容器：把"高频 publish"隔离在 Overlay 子树内
// ============================================================================

/// 永不 publish 的持有者。容器用 @StateObject 持有它 → 容器不会因音频状态而重绘。
@MainActor
final class ReaderAudioHolder: ObservableObject {
    let controller = ReaderAudioController()
}

@MainActor
final class ReaderAudioController: ObservableObject {
    let player = AudioPlayerManager()
    @Published var isCollapsed = false
    var onNextRequested: (() -> Void)?

    init() {
        player.onNextRequested = { [weak self] in self?.onNextRequested?() }
        player.onPlaybackFinished = { }
    }

    var isActive: Bool { player.isPlaybackActive }

    func start(text: String, title: String, language: String) {
        if isCollapsed { isCollapsed = false }      // 值不变不写，避免无谓 publish
        player.startPlayback(text: text, title: title, language: language)
    }
    /// 空闲时 AudioPlayerManager.stop() 会立即返回，零成本
    func stop() { player.stop() }
    func prepareForNext() { player.prepareForNextTransition() }
}

/// 只有这棵子树观察音频状态（进度又进一步隔离在 AudioProgressRow 里）
private struct ReaderAudioOverlay: View {
    @ObservedObject var controller: ReaderAudioController
    @ObservedObject var player: AudioPlayerManager
    let onStartRequest: () -> Void
    let onNext: () -> Void

    init(controller: ReaderAudioController,
         onStartRequest: @escaping () -> Void,
         onNext: @escaping () -> Void) {
        self.controller = controller
        self.player = controller.player
        self.onStartRequest = onStartRequest
        self.onNext = onNext
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MiniAudioBubbleView(isPlaybackActive: player.isPlaybackActive, onTap: handleBubbleTap)
                .padding(.bottom, 10)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(2)

            if !controller.isCollapsed && player.isPlaybackActive {
                AudioPlayerView(
                    playerManager: player,
                    playNextAndStart: onNext,
                    toggleCollapse: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                            controller.isCollapsed = true
                        }
                    }
                )
                .padding(.horizontal).padding(.bottom, 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func handleBubbleTap() {
        if !controller.isCollapsed && player.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { controller.isCollapsed = true }
        } else if player.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { controller.isCollapsed = false }
        } else {
            onStartRequest()
        }
    }
}

// ============================================================================
// MARK: - ArticleContainerView
// ============================================================================
struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    let autoPlayOnAppear: Bool

    @EnvironmentObject var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("isGlobalEnglishMode") private var isEnglishMode = false
    @AppStorage("articleBodyFontSize") private var articleBodyFontSize: Double = 25

    // 不观察：只调方法（避免 ResourceManager / NewsViewModel 的 publish 让详情页重排）
    let viewModel: NewsViewModel
    let resourceManager: ResourceManager

    @StateObject private var audioHolder = ReaderAudioHolder()

    @State private var currentArticle: Article
    @State private var currentSourceName: String

    @State private var unreadCountForGroup: Int = 0
    @State private var totalUnreadCountForContext: Int = 0

    @State private var showNoNextToast = false
    @State private var didCommitOnDisappear = false
    @State private var isSceneActive = true

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

    private var controller: ReaderAudioController { audioHolder.controller }

    private var displaySourceName: String {
        if isEnglishMode,
           let s = viewModel.sources.first(where: { $0.name == currentSourceName }) {
            return s.name_en
        }
        return currentSourceName
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ArticleDetailView(
                article: currentArticle,
                sourceName: currentSourceName,
                sourceDisplayName: displaySourceName,
                unreadCountForGroup: unreadCountForGroup,
                totalUnreadCount: totalUnreadCountForContext,
                isEnglishMode: $isEnglishMode,
                showStickyTitle: authManager.isPermanentVIP,
                requestNextArticle: { await switchToNextArticleAndStopAudio() }
            )
            .id(currentArticle.id)
            .transition(.opacity)

            if showNoNextToast { ToastView(message: Localized.noMore).zIndex(5) }

            ReaderAudioOverlay(
                controller: controller,
                onStartRequest: { startPlayback() },
                onNext: {
                    Task { await switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true) }
                }
            )
        }
        .onAppear {
            didCommitOnDisappear = false
            isSceneActive = (scenePhase == .active)

            viewModel.beginReading(currentArticle)
            updateUnreadCounts()

            NewsTrackingManager.shared.track(event: .view, article: currentArticle,
                                             sourceId: currentArticle.source_id)
            NotificationPermissionManager.shared.record(.newsOpenArticle)

            noteFreeReadIfNeeded(currentArticle)
            prefetchNext()

            controller.onNextRequested = {
                Task { await switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true) }
            }

            if autoPlayOnAppear {
                // ★ 合成已全部移到后台，无需再等 0.6s；只错开 push 动画的前几帧即可
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !controller.isActive { startPlayback() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            isSceneActive = (phase == .active)
        }
        .onDisappear {
            // 只有"App 仍在前台"时的 disappear 才是真正的"用户返回列表"
            guard isSceneActive, scenePhase == .active else {
                print("⏸️ [阅读会话] 因 App 离开前台而 disappear —— 不标记已读，保持未读。")
                return
            }
            guard !didCommitOnDisappear else { return }
            didCommitOnDisappear = true

            controller.stop()
            viewModel.finishReading(markCurrentAsRead: true)
            AnonymousSubscribePromptManager.shared.flushIfNeeded()
        }
        .onChange(of: currentArticle) { _, newArticle in
            viewModel.beginReading(newArticle)
            updateUnreadCounts()
            noteFreeReadIfNeeded(newArticle)
            prefetchNext()
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

    // MARK: - 播放
    /// 只做"选语言"；分段规整 / 读音预处理全部由 AudioPlayerManager 在后台完成
    private func playbackPayload(for article: Article) -> (String, String, String) {
        if isEnglishMode,
           let engText = article.article_eng, !engText.isEmpty,
           let engTitle = article.topic_eng {
            return (engText, engTitle, "en-US")
        }
        return (article.article, article.topic, "zh-CN")
    }

    private func startPlayback() {
        let (text, title, lang) = playbackPayload(for: currentArticle)
        controller.start(text: text, title: title, language: lang)
        NewsTrackingManager.shared.track(event: .listen, article: currentArticle,
                                         sourceId: currentArticle.source_id)
    }

    private func updateUnreadCounts() {
        let name = contextSourceName
        unreadCountForGroup = viewModel.getUnreadCountForDateGroup(
            timestamp: currentArticle.timestamp, inSource: name)
        totalUnreadCountForContext = viewModel.getEffectiveUnreadCount(inSource: name)
    }

    private var contextSourceName: String? {
        switch navigationContext {
        case .fromSource(let n): return n
        case .fromAllArticles: return nil
        }
    }

    // MARK: - 下一篇
    private func switchToNextArticleAndStopAudio() async {
        controller.stop()   // 空闲时零成本
        await switchToNextArticle(shouldAutoplayNext: false, triggerViewTrack: true)
    }

    private func switchToNextArticle(shouldAutoplayNext: Bool,
                                     triggerViewTrack: Bool = false,
                                     triggerListenTrack: Bool = false) async {
        ReviewManager.shared.recordInteraction()
        if shouldAutoplayNext { controller.prepareForNext() }

        viewModel.markArticleAsRead(currentArticle)

        Task { await resourceManager.silentRefresh(minInterval: 180, reason: "next-article") }
        NotificationPermissionManager.shared.record(.newsNextArticle)

        guard let next = viewModel.findNextUnread(after: currentArticle.id,
                                                  inSource: contextSourceName) else {
            showToast { self.showNoNextToast = $0 }
            controller.stop()
            return
        }

        if !NewsPointsCoordinator.canAccess(next.article, auth: authManager, viewModel: viewModel) {
            let willPrompt = NewsPointsCoordinator.shared.willPromptForUnlock(
                next.article, auth: authManager, viewModel: viewModel)
            if willPrompt { controller.stop() }
            NewsPointsCoordinator.shared.attemptUnlockArticle(
                next.article, auth: authManager, viewModel: viewModel,
                onBlocked: { self.controller.stop() }
            ) {
                Task {
                    await self.performSwitchAfterUnlock(next: next,
                                                        shouldAutoplayNext: shouldAutoplayNext,
                                                        triggerViewTrack: triggerViewTrack,
                                                        triggerListenTrack: triggerListenTrack)
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
        // ★ 先启动音频（后台合成与页面切换并行），缩短"下一篇开口"的等待
        if shouldAutoplayNext {
            let (text, title, lang) = playbackPayload(for: next.article)
            controller.start(text: text, title: title, language: lang)
        }

        if !next.article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: next.article.timestamp,
                                                  imageNames: next.article.images,
                                                  priority: true)
        }
        ArticleBodyCache.shared.prefetch(article: next.article,
                                         english: isEnglishMode,
                                         fontSize: articleBodyFontSize)

        withAnimation(.easeInOut(duration: 0.22)) {
            currentArticle = next.article
            currentSourceName = next.sourceName
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

    private func prefetchNext() {
        guard let next = viewModel.findNextUnread(after: currentArticle.id,
                                                  inSource: contextSourceName) else { return }
        if !next.article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: next.article.timestamp,
                                                  imageNames: next.article.images)
        }
        ArticleBodyCache.shared.prefetch(article: next.article,
                                         english: isEnglishMode,
                                         fontSize: articleBodyFontSize)
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