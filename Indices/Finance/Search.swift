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
    var results: [(result: SearchResult, score: Int)] // 改为存储结果及其评分
    let highestScore: Int
}

// 定义匹配类别
enum MatchCategory: String, CaseIterable, Identifiable {
    case symbol = "Symbol Matches"
    case name = "Name Matches"
    case stockTag = "Stock Tag Matches"
    case etfTag = "ETF Tag Matches"
    case description = "Description Matches"
    var id: String { self.rawValue }
    
    // 添加权重属性
    var priority: Int {
        switch self {
        case .symbol:     return 1000  // 最高优先级
        case .stockTag:   return 800   // stock tag 优先于 etf tag
        case .etfTag:     return 700
        case .name:       return 500
        case .description: return 300  // 最低优先级
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
    @Published var volume: String?
    
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
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        NavigationStack {  // 使用 NavigationStack
            VStack {
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
                .padding()
                
                Spacer()
            }
            .navigationDestination(isPresented: $showSearch) {
                SearchView(isSearchActive: true, dataService: dataService)
            }
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
    let result: SearchResult
    let score: Int // 添加评分属性
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("\(result.symbol) - \(result.name)")
                    .font(.headline)
                Spacer()
                Text("Score: \(score)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Text(result.tag.joined(separator: ", "))
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let marketCap = result.marketCap, let peRatio = result.peRatio {
                Text("\(marketCap) \(peRatio)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let compare = result.compare {
                Text("\(compare)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let volume = result.volume {
                Text("\(volume)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
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
            
            // 修改数据结构定义，使用元组存储所有需要的信息
            struct ScoredGroup {
                let group: GroupedSearchResults
                let matchScore: Int
                let priority: Int
            }
            
            var groupedResults: [ScoredGroup] = []
            let categories: [MatchCategory] = MatchCategory.allCases
            
            for category in categories {
                var matches: [(result: SearchResult, score: Int)] = []
                
                switch category {
                case .symbol, .name, .description:
                    let stockMatches = self.searchCategory(items: descriptionData.stocks, keywords: keywords, category: category)
                    let etfMatches = self.searchCategory(items: descriptionData.etfs, keywords: keywords, category: category)
                    matches = stockMatches + etfMatches
                case .stockTag:
                    matches = self.searchCategory(items: descriptionData.stocks, keywords: keywords, category: category)
                case .etfTag:
                    matches = self.searchCategory(items: descriptionData.etfs, keywords: keywords, category: category)
                }
                
                if !matches.isEmpty {
                    let highestScore = matches.max(by: { $0.score < $1.score })?.score ?? 0
                    let results = matches.map { $0.result }
                    
                    
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
        
            // 修改排序逻辑，先按分数排序，分数相同时按优先级排序
            let sortedGroups = groupedResults.sorted { first, second in
                if first.matchScore != second.matchScore {
                    return first.matchScore > second.matchScore  // 先按分数排序
                }
                // 分数相同时，再按优先级排序
                return first.priority > second.priority
            }.map { $0.group }

            // 添加到搜索历史
            DispatchQueue.main.async {
                if !keywords.isEmpty {
                    self.addSearchHistory(term: query)
                }
                self.groupedSearchResults = sortedGroups
                
                completion(sortedGroups)
            }
        }
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
                case .symbol:
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
                    
                case .name:
                    if lowercasedKeyword == item.name.lowercased() {
                        matchScore = 3
                        matched = true
                    } else if item.name.lowercased().contains(lowercasedKeyword) {
                        matchScore = 2
                        matched = true
                    } else if fuzzyMatch(text: item.name.lowercased(), keyword: lowercasedKeyword, maxDistance: 1) {
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
                    
                case .description:
                    let desc1 = item.description1.lowercased()
                    let desc2 = item.description2.lowercased()
                    let descWords = desc1.split(separator: " ") + desc2.split(separator: " ")
                    
                    if descWords.contains(where: { String($0) == lowercasedKeyword }) {
                        matchScore = max(matchScore, 2)
                        matched = true
                    } else if desc1.contains(lowercasedKeyword) || desc2.contains(lowercasedKeyword) {
                        matchScore = max(matchScore, 1)
                        matched = true
//                    } else if fuzzyMatch(text: desc1, keyword: lowercasedKeyword, maxDistance: 1) ||
//                              fuzzyMatch(text: desc2, keyword: lowercasedKeyword, maxDistance: 1) {
//                        matchScore = max(matchScore, 1)
//                        matched = true
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
                    compare: compare
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
