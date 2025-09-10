import SwiftUI

// ==================== 数据模型和枚举 ====================
enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

// ==================== 文章卡片视图 ====================
struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = sourceName {
                Text(name.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(article.topic)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(article.isRead ? .secondary : .primary)
                .lineLimit(3)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.viewBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}

// ==================== 单一来源列表 ====================
struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    // MARK: - 搜索状态
    @State private var searchText = ""
    @State private var isSearchActive = false
    
    private var filteredArticles: [Article] {
        let articlesByFilterMode = source.articles.filter { filterMode == .unread ? !$0.isRead : $0.isRead }
        
        if searchText.isEmpty {
            return articlesByFilterMode
        } else {
            return articlesByFilterMode.filter { $0.topic.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    private var groupedArticles: [String: [Article]] {
        Dictionary(grouping: filteredArticles, by: { $0.timestamp })
    }
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted()
    }
    private var unreadCount: Int { source.articles.filter { !$0.isRead }.count }
    private var readCount: Int { source.articles.filter { $0.isRead }.count }

    var body: some View {
        VStack {
            List {
                ForEach(sortedTimestamps, id: \.self) { timestamp in
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.vertical, 4)
                    ) {
                        ForEach(groupedArticles[timestamp] ?? []) { article in
                            NavigationLink(destination: ArticleContainerView(
                                article: article,
                                sourceName: source.name,
                                context: .fromSource(source.name),
                                viewModel: viewModel
                            )) {
                                ArticleRowCardView(article: article, sourceName: nil)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                if article.isRead {
                                    Button { viewModel.markAsUnread(articleID: article.id) }
                                    label: { Label("标记为未读", systemImage: "circle") }
                                } else {
                                    Button { viewModel.markAsRead(articleID: article.id) }
                                    label: { Label("标记为已读", systemImage: "checkmark.circle") }
                                    if filterMode == .unread {
                                        Divider()
                                        Button {
                                            viewModel.markAllAboveAsRead(articleID: article.id, inVisibleList: self.filteredArticles)
                                        }
                                        label: { Label("以上全部已读", systemImage: "arrow.up.to.line.compact") }
                                        
                                        Button {
                                            viewModel.markAllBelowAsRead(articleID: article.id, inVisibleList: self.filteredArticles)
                                        }
                                        label: { Label("以下全部已读", systemImage: "arrow.down.to.line.compact") }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle(source.name.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            // MARK: - 修改工具栏：只保留搜索按钮
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isSearchActive = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                }
            }
            
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? unreadCount : readCount
                    Text("\(mode.rawValue) (\(count))").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom])
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .searchable(text: $searchText, isPresented: $isSearchActive, placement: .navigationBarDrawer, prompt: "搜索文章标题")
    }
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}

// ==================== 所有文章列表 ====================
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @State private var filterMode: ArticleFilterMode = .unread
    
    // MARK: - 搜索状态
    @State private var searchText = ""
    @State private var isSearchActive = false
    
    private var filteredArticles: [(article: Article, sourceName: String)] {
        let articlesByFilterMode = viewModel.allArticlesSortedForDisplay.filter { item in
            filterMode == .unread ? !item.article.isRead : item.article.isRead
        }
        
        if searchText.isEmpty {
            return articlesByFilterMode
        } else {
            return articlesByFilterMode.filter { $0.article.topic.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    private var groupedArticles: [String: [(article: Article, sourceName: String)]] {
        Dictionary(grouping: filteredArticles, by: { $0.article.timestamp })
    }
    
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted()
    }
    
    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }
    
    var body: some View {
        VStack {
            List {
                ForEach(sortedTimestamps, id: \.self) { timestamp in
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.vertical, 4)
                    ) {
                        ForEach(groupedArticles[timestamp] ?? [], id: \.article.id) { item in
                            NavigationLink(destination: ArticleContainerView(
                                article: item.article,
                                sourceName: item.sourceName,
                                context: .fromAllArticles,
                                viewModel: viewModel
                            )) {
                                ArticleRowCardView(article: item.article, sourceName: item.sourceName)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                if item.article.isRead {
                                    Button { viewModel.markAsUnread(articleID: item.article.id) }
                                    label: { Label("标记为未读", systemImage: "circle") }
                                } else {
                                    Button { viewModel.markAsRead(articleID: item.article.id) }
                                    label: { Label("标记为已读", systemImage: "checkmark.circle") }
                                    if filterMode == .unread {
                                        Divider()
                                        Button {
                                            let visibleArticleList = self.filteredArticles.map { $0.article }
                                            viewModel.markAllAboveAsRead(articleID: item.article.id, inVisibleList: visibleArticleList)
                                        }
                                        label: { Label("以上全部已读", systemImage: "arrow.up.to.line.compact") }
                                        
                                        Button {
                                            let visibleArticleList = self.filteredArticles.map { $0.article }
                                            viewModel.markAllBelowAsRead(articleID: item.article.id, inVisibleList: visibleArticleList)
                                        }
                                        label: { Label("以下全部已读", systemImage: "arrow.down.to.line.compact") }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationBarTitleDisplayMode(.inline)
            // MARK: - 修改工具栏：只保留搜索按钮
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isSearchActive = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                }
            }
            
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? totalUnreadCount : totalReadCount
                    Text("\(mode.rawValue) (\(count))").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom])
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .searchable(text: $searchText, isPresented: $isSearchActive, placement: .navigationBarDrawer, prompt: "搜索文章标题")
    }
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}
