import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

// ==================== 核心修改: 列表视图增加日期分组 ====================
struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    // 1. 先过滤出已读/未读文章
    private var filteredArticles: [Article] {
        source.articles.filter {
            filterMode == .unread ? !$0.isRead : $0.isRead
        }
    }
    
    // 2. 将过滤后的文章按时间戳分组
    private var groupedArticles: [String: [Article]] {
        Dictionary(grouping: filteredArticles, by: { $0.timestamp })
    }
    
    // 3. 获取所有时间戳并倒序排序，作为 Section 的 key
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted().reversed()
    }
    
    private var unreadCount: Int { source.articles.filter { !$0.isRead }.count }
    private var readCount: Int { source.articles.filter { $0.isRead }.count }

    var body: some View {
        VStack {
            // 4. 使用新的分组数据结构来构建 List
            List {
                ForEach(sortedTimestamps, id: \.self) { timestamp in
                    // 每个时间戳是一个 Section
                    Section(header: Text(formatTimestamp(timestamp))
                                .font(.headline)
                                .padding(.vertical, 4)
                    ) {
                        // Section 内部是该日期的文章列表
                        ForEach(groupedArticles[timestamp] ?? []) { article in
                            NavigationLink(destination: ArticleContainerView(
                                article: article,
                                sourceName: source.name,
                                context: .fromSource(source.name),
                                viewModel: viewModel
                            )) {
                                VStack(alignment: .leading, spacing: 8) {
                                    // 来源名称可以省略，因为已经在标题里了
                                    // Text(source.name).font(.caption).foregroundColor(.gray)
                                    Text(article.topic)
                                        .fontWeight(.semibold)
                                        .foregroundColor(article.isRead ? .gray : .primary)
                                }
                                .padding(.vertical, 8)
                                .contextMenu {
                                    // ContextMenu 逻辑不变
                                    if article.isRead {
                                        Button { viewModel.markAsUnread(articleID: article.id) }
                                        label: { Label("标记为未读", systemImage: "circle") }
                                    } else {
                                        Button { viewModel.markAsRead(articleID: article.id) }
                                        label: { Label("标记为已读", systemImage: "checkmark.circle") }
                                    }
                                }
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle(source.name.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            
            // Picker 逻辑不变
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? unreadCount : readCount
                    Text("\(mode.rawValue) (\(count))").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom])
        }
    }
    
    // 辅助函数：将 "250704" 格式化为 "2025年7月4日"
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else {
            return timestamp // 如果格式不符，直接返回原始字符串
        }
        
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}

struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @State private var filterMode: ArticleFilterMode = .unread
    
    // 1. 过滤所有来源的文章
    private var filteredArticles: [(article: Article, sourceName: String)] {
        viewModel.sources.flatMap { source in
            source.articles
                .filter { filterMode == .unread ? !$0.isRead : $0.isRead }
                .map { (article: $0, sourceName: source.name) }
        }
    }
    
    // 2. 按时间戳分组
    private var groupedArticles: [String: [(article: Article, sourceName: String)]] {
        Dictionary(grouping: filteredArticles, by: { $0.article.timestamp })
    }
    
    // 3. 获取并排序时间戳
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted().reversed()
    }
    
    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }
    
    var body: some View {
        VStack {
            // 4. 使用分组数据构建 List
            List {
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
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.sourceName.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text(item.article.topic)
                                        .fontWeight(.semibold)
                                        .foregroundColor(item.article.isRead ? .gray : .primary)
                                }
                                .padding(.vertical, 8)
                                .contextMenu {
                                    if item.article.isRead {
                                        Button { viewModel.markAsUnread(articleID: item.article.id) }
                                        label: { Label("标记为未读", systemImage: "circle") }
                                    } else {
                                        Button { viewModel.markAsRead(articleID: item.article.id) }
                                        label: { Label("标记为已读", systemImage: "checkmark.circle") }
                                    }
                                }
                            }
                            .listRowSeparator(.hidden)
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
    }
    
    // 辅助函数：格式化时间戳
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}
// =========================================================================
