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
                ToastView(message: "该分组内已无更多文章")
            }
        }
        .onDisappear {
            // ==================== 修复点 2: 返回列表页时标记当前文章为已读 ====================
            // 先将当前正在查看的文章标记为本地已读
            markCurrentArticleAsReadLocally()
            
            // 然后批量提交所有已读状态到 ViewModel
            commitReadStatusToViewModel()
            // ===============================================================================
        }
        .background(Color.viewBackground.ignoresSafeArea())
    }

    // ==================== 核心修改: 分离本地状态管理和 ViewModel 更新 ====================
    /// 切换到下一篇文章的逻辑
    private func switchToNextArticle() {
        // 1. 将当前文章加入本地已读集合（不立即提交到 ViewModel）
        markCurrentArticleAsReadLocally()
        
        // 2. 寻找下一篇文章
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name): sourceNameToSearch = name
        case .fromAllArticles: sourceNameToSearch = nil
        }

        if let next = viewModel.findNextUnread(after: currentArticle.id,
                                               inSource: sourceNameToSearch) {
            
            // 检查是否已经在本次会话中读过这篇文章（防止无限循环）
            if readArticleIDsInThisSession.contains(next.article.id) {
                // 所有文章都读过了，提交状态并显示提示
                commitReadStatusToViewModel()
                showToast { shouldShow in self.showNoNextToast = shouldShow }
            } else {
                // 切换到下一篇文章
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.currentArticle = next.article
                    self.currentSourceName = next.sourceName
                }
            }
        } else {
            // 没有更多未读文章，提交状态并显示提示
            commitReadStatusToViewModel()
            showToast { shouldShow in self.showNoNextToast = shouldShow }
        }
    }
    
    // ==================== 新增: 本地状态管理方法 ====================
    /// 将当前文章标记为本地已读（不立即提交到 ViewModel）
    private func markCurrentArticleAsReadLocally() {
        let articleID = currentArticle.id
        
        // 防止重复处理
        if readArticleIDsInThisSession.contains(articleID) {
            print("文章已在本次会话中处理过，跳过: \(currentArticle.topic)")
            return
        }
        
        // 检查文章当前的已读状态
        guard let article = viewModel.sources.flatMap({ $0.articles }).first(where: { $0.id == articleID }) else {
            print("无法找到文章 ID: \(articleID)")
            return
        }
        
        // 只处理未读文章
        if !article.isRead {
            // 将文章添加到会话已读集合
            readArticleIDsInThisSession.insert(articleID)
            
            // 更新本地的未读计数显示
            if liveUnreadCount > 0 {
                liveUnreadCount -= 1
            }
            
            // ==================== 修复点 1: 实时更新 App 角标 ====================
            // 计算当前应该显示的全局未读数（原始未读数 - 本次会话已读数）
            let currentGlobalUnread = viewModel.totalUnreadCount - readArticleIDsInThisSession.count
            
            // 立即更新 App 角标
            if let badgeUpdater = viewModel.badgeUpdater {
                badgeUpdater(currentGlobalUnread)
                print("App 角标已更新为: \(currentGlobalUnread)")
            }
            // =====================================================================
            
            print("文章已加入本地已读集合: \(currentArticle.topic)")
            print("本地未读数: \(liveUnreadCount)")
            print("本次会话已读文章数: \(readArticleIDsInThisSession.count)")
        } else {
            print("文章已经是已读状态，跳过: \(currentArticle.topic)")
        }
    }
    
    /// 将本地已读状态批量提交到 ViewModel
    private func commitReadStatusToViewModel() {
        guard !readArticleIDsInThisSession.isEmpty else {
            print("没有需要提交的已读状态")
            return
        }
        
        print("开始提交已读状态到 ViewModel，共 \(readArticleIDsInThisSession.count) 篇文章")
        
        // 批量提交所有已读文章
        for articleID in readArticleIDsInThisSession {
            viewModel.markAsRead(articleID: articleID)
        }
        
        // 清空本地集合
        readArticleIDsInThisSession.removeAll()
        
        print("已读状态提交完成，全局未读数: \(viewModel.totalUnreadCount)")
    }
    // =============================================================================
    
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
