import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    // ==================== 核心修改 1：添加会话内已读ID集合 ====================
    // 这个集合用于暂存本次“翻页阅读”会话中所有被阅读过的文章ID。
    // 它只在内部使用，不会触发ViewModel的更新。
    @State private var readArticleIDsInThisSession: Set<UUID> = []
    // =======================================================================
    
    @State private var showNoNextToast = false
    @State private var showNoPreviousToast = false

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
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
                viewModel: viewModel,
                requestNextArticle: {
                    self.switchToNextArticle()
                },
                requestPreviousArticle: {
                    self.switchToPreviousArticle()
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
            
            if showNoPreviousToast {
                ToastView(message: "这已经是第一篇文章了")
            }
        }
        .navigationTitle(currentSourceName)
        .navigationBarTitleDisplayMode(.inline)
        // ==================== 核心修改 2：修改 onDisappear 逻辑 ====================
        // 当整个容器视图消失时（用户点击返回），这是唯一安全的时机去更新ViewModel。
        .onDisappear {
            // 首先，将用户看到的最后一篇文章也加入待办列表
            readArticleIDsInThisSession.insert(currentArticle.id)
            
            // 然后，批量、一次性地通知ViewModel更新所有已读文章
            for articleID in readArticleIDsInThisSession {
                viewModel.markAsRead(articleID: articleID)
            }
        }
        // ========================================================================
        // ==================== 核心修改 3：修改 onChange 逻辑 ====================
        // 当文章切换时，我们不再直接调用ViewModel...
        .onChange(of: currentArticle.id) { oldValue, newValue in
            // ...而是仅仅将刚刚离开的文章ID（oldValue）记录到我们自己的“待办”集合中。
            // 这个操作不会触发任何UI刷新，因此是完全安全的。
            readArticleIDsInThisSession.insert(oldValue)
        }
        // ========================================================================
    }

    /// 切换到下一篇文章的逻辑
    private func switchToNextArticle() {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let next = viewModel.findNextArticle(after: currentArticle.id, inSource: sourceNameToSearch) {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentArticle = next.article
                self.currentSourceName = next.sourceName
            }
        } else {
            showToast { shouldShow in self.showNoNextToast = shouldShow }
        }
    }
    
    /// 切换到上一篇文章的逻辑
    private func switchToPreviousArticle() {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let prev = viewModel.findPreviousArticle(before: currentArticle.id, inSource: sourceNameToSearch) {
            withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.8)) {
                self.currentArticle = prev.article
                self.currentSourceName = prev.sourceName
            }
        } else {
            showToast { shouldShow in self.showNoPreviousToast = shouldShow }
        }
    }
    
    /// 辅助函数，接收一个“设置器”闭包来显示和隐藏提示
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
