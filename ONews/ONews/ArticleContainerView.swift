import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    // 【新增】标记是否在页面出现时自动开始播放
    let autoPlayOnAppear: Bool

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
            
            Task {
                await preDownloadNextArticleImages()
            }
            
            audioPlayerManager.onNextRequested = {
                Task {
                    await self.switchToNextArticle(shouldAutoplayNext: true)
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
        .onChange(of: currentArticle) { _, newArticle in
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
        
        // 【新增】在这里调用 ReviewManager
        // 逻辑：用户决定看下一篇，说明刚刚这就这篇看完了/听完了，记录一次有效交互
        ReviewManager.shared.recordInteraction()

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
        
        // ... (图片下载逻辑保持不变，为了节省篇幅这里省略，请保留原有的图片下载代码) ...
        if !next.article.images.isEmpty {
             // ... 图片下载代码 ...
             let imagesAlreadyExist = resourceManager.checkIfImagesExistForArticle(
                timestamp: next.article.timestamp,
                imageNames: next.article.images
            )
            
            if !imagesAlreadyExist {
                // 1. 设置下载状态的初始值
                await MainActor.run {
                    isDownloadingImages = true
                    downloadProgress = 0.0
                    downloadProgressText = Localized.imagePrepare // 使用词典：准备中
                }
                
                do {
                    // 2. 调用下载方法，并传入一个闭包来处理进度更新
                    try await resourceManager.downloadImagesForArticle(
                        timestamp: next.article.timestamp,
                        imageNames: next.article.images,
                        progressHandler: { current, total in
                            // 这个闭包会在 MainActor 上被调用，可以直接更新UI状态
                            self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                            // 【修改】使用词典拼接：已下载 X / Y
                            self.downloadProgressText = "\(Localized.imageDownloaded) \(current) / \(total)"
                        }
                    )
                } catch {
                    await MainActor.run {
                        isDownloadingImages = false
                        errorMessage = "\(Localized.imageLoadFailed): \(error.localizedDescription)"
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
        
        // --- 【核心修改开始】 ---
        
        // 移除原有的 "shouldKeepEnglish" 强制切换逻辑
        // 我们希望保留用户的“偏好设置”，即使当前文章没有英文，开关依然是开着的(只是显示中文)
        // 这样下一篇如果有英文，依然会自动显示英文。
        
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentArticle = next.article
                self.currentSourceName = next.sourceName
                // 【删除】self.isEnglishMode = shouldKeepEnglish
            }
        }
        
        if shouldAutoplayNext {
            await MainActor.run {
                // 自动播放时，确保播放器是展开的
                self.isMiniPlayerCollapsed = false
                
                // 3. 根据全局 isEnglishMode 和当前文章是否有英文，决定播放语言
                let rawText: String
                let title: String
                let language: String
                
                // 动态判断当前这篇新文章能不能播英文
                let canPlayEnglish = self.isEnglishMode && 
                                     (next.article.article_eng != nil && !next.article.article_eng!.isEmpty)
                
                if canPlayEnglish,
                   let engText = next.article.article_eng, 
                   let engTitle = next.article.topic_eng {
                    // 播放英文
                    rawText = engText
                    title = engTitle
                    language = "en-US"
                } else {
                    // 播放中文
                    rawText = next.article.article
                    title = next.article.topic
                    language = "zh-CN"
                }
                
                let paragraphs = rawText
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let fullText = paragraphs.joined(separator: "\n\n")
                
                // 【修复】明确传入 "zh-CN"，确保逻辑一致
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