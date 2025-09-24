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

    // 焦点绑定
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索标题关键字", text: $text, onCommit: onCommit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .focused($isFocused)
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
                // 取消时顺便收起键盘
                isFocused = false
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear {
            // 出现时自动聚焦
            DispatchQueue.main.async {
                self.isFocused = true
            }
        }
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
    
    // 新增：用于跟踪展开的日期分区
    @State private var expandedTimestamps: Set<String> = []

    // 搜索相关状态
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false   // 表示当前是否显示搜索结果

    // 基础过滤（仅按已读/未读）----用于非搜索态
    private var baseFilteredArticles: [Article] {
        source.articles.filter { filterMode == .unread ? !$0.isRead : $0.isRead }
    }

    // 分组（通用，用于非搜索和搜索）
    private func groupedByTimestamp(_ articles: [Article]) -> [String: [Article]] {
        let initial = Dictionary(grouping: articles, by: { $0.timestamp })
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }

    // 非搜索态分组
    private var groupedArticles: [String: [Article]] {
        groupedByTimestamp(baseFilteredArticles)
    }

    // Section 的日期顺序：已读时降序，未读时升序（通用）
    private func sortedTimestamps(for groups: [String: [Article]]) -> [String] {
        if filterMode == .read {
            return groups.keys.sorted(by: >)
        } else {
            return groups.keys.sorted(by: <)
        }
    }

    // 用于上下文菜单“以上/以下全部已读”的可见列表（非搜索态使用）
    private var filteredArticles: [Article] {
        baseFilteredArticles
    }

    private var unreadCount: Int { source.articles.filter { !$0.isRead }.count }
    private var readCount: Int { source.articles.filter { $0.isRead }.count }

    // 搜索过滤（不受当前 filterMode 限制，合并已读+未读）
    private var searchResults: [Article] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 合并两类
        return source.articles.filter { $0.topic.lowercased().contains(keyword) }
    }

    // 搜索态分组（固定为最新在前）
    private func groupedSearchByTimestamp() -> [String: [Article]] {
        var initial = Dictionary(grouping: searchResults, by: { $0.timestamp })
        // 每个分组内也按“最新在前”排序：假设 source.articles 原本按时间升序，这里反转
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

    // 搜索态的时间戳顺序：固定为降序（最新在前）
    private func sortedSearchTimestamps(for groups: [String: [Article]]) -> [String] {
        return groups.keys.sorted(by: >)
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
                    // 搜索结果区域保持不变，默认全部展开
                    let grouped = groupedSearchByTimestamp()
                    let timestamps = sortedSearchTimestamps(for: grouped)

                    if searchResults.isEmpty {
                        Section {
                            Text("未找到匹配的文章")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .listRowBackground(Color.clear)
                        } header: {
                            Text("搜索结果")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.vertical, 4)
                        }
                    } else {
                        ForEach(timestamps, id: \.self) { timestamp in
                            Section(header:
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("搜索结果")
                                                .font(.subheadline)
                                                .foregroundColor(.blue.opacity(0.7))
                                            // ==================== 修改点 1/4 ====================
                                            // 在搜索结果的日期右侧添加文章数量
                                            Text("\(formatTimestamp(timestamp)) \(grouped[timestamp]?.count ?? 0)")
                                                .font(.headline)
                                                .foregroundColor(.blue.opacity(0.85))
                                        }
                                        .padding(.vertical, 4)
                            ) {
                                ForEach(grouped[timestamp] ?? []) { article in
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
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // 非搜索结果区域，实现折叠功能
                    let timestamps = sortedTimestamps(for: groupedArticles)
                    ForEach(timestamps, id: \.self) { timestamp in
                        Section {
                            // 修改：仅当分区展开时才显示内容
                            if !expandedTimestamps.contains(timestamp) {
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
                        } header: {
                            // 修改：将Header转换为可点击的HStack，并添加折叠图标
                            HStack {
                                // ==================== 修改点 2/4 ====================
                                // 在非搜索模式的日期右侧添加文章数量
                                Text("\(formatTimestamp(timestamp)) \(groupedArticles[timestamp]?.count ?? 0)")
                                    .font(.headline)
                                    .foregroundColor(.blue.opacity(0.7))
                                Spacer()
                                Image(systemName: expandedTimestamps.contains(timestamp) ? "chevron.down" : "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.footnote.weight(.semibold))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle()) // 使整个HStack区域都可点击
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedTimestamps.contains(timestamp) {
                                        expandedTimestamps.remove(timestamp)
                                    } else {
                                        expandedTimestamps.insert(timestamp)
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

    // 新增：用于跟踪展开的日期分区（默认全部折叠）
    @State private var expandedTimestamps: Set<String> = []

    // 基础过滤（仅按已读/未读）----用于非搜索态
    private var baseFilteredArticles: [(article: Article, sourceName: String)] {
        viewModel.allArticlesSortedForDisplay.filter { item in
            filterMode == .unread ? !item.article.isRead : item.article.isRead
        }
    }

    // 分组（通用）----用于非搜索态
    private func groupedByTimestamp(_ items: [(article: Article, sourceName: String)]) -> [String: [(article: Article, sourceName: String)]] {
        let initial = Dictionary(grouping: items, by: { $0.article.timestamp })
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }

    // 非搜索态分组
    private var groupedArticles: [String: [(article: Article, sourceName: String)]] {
        groupedByTimestamp(baseFilteredArticles)
    }

    // Section 顺序（未读升序、已读降序）
    private func sortedTimestamps(for groups: [String: [(article: Article, sourceName: String)]]) -> [String] {
        if filterMode == .read {
            return groups.keys.sorted(by: >)
        } else {
            return groups.keys.sorted(by: <)
        }
    }

    // 用于上下文菜单“以上/以下全部已读”的可见列表（非搜索态使用）
    private var filteredArticles: [(article: Article, sourceName: String)] {
        baseFilteredArticles
    }

    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }

    // 搜索过滤（全量，合并已读+未读）
    private var searchResults: [(article: Article, sourceName: String)] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.allArticlesSortedForDisplay.filter { $0.article.topic.lowercased().contains(keyword) }
    }

    // 搜索态分组（固定为最新在前）
    private func groupedSearchByTimestamp() -> [String: [(article: Article, sourceName: String)]] {
        var initial = Dictionary(grouping: searchResults, by: { $0.article.timestamp })
        // 每个分组内按最新在前
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

    // 搜索态的时间戳顺序：固定为降序（最新在前）
    private func sortedSearchTimestamps(for groups: [String: [(article: Article, sourceName: String)]]) -> [String] {
        return groups.keys.sorted(by: >)
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
                    // 搜索结果按日期分组显示（固定最新在上）
                    let grouped = groupedSearchByTimestamp()
                    let timestamps = sortedSearchTimestamps(for: grouped)

                    if searchResults.isEmpty {
                        Section {
                            Text("未找到匹配的文章")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .listRowBackground(Color.clear)
                        } header: {
                            Text("搜索结果")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.vertical, 4)
                        }
                    } else {
                        ForEach(timestamps, id: \.self) { timestamp in
                            Section(header:
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("搜索结果")
                                                .font(.subheadline)
                                                .foregroundColor(.blue.opacity(0.7))
                                            // ==================== 修改点 3/4 ====================
                                            // 在搜索结果的日期右侧添加文章数量
                                            Text("\(formatTimestamp(timestamp)) \(grouped[timestamp]?.count ?? 0)")
                                                .font(.headline)
                                                .foregroundColor(.blue.opacity(0.85))
                                        }
                                        .padding(.vertical, 4)
                            ) {
                                ForEach(grouped[timestamp] ?? [], id: \.article.id) { item in
                                    NavigationLink(destination: ArticleContainerView(
                                        article: item.article,
                                        sourceName: item.sourceName,
                                        context: .fromAllArticles,
                                        viewModel: viewModel
                                    )) {
                                        // 行视图会自动根据 isRead 设置颜色：未读主色、已读灰色
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
                                        }
                                        // 搜索态下不显示“以上/以下全部已读”
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // 非搜索态：支持折叠
                    let timestamps = sortedTimestamps(for: groupedArticles)
                    ForEach(timestamps, id: \.self) { timestamp in
                        Section {
                            if !expandedTimestamps.contains(timestamp) {
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
                        } header: {
                            HStack {
                                // ==================== 修改点 4/4 ====================
                                // 在非搜索模式的日期右侧添加文章数量
                                Text("\(formatTimestamp(timestamp)) \(groupedArticles[timestamp]?.count ?? 0)")
                                    .font(.headline)
                                    .foregroundColor(.blue.opacity(0.7))
                                Spacer()
                                Image(systemName: expandedTimestamps.contains(timestamp) ? "chevron.down" : "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.footnote.weight(.semibold))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedTimestamps.contains(timestamp) {
                                        expandedTimestamps.remove(timestamp)
                                    } else {
                                        expandedTimestamps.insert(timestamp)
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
