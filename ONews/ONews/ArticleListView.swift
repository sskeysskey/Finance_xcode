import SwiftUI

// ==================== 数据模型和枚举 (无变化) ====================
enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

// ==================== 核心新增: 文章卡片视图 ====================
struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String?

    var body: some View {
        // ==================== 核心修改: 减小 VStack 内部的间距 ====================
        // 将 VStack 的 spacing 从 8 改为 4，以减小来源和标题之间的垂直距离
        VStack(alignment: .leading, spacing: 4) {
        // ==========================================================================
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


// ==================== 优化后的 ArticleListView (无变化) ====================
struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    private var filteredArticles: [Article] {
        source.articles.filter { filterMode == .unread ? !$0.isRead : $0.isRead }
    }
    private var groupedArticles: [String: [Article]] {
        Dictionary(grouping: filteredArticles, by: { $0.timestamp })
    }
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted().reversed()
    }
    private var unreadCount: Int { source.articles.filter { !$0.isRead }.count }
    private var readCount: Int { source.articles.filter { $0.isRead }.count }

    var body: some View {
        VStack {
            List {
                ForEach(sortedTimestamps, id: \.self) { timestamp in
                    // ==================== 修改点 ====================
                    // 移除了 .padding(.leading)，让 List 自动处理 Header 和 Row 的对齐
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
                                .padding(.vertical, 4)
                                // .padding(.leading) // <-- 此行已被移除
                    ) {
                    // ===============================================
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
                                        Button { viewModel.markAllAboveAsRead(articleID: article.id, inSource: source.name) }
                                        label: { Label("以上全部已读", systemImage: "arrow.up.to.line.compact") }
                                        Button { viewModel.markAllBelowAsRead(articleID: article.id, inSource: source.name) }
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


// ==================== 优化后的 AllArticlesListView (有修改) ====================
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @State private var filterMode: ArticleFilterMode = .unread
    
    // ==================== 核心修改: 直接使用 ViewModel 中排好序的列表 ====================
    private var filteredArticles: [(article: Article, sourceName: String)] {
        // 直接从 viewModel 获取权威、排序好的列表，然后根据 filterMode 过滤
        viewModel.allArticlesSortedForDisplay.filter { item in
            filterMode == .unread ? !item.article.isRead : item.article.isRead
        }
    }
    // =================================================================================
    
    // Grouping logic remains the same, but now operates on the correctly sorted data
    private var groupedArticles: [String: [(article: Article, sourceName: String)]] {
        Dictionary(grouping: filteredArticles, by: { $0.article.timestamp })
    }
    
    // Sorting of timestamps is still needed for section headers
    private var sortedTimestamps: [String] {
        // 注意：因为 viewModel.allArticlesSortedForDisplay 已经是降序了，
        // 所以这里的 keys 顺序可能不是严格的降序。我们必须重新排序。
        groupedArticles.keys.sorted().reversed()
    }
    
    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }
    
    var body: some View {
        VStack {
            List {
                // The rest of the view body remains exactly the same
                ForEach(sortedTimestamps, id: \.self) { timestamp in
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
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
                                        Button { viewModel.markAllAboveAsRead(articleID: item.article.id, inSource: nil) }
                                        label: { Label("以上全部已读", systemImage: "arrow.up.to.line.compact") }
                                        Button { viewModel.markAllBelowAsRead(articleID: item.article.id, inSource: nil) }
                                        label: { Label("以下全部已读", systemImage: "arrow.down.to.line.compact") }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle(filterMode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            
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
