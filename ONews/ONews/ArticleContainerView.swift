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

    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel, resourceManager: ResourceManager, autoPlayOnAppear: Bool = false) {
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
                requestNextArticle: {
                    await self.switchToNextArticleAndStopAudio()
                },
                onAudioToggle: { handleAudioToggle() }
            )
            .id(currentArticle.id)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
            )

            if showNoNextToast {
                ToastView(message: Localized.noMore)
            }

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
                        Task {
                            await switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true)
                        }
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
                .zIndex(3)
            }

            if isDownloadingImages {
                VStack(spacing: 12) {
                    Text(Localized.imageLoading).font(.headline).foregroundColor(.white)
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .white))
                        .padding(.horizontal, 40)
                    Text(downloadProgressText).font(.caption).foregroundColor(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.75))
                .edgesIgnoringSafeArea(.all)
                .zIndex(4)
            }
        }
        .onAppear {
            didCommitOnDisappear = false
            // ★★★【需求1】进入详情页 → 冻结列表重建，避免 Article.id 被重新生成
            viewModel.isReadingArticle = true
            updateUnreadCounts()

            NewsTrackingManager.shared.track(
                event: .view, article: currentArticle, sourceId: currentArticle.source_id)

            // 【需求3】记录互动（阅读中不弹窗，只累积分数）
            NotificationPermissionManager.shared.record(.newsOpenArticle)

            Task { await preDownloadNextArticleImages() }

            audioPlayerManager.onNextRequested = {
                Task {
                    await self.switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true)
                }
            }
            audioPlayerManager.onPlaybackFinished = { }

            if autoPlayOnAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !audioPlayerManager.isPlaybackActive { startPlayback() }
                }
            }
        }
        .onDisappear {
            // ★★★ 离开详情页 → 解冻；若期间有新数据会自动落地
            viewModel.isReadingArticle = false
            guard !didCommitOnDisappear else { return }
            didCommitOnDisappear = true
            audioPlayerManager.stop()
            _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
            viewModel.commitPendingReads()
        }
        .onChange(of: currentArticle) { newArticle in
            updateUnreadCounts()
            Task { await preDownloadNextArticleImages() }
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .alert("", isPresented: $showErrorAlert, actions: {
            Button(Localized.ok, role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }

    private func handleBubbleTap() {
        if !isMiniPlayerCollapsed && audioPlayerManager.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                isMiniPlayerCollapsed = true
            }
        } else if audioPlayerManager.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                isMiniPlayerCollapsed = false
            }
        } else {
            startPlayback()
        }
    }

    private func handleAudioToggle() {
        if audioPlayerManager.isPlaybackActive {
            audioPlayerManager.stop()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        isMiniPlayerCollapsed = false

        let rawText: String
        let title: String
        let language: String

        if isEnglishMode,
           let engText = currentArticle.article_eng, !engText.isEmpty,
           let engTitle = currentArticle.topic_eng {
            rawText = engText; title = engTitle; language = "en-US"
        } else {
            rawText = currentArticle.article; title = currentArticle.topic; language = "zh-CN"
        }

        let paragraphs = rawText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fullText = paragraphs.joined(separator: "\n\n")

        audioPlayerManager.startPlayback(text: fullText, title: title, language: language)

        NewsTrackingManager.shared.track(
            event: .listen, article: currentArticle, sourceId: currentArticle.source_id)
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

    private func switchToNextArticle(shouldAutoplayNext: Bool, triggerViewTrack: Bool = false, triggerListenTrack: Bool = false) async {
        ReviewManager.shared.recordInteraction()
        if shouldAutoplayNext { audioPlayerManager.prepareForNextTransition() }
        _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)

        // ★★★【需求1】点击"下一篇"时顺手拉一次服务器（只下载，不打断阅读；
        // 新数据会在退出详情页后自动落地，绝不会让"下一篇"失效）★★★
        Task { await resourceManager.silentRefresh(minInterval: 180, reason: "next-article") }

        // 【需求3】阅读完成是最佳"成功时刻"，允许弹通知预弹窗（延迟 0.8s，等转场结束）
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
            await MainActor.run {
                audioPlayerManager.stop()
                NewsPointsCoordinator.shared.attemptUnlockArticle(next.article, auth: authManager, viewModel: viewModel) {
                    Task {
                        await self.performSwitchAfterUnlock(next: next,
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
            let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
                timestamp: next.article.timestamp, imageNames: next.article.images)
            if !imagesAlreadyExist {
                await MainActor.run {
                    isDownloadingImages = true
                    downloadProgress = 0.0
                    downloadProgressText = Localized.imagePrepare
                }
                do {
                    try await resourceManager.downloadImagesForArticle(
                        timestamp: next.article.timestamp, imageNames: next.article.images,
                        progressHandler: { current, total in
                            self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                            self.downloadProgressText = "\(Localized.imageDownloaded) \(current) / \(total)"
                        })
                } catch {
                    await MainActor.run { isDownloadingImages = false }
                    print("下一篇图片预下载失败，继续切换: \(error.localizedDescription)")
                }
                await MainActor.run { isDownloadingImages = false }
            }
        }

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentArticle = next.article
                self.currentSourceName = next.sourceName
            }
            if triggerViewTrack {
                NewsTrackingManager.shared.track(event: .view, article: next.article, sourceId: next.article.source_id)
            }
            if triggerListenTrack {
                NewsTrackingManager.shared.track(event: .listen, article: next.article, sourceId: next.article.source_id)
            }
        }

        if shouldAutoplayNext {
            await MainActor.run {
                self.isMiniPlayerCollapsed = false
                let rawText: String; let title: String; let language: String
                let canPlayEnglish = self.isEnglishMode &&
                    (next.article.article_eng != nil && !next.article.article_eng!.isEmpty)
                if canPlayEnglish, let engText = next.article.article_eng, let engTitle = next.article.topic_eng {
                    rawText = engText; title = engTitle; language = "en-US"
                } else {
                    rawText = next.article.article; title = next.article.topic; language = "zh-CN"
                }
                let paragraphs = rawText.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let fullText = paragraphs.joined(separator: "\n\n")
                self.audioPlayerManager.startPlayback(text: fullText, title: title, language: language)
            }
        }
    }

    private func preDownloadNextArticleImages() async {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }
        guard let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) else { return }
        guard !next.article.images.isEmpty else { return }
        do {
            try await resourceManager.preDownloadImagesForArticleSilently(
                timestamp: next.article.timestamp, imageNames: next.article.images)
        } catch {
            print("静默预下载下一篇文章的图片失败: \(error.localizedDescription)")
        }
    }

    private func showToast(setter: @escaping (Bool) -> Void) {
        setter(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { setter(false) }
        }
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