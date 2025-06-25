// /Users/yanzhang/Documents/Xcode/ONews/ONews/ArticleContainerView.swift

import SwiftUI

struct ArticleContainerView: View {
    let initialArticle: Article
    let navigationContext: NavigationContext
    
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    @State private var readArticleIDsInThisSession: Set<UUID> = []
    
    @State private var showNoNextToast = false
    @State private var showNoPreviousToast = false

    enum NavigationContext {
        case fromSource(String)
        case fromAllArticles
    }

    // ==================== 新增计算属性 ====================
    /// 根据当前的导航上下文，计算对应的未读文章数量
    private var currentUnreadCount: Int {
        switch navigationContext {
        // 如果是从“所有文章”进入，则返回总未读数
        case .fromAllArticles:
            return viewModel.totalUnreadCount
        
        // 如果是从特定来源进入，则查找该来源并返回其未读数
        case .fromSource(let sourceName):
            // 在 viewModel 的 sources 数组中找到匹配的来源
            // 如果找到了，返回它的 unreadCount，否则返回 0
            return viewModel.sources.first { $0.name == sourceName }?.unreadCount ?? 0
        }
    }
    // =====================================================

    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        
        self._currentArticle = State(initialValue: article)
        self._currentSourceName = State(initialValue: sourceName)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // ==================== 修改点 1: 传递未读数 ====================
            // 将我们新计算的 `currentUnreadCount` 传递给 ArticleDetailView
            ArticleDetailView(
                article: currentArticle,
                sourceName: currentSourceName,
                unreadCount: currentUnreadCount, // <- 新增传递的参数
                viewModel: viewModel,
                requestNextArticle: {
                    self.switchToNextArticle()
                },
                requestPreviousArticle: {
                    self.switchToPreviousArticle()
                }
            )
            // =============================================================
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
        // ==================== 修改点 2: 移除旧的导航栏标题 ====================
        // .navigationTitle(currentSourceName) // <- 移除这一行
        // .navigationBarTitleDisplayMode(.inline) // <- 移除这一行
        // ===================================================================
        .onDisappear {
            readArticleIDsInThisSession.insert(currentArticle.id)
            
            for articleID in readArticleIDsInThisSession {
                viewModel.markAsRead(articleID: articleID)
            }
        }
        .onChange(of: currentArticle.id) { oldValue, newValue in
            readArticleIDsInThisSession.insert(oldValue)
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
