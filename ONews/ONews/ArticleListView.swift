// /Users/yanzhang/Coding/Xcode/ONews/ONews/ArticleListView.swift
import SwiftUI

enum ArticleFilterMode: String, CaseIterable {
    case unread = "Unread"
    case read = "Read"
}

// ==================== 单一来源列表 ====================
struct ArticleListView: View {
    let source: NewsSource
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager

    @State private var filterMode: ArticleFilterMode = .unread
    
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    
    // 【修改】这两个状态变量依然用于控制导航
    @State private var selectedArticle: Article?
    @State private var isNavigationActive = false

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
        ZStack {
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

                listContent
                    .listStyle(PlainListStyle())

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
            
            // 【移除】废弃的、隐藏的 NavigationLink 已被移除
            /*
            if let article = selectedArticle {
                NavigationLink(
                    destination: ArticleContainerView(...),
                    isActive: $isNavigationActive
                ) { EmptyView() }.hidden()
            }
            */
        }
        // 【核心修改】使用新的 navigationDestination 修饰符来处理程序化导航
        .navigationDestination(isPresented: $isNavigationActive) {
            // 确保 selectedArticle 有值时才创建目标视图
            if let article = selectedArticle {
                ArticleContainerView(
                    article: article,
                    sourceName: source.name,
                    context: .fromSource(source.name),
                    viewModel: viewModel,
                    resourceManager: resourceManager
                )
            }
        }
        .navigationTitle(source.name.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .overlay(
            Group {
                if isDownloadingImages {
                    VStack(spacing: 12) {
                        Text("正在加载图片...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .padding(.horizontal, 40)
                        
                        Text(downloadProgressText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.75))
                    .edgesIgnoringSafeArea(.all)
                }
            }
        )
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    @ViewBuilder
    private var listContent: some View {
        List {
            if isSearchActive {
                searchResultsList
            } else {
                articlesList
            }
        }
        .onAppear {
            initializeStateIfNeeded()
        }
    }
    
    @ViewBuilder
    private var searchResultsList: some View {
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
                        Button(action: {
                            Task {
                                await handleArticleTap(article)
                            }
                        }) {
                            ArticleRowCardView(
                                article: article,
                                sourceName: nil,
                                isReadEffective: viewModel.isArticleEffectivelyRead(article)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(article.id)
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
    }
    
    @ViewBuilder
    private var articlesList: some View {
        let timestamps = sortedTimestamps(for: groupedArticles)
        let expandedSet = viewModel.expandedTimestampsBySource[source.name, default: Set<String>()]
        
        ForEach(timestamps, id: \.self) { timestamp in
            Section {
                if expandedSet.contains(timestamp) {
                    ForEach(groupedArticles[timestamp] ?? []) { article in
                        Button(action: {
                            Task {
                                await handleArticleTap(article)
                            }
                        }) {
                            ArticleRowCardView(
                                article: article,
                                sourceName: nil,
                                isReadEffective: viewModel.isArticleEffectivelyRead(article)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(article.id)
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

                    Image(systemName: expandedSet.contains(timestamp) ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.footnote.weight(.semibold))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleTimestampExpansion(for: source.name, timestamp: timestamp)
                    }
                }
            }
        }
    }

    // 【无需修改】此函数逻辑保持不变，它正确地控制了 isNavigationActive 状态
    private func handleArticleTap(_ article: Article) async {
        guard !article.images.isEmpty else {
            selectedArticle = article
            isNavigationActive = true
            return
        }
        
        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = "准备中..."
        }
        
        do {
            try await resourceManager.downloadImagesForArticle(
                timestamp: article.timestamp,
                imageNames: article.images,
                progressHandler: { current, total in
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "已下载 \(current) / \(total)"
                }
            )
            
            await MainActor.run {
                isDownloadingImages = false
                selectedArticle = article
                isNavigationActive = true
            }
        } catch {
            await MainActor.run {
                isDownloadingImages = false
                errorMessage = "图片下载失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }

    private func initializeStateIfNeeded() {
        if viewModel.expandedTimestampsBySource[source.name] == nil {
            let timestamps = sortedTimestamps(for: groupedArticles)
            if timestamps.count == 1 {
                viewModel.expandedTimestampsBySource[source.name] = Set(timestamps)
            }
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
    
    private func syncResources(isManual: Bool = false) async {
        do {
            try await resourceManager.checkAndDownloadUpdates(isManual: isManual)
            viewModel.loadNews()
        } catch {
            if isManual {
                switch error {
                case is DecodingError:
                    self.errorMessage = "数据解析失败,请稍后重试。"
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
    @ObservedObject var resourceManager: ResourceManager

    @State private var filterMode: ArticleFilterMode = .unread

    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    
    // 【修改】这两个状态变量依然用于控制导航
    @State private var selectedArticleItem: (article: Article, sourceName: String)?
    @State private var isNavigationActive = false

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
        ZStack {
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

                listContent
                    .listStyle(PlainListStyle())

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
            
            // 【移除】废弃的、隐藏的 NavigationLink 已被移除
            /*
            if let item = selectedArticleItem {
                NavigationLink(
                    destination: ArticleContainerView(...),
                    isActive: $isNavigationActive
                ) { EmptyView() }.hidden()
            }
            */
        }
        // 【核心修改】使用新的 navigationDestination 修饰符来处理程序化导航
        .navigationDestination(isPresented: $isNavigationActive) {
            // 确保 selectedArticleItem 有值时才创建目标视图
            if let item = selectedArticleItem {
                ArticleContainerView(
                    article: item.article,
                    sourceName: item.sourceName,
                    context: .fromAllArticles,
                    viewModel: viewModel,
                    resourceManager: resourceManager
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .overlay(
            Group {
                if isDownloadingImages {
                    VStack(spacing: 12) {
                        Text("正在加载图片...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .padding(.horizontal, 40)
                        
                        Text(downloadProgressText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.75))
                    .edgesIgnoringSafeArea(.all)
                }
            }
        )
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    @ViewBuilder
    private var listContent: some View {
        List {
            if isSearchActive {
                searchResultsList
            } else {
                articlesList
            }
        }
        .onAppear {
            initializeStateIfNeeded()
        }
    }
    
    @ViewBuilder
    private var searchResultsList: some View {
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
                        Button(action: {
                            Task {
                                await handleArticleTap(item)
                            }
                        }) {
                            ArticleRowCardView(
                                article: item.article,
                                sourceName: item.sourceName,
                                isReadEffective: viewModel.isArticleEffectivelyRead(item.article)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(item.article.id)
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
    }
    
    @ViewBuilder
    private var articlesList: some View {
        let timestamps = sortedTimestamps(for: groupedArticles)
        let expandedSet = viewModel.expandedTimestampsBySource[viewModel.allArticlesKey, default: Set<String>()]

        ForEach(timestamps, id: \.self) { timestamp in
            Section {
                if expandedSet.contains(timestamp) {
                    ForEach(groupedArticles[timestamp] ?? [], id: \.article.id) { item in
                        Button(action: {
                            Task {
                                await handleArticleTap(item)
                            }
                        }) {
                            ArticleRowCardView(
                                article: item.article,
                                sourceName: item.sourceName,
                                isReadEffective: viewModel.isArticleEffectivelyRead(item.article)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(item.article.id)
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

                    Image(systemName: expandedSet.contains(timestamp) ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.footnote.weight(.semibold))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleTimestampExpansion(for: viewModel.allArticlesKey, timestamp: timestamp)
                    }
                }
            }
        }
    }

    // 【无需修改】此函数逻辑保持不变，它正确地控制了 isNavigationActive 状态
    private func handleArticleTap(_ item: (article: Article, sourceName: String)) async {
        guard !item.article.images.isEmpty else {
            selectedArticleItem = item
            isNavigationActive = true
            return
        }
        
        await MainActor.run {
            isDownloadingImages = true
            downloadProgress = 0.0
            downloadProgressText = "准备中..."
        }
        
        do {
            try await resourceManager.downloadImagesForArticle(
                timestamp: item.article.timestamp,
                imageNames: item.article.images,
                progressHandler: { current, total in
                    self.downloadProgress = total > 0 ? Double(current) / Double(total) : 0
                    self.downloadProgressText = "已下载 \(current) / \(total)"
                }
            )
            
            await MainActor.run {
                isDownloadingImages = false
                selectedArticleItem = item
                isNavigationActive = true
            }
        } catch {
            await MainActor.run {
                isDownloadingImages = false
                errorMessage = "图片下载失败: \(error.localizedDescription)"
                showErrorAlert = true
            }
        }
    }

    private func initializeStateIfNeeded() {
        let key = viewModel.allArticlesKey
        
        if viewModel.expandedTimestampsBySource[key] == nil {
            let timestamps = sortedTimestamps(for: groupedArticles)
            if timestamps.count == 1 {
                viewModel.expandedTimestampsBySource[key] = Set(timestamps)
            }
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
