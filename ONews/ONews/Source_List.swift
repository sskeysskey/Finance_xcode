import SwiftUI

// 【修改】定义导航目标，source 只存储名称
enum NavigationTarget: Hashable {
    case allArticles
    case source(String)  // 只存储源的名称，而不是整个 NewsSource
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
                case .source(let sourceName):
                    ArticleListView(sourceName: sourceName, viewModel: viewModel, resourceManager: resourceManager)
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
            // 【核心修改】
            // 判断逻辑的核心变更：不再使用 `viewModel.sources.isEmpty` 来判断是否显示“未订阅”提示。
            // `viewModel.sources` 在数据加载完成前是空的，会导致不必要的闪烁。
            // 正确的逻辑是直接检查持久化的订阅管理器 `SubscriptionManager`。
            // `SubscriptionManager.shared.subscribedSources` 能立即、准确地反映用户是否已订阅了任何源。
            if SubscriptionManager.shared.subscribedSources.isEmpty && !resourceManager.isSyncing {
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
                // 如果用户有订阅（即使 `viewModel.sources` 尚未加载完毕），或者正在同步中，
                // 直接显示列表。列表在数据加载完成前会自然地为空，然后自动填充，
                // 这样就避免了显示错误的“未订阅”提示。
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
                        NavigationLink(value: NavigationTarget.source(source.name)) {
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