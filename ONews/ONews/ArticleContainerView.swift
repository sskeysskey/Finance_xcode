import SwiftUI

/// 一个容器视图，管理当前文章的显示和切换逻辑
struct ArticleContainerView: View {
    // 从列表页传入的初始文章和上下文信息
    let initialArticle: Article
    let navigationContext: NavigationContext // 标记是从哪里来的
    
    @ObservedObject var viewModel: NewsViewModel
    
    // 使用 @State 来管理当前正在显示的文章
    @State private var currentArticle: Article
    @State private var currentSourceName: String
    
    // 控制提示信息的显示状态
    @State private var showToast = false

    // 定义导航上下文，以区分不同的文章列表
    enum NavigationContext {
        case fromSource(String) // 来自特定来源，值为来源名称
        case fromAllArticles      // 来自“所有文章”列表
    }

    // 自定义初始化方法
    init(article: Article, sourceName: String, context: NavigationContext, viewModel: NewsViewModel) {
        self.initialArticle = article
        self.navigationContext = context
        self.viewModel = viewModel
        
        // 使用 State 的初始值包装器来设置初始状态
        self._currentArticle = State(initialValue: article)
        self._currentSourceName = State(initialValue: sourceName)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 核心内容：文章详情页
            ArticleDetailView(
                article: currentArticle,
                sourceName: currentSourceName,
                viewModel: viewModel,
                // 传递一个闭包作为请求下一篇的回调
                requestNextArticle: {
                    self.switchToNextArticle()
                }
            )
            .id(currentArticle.id) // 使用 .id() 来确保当 currentArticle 改变时，整个 DetailView 被重新创建，触发动画
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
            )

            // 如果需要显示提示，则在底部显示
            if showToast {
                Text("该分组内已无未阅读的文章存在了")
                    .font(.subheadline)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.bottom, 50)
                    .transition(.opacity.animation(.easeInOut))
            }
        }
        .navigationTitle(currentSourceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 切换到下一篇文章的逻辑
    private func switchToNextArticle() {
        let sourceNameToSearch: String?
        switch navigationContext {
        case .fromSource(let name):
            sourceNameToSearch = name
        case .fromAllArticles:
            sourceNameToSearch = nil
        }

        // 调用 ViewModel 查找下一篇文章
        if let next = viewModel.findNextArticle(after: currentArticle.id, inSource: sourceNameToSearch) {
            // 如果找到了，用动画更新当前文章状态
            withAnimation(.easeInOut(duration: 0.5)) {
                self.currentArticle = next.article
                self.currentSourceName = next.sourceName
            }
        } else {
            // 如果没找到，显示提示信息
            withAnimation {
                showToast = true
            }
            // 2秒后自动隐藏提示
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showToast = false
                }
            }
        }
    }
}
