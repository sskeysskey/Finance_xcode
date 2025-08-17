import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    @State private var liveUnreadCount: Int
    
    @State private var readArticleIDsInThisSession: Set<UUID> = []
    
    @State private var showNoNextToast = false

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
                requestNextArticle: {
                    self.switchToNextArticle()
                }
            )
            
            if showNoNextToast {
                ToastView(message: "该分组内已无更多文章")
            }
        }
                .background(Color.viewBackground.ignoresSafeArea())
            
        }
        

    // ==================== 核心修改: 重写 switchToNextArticle 方法 ====================
    private func switchToNextArticle() {
        // 1. 首先检查当前文章是否未读
        let currentArticleIsUnread = viewModel.sources
            .flatMap { $0.articles }
            .first(where: { $0.id == currentArticle.id })?.isRead == false
        
        // 2. 如果当前文章未读，立即标记为已读
        if currentArticleIsUnread {
            // 立即调用 viewModel 的方法标记为已读
            // 这会触发 @Published sources 的更新，进而更新角标
            viewModel.markAsRead(articleID: currentArticle.id)
            
            // 更新本地的未读计数
            if liveUnreadCount > 0 {
                liveUnreadCount -= 1
            }
            
            // 将ID加入已读集合（用于循环检测）
            readArticleIDsInThisSession.insert(currentArticle.id)
        }
        
        // 3. 查找下一篇未读文章
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name):
            sourceNameToSearch = name
        case .fromAllArticles:
            sourceNameToSearch = nil
        }

        if let next = viewModel.findNextUnread(after: currentArticle.id,
                                               inSource: sourceNameToSearch) {
            
            // 4. 检查是否循环回到了本轮已读的文章
            if readArticleIDsInThisSession.contains(next.article.id) {
                // 已经循环了，显示提示
                showToast { shouldShow in self.showNoNextToast = shouldShow }
            } else {
                // 5. 切换到下一篇文章
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.currentArticle = next.article
                    self.currentSourceName = next.sourceName
                }
            }
        } else {
            // 没有找到任何未读文章
            showToast { shouldShow in self.showNoNextToast = shouldShow }
        }
    }
    // ===========================================================================
    
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
