// 文件: /Users/yanzhang/Documents/Xcode/ONews/ONews/ArticleContainerView.swift

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
    @State private var showNoPreviousToast = false

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
            .id(currentArticle.id)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
            )
            
            if showNoNextToast {
                ToastView(message: "该分组内已无更多文章了")
            }
            
            if showNoPreviousToast {
                ToastView(message: "这已经是第一篇文章了")
            }
        }
        .onDisappear {
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
        }
        .background(Color.viewBackground.ignoresSafeArea())
    }

    // ==================== 最终修改: 简化并统一 switchToNextArticle 逻辑 ====================
    /// 切换到下一篇文章的逻辑
    private func switchToNextArticle() {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let next = viewModel.findNextUnread(after: currentArticle.id,
                                               inSource: sourceNameToSearch) {
            
            // 关键逻辑：不再区分上下文，统一进行检查。
            // 如果 ViewModel 循环推荐的下一篇文章，是我们在本轮会话中已经读过的，
            // 那么就意味着我们已经完成了对当前范围内所有未读文章的阅读。
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
    // ====================================================================================
    
    /// 切换到上一篇文章的逻辑 (此方法当前未被UI调用)
    private func switchToPreviousArticle() {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let prev = viewModel.findPreviousUnread(before: currentArticle.id, inSource: sourceNameToSearch) {
            withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.8)) {
                self.currentArticle = prev.article
                self.currentSourceName = prev.sourceName
            }
        } else {
            showToast { shouldShow in self.showNoPreviousToast = shouldShow }
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
