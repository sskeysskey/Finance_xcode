import SwiftUI

// ===== 新增 (1/4): 定义筛选模式 =====
// 为了代码清晰和可维护性，我们使用枚举来定义两种筛选模式
enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}
// ====================================

struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    // ===== 新增 (2/4): 添加状态变量 =====
    // @State 变量用于追踪当前视图的筛选模式，默认为 .unread
    @State private var filterMode: ArticleFilterMode = .unread
    // ====================================
    
    // ===== 新增 (3/4): 创建计算属性 =====
    // 这个计算属性会根据 filterMode 的值，返回筛选后的文章数组
    private var filteredArticles: [Article] {
        switch filterMode {
        case .unread:
            // 返回所有 isRead 为 false 的文章
            return source.articles.filter { !$0.isRead }
        case .read:
            // 返回所有 isRead 为 true 的文章
            return source.articles.filter { $0.isRead }
        }
    }
    // ====================================

    var body: some View {
        // ===== 修改 (4/4): 调整视图结构 =====
        // 使用 VStack 将列表和底部的筛选器包裹起来
        VStack {
            ScrollViewReader { proxy in
                List {
                    // 日期显示
                    Text(formattedDate())
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.top)
                        .listRowSeparator(.hidden)
                    
                    // 将 ForEach 的数据源从 source.articles 改为 filteredArticles
                    ForEach(filteredArticles) { article in
                        NavigationLink(destination: ArticleContainerView(
                            article: article,
                            sourceName: source.name,
                            context: .fromSource(source.name),
                            viewModel: viewModel
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(source.name)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text(article.topic)
                                    .fontWeight(.semibold)
                                    .foregroundColor(article.isRead ? .gray : .primary)
                            }
                            .padding(.vertical, 8)
                            .contextMenu {
                                if article.isRead {
                                    Button {
                                        viewModel.markAsUnread(articleID: article.id)
                                    } label: {
                                        Label("标记为未读", systemImage: "circle")
                                    }
                                } else {
                                    Button {
                                        viewModel.markAsRead(articleID: article.id)
                                    } label: {
                                        Label("标记为已读", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                        .id(article.id)
                    }
                }
                .listStyle(PlainListStyle())
                .navigationTitle("Unread")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    if let lastID = viewModel.lastViewedArticleID {
                        // 只有当上次查看的文章存在于当前筛选列表时，滚动才有意义
                        if filteredArticles.contains(where: { $0.id == lastID }) {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            // ===== 新增: 底部筛选器 =====
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            // ============================
        }
        // ====================================
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        
        if Calendar.current.isDateInToday(Date()) {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return "TODAY, \(formatter.string(from: Date()).uppercased())"
        } else if Calendar.current.isDateInYesterday(Date()) {
            return "YESTERDAY"
        } else {
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            return formatter.string(from: Date()).uppercased()
        }
    }
}

struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    
    // ===== 新增 (与 ArticleListView 相同的逻辑) =====
    @State private var filterMode: ArticleFilterMode = .unread
    // ===============================================
    
    var body: some View {
        // ===== 修改: 调整视图结构 =====
        VStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(viewModel.sources) { source in
                        // 在遍历文章前，先根据筛选模式过滤
                        let articlesToDisplay = source.articles.filter { article in
                            switch filterMode {
                            case .unread:
                                return !article.isRead
                            case .read:
                                return article.isRead
                            }
                        }
                        
                        // 只有当筛选后仍有文章时，才显示该来源下的内容
                        if !articlesToDisplay.isEmpty {
                            ForEach(articlesToDisplay) { article in
                                NavigationLink(destination: ArticleContainerView(
                                    article: article,
                                    sourceName: source.name,
                                    context: .fromAllArticles,
                                    viewModel: viewModel
                                )) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(source.name)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Text(article.topic)
                                            .fontWeight(.semibold)
                                            .foregroundColor(article.isRead ? .gray : .primary)
                                    }
                                    .padding(.vertical, 8)
                                    .contextMenu {
                                        if article.isRead {
                                            Button {
                                                viewModel.markAsUnread(articleID: article.id)
                                            } label: {
                                                Label("标记为未读", systemImage: "circle")
                                            }
                                        } else {
                                            Button {
                                                viewModel.markAsRead(articleID: article.id)
                                            } label: {
                                                Label("标记为已读", systemImage: "checkmark.circle")
                                            }
                                        }
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .id(article.id)
                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    if let lastID = viewModel.lastViewedArticleID {
                        // 同样，检查 lastID 是否存在于当前筛选结果中
                        let allFilteredArticles = viewModel.sources.flatMap { $0.articles }.filter {
                            filterMode == .unread ? !$0.isRead : $0.isRead
                        }
                        if allFilteredArticles.contains(where: { $0.id == lastID }) {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            // ===== 新增: 底部筛选器 (与 ArticleListView 相同) =====
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            // ===================================================
        }
        // ====================================
    }
}
