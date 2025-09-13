import SwiftUI

// ==================== 数据模型和枚举 ====================
enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

// 公共：搜索输入视图（在导航栏下方显示）
private struct SearchBarInline: View {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索标题关键字", text: $text, onCommit: onCommit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)

            if !text.isEmpty {
                Button("搜索") { onCommit() }
                    .buttonStyle(.borderedProminent)
            }

            Button("取消") {
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
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

    // 搜索相关状态
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false   // 表示当前是否显示搜索结果

    private var filteredArticles: [Article] {
        source.articles.filter { filterMode == .unread ? !$0.isRead : $0.isRead }
    }
    private var groupedArticles: [String: [Article]] {
        Dictionary(grouping: filteredArticles, by: { $0.timestamp })
    }
    private var sortedTimestamps: [String] {
        groupedArticles.keys.sorted()
    }
    private var unreadCount: Int { source.articles.filter { !$0.isRead }.count }
    private var readCount: Int { source.articles.filter { $0.isRead }.count }

    // 搜索过滤（针对当前 filterMode 的可见集合）
    private var searchResults: [Article] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return filteredArticles.filter { $0.topic.lowercased().contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                SearchBarInline(
                    text: $searchText,
                    onCommit: {
                        isSearchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    },
                    onCancel: {
                        withAnimation {
                            isSearching = false
                            isSearchActive = false
                            searchText = ""
                        }
                    }
                )
            }

            List {
                if isSearchActive {
                    Section(header:
                                Text("搜索结果")
                        .font(.headline)
                        .foregroundColor(.blue.opacity(0.7))
                        .padding(.vertical, 4)
                    ) {
                        if searchResults.isEmpty {
                            Text("未找到匹配的文章")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(searchResults) { article in
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
                } else {
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
            }
            .listStyle(PlainListStyle())
            .navigationTitle(source.name.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            isSearching.toggle()
                            if !isSearching {
                                // 退出搜索模式
                                isSearchActive = false
                                searchText = ""
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                }
            }
            
            // 仅非搜索结果时显示筛选器
            if !isSearchActive {
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

// ==================== 所有文章列表 ====================
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @State private var filterMode: ArticleFilterMode = .unread

    // 搜索相关状态
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false

    private var filteredArticles: [(article: Article, sourceName: String)] {
        viewModel.allArticlesSortedForDisplay.filter { item in
            filterMode == .unread ? !item.article.isRead : item.article.isRead
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

    // 搜索过滤（针对当前 filterMode 的可见集合）
    private var searchResults: [(article: Article, sourceName: String)] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return filteredArticles.filter { $0.article.topic.lowercased().contains(keyword) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                SearchBarInline(
                    text: $searchText,
                    onCommit: {
                        isSearchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    },
                    onCancel: {
                        withAnimation {
                            isSearching = false
                            isSearchActive = false
                            searchText = ""
                        }
                    }
                )
            }

            List {
                if isSearchActive {
                    Section(header:
                                Text("搜索结果")
                        .font(.headline)
                        .foregroundColor(.blue.opacity(0.7))
                        .padding(.vertical, 4)
                    ) {
                        if searchResults.isEmpty {
                            Text("未找到匹配的文章")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(searchResults, id: \.article.id) { item in
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
                } else {
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
            }
            .listStyle(PlainListStyle())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            isSearching.toggle()
                            if !isSearching {
                                isSearchActive = false
                                searchText = ""
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                }
            }
            
            if !isSearchActive {
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
