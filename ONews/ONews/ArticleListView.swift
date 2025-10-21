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
                    .buttonStyle(.bordered) // 【修改】将 .buttonStyle(.bordered) 从取消按钮移到这里
            }

            Button("取消") {
                onCancel()
                // 取消时顺便收起键盘
                isFocused = false
            }
            // 【修改】移除这里的 .buttonStyle(.bordered)
            // .buttonStyle(.bordered)
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
    let isReadEffective: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = sourceName {
                Text(name.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(article.topic)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isReadEffective ? .secondary : .primary)
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
    // 【新增】接收从 SourceListView 传递过来的 resourceManager
    @ObservedObject var resourceManager: ResourceManager

    @State private var filterMode: ArticleFilterMode = .unread
    
    @State private var expandedTimestamps: Set<String> = []

    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
    // 【新增】用于显示错误弹窗的状态
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    // 基础过滤（仅按已读/未读）----用于非搜索态
    private var baseFilteredArticles: [Article] {
        source.articles.filter { article in
            let isReadEff = viewModel.isArticleEffectivelyRead(article)
            return (filterMode == .unread) ? !isReadEff : isReadEff
        }
    }

    private func groupedByTimestamp(_ articles: [Article]) -> [String: [Article]] {
        let initial = Dictionary(grouping: articles, by: { $0.timestamp })
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }

    private var groupedArticles: [String: [Article]] {
        groupedByTimestamp(baseFilteredArticles)
    }

    private func sortedTimestamps(for groups: [String: [Article]]) -> [String] {
        if filterMode == .read {
            return groups.keys.sorted(by: >)
        } else {
            return groups.keys.sorted(by: <)
        }
    }

    private var filteredArticles: [Article] {
        baseFilteredArticles
    }

    private var unreadCount: Int {
        source.articles.filter { !$0.isRead }.count
    }
    private var readCount: Int {
        source.articles.filter { $0.isRead }.count
    }

    // 搜索过滤（不受当前 filterMode 限制，合并已读+未读）
    private var searchResults: [Article] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source.articles.filter { $0.topic.lowercased().contains(keyword) }
    }

    private func groupedSearchByTimestamp() -> [String: [Article]] {
        var initial = Dictionary(grouping: searchResults, by: { $0.timestamp })
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

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
                        resetExpandedState()
                    }
                )
            }

            List {
                if isSearchActive {
                    // ... 搜索部分代码保持不变
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
                                        ArticleRowCardView(
                                            article: article,
                                            sourceName: nil,
                                            isReadEffective: viewModel.isArticleEffectivelyRead(article)
                                        )
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
                    let timestamps = sortedTimestamps(for: groupedArticles)
                    ForEach(timestamps, id: \.self) { timestamp in
                        Section {
                            if expandedTimestamps.contains(timestamp) {
                                ForEach(groupedArticles[timestamp] ?? []) { article in
                                    NavigationLink(destination: ArticleContainerView(
                                        article: article,
                                        sourceName: source.name,
                                        context: .fromSource(source.name),
                                        viewModel: viewModel
                                    )) {
                                        ArticleRowCardView(
                                            article: article,
                                            sourceName: nil,
                                            isReadEffective: viewModel.isArticleEffectivelyRead(article)
                                        )
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
                            HStack(spacing: 8) {
                                Text(formatTimestamp(timestamp))
                                    .font(.headline)
                                    .foregroundColor(.blue.opacity(0.7))

                                Spacer(minLength: 8)

                                Text("\(groupedArticles[timestamp]?.count ?? 0)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

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
            .onAppear(perform: resetExpandedState)
            .onChange(of: filterMode) { _, _ in
                resetExpandedState()
            }
            .navigationTitle(source.name.replacingOccurrences(of: "_", with: " "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 【新增】刷新按钮
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await syncResources(isManual: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(resourceManager.isSyncing)
                    .accessibilityLabel("刷新")
                }
                
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
        // 【新增】错误提示弹窗
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }

    private func resetExpandedState() {
        let timestamps = sortedTimestamps(for: groupedArticles)
        if timestamps.count == 1 {
            self.expandedTimestamps = Set(timestamps)
        } else {
            self.expandedTimestamps = []
        }
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
    
    // 【新增】从 SourceListView 复制过来的刷新函数
    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
        } catch {
            if isManual {
                switch error {
                case is DecodingError:
                    self.errorMessage = "数据解析失败，请稍后重试。"
                    self.showErrorAlert = true
                case let urlError as URLError where
                    urlError.code == .cannotConnectToHost ||
                    urlError.code == .timedOut ||
                    urlError.code == .notConnectedToInternet:
                    self.errorMessage = "网络连接失败，请检查网络设置或稍后重试。"
                    self.showErrorAlert = true
                default:
                    self.errorMessage = "发生未知错误，请稍后重试。"
                    self.showErrorAlert = true
                }
                print("手动同步失败: \(error)")
            } else {
                print("自动同步静默失败: \(error)")
            }
        }
    }
}

// ==================== 所有文章列表 ====================
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    // 【新增】接收从 SourceListView 传递过来的 resourceManager
    @ObservedObject var resourceManager: ResourceManager

    @State private var filterMode: ArticleFilterMode = .unread

    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false

    @State private var expandedTimestamps: Set<String> = []
    
    // 【新增】用于显示错误弹窗的状态
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var baseFilteredArticles: [(article: Article, sourceName: String)] {
        viewModel.allArticlesSortedForDisplay.filter { item in
            let isReadEff = viewModel.isArticleEffectivelyRead(item.article)
            return (filterMode == .unread) ? !isReadEff : isReadEff
        }
    }

    private func groupedByTimestamp(_ items: [(article: Article, sourceName: String)]) -> [String: [(article: Article, sourceName: String)]] {
        let initial = Dictionary(grouping: items, by: { $0.article.timestamp })
        if filterMode == .read {
            return initial.mapValues { Array($0.reversed()) }
        } else {
            return initial
        }
    }

    private var groupedArticles: [String: [(article: Article, sourceName: String)]] {
        groupedByTimestamp(baseFilteredArticles)
    }

    private func sortedTimestamps(for groups: [String: [(article: Article, sourceName: String)]]) -> [String] {
        if filterMode == .read {
            return groups.keys.sorted(by: >)
        } else {
            return groups.keys.sorted(by: <)
        }
    }

    private var filteredArticles: [(article: Article, sourceName: String)] {
        baseFilteredArticles
    }

    private var totalUnreadCount: Int { viewModel.totalUnreadCount }
    private var totalReadCount: Int { viewModel.sources.flatMap { $0.articles }.filter { $0.isRead }.count }

    private var searchResults: [(article: Article, sourceName: String)] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.allArticlesSortedForDisplay.filter { $0.article.topic.lowercased().contains(keyword) }
    }

    private func groupedSearchByTimestamp() -> [String: [(article: Article, sourceName: String)]] {
        var initial = Dictionary(grouping: searchResults, by: { $0.article.timestamp })
        initial = initial.mapValues { Array($0.reversed()) }
        return initial
    }

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
                        resetExpandedState()
                    }
                )
            }

            List {
                if isSearchActive {
                    // ... 搜索部分代码保持不变
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
                                        ArticleRowCardView(
                                            article: item.article,
                                            sourceName: item.sourceName,
                                            isReadEffective: viewModel.isArticleEffectivelyRead(item.article)
                                        )
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
                                    }
                                }
                            }
                        }
                    }
                } else {
                    let timestamps = sortedTimestamps(for: groupedArticles)
                    ForEach(timestamps, id: \.self) { timestamp in
                        Section {
                            if expandedTimestamps.contains(timestamp) {
                                ForEach(groupedArticles[timestamp] ?? [], id: \.article.id) { item in
                                    NavigationLink(destination: ArticleContainerView(
                                        article: item.article,
                                        sourceName: item.sourceName,
                                        context: .fromAllArticles,
                                        viewModel: viewModel
                                    )) {
                                        ArticleRowCardView(
                                            article: item.article,
                                            sourceName: item.sourceName,
                                            isReadEffective: viewModel.isArticleEffectivelyRead(item.article)
                                        )
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
                            HStack(spacing: 8) {
                                Text(formatTimestamp(timestamp))
                                    .font(.headline)
                                    .foregroundColor(.blue.opacity(0.7))

                                Spacer(minLength: 8)

                                Text("\(groupedArticles[timestamp]?.count ?? 0)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

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
            .onAppear(perform: resetExpandedState)
            .onChange(of: filterMode) { _, _ in
                resetExpandedState()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 【新增】刷新按钮
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await syncResources(isManual: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(resourceManager.isSyncing)
                    .accessibilityLabel("刷新")
                }
                
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
        // 【新增】错误提示弹窗
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }

    private func resetExpandedState() {
        let timestamps = sortedTimestamps(for: groupedArticles)
        if timestamps.count == 1 {
            self.expandedTimestamps = Set(timestamps)
        } else {
            self.expandedTimestamps = []
        }
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
    
    // 【新增】从 SourceListView 复制过来的刷新函数
    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
        } catch {
            if isManual {
                switch error {
                case is DecodingError:
                    self.errorMessage = "数据解析失败，请稍后重试。"
                    self.showErrorAlert = true
                case let urlError as URLError where
                    urlError.code == .cannotConnectToHost ||
                    urlError.code == .timedOut ||
                    urlError.code == .notConnectedToInternet:
                    self.errorMessage = "网络连接失败，请检查网络设置或稍后重试。"
                    self.showErrorAlert = true
                default:
                    self.errorMessage = "发生未知错误，请稍后重试。"
                    self.showErrorAlert = true
                }
                print("手动同步失败: \(error)")
            } else {
                print("自动同步静默失败: \(error)")
            }
        }
    }
}
