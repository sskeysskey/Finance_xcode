import Foundation
import Combine
import SwiftUI

// MARK: - 协议与模型
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
    var results: [(result: SearchResult, score: Int)]
    let highestScore: Int
}

enum MatchCategory: String, CaseIterable, Identifiable {
    case stockSymbol = "Stock Symbol"
    case etfSymbol = "ETF Symbol"
    case stockName = "Stock Name"
    case etfName = "ETF Name"
    case stockTag = "Stock Tag"
    case etfTag = "ETF Tag"
    case stockDescription = "Stock Description"
    case etfDescription = "ETF Description"
    
    var id: String { self.rawValue }
    
    var priority: Int {
        switch self {
        case .stockSymbol, .etfSymbol:
            return 1000
        case .stockTag, .etfTag:
            return 800
        case .stockName, .etfName:
            return 500
        case .stockDescription, .etfDescription:
            return 300
        }
    }
}

// MARK: - 搜索结果包装
class SearchResult: Identifiable, ObservableObject {
    let id = UUID()
    @Published var symbol: String
    @Published var name: String
    @Published var tag: [String]
    @Published var marketCap: String?
    @Published var peRatio: String?
    @Published var compare: String?
    @Published var volume: String?
    
    init(symbol: String, name: String, tag: [String],
         marketCap: String? = nil, peRatio: String? = nil,
         compare: String? = nil, volume: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.tag = tag
        self.marketCap = marketCap
        self.peRatio = peRatio
        self.compare = compare
        self.volume = volume
    }
}

// MARK: - 分组 header
struct GroupHeaderView: View {
    let category: MatchCategory
    @Binding var isCollapsed: Bool
    
    var body: some View {
        HStack {
            Text(category.rawValue)
                .font(.headline)
                .foregroundColor(.gray)
            Spacer()
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .foregroundColor(.gray)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                isCollapsed.toggle()
            }
        }
    }
}

// MARK: - 主搜索按钮页面
struct SearchContentView: View {
    @State private var showSearch = false
    @State private var showCompare = false
    @State private var showEarning = false // 添加新状态
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        NavigationStack {
            HStack(spacing: 12) {
                Button(action: { showCompare = true }) {
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
                
                Button(action: { showSearch = true }) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("点击搜索")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                
                Button(action: { showEarning = true }) {
                    VStack {
                        Image(systemName: "calendar")
                            .font(.system(size: 20))
                        Text("财报")
                            .font(.caption)
                    }
                    .frame(width: 60)
                    .padding(.vertical, 8)
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
        .navigationDestination(isPresented: $showEarning) {
                    EarningReleaseView()
                }
    }
}

// MARK: - 搜索页面
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
    @State private var isFirstAppear = true
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showChartView: Bool = false
    @State private var selectedSymbolForChart: SelectedSymbol? = nil
    @State private var selectedSymbolForDescription: SelectedSymbol? = nil
    
    @State private var collapsedGroups: [MatchCategory: Bool] = [:]
    let isSearchActive: Bool
    
    init(isSearchActive: Bool = false, dataService: DataService) {
        self.isSearchActive = isSearchActive
        self.viewModel = SearchViewModel(dataService: dataService)
        _showSearchHistory = State(initialValue: isSearchActive)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding()
            
            ZStack {
                if showSearchHistory {
                    SearchHistoryView(viewModel: viewModel) { term in
                        searchText = term
                        startSearch()
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
                
                if isLoading {
                    ProgressView("正在搜索...")
                        .padding()
                }
                
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
            .sheet(item: $selectedSymbol) { selected in
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
        }
        .onAppear {
            if isSearchActive && isFirstAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                    isFirstAppear = false
                }
            }
        }
    }
    
    private var searchBar: some View {
        HStack {
            ZStack(alignment: .trailing) {
                TextField("请输入要搜索的关键字", text: $searchText, onEditingChanged: { isEditing in
                    withAnimation {
                        showSearchHistory = isEditing && searchText.isEmpty
                        if isEditing && searchText.isEmpty {
                            groupedSearchResults = []
                        }
                    }
                }, onCommit: {
                    startSearch()
                })
                .focused($isSearchFieldFocused)
                .padding(10)
                .padding(.trailing, showClearButton ? 30 : 10)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .onChange(of: searchText) { _, newValue in
                    showClearButton = !newValue.isEmpty
                    if newValue.isEmpty {
                        withAnimation {
                            showSearchHistory = true
                            groupedSearchResults = []
                        }
                    }
                }
                
                if showClearButton {
                    Button(action: {
                        searchText = ""
                        withAnimation {
                            showSearchHistory = true
                            groupedSearchResults = []
                            isSearchFieldFocused = true
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .opacity(0.6)
                    }
                    .padding(.trailing, 15)
                    .transition(.opacity)
                }
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
    
    private var searchResultsList: some View {
        List {
            ForEach(groupedSearchResults) { groupedResult in
                if !groupedResult.results.isEmpty {
                    Section(header: GroupHeaderView(
                        category: groupedResult.category,
                        isCollapsed: Binding(
                            get: { collapsedGroups[groupedResult.category] ?? false },
                            set: { collapsedGroups[groupedResult.category] = $0 }
                        )
                    )) {
                        if !(collapsedGroups[groupedResult.category] ?? false) {
                            ForEach(groupedResult.results.sorted { $0.score > $1.score }, id: \.result.id) { result, score in
                                Button(action: {
                                    handleResultSelection(result: result)
                                }) {
                                    SearchResultRow(result: result, score: score)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .sheet(item: $selectedSymbolForDescription) { selected in
            if let descriptions = getDescriptions(for: selected.result.symbol) {
                DescriptionView(descriptions: descriptions, isDarkMode: true)
            } else {
                DescriptionView(descriptions: ("No description available.", ""), isDarkMode: true)
            }
        }
        .navigationDestination(isPresented: $showChartView) {
            if let selected = selectedSymbolForChart {
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
        }
    }

    // 添加处理结果选择的方法
    private func handleResultSelection(result: SearchResult) {
        // 检查symbol是否在数据库中有数据
        if let groupName = viewModel.dataService.getCategory(for: result.symbol) {
            // 检查数据库中是否有该symbol的价格数据
            DispatchQueue.global(qos: .userInitiated).async {
                let data = DatabaseManager.shared.fetchHistoricalData(
                    symbol: result.symbol,
                    tableName: groupName,
                    dateRange: .timeRange(.oneMonth)
                )
                
                DispatchQueue.main.async {
                    if data.isEmpty {
                        // 如果没有价格数据，但有description数据
                        if getDescriptions(for: result.symbol) != nil {
                            selectedSymbolForDescription = SelectedSymbol(result: result, category: "Description")
                        }
                    } else {
                        // 有价格数据，通过导航打开ChartView
                        selectedSymbolForChart = SelectedSymbol(result: result, category: groupName)
                        showChartView = true
                    }
                }
            }
        } else {
            // 如果在分类中找不到，但可能有description
            if getDescriptions(for: result.symbol) != nil {
                selectedSymbolForDescription = SelectedSymbol(result: result, category: "Description")
            }
        }
    }

    // 添加获取描述的辅助方法
    private func getDescriptions(for symbol: String) -> (String, String)? {
        // 检查是否为股票
        if let stock = viewModel.dataService.descriptionData?.stocks.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (stock.description1, stock.description2)
        }
        // 检查是否为ETF
        if let etf = viewModel.dataService.descriptionData?.etfs.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (etf.description1, etf.description2)
        }
        return nil
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

// MARK: - 搜索结果行
struct SearchResultRow: View {
    @ObservedObject var result: SearchResult
    let score: Int
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(result.symbol)
                            .foregroundColor(.green)
                        Text(result.name)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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
                if let peRatio = result.peRatio, peRatio != "--" {
                    Text(peRatio)
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
                            .contentShape(Rectangle())
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

// MARK: - ViewModel
class SearchViewModel: ObservableObject {
    @Published var searchHistory: [String] = []
    @Published var errorMessage: String? = nil
    @Published var isChartLoading: Bool = false
    @Published var groupedSearchResults: [GroupedSearchResults] = []
    
    var dataService: DataService
    private var cancellables = Set<AnyCancellable>()
    
    init(dataService: DataService = DataService()) {
        self.dataService = dataService
        dataService.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
        loadSearchHistory()
    }
    
    func performSearch(query: String, completion: @escaping ([GroupedSearchResults]) -> Void) {
        let keywords = query.lowercased().split(separator: " ").map { String($0) }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let descriptionData = self.dataService.descriptionData else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            var groupedResults: [(
                group: GroupedSearchResults,
                matchScore: Int,
                priority: Int
            )] = []
            
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
                    let group = GroupedSearchResults(category: category, results: matches, highestScore: highestScore)
                    groupedResults.append((group, highestScore, category.priority))
                }
            }
            
            let sortedGroups = groupedResults.sorted {
                if $0.matchScore != $1.matchScore {
                    return $0.matchScore > $1.matchScore
                }
                return $0.priority > $1.priority
            }.map { $0.group }
            
            DispatchQueue.main.async {
                if !keywords.isEmpty {
                    self.addSearchHistory(term: query)
                }
                self.groupedSearchResults = sortedGroups
                self.fetchLatestVolumes(for: sortedGroups) {
                    completion(sortedGroups)
                }
            }
        }
    }
    
    // 为 ETF 搜索结果获取最新 volume
    private func fetchLatestVolumes(for groupedResults: [GroupedSearchResults], completion: @escaping () -> Void) {
        let etfCategories: Set<MatchCategory> = [.etfSymbol, .etfName, .etfDescription, .etfTag]
        
        for groupedResult in groupedResults {
            if etfCategories.contains(groupedResult.category) {
                for (_, entry) in groupedResult.results.enumerated() {
                    let symbol = entry.result.symbol
                    if let latestVolume = DatabaseManager.shared.fetchLatestVolume(forSymbol: symbol, tableName: "ETFs") {
                        DispatchQueue.main.async {
                            entry.result.volume = self.formatVolume(latestVolume)
                        }
                    } else {
                        DispatchQueue.main.async {
                            entry.result.volume = "--K"
                        }
                    }
                }
            }
        }
        completion()
    }
    
    private func formatVolume(_ volume: Int64) -> String {
        let kVolume = Double(volume) / 1000.0
        return String(format: "%.0fK", kVolume)
    }
    
    // 搜索类别，并根据结果进行匹配和排序
    func searchCategory<T: SearchDescribableItem>(items: [T],
                                                  keywords: [String],
                                                  category: MatchCategory)
    -> [(result: SearchResult, score: Int)] {
        var scoredResults: [(SearchResult, Int)] = []
        
        for item in items {
            if let totalScore = matchScoreForItem(item, category: category, keywords: keywords) {
                let upperSymbol = item.symbol.uppercased()
                let data = dataService.marketCapData[upperSymbol]
                let marketCap = data?.marketCap
                let peRatioStr = data?.peRatio != nil ? String(format: "%.2f", data!.peRatio!) : "--"
                
                let result = SearchResult(
                    symbol: item.symbol,
                    name: item.name,
                    tag: item.tag,
                    marketCap: marketCap,
                    peRatio: peRatioStr,
                    compare: dataService.compareData[upperSymbol]
                )
                
                scoredResults.append((result, totalScore))
            }
        }
        
        return scoredResults.sorted { $0.1 > $1.1 }
    }
    
    // 计算某个 item 与一组关键词在指定分类下的匹配分数
    private func matchScoreForItem<T: SearchDescribableItem>(
        _ item: T,
        category: MatchCategory,
        keywords: [String]) -> Int? {
        
        var totalScore = 0
        
        for keyword in keywords {
            let lowerKeyword = keyword.lowercased()
            let singleScore = scoreOfSingleMatch(item: item, keyword: lowerKeyword, category: category)
            if singleScore <= 0 {
                return nil
            } else {
                totalScore += singleScore
            }
        }
        return totalScore
    }
    
    // 计算单个关键词在指定分类下的匹配分数
    private func scoreOfSingleMatch<T: SearchDescribableItem>(
        item: T,
        keyword: String,
        category: MatchCategory) -> Int {
        
        switch category {
        case .stockSymbol, .etfSymbol:
            return matchSymbol(item.symbol.lowercased(), keyword: keyword)
        case .stockName, .etfName:
            return matchName(item.name, keyword: keyword)
        case .stockTag, .etfTag:
            return matchTags(item.tag, keyword: keyword)
        case .stockDescription, .etfDescription:
            return matchDescriptions(item.description1, item.description2, keyword: keyword)
        }
    }
    
    private func matchSymbol(_ symbol: String, keyword: String) -> Int {
        if symbol == keyword {
            return 3
        } else if symbol.contains(keyword) {
            return 2
        } else if isFuzzyMatch(text: symbol, keyword: keyword, maxDistance: 1) {
            return 1
        }
        return 0
    }
    
    private func matchName(_ name: String, keyword: String) -> Int {
        let lowercasedName = name.lowercased()
        let nameComponents = lowercasedName.components(separatedBy: ",")
        let mainName = nameComponents.first ?? lowercasedName
        let nameWords = mainName.split(separator: " ").map { String($0) }
        
        if lowercasedName == keyword {
            return 4
        } else if nameWords.contains(keyword) || mainName == keyword {
            return 3
        } else if mainName.contains(keyword) {
            return 2
        } else if lowercasedName.contains(keyword) {
            return 1
        } else if isFuzzyMatch(text: lowercasedName, keyword: keyword, maxDistance: 1) {
            return 1
        }
        return 0
    }
    
    private func matchTags(_ tags: [String], keyword: String) -> Int {
        var maxScore = 0
        for t in tags {
            let lowerTag = t.lowercased()
            var score = 0
            if lowerTag == keyword {
                score = 3
            } else if lowerTag.contains(keyword) {
                score = 2
            } else if isFuzzyMatch(text: lowerTag, keyword: keyword, maxDistance: 1) {
                score = 1
            }
            maxScore = max(maxScore, score)
        }
        return maxScore
    }
    
    private func matchDescriptions(_ desc1: String, _ desc2: String, keyword: String) -> Int {
        let d1 = desc1.lowercased()
        let d2 = desc2.lowercased()
        let words = d1.split(separator: " ") + d2.split(separator: " ")
        
        if words.contains(where: { String($0) == keyword }) {
            return 2
        } else if d1.contains(keyword) || d2.contains(keyword) {
            return 1
        }
        return 0
    }
    
    private func isFuzzyMatch(text: String, keyword: String, maxDistance: Int) -> Bool {
        if keyword.count <= 1 {
            return text.contains(keyword)
        }
        let words = text.split(separator: " ").map { String($0) }
        return words.contains { levenshteinDistance($0, keyword) <= maxDistance }
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
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
                        matrix[i - 1][j] + 1,
                        matrix[i][j - 1] + 1,
                        matrix[i - 1][j - 1] + 1
                    )
                }
            }
        }
        return matrix[n][m]
    }
    
    // MARK: - 搜索历史
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
