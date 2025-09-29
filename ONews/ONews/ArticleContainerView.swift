import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    
    @ObservedObject var viewModel: NewsViewModel
    
    @StateObject private var audioPlayerManager = AudioPlayerManager()
    
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    @State private var liveUnreadCount: Int
    // 已移除: @State private var readArticleIDsInThisSession: Set<UUID> = []
    
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
        .onAppear {
            audioPlayerManager.onNextRequested = {
                self.switchToNextArticle(shouldAutoplayNext: true)
            }
            audioPlayerManager.onPlaybackFinished = {
                // 行为已在 AudioPlayerManager 内部处理
            }
        }
        .onDisappear {
            // ✅ 需求1的实现入口：当离开详情页（返回列表）时
            audioPlayerManager.stop()
            
            // 将当前正在看的、但还未切换走的文章也暂存起来
            _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
            
            // 调用完整提交方法，它会更新 `sources` 并触发列表页的UI刷新
            viewModel.commitPendingReads()
        }
        // 已移除 .onChange(of: currentArticle.id) 修饰符，逻辑已合并
        .background(Color.viewBackground.ignoresSafeArea())
    }
    
    // MARK: - 修改后的函数
    private func switchToNextArticleAndStopAudio() {
        audioPlayerManager.stop()
        switchToNextArticle(shouldAutoplayNext: false)
    }
    
    private func switchToNextArticle(shouldAutoplayNext: Bool) {
        if shouldAutoplayNext {
            audioPlayerManager.prepareForNextTransition()
        }
        
        // 在切换前，将当前文章暂存为待读。如果暂存成功（即首次阅读），则更新UI上的未读计数器。
        if viewModel.stageArticleAsRead(articleID: currentArticle.id) {
            // 如果暂存成功（说明是本会话首次阅读），则更新UI上的未读计数器。
            if liveUnreadCount > 0 {
                liveUnreadCount -= 1
            }
        }
        
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }
        
        // findNextUnread 现在会智能地跳过已读和已暂存的文章
        if let next = viewModel.findNextUnread(after: currentArticle.id, inSource: sourceNameToSearch) {
            
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
        else {
            showToast { shouldShow in self.showNoNextToast = shouldShow }
            audioPlayerManager.stop() // 如果没有下一篇了，也停止播放器
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
    
    
    // ToastView 保持不变
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
