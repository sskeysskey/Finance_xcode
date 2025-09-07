import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    
    @ObservedObject var viewModel: NewsViewModel
    
    // ==================== 新增修改 1: 创建并持有 AudioPlayerManager ====================
    @StateObject private var audioPlayerManager = AudioPlayerManager()
    // ==============================================================================
    
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    @State private var liveUnreadCount: Int
    
    @State private var readArticleIDsInThisSession: Set<UUID> = []
    
    @State private var showNoNextToast = false
    // NEW: 控制“自动播放下一篇”的一次性开关
    @State private var shouldAutoplayNext = false

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
                // ==================== 新增修改 2: 将 audioPlayerManager 传递给子视图 ====================
                audioPlayerManager: audioPlayerManager,
                // ====================================================================================
                requestNextArticle: {
                    self.switchToNextArticle()
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
            
            // ==================== 新增修改 3: 显示音频播放器UI ====================
            if audioPlayerManager.isPlaybackActive {
                        AudioPlayerView(
                            playerManager: audioPlayerManager,
                            // NEW: 注入“播放下一篇并自动朗读”的闭包
                            playNextAndStart: {
                                shouldAutoplayNext = true
                                switchToNextArticle()
                            }
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                    }
        }
        .onAppear {
            audioPlayerManager.onNextRequested = {
                // 来自锁屏/耳机“下一首”
                shouldAutoplayNext = true
                switchToNextArticle()
            }
            
            audioPlayerManager.onPlaybackFinished = {
                if audioPlayerManager.isAutoPlayEnabled {
                    shouldAutoplayNext = true
                    switchToNextArticle()
                } else {
                    print("播放自然结束（手动模式），等待用户点击‘播放下一篇’")
                }
            }
        }
        .onDisappear {
            // 当视图消失时，停止音频并清理会话
            audioPlayerManager.stop()
            
            if !currentArticle.isRead {
                readArticleIDsInThisSession.insert(currentArticle.id)
            }
            
            for articleID in readArticleIDsInThisSession {
                viewModel.markAsRead(articleID: articleID)
            }
        }
        .onChange(of: currentArticle.id) { oldValue, newValue in
            let wasArticleUnread = !viewModel.sources.flatMap { $0.articles }.first { $0.id == oldValue }!.isRead
            let isNewToSession = !readArticleIDsInThisSession.contains(oldValue)

            if wasArticleUnread && isNewToSession {
                liveUnreadCount -= 1
                readArticleIDsInThisSession.insert(oldValue)
            }
            // NEW: 如果是“播放下一篇”触发的切换，自动开始播放
                    if shouldAutoplayNext {
                        shouldAutoplayNext = false
                        // 准备下一篇文本
                        let paragraphs = self.currentArticle.article
                            .components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        let fullText = paragraphs.joined(separator: "\n\n")
                        audioPlayerManager.startPlayback(text: fullText)
                    }
        }
        .background(Color.viewBackground.ignoresSafeArea())
    }

        /// 切换到下一篇文章的逻辑
        private func switchToNextArticle() {
            // --- 核心修复点 开始 ---
            // 在寻找下一篇之前，立即将当前文章标记为“本轮会话已读”。
            // 这是解决“最后一篇文章”问题的关键。
            // 我们需要确保在检查循环时，当前文章的ID已经被记录下来。
            let wasArticleUnread = !viewModel.sources.flatMap { $0.articles }.first { $0.id == currentArticle.id }!.isRead
            let isNewToSession = !readArticleIDsInThisSession.contains(currentArticle.id)

            if wasArticleUnread && isNewToSession {
                // 将当前文章加入会话已读集合
                readArticleIDsInThisSession.insert(currentArticle.id)
                
                // 因为我们可能不会切换到新文章（即这是最后一篇），
                // .onChange 将不会触发。因此，我们需要在这里手动更新UI上的未读计数。
                if liveUnreadCount > 0 {
                    liveUnreadCount -= 1
                }
            }
            // --- 核心修复点 结束 ---

            let sourceNameToSearch: String?
            switch navigationContext {
            case .fromSource(let name): sourceNameToSearch = name
            case .fromAllArticles: sourceNameToSearch = nil
            }

            if let next = viewModel.findNextUnread(after: currentArticle.id,
                                                   inSource: sourceNameToSearch) {
                
                // 现在，当 findNextUnread 循环推荐回同一篇文章时，
                // 下面的检查会因为我们刚刚在上面插入的 ID 而成功。
                if readArticleIDsInThisSession.contains(next.article.id) {
                    // 停止跳转，并显示提示。
                    showToast { shouldShow in self.showNoNextToast = shouldShow }
                } else {
                    // 否则，这是一篇真正“新”的未读文章，执行跳转。
                    withAnimation(.easeInOut(duration: 0.4)) {
                        self.currentArticle = next.article
                        self.currentSourceName = next.sourceName
                    }
                }
            } else {
                // 这个分支处理的是一开始就没有任何未读文章的情况。
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

/// 一个可重用的提示视图
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
