import SwiftUI

// 【新增】定义导航目标，使其类型安全且可哈希
enum NavigationTarget: Hashable {
    case allArticles
    case source(NewsSource)
    
    // NewsSource 默认没有实现 Hashable，我们需要手动实现
    // 但由于 NewsSource 有一个 UUID 类型的 id，我们可以直接用它来比较和哈希
    func hash(into hasher: inout Hasher) {
        switch self {
        case .allArticles:
            hasher.combine("allArticles")
        case .source(let source):
            hasher.combine(source.id)
        }
    }
    
    static func == (lhs: NavigationTarget, rhs: NavigationTarget) -> Bool {
        switch (lhs, rhs) {
        case (.allArticles, .allArticles):
            return true
        case (.source(let lhsSource), .source(let rhsSource)):
            return lhsSource.id == rhsSource.id
        default:
            return false
        }
    }
}


// ==================== 主视图：SourceListView ====================

struct SourceListView: View {
    @EnvironmentObject var viewModel: NewsViewModel
    @EnvironmentObject var resourceManager: ResourceManager
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    @State private var showAddSourceSheet = false
    
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchActive: Bool = false
    
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
        // 【修改】将 NavigationView 升级为 NavigationStack
        NavigationStack {
            VStack(spacing: 0) {
                if isSearching {
                    SearchBarInline(
                        text: $searchText,
                        placeholder: "搜索所有文章的标题关键字",
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
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if isSearchActive {
                    searchResultsView
                } else {
                    sourceAndAllArticlesView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Image("welcome_background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.4).ignoresSafeArea())
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        withAnimation {
                            isSearching.toggle()
                            if !isSearching {
                                isSearchActive = false
                                searchText = ""
                            }
                        }
                    }) {
                        Image(systemName: isSearching ? "xmark.circle.fill" : "magnifyingglass")
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("搜索")
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showAddSourceSheet = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await syncResources(isManual: true)
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                    }
                    .disabled(resourceManager.isSyncing)
                }
            }
            .navigationBarTitle(isSearching ? "" : "", displayMode: .inline)
            // 【修改】添加 navigationDestination 来处理所有来自此视图的导航请求
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .allArticles:
                    AllArticlesListView(viewModel: viewModel, resourceManager: resourceManager)
                case .source(let source):
                    // 从 viewModel.sources 中找到最新的 source 数据传递过去
                    // 这样可以确保即使 viewModel 中的数据更新了，导航到的页面也是最新的
                    if let updatedSource = viewModel.sources.first(where: { $0.id == source.id }) {
                        ArticleListView(source: updatedSource, viewModel: viewModel, resourceManager: resourceManager)
                    } else {
                        // 如果源被删除了，提供一个回退视图
                        Text("新闻源 “\(source.name)” 不再可用。")
                    }
                }
            }
        }
        .accentColor(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.loadNews()
            Task {
                await syncResources()
            }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: {
            print("AddSourceView 已关闭，重新加载新闻...")
            viewModel.loadNews()
        }) {
            NavigationView {
                AddSourceView(
                    isFirstTimeSetup: false,
                    onConfirm: {
                        print("AddSourceView 确定：关闭并刷新")
                        showAddSourceSheet = false
                    }
                )
            }
            .preferredColorScheme(.dark)
            .environmentObject(resourceManager)
        }
        .overlay(
            Group {
                if resourceManager.isSyncing {
                    VStack(spacing: 15) {
                        if resourceManager.syncMessage == "当前已是最新" || resourceManager.syncMessage == "新闻清单已是最新。" {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.white)
                            
                            Text(resourceManager.syncMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        else if resourceManager.isDownloading {
                            Text(resourceManager.syncMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            ProgressView(value: resourceManager.downloadProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .white))
                                .padding(.horizontal, 50)
                            
                            Text(resourceManager.progressText)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            
                            Text(resourceManager.syncMessage)
                                .padding(.top, 10)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
                    .edgesIgnoringSafeArea(.all)
                    .contentShape(Rectangle())
                }
            }
        )
        .alert("", isPresented: $showErrorAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
    }
    
    private var searchResultsView: some View {
        List {
            let grouped = groupedSearchByTimestamp()
            let timestamps = sortedSearchTimestamps(for: grouped)

            if searchResults.isEmpty {
                Section {
                    Text("未找到匹配的文章")
                        .foregroundColor(.white.opacity(0.8))
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
                            Text("\(formatTimestamp(timestamp)) (\(grouped[timestamp]?.count ?? 0))")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.85))
                        }
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    ) {
                        ForEach(grouped[timestamp] ?? [], id: \.article.id) { item in
                            // 【修改】这里也使用 value-based NavigationLink
                            // 虽然它会导航到 ArticleContainerView，但这个视图尚未适配 value-based 导航
                            // 且这里的导航逻辑比较复杂（点击后需要下载），因此保持 ArticleListView/AllArticlesListView 内部的 isPresented 逻辑是更好的选择。
                            // 为了简化，我们直接导航到包含该文章的列表页。更好的体验需要更复杂的导航状态管理。
                            // 暂时保持原样，因为主要修复的是 ArticleListView 内部的警告。
                            // 这里的 NavigationLink 实际上是导航到 ArticleContainerView，但它是在另一个 NavigationStack 的上下文中。
                            // 为了正确修复，我们需要在 ArticleListView 中处理这个 item。
                            // 这里的 NavigationLink(destination:) 仍然有效，因为它在 NavigationStack 内。
                            // 虽然不是最新的 value-based 写法，但它不会产生警告。
                            NavigationLink(destination: ArticleContainerView(
                                article: item.article,
                                sourceName: item.sourceName,
                                context: .fromAllArticles,
                                viewModel: viewModel,
                                resourceManager: resourceManager
                            )) {
                                ArticleRowCardView(
                                    article: item.article,
                                    sourceName: item.sourceName,
                                    isReadEffective: viewModel.isArticleEffectivelyRead(item.article)
                                )
                                .colorScheme(.dark)
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .transition(.opacity.animation(.easeInOut))
    }
    
    private var sourceAndAllArticlesView: some View {
        Group {
            if viewModel.sources.isEmpty && !resourceManager.isSyncing {
                VStack(spacing: 20) {
                    Text("您还没有订阅任何新闻源")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))
                    Button(action: { showAddSourceSheet = true }) {
                        Label("点击这里添加", systemImage: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    // 【修改】使用新的 value-based NavigationLink
                    NavigationLink(value: NavigationTarget.allArticles) {
                        HStack {
                            Text("ALL")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(viewModel.totalUnreadCount)")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    
                    ForEach(viewModel.sources) { source in
                        // 【修改】使用新的 value-based NavigationLink
                        NavigationLink(value: NavigationTarget.source(source)) {
                            HStack {
                                Text(source.name)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(source.unreadCount)")
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .transition(.opacity.animation(.easeInOut))
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
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日, EEEE"
        return formatter.string(from: date)
    }
}

// 【修改】为了让 NavigationTarget.source(NewsSource) 可用
// 需要让 NewsSource 符合 Hashable 协议。因为它有 id: UUID，这很简单。
extension NewsSource: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: NewsSource, rhs: NewsSource) -> Bool {
        lhs.id == rhs.id
    }
}
