import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    // --- 新增 ---
    // 1. 用于在当前页面生命周期内，实时更新未读计数的局部状态变量
    @State private var liveUnreadCount: Int
    
    // --- 恢复并修改 ---
    // 2. 用于累积在本次查看会话中所有被读过的文章ID
    @State private var readArticleIDsInThisSession: Set<UUID> = []
    
    @State private var showNoNextToast = false
    @State private var showNoPreviousToast = false

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    // 这个计算属性现在只用于初始化
    private var initialUnreadCount: Int {
        switch navigationContext {
        case .fromAllArticles:
            return viewModel.totalUnreadCount
        case .fromSource(let sourceName):
            return viewModel.sources.first { $0.name == sourceName }?.unreadCount ?? 0
        }
    }

    // --- 修改: 自定义 init ---
    // 我们需要自定义 init 来正确初始化新的 @State 变量 liveUnreadCount
    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        
        // 初始化内部状态
        self._currentArticle = State(initialValue: article)
        self._currentSourceName = State(initialValue: sourceName)
        
        // 根据上下文计算初始的未读数，并用它来初始化 liveUnreadCount
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
            // --- 修改: 传递 liveUnreadCount ---
            // 将我们实时的、局部的未读数传递给详情页
            ArticleDetailView(
                article: currentArticle,
                sourceName: currentSourceName,
                unreadCount: liveUnreadCount, // <- 使用局部状态
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
        // --- 新增: onAppear ---
        // 当视图首次出现时，立即将当前文章ID设置为“最后查看”
        .onAppear {
            viewModel.lastViewedArticleID = currentArticle.id
        }
        // --- 修改: 恢复并优化 .onDisappear ---
        .onDisappear {
            // 当视图最终消失时，将当前正在看的文章也加入待处理集合
            // 我们需要检查这篇文章是否本身就是未读的
            if !currentArticle.isRead {
                readArticleIDsInThisSession.insert(currentArticle.id)
            }
            
            // 一次性将所有在本次会话中读过的文章ID提交给ViewModel
            for articleID in readArticleIDsInThisSession {
                viewModel.markAsRead(articleID: articleID)
            }
        }
        // --- 修改: 恢复并优化 .onChange ---
        .onChange(of: currentArticle.id) { oldValue, newValue in
            // --- 修改: 在 onChange 中也更新 lastViewedArticleID ---
            // 每次切换文章时，都更新 ViewModel 中的记录
            viewModel.lastViewedArticleID = newValue
            
            // 当文章切换时，我们处理刚刚离开的文章 (oldValue)
            
            // 检查这篇文章是否本身是未读的，并且我们还没有处理过它
            let wasArticleUnread = !viewModel.sources.flatMap { $0.articles }.first { $0.id == oldValue }!.isRead
            let isNewToSession = !readArticleIDsInThisSession.contains(oldValue)

            if wasArticleUnread && isNewToSession {
                // 如果它确实是篇新的未读文章，那么：
                // 1. 将局部未读数减 1，立即更新UI
                liveUnreadCount -= 1
                // 2. 将它的ID加入待处理集合，以便在最后统一提交
                readArticleIDsInThisSession.insert(oldValue)
            }
        }
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
