import SwiftUI

struct ArticleContainerView: View {
let initialArticle: Article
let navigationContext: NavigationContext

@ObservedObject var viewModel: NewsViewModel

@StateObject private var audioPlayerManager = AudioPlayerManager()

@State private var currentArticle: Article
@State private var currentSourceName: String

@State private var showNoNextToast = false
@State private var isMiniPlayerCollapsed = false

// 防止 onDisappear 多次触发重复提交
@State private var didCommitOnDisappear = false

enum NavigationContext {
    case fromSource(String)
    case fromAllArticles
}

// MARK: - 动态计算属性

/// 获取当前导航上下文对应的 sourceName (nil 代表 "ALL")
private var sourceNameForContext: String? {
    switch navigationContext {
    case .fromSource(let name):
        return name
    case .fromAllArticles:
        return nil
    }
}

/// 计算当前日期分组的未读数
private var unreadCountForGroup: Int {
    viewModel.getUnreadCountForDateGroup(
        timestamp: currentArticle.timestamp,
        inSource: sourceNameForContext
    )
}

/// 计算当前上下文（Source 或 ALL）的总有效未读数
private var totalUnreadCountForContext: Int {
    viewModel.getEffectiveUnreadCount(inSource: sourceNameForContext)
}

init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel) {
    self.initialArticle = article
    self.navigationContext = context
    self.viewModel = viewModel
    
    self._currentArticle = State(initialValue: article)
    self._currentSourceName = State(initialValue: sourceName)
}

var body: some View {
    ZStack(alignment: .bottom) {
        ArticleDetailView(
            article: currentArticle,
            sourceName: currentSourceName,
            // 传递两个计数值
            unreadCountForGroup: unreadCountForGroup,
            totalUnreadCount: totalUnreadCountForContext,
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
        // 进入时重置防重入标记
        didCommitOnDisappear = false
        
        audioPlayerManager.onNextRequested = {
            self.switchToNextArticle(shouldAutoplayNext: true)
        }
        audioPlayerManager.onPlaybackFinished = {
            // 行为已在 AudioPlayerManager 内部处理
        }
    }
    .onDisappear {
        // 避免重复执行（例如多次 onDisappear 或导航边界情况）
        guard !didCommitOnDisappear else { return }
        didCommitOnDisappear = true
        
        // 1) 停止音频
        audioPlayerManager.stop()
        // 2) 将当前正在看的文章也加入暂存
        _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
        // 3) 提交并刷新 UI（保证退后台回来再左滑返回时，A/B 均能入已读并从未读列表消失）
        viewModel.commitPendingReads()
    }
    .background(Color.viewBackground.ignoresSafeArea())
}

private func switchToNextArticleAndStopAudio() {
    audioPlayerManager.stop()
    switchToNextArticle(shouldAutoplayNext: false)
}

private func switchToNextArticle(shouldAutoplayNext: Bool) {
    if shouldAutoplayNext {
        audioPlayerManager.prepareForNextTransition()
    }
    
    // 在切换前，将当前文章暂存为待读。
    _ = viewModel.stageArticleAsRead(articleID: currentArticle.id)
    
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
    } else {
        showToast { shouldShow in self.showNoNextToast = shouldShow }
        audioPlayerManager.stop()
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
