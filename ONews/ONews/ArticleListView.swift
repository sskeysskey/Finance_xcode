import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    private var filteredArticles: [Article] {
        switch filterMode {
        case .unread:
            // 为了保证每次都是最新的未读列表，并且顺序正确，我们最好在这里也排序
            // 假设文章没有明确的时间戳，我们可以按主题排序作为示例
            return source.articles.filter { !$0.isRead }.sorted { $0.topic < $1.topic }
        case .read:
            return source.articles.filter { $0.isRead }.sorted { $0.topic < $1.topic }
        }
    }
    
    private var unreadCount: Int {
        source.articles.filter { !$0.isRead }.count
    }
    
    private var readCount: Int {
        source.articles.filter { $0.isRead }.count
    }

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                List {
                    Text(formattedDate())
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.top)
                        .listRowSeparator(.hidden)
                    
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
                // ===== 新增修改 (1/1) =====
                // 监听 filterMode 的变化
                .onChange(of: filterMode) {
                    // 当切换到 "Unread" 模式时
                    if filterMode == .unread {
                        // 找到当前已过滤（即未读）文章列表中的第一篇
                        if let firstArticleID = filteredArticles.first?.id {
                            // 使用 proxy 将列表滚动到该文章的位置，并添加动画
                            withAnimation {
                                proxy.scrollTo(firstArticleID, anchor: .top)
                            }
                        }
                    }
                }
                // ===========================
            }
            
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? unreadCount : readCount
                    Text("\(mode.rawValue) (\(count))")
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
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

// AllArticlesListView 保持不变，但为了完整性，我们也将对其进行同样的修改
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    // ===== 新增 (与 ArticleListView 类似的逻辑) =====
    private var totalUnreadCount: Int {
        viewModel.sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
    
    private var totalReadCount: Int {
        viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count
    }
    
    // ===== 新增 (2/2): 计算过滤后的文章列表 =====
    private var filteredArticles: [(source: NewsSource, article: Article)] {
        let allArticles = viewModel.sources.flatMap { source in
            source.articles.map { (source: source, article: $0) }
        }
        
        switch filterMode {
        case .unread:
            return allArticles.filter { !$0.article.isRead }.sorted { $0.article.topic < $1.article.topic }
        case .read:
            return allArticles.filter { $0.article.isRead }.sorted { $0.article.topic < $1.article.topic }
        }
    }
    // ==============================================
    
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                List {
                    // 使用我们新计算的 filteredArticles 属性
                    ForEach(filteredArticles, id: \.article.id) { item in
                        NavigationLink(destination: ArticleContainerView(
                            article: item.article,
                            sourceName: item.source.name,
                            context: .fromAllArticles,
                            viewModel: viewModel
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.source.name)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text(item.article.topic)
                                    .fontWeight(.semibold)
                                    .foregroundColor(item.article.isRead ? .gray : .primary)
                            }
                            .padding(.vertical, 8)
                            .contextMenu {
                                if item.article.isRead {
                                    Button {
                                        viewModel.markAsUnread(articleID: item.article.id)
                                    } label: {
                                        Label("标记为未读", systemImage: "circle")
                                    }
                                } else {
                                    Button {
                                        viewModel.markAsRead(articleID: item.article.id)
                                    } label: {
                                        Label("标记为已读", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                        .id(item.article.id)
                    }
                }
                .listStyle(PlainListStyle())
                .navigationBarTitleDisplayMode(.inline)
                // ===== 新增修改 (与 ArticleListView 相同) =====
                .onChange(of: filterMode) {
                    if filterMode == .unread {
                        // 从所有文章的过滤结果中找到第一篇
                        if let firstItemID = filteredArticles.first?.article.id {
                            withAnimation {
                                proxy.scrollTo(firstItemID, anchor: .top)
                            }
                        }
                    }
                }
                // =============================================
            }
            
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? totalUnreadCount : totalReadCount
                    Text("\(mode.rawValue) (\(count))")
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}
