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
        VStack(alignment: .leading, spacing: 8) {
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
        // ==================== 核心修改 1: 减小卡片内部的垂直内边距 ====================
        // 将 .padding(16) 改为更精确的控制，减少上下边距，使卡片更薄
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        // ==========================================================================
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.viewBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}


// ==================== 优化后的 ArticleListView ====================
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
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
                                .padding(.vertical, 4)
                                .padding(.leading)
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
                            // ==================== 核心修改 2: 调整行间距，使其紧凑且一致 ====================
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            // ==========================================================================
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


// ==================== 优化后的 AllArticlesListView ====================
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @State private var filterMode: ArticleFilterMode = .unread
    
    private var filteredArticles: [(article: Article, sourceName: String)] {
        viewModel.sources.flatMap { source in
            source.articles
                .filter { filterMode == .unread ? !$0.isRead : $0.isRead }
                .map { (article: $0, sourceName: source.name) }
        }
    }
    private var groupedArticles: [String: [(article: Article, sourceName: String)]] {
        Dictionary(grouping: filteredArticles, by: { $0.article.timestamp })
    }
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted().reversed()
    }
    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }
    
    var body: some View {
        VStack {
            List {
                ForEach(sortedTimestamps, id: \.self) { timestamp in
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
                                .padding(.vertical, 4)
                                .padding(.leading)
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
                            // ==================== 核心修改 3: 减小行间距，与另一个列表统一 ====================
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            // ==========================================================================
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
