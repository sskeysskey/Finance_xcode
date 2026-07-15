import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    // 【新增】标记是否在页面出现时自动开始播放
    let autoPlayOnAppear: Bool
    @EnvironmentObject var authManager: AuthManager

    // 【修改】将 @State 替换为 @AppStorage，使用固定的 Key "isGlobalEnglishMode"
    // 这样列表页和详情页共享同一个持久化状态
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
                    // 【修改】点击“阅读下一篇”切换，并触发曝光(view)埋点
                    await self.switchToNextArticleAndStopAudio()
                },
                // 【修改】传递 onAudioToggle 闭包
                onAudioToggle: {
                    handleAudioToggle()
                }
            )
            .id(currentArticle.id)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
            )
            
            if showNoNextToast {
                // 【修改】使用词典：无更多文章
                ToastView(message: Localized.noMore) 
            }
            
            // 常驻的悬浮按钮
            MiniAudioBubbleView(
                isPlaybackActive: audioPlayerManager.isPlaybackActive,
                onTap: { handleBubbleTap() }
            )
            .padding(.bottom, 10)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .zIndex(2) // 确保在详情页之上
            
            // 条件显示的完整播放器
            if !isMiniPlayerCollapsed && audioPlayerManager.isPlaybackActive {
                AudioPlayerView(
                    playerManager: audioPlayerManager,
                    playNextAndStart: {
                        Task {
                            // 【修改】点击播放器“下一个”触发朗读(listen)埋点
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
                // 【修改】增大底部间距，将播放器整体上移，避免重叠
                .padding(.bottom, 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3) // 确保在悬浮按钮之上
            }
            
            // 更新图片下载遮罩层UI以显示详细进度
            if isDownloadingImages {
                VStack(spacing: 12) {
                    Text(Localized.imageLoading) // 使用词典：正在加载图片
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
                .zIndex(4) // 最高层级
            }
        }
        .onAppear {
            didCommitOnDisappear = false
            updateUnreadCounts()

            // 🔥 新增：曝光埋点
            NewsTrackingManager.shared.track(
                event: .view,
                article: currentArticle,
                sourceId: currentArticle.source_id
            )
            
            Task {
                await preDownloadNextArticleImages()
            }
            
            audioPlayerManager.onNextRequested = {
                Task {
                    // 【修改】自动播放下一篇，触发朗读(listen)埋点
                    await self.switchToNextArticle(shouldAutoplayNext: true, triggerListenTrack: true)
                }
            }
            audioPlayerManager.onPlaybackFinished = { }

            // 【新增】处理进入页面后的自动播放逻辑
            if autoPlayOnAppear {
                // 稍微延迟一点，确保视图加载完成，且避免和系统的转场动画冲突
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !audioPlayerManager.isPlaybackActive {
                        startPlayback()
                    }
                }
            }
        }
        .onDisappear {
            guard !didCommitOnDisappear else { return }
            didCommitOnDisappear = true
            audioPlayerManager.stop()
            _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
            viewModel.commitPendingReads()
        }
        .onChange(of: currentArticle) { newArticle in
            updateUnreadCounts()
            Task {
                await preDownloadNextArticleImages()
            }
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .alert("", isPresented: $showErrorAlert, actions: {
            Button(Localized.ok, role: .cancel) { } // 使用词典：好的
        }, message: {
            Text(errorMessage)
        })
    }

    // 【修改】更新处理悬浮按钮点击的逻辑
    private func handleBubbleTap() {
        // 【新增逻辑】如果完整播放器是展开状态，并且音频正在播放，则点击悬浮按钮执行最小化操作
        if !isMiniPlayerCollapsed && audioPlayerManager.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                isMiniPlayerCollapsed = true
            }
        }
        // 如果音频正在播放（但播放器是收起的），点击悬浮按钮则展开完整播放器
        else if audioPlayerManager.isPlaybackActive {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0.1)) {
                isMiniPlayerCollapsed = false
            }
        } else {
            // 如果未播放，点击则开始播放
            startPlayback()
        }
    }
    
    // 处理右上角工具栏按钮点击的逻辑
    private func handleAudioToggle() {
        if audioPlayerManager.isPlaybackActive {
            audioPlayerManager.stop()
        } else {
            startPlayback()
        }
    }
    
    // 一个统一的开始播放的辅助函数
    private func startPlayback() {
        // 开始播放时，确保完整播放器是展开状态
        isMiniPlayerCollapsed = false
        
        let rawText: String
        let title: String
        let language: String
        
        // 根据 isEnglishMode 决定播放内容
        if isEnglishMode,
           let engText = currentArticle.article_eng, !engText.isEmpty,
           let engTitle = currentArticle.topic_eng {
            rawText = engText
            title = engTitle
            language = "en-US"
        } else {
            rawText = currentArticle.article
            title = currentArticle.topic
            language = "zh-CN"
        }
        
        let paragraphs = rawText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fullText = paragraphs.joined(separator: "\n\n")
        
        // 传入 language 参数
        audioPlayerManager.startPlayback(text: fullText, title: title, language: language)
        
        // 🔥 新增：朗读埋点
        NewsTrackingManager.shared.track(
            event: .listen,
            article: currentArticle,
            sourceId: currentArticle.source_id
        )
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
        // 【修改】点击“阅读下一篇”触发的是曝光(view)埋点
        await switchToNextArticle(shouldAutoplayNext: false, triggerViewTrack: true)
    }

    // 【修改】新增 triggerViewTrack 和 triggerListenTrack 参数，用于在切换到下一篇时进行排重打点
    private func switchToNextArticle(shouldAutoplayNext: Bool, triggerViewTrack: Bool = false, triggerListenTrack: Bool = false) async {
        ReviewManager.shared.recordInteraction()
        if shouldAutoplayNext { audioPlayerManager.prepareForNextTransition() }
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

        // 点数门禁：下一篇若为受限最新新闻且未解锁，先停音频并弹窗
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
        // 图片预下载（保持原逻辑）
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
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.green)
                
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // 使用毛玻璃效果，适配深色/浅色模式
            .background(.ultraThinMaterial)
            // 胶囊形状
            .clipShape(Capsule())
            // 增加阴影，使其浮在内容之上
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
            // 底部间距稍微调大，避免遮挡悬浮按钮
            .padding(.bottom, 350)
            // 动画：从底部滑入 + 透明度变化
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}