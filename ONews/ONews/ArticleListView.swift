import SwiftUI

// ==================== 数据模型和枚举 (无变化) ====================
enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

// ==================== 核心新增: 文章卡片视图 ====================
// (将上面步骤1的代码放在这里)
struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String? // 来源名称是可选的，因为在单个来源列表中不需要显示

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 如果来源名称存在，则显示它
            if let name = sourceName {
                Text(name.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary) // 使用 .secondary 颜色，更柔和
            }
            
            // 文章标题
            Text(article.topic)
                .font(.headline) // 使用 .headline 增加标题的权重
                .fontWeight(.semibold)
                .foregroundColor(article.isRead ? .secondary : .primary) // 已读文章颜色变灰
                .lineLimit(3) // 限制标题最多显示3行
        }
        .padding() // 关键：在卡片内部创建呼吸空间
        .frame(maxWidth: .infinity, alignment: .leading) // 让卡片撑满宽度
        .background(Color(.systemBackground)) // 使用系统背景色，以支持深色/浅色模式
        .cornerRadius(12) // 给卡片添加圆角
        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2) // 添加一层细微的阴影，增加立体感
    }
}


// ==================== 优化后的 ArticleListView ====================
struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    
    @State private var filterMode: ArticleFilterMode = .unread
    
    // 数据处理逻辑保持不变
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
                                .padding(.leading) // 给 Section 标题也增加一点边距
                    ) {
                        ForEach(groupedArticles[timestamp] ?? []) { article in
                            NavigationLink(destination: ArticleContainerView(
                                article: article,
                                sourceName: source.name,
                                context: .fromSource(source.name),
                                viewModel: viewModel
                            )) {
                                // MARK: 这里是关键改动，使用新的卡片视图
                                ArticleRowCardView(article: article, sourceName: nil)
                            }
                            // MARK: 优化行间距和样式
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)) // 设置卡片与屏幕边缘的间距
                            .listRowSeparator(.hidden) // 隐藏默认的分割线
                            .listRowBackground(Color.clear) // 将列表行的背景设为透明，让卡片的阴影可见
                            .contextMenu {
                                // ContextMenu 逻辑保持不变
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
            .listStyle(PlainListStyle()) // 继续使用 PlainListStyle 以移除 Section 的默认背景
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
        .background(Color(.systemGroupedBackground)) // 给整个视图一个分组背景色，更好地衬托卡片
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
    
    // 数据处理逻辑保持不变
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
                                // MARK: 这里是关键改动，使用新的卡片视图
                                ArticleRowCardView(article: item.article, sourceName: item.sourceName)
                            }
                            // MARK: 优化行间距和样式 (与 ArticleListView 相同)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                // ContextMenu 逻辑保持不变
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
            
            // Picker 逻辑不变
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    let count = (mode == .unread) ? totalUnreadCount : totalReadCount
                    Text("\(mode.rawValue) (\(count))").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom])
        }
        .background(Color(.systemGroupedBackground)) // 给整个视图一个分组背景色
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
