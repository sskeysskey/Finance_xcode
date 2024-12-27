import Foundation
import Combine
import SwiftUI

// 定义公共协议
protocol SearchDescribableItem {
    var symbol: String { get }
    var name: String { get }
    var tag: [String] { get }
    var description1: String { get }
    var description2: String { get }
}

struct SearchStock: Identifiable, Codable, SearchDescribableItem {
    let id = UUID()
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    
    enum CodingKeys: String, CodingKey {
        case symbol, name, tag, description1, description2
    }
}

// 使 ETF 遵循 DescribableItem 协议
struct SearchETF: Identifiable, Codable, SearchDescribableItem {
    let id = UUID()
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    
    enum CodingKeys: String, CodingKey {
        case symbol, name, tag, description1, description2
    }
}

struct SelectedSymbol: Identifiable {
    let id = UUID()
    let result: SearchResult
    let category: String
}

struct GroupedSearchResults: Identifiable {
    var id = UUID()
    var category: MatchCategory
    var results: [(result: SearchResult, score: Int)] // 存储结果及其评分
    let highestScore: Int
}

// 定义匹配类别
enum MatchCategory: String, CaseIterable, Identifiable {
    // Symbol Matches
    case stockSymbol = "Stock Symbol Matches"
    case etfSymbol = "ETF Symbol Matches"
    
    // Name Matches
    case stockName = "Stock Name Matches"
    case etfName = "ETF Name Matches"
    
    // Tag Matches
    case stockTag = "Stock Tag Matches"
    case etfTag = "ETF Tag Matches"
    
    // Description Matches
    case stockDescription = "Stock Description Matches"
    case etfDescription = "ETF Description Matches"
    
    var id: String { self.rawValue }
    
    // 更新权重属性，根据新的分类调整优先级
    var priority: Int {
        switch self {
        case .stockSymbol, .etfSymbol:
            return 1000  // 最高优先级
        case .stockTag, .etfTag:
            return 800
        case .stockName, .etfName:
            return 500
        case .stockDescription, .etfDescription:
            return 300  // 最低优先级
        }
    }
}

class SearchResult: Identifiable, ObservableObject {
    let id = UUID()
    @Published var symbol: String
    @Published var name: String
    @Published var tag: [String]
    @Published var marketCap: String?
    @Published var peRatio: String?
    @Published var compare: String?
    @Published var volume: String?  // 确保这是一个可选的 String
    
    init(symbol: String, name: String, tag: [String], marketCap: String? = nil,
         peRatio: String? = nil, compare: String? = nil, volume: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.tag = tag
        self.marketCap = marketCap
        self.peRatio = peRatio
        self.compare = compare
        self.volume = volume
    }
}

struct GroupHeaderView: View {
    let category: MatchCategory
    @Binding var isCollapsed: Bool
    
    var body: some View {
        HStack {
            Text(category.rawValue)
                .font(.headline)
                .foregroundColor(.blue)
            
            Spacer()
            
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .foregroundColor(.gray)
        }
        .contentShape(Rectangle()) // 让整个区域都可点击
        .onTapGesture {
            withAnimation {
                isCollapsed.toggle()
            }
        }
    }
}

// MARK: - Views
struct SearchContentView: View {
    @State private var showSearch = false
    @State private var showCompare = false
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        NavigationStack {
            HStack(spacing: 12) {
                // 比较按钮
                Button(action: {
                    showCompare = true
                }) {
                    VStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 20))
                        Text("比较")
                            .font(.caption)
                    }
                    .frame(width: 60)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                
                // 搜索按钮
                Button(action: {
                    showSearch = true
                }) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("点击搜索")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .navigationDestination(isPresented: $showSearch) {
            SearchView(isSearchActive: true, dataService: dataService)
        }
        .navigationDestination(isPresented: $showCompare) {
            CompareView(initialSymbol: "")
        }
    }
}

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var showClearButton: Bool = false
    @State private var showSearchHistory: Bool = false
    @State private var groupedSearchResults: [GroupedSearchResults] = []
    @State private var isLoading: Bool = false
    @State private var selectedCategory: String? = nil
    @State private var showChart: Bool = false
    @State private var selectedResult: SearchResult? = nil
    @State private var selectedSymbol: SelectedSymbol? = nil
    @State private var isFirstAppear = true  // 新增状态变量
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    
    // 添加分组折叠状态
    @State private var collapsedGroups: [MatchCategory: Bool] = [:]
    
    // 添加存储属性
    let isSearchActive: Bool
    
    init(isSearchActive: Bool = false, dataService: DataService) {
        self.isSearchActive = isSearchActive
        self.viewModel = SearchViewModel(dataService: dataService)
        // 如果需要显示历史记录，设置初始值
        _showSearchHistory = State(initialValue: isSearchActive)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            searchBar
                .padding()
            
            // 主要内容区域
            ZStack {
                // 搜索历史
                if showSearchHistory {
                    SearchHistoryView(viewModel: viewModel, onSelect: { term in
                        searchText = term
                        startSearch()
                    })
                    .transition(.opacity)
                    .zIndex(1) // 确保历史记录始终在最上层
                }
                
                // 加载指示器
                if isLoading {
                    ProgressView("正在搜索...")
                        .padding()
                }
                
                // 搜索结果列表
                if !showSearchHistory && !groupedSearchResults.isEmpty {
                    searchResultsList
                        .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: Binding<Bool>(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Alert(
                    title: Text("错误"),
                    message: Text(viewModel.errorMessage ?? ""),
                    dismissButton: .default(Text("确定"))
                )
            }
            // 使用 sheet(item:) 展示 ChartView
            .sheet(item: $selectedSymbol) { selected in
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
        }
        .onAppear {
            if isSearchActive && isFirstAppear {
                // 只在首次进入搜索页面时激活输入框焦点
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                    isFirstAppear = false  // 标记不再是首次加载
                }
            }
        }
//        .ignoresSafeArea(.keyboard) // 防止键盘顶起视图
    }
    
    // MARK: - 搜索栏
    private var searchBar: some View {
        HStack {
            TextField("请输入要搜索的关键字", text: $searchText, onEditingChanged: { isEditing in
                withAnimation {
                    // 只在文本为空且正在编辑时显示搜索历史
                    showSearchHistory = isEditing && searchText.isEmpty
                    if isEditing && searchText.isEmpty {
                        groupedSearchResults = [] // 只在合适的时机清空搜索结果
                    }
                }
            }, onCommit: {
                startSearch()
            })
            .focused($isSearchFieldFocused)
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .onChange(of: searchText) { oldValue, newValue in
                showClearButton = !newValue.isEmpty
                if newValue.isEmpty {
                    withAnimation {
                        showSearchHistory = true
                        groupedSearchResults = [] // 清空搜索结果
                    }
                }
            }
            
            if showClearButton {
                Button(action: {
                    searchText = ""
                    withAnimation {
                        showSearchHistory = true
                        groupedSearchResults = [] // 清空搜索结果
                        isSearchFieldFocused = true  // 添加这一行，设置输入框焦点
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .transition(.opacity)
            }
            
            Button(action: {
                startSearch()
                isSearchFieldFocused = false
            }) {
                Text("搜索")
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
    }
    
    // MARK: - 搜索结果列表
    private var searchResultsList: some View {
        List {
            ForEach(groupedSearchResults) { groupedResult in
                if !groupedResult.results.isEmpty {
                    Section(header: GroupHeaderView(category: groupedResult.category, isCollapsed: Binding(
                        get: { collapsedGroups[groupedResult.category] ?? false },
                        set: { collapsedGroups[groupedResult.category] = $0 }
                    ))) {
                        if !(collapsedGroups[groupedResult.category] ?? false) {
                            // 按照评分降序排列
                            ForEach(groupedResult.results.sorted { $0.score > $1.score }, id: \.result.id) { result, score in
                                NavigationLink(destination: {
                                    if let category = viewModel.dataService.getCategory(for: result.symbol) {
                                        ChartView(symbol: result.symbol, groupName: category)
                                    }
                                }) {
                                    SearchResultRow(result: result, score: score)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    func startSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearchFieldFocused = false
        isLoading = true
        showSearchHistory = false
        
        viewModel.performSearch(query: searchText) { groupedResults in
            DispatchQueue.main.async {
                withAnimation {
                    self.groupedSearchResults = groupedResults
                    self.isLoading = false
                    
                    // 初始化 collapsedGroups，所有分组默认展开
                    for group in groupedResults {
                        if collapsedGroups[group.category] == nil {
                            collapsedGroups[group.category] = false
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 搜索结果行视图
struct SearchResultRow: View {
    @ObservedObject var result: SearchResult
    let score: Int // 添加评分属性
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(result.symbol) - \(result.name)")
                        .font(.headline)
                    Text(result.tag.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack {
                if let marketCap = result.marketCap {
                    Text(marketCap)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // 修改这部分代码
                if let peRatio = result.peRatio, peRatio != "--" {
                    Text("\(peRatio)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let compare = result.compare {
                    Text(compare)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let volume = result.volume {
                    Text(volume)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 搜索历史视图
struct SearchHistoryView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onSelect: (String) -> Void
    
    var body: some View {
        VStack {
            if viewModel.searchHistory.isEmpty {
                Text("暂无搜索历史")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.searchHistory, id: \.self) { term in
                            HStack {
                                Text(term)
                                Spacer()
                                Button(action: {
                                    viewModel.removeSearchHistory(term: term)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle()) // 确保整个 HStack 区域可点击
                            .onTapGesture {
                                onSelect(term)
                            }
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(8)
                .shadow(radius: 5)
                .padding([.horizontal, .bottom])
            }
        }
    }
}

class SearchViewModel: ObservableObject {
    @Published var searchHistory: [String] = []
    @Published var errorMessage: String? = nil
    @Published var isChartLoading: Bool = false
    @Published var groupedSearchResults: [GroupedSearchResults] = []
    
    var dataService: DataService
    private var cancellables = Set<AnyCancellable>()
    
    init(dataService: DataService = DataService()) {
        self.dataService = dataService
        // 监听 DataService 的 errorMessage
        dataService.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
        
        loadSearchHistory()
    }
    
    // 搜索功能
    func performSearch(query: String, completion: @escaping ([GroupedSearchResults]) -> Void) {
        let keywords = query.lowercased().split(separator: " ").map { String($0) }
            
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let descriptionData = self.dataService.descriptionData else {
                DispatchQueue.main.async {
                    completion([])
                }
                return
            }
            
            struct ScoredGroup {
                let group: GroupedSearchResults
                let matchScore: Int
                let priority: Int
            }
            
            var groupedResults: [ScoredGroup] = []
            let categories: [MatchCategory] = [
                .stockSymbol, .etfSymbol,
                .stockName, .etfName,
                .stockTag, .etfTag,
                .stockDescription, .etfDescription
            ]
            
            for category in categories {
                var matches: [(result: SearchResult, score: Int)] = []
                
                switch category {
                case .stockSymbol, .stockName, .stockDescription, .stockTag:
                    matches = self.searchCategory(items: descriptionData.stocks, keywords: keywords, category: category)
                case .etfSymbol, .etfName, .etfDescription, .etfTag:
                    matches = self.searchCategory(items: descriptionData.etfs, keywords: keywords, category: category)
                }
                
                if !matches.isEmpty {
                    let highestScore = matches.max(by: { $0.score < $1.score })?.score ?? 0
                    
                    let group = GroupedSearchResults(
                        category: category,
                        results: matches,
                        highestScore: highestScore
                    )
                    
                    let scoredGroup = ScoredGroup(
                        group: group,
                        matchScore: highestScore,
                        priority: category.priority
                    )
                    
                    groupedResults.append(scoredGroup)
                }
            }
        
            // 按分数和优先级排序
            let sortedGroups = groupedResults.sorted { first, second in
                if first.matchScore != second.matchScore {
                    return first.matchScore > second.matchScore
                }
                return first.priority > second.priority
            }.map { $0.group }

            DispatchQueue.main.async {
                if !keywords.isEmpty {
                    self.addSearchHistory(term: query)
                }
                self.groupedSearchResults = sortedGroups
                
                // 获取 ETF 的最新 volume
                self.fetchLatestVolumes(for: sortedGroups) {
                    completion(sortedGroups)
                }
            }
        }
    }
    
    // 新增的方法：为 ETF 搜索结果获取最新 volume
    private func fetchLatestVolumes(for groupedResults: [GroupedSearchResults], completion: @escaping () -> Void) {
        // 定义所有ETF相关的分类
        let etfCategories: Set<MatchCategory> = [.etfSymbol, .etfName, .etfDescription, .etfTag]
        
        // 遍历所有分组结果
        for groupedResult in groupedResults {
            // 检查当前分组是否属于ETF相关分类
            if etfCategories.contains(groupedResult.category) {
                for (_, (result, _)) in groupedResult.results.enumerated() {
                    let symbol = result.symbol
                    // 从数据库获取最新的volume
                    if let latestVolume = DatabaseManager.shared.fetchLatestVolume(forSymbol: symbol, tableName: "ETFs") {
                        // 将volume格式化为K单位
                        let formattedVolume = formatVolume(latestVolume)
                        // 更新SearchResult的volume属性
                        DispatchQueue.main.async {
                            result.volume = formattedVolume
                        }
                    } else {
                        // 如果未找到volume，则设置为"--K"
                        DispatchQueue.main.async {
                            result.volume = "--K"
                        }
                    }
                }
            }
        }
        completion()
    }
    
    // 辅助方法：将 volume 转换为 K 单位的字符串
    private func formatVolume(_ volume: Int64) -> String {
        let kVolume = Double(volume) / 1000.0
        return String(format: "%.0fK", kVolume)
    }
    
    // 搜索类别，并排序结果（完全匹配优先）
    func searchCategory<T: SearchDescribableItem>(items: [T], keywords: [String], category: MatchCategory) -> [(result: SearchResult, score: Int)] {
        var scoredResults: [(result: SearchResult, score: Int)] = []
        
        for item in items {
            var totalScore = 0
            var allKeywordsMatched = true
            
            for keyword in keywords {
                let lowercasedKeyword = keyword.lowercased()
                var matchScore = 0
                var matched = false
                
                switch category {
                case .stockSymbol, .etfSymbol:
                    if lowercasedKeyword == item.symbol.lowercased() {
                        matchScore = 3
                        matched = true
                    } else if item.symbol.lowercased().contains(lowercasedKeyword) {
                        matchScore = 2
                        matched = true
                    } else if fuzzyMatch(text: item.symbol.lowercased(), keyword: lowercasedKeyword, maxDistance: 1) {
                        matchScore = 1
                        matched = true
                    }
                    
//                case .stockName, .etfName:
//                    if lowercasedKeyword == item.name.lowercased() {
//                        matchScore = 3
//                        matched = true
//                    } else if item.name.lowercased().contains(lowercasedKeyword) {
//                        matchScore = 2
//                        matched = true
//                    } else if fuzzyMatch(text: item.name.lowercased(), keyword: lowercasedKeyword, maxDistance: 1) {
//                        matchScore = 1
//                        matched = true
//                    }
                    
                case .stockName, .etfName:
                    // 安全地处理名称分割
                    let nameComponents = item.name.lowercased().components(separatedBy: ",")
                    let mainName = nameComponents.first ?? item.name.lowercased()
                    let nameWords = mainName.split(separator: " ").map { String($0) }
                    
                    if lowercasedKeyword == item.name.lowercased() {
                        // 完全匹配整个名称
                        matchScore = 4
                        matched = true
                    } else if nameWords.contains(where: { $0 == lowercasedKeyword }) ||
                              mainName == lowercasedKeyword {
                        // 精确匹配任何完整单词或主要名称
                        matchScore = 3
                        matched = true
                    } else if mainName.contains(lowercasedKeyword) {
                        // 主要名称中的部分匹配
                        matchScore = 2
                        matched = true
                    } else if item.name.lowercased().contains(lowercasedKeyword) {
                        // 整个名称中的部分匹配
                        matchScore = 1
                        matched = true
                    } else if fuzzyMatch(text: item.name.lowercased(), keyword: lowercasedKeyword, maxDistance: 1) {
                        // 模糊匹配
                        matchScore = 1
                        matched = true
                    }
                    
                case .stockTag, .etfTag:
                    var tagMatchScore = 0
                    for tag in item.tag {
                        let lowercasedTag = tag.lowercased()
                        if lowercasedTag == lowercasedKeyword {
                            tagMatchScore = max(tagMatchScore, 3)
                        } else if lowercasedTag.contains(lowercasedKeyword) {
                            tagMatchScore = max(tagMatchScore, 2)
                        } else if fuzzyMatch(text: lowercasedTag, keyword: lowercasedKeyword, maxDistance: 1) {
                            tagMatchScore = max(tagMatchScore, 1)
                        }
                    }
                    if tagMatchScore > 0 {
                        matchScore = tagMatchScore
                        matched = true
                    }
                    
                case .stockDescription, .etfDescription:
                    let desc1 = item.description1.lowercased()
                    let desc2 = item.description2.lowercased()
                    let descWords = desc1.split(separator: " ") + desc2.split(separator: " ")
                    
                    if descWords.contains(where: { String($0) == lowercasedKeyword }) {
                        matchScore = max(matchScore, 2)
                        matched = true
                    } else if desc1.contains(lowercasedKeyword) || desc2.contains(lowercasedKeyword) {
                        matchScore = max(matchScore, 1)
                        matched = true
                    }
                }
                
                if matched {
                    totalScore += matchScore
                } else {
                    allKeywordsMatched = false
                    break
                }
            }
            
            if allKeywordsMatched {
                let marketCap = dataService.marketCapData[item.symbol.uppercased()]?.marketCap
                let peRatio = dataService.marketCapData[item.symbol.uppercased()]?.peRatio
                let compare = dataService.compareData[item.symbol.uppercased()]
                
                let result = SearchResult(
                    symbol: item.symbol,
                    name: item.name,
                    tag: item.tag,
                    marketCap: marketCap,
                    peRatio: peRatio != nil ? String(format: "%.2f", peRatio!) : "--",
                    compare: compare,
                    volume: nil  // 初始为 nil，稍后设置
                )
                scoredResults.append((result: result, score: totalScore))
            }
        }
        
        // 按分数降序排序
        return scoredResults.sorted { $0.score > $1.score }
    }
    
    // 字符串匹配
    private func matchText(_ text: String, keywords: [String]) -> Bool {
        if keywords.count > 1 {
            return keywords.allSatisfy { text.contains($0) }
        }
        return text.contains(keywords[0])
    }
    // 模糊匹配
    private func fuzzyMatch(text: String, keyword: String, maxDistance: Int) -> Bool {
        if keyword.count <= 1 {
            return text.contains(keyword)
        }
        let words = text.split(separator: " ").map { String($0) }
        return words.contains { levenshtein_distance(String($0), keyword) <= maxDistance }
    }
    // Levenshtein 距离计算
    private func levenshtein_distance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let n = a.count
        let m = b.count
        
        if n == 0 { return m }
        if m == 0 { return n }
        
        var matrix = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        
        for i in 0...n { matrix[i][0] = i }
        for j in 0...m { matrix[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1, //删除
                        matrix[i][j - 1] + 1, //插入
                        matrix[i - 1][j - 1] + 1 //替换
                    )
                }
            }
        }
        
        return matrix[n][m]
    }
    
    // 搜索历史管理
    func loadSearchHistory() {
        if let history = UserDefaults.standard.array(forKey: "stockSearchHistory") as? [String] {
            self.searchHistory = history
        }
    }
    
    func addSearchHistory(term: String) {
        let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
        guard !trimmedTerm.isEmpty else { return }
        
        if let index = self.searchHistory.firstIndex(where: { $0.lowercased() == trimmedTerm.lowercased() }) {
            self.searchHistory.remove(at: index)
        }
        self.searchHistory.insert(trimmedTerm, at: 0)
                
        if self.searchHistory.count > 10 {
            self.searchHistory = Array(self.searchHistory.prefix(10))
        }
        
        UserDefaults.standard.set(searchHistory, forKey: "stockSearchHistory")
    }
    
    func removeSearchHistory(term: String) {
        if let index = searchHistory.firstIndex(where: { $0.lowercased() == term.lowercased() }) {
            searchHistory.remove(at: index)
            UserDefaults.standard.set(searchHistory, forKey: "stockSearchHistory")
        }
    }
}
