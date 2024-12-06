import Foundation
import Combine

class SearchViewModel: ObservableObject {
    @Published var searchHistory: [String] = []
    @Published var errorMessage: String? = nil
    @Published var isChartLoading: Bool = false
    @Published var chartData: [Double] = []
    @Published var groupedSearchResults: [GroupedSearchResults] = []
    
    private var descriptionData: SearchDescriptionData?
    private var sectorsData: [String: [String]] = [:]
    private var marketCapData: [String: SearchMarketCapDataItem] = [:]
    private var compareData: [String: String] = [:]
    
    init() {
        loadAllData()
        loadSearchHistory()
    }
    
    func loadAllData() {
        // 加载description.json
        if let url = Bundle.main.url(forResource: "description", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                descriptionData = try decoder.decode(SearchDescriptionData.self, from: data)
            } catch {
                errorMessage = "加载 description 数据失败: \(error.localizedDescription)"
            }
        }
        
        // 加载sectors_all.json
        if let url = Bundle.main.url(forResource: "Sectors_All", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                sectorsData = try decoder.decode([String: [String]].self, from: data)
            } catch {
                errorMessage = "加载 sectors 数据失败: \(error.localizedDescription)"
            }
        }
        
        loadMarketCapData()
        loadCompareData()
    }
    
    func getCategory(for symbol: String) -> String? {
        for (category, symbols) in sectorsData {
            if symbols.map({ $0.uppercased() }).contains(symbol.uppercased()) {
                return category
            }
        }
        return nil
    }
    
    func loadMarketCapData() {
        if let url = Bundle.main.url(forResource: "marketcap_pe", withExtension: "txt") {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(separator: "\n")
                
                for line in lines {
                    let parts = line.split(separator: ":")
                    if parts.count >= 2 {
                        let symbol = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
                        let values = parts[1].split(separator: ",")
                        
                        if values.count >= 2 {
                            if let marketCap = Double(values[0].trimmingCharacters(in: .whitespaces)) {
                                let peRatioString = values[1].trimmingCharacters(in: .whitespaces)
                                let peRatio = peRatioString == "--" ? nil : Double(peRatioString)
                                marketCapData[symbol] = SearchMarketCapDataItem(marketCap: marketCap, peRatio: peRatio)
                            }
                        }
                    }
                }
            } catch {
                errorMessage = "加载 MarketCap 数据失败: \(error.localizedDescription)"
            }
        }
    }
    
    func loadCompareData() {
        if let url = Bundle.main.url(forResource: "Compare_All", withExtension: "txt") {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(separator: "\n")
                
                for line in lines {
                    let parts = line.split(separator: ":")
                    if parts.count >= 2 {
                        let symbol = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
                        let value = parts[1].trimmingCharacters(in: .whitespaces)
                        compareData[symbol] = value
                    }
                }
            } catch {
                errorMessage = "加载 Compare 数据失败: \(error.localizedDescription)"
            }
        }
    }
    
    // 搜索功能
    func performSearch(query: String, completion: @escaping ([GroupedSearchResults]) -> Void) {
        let keywords = query.lowercased().split(separator: " ").map { String($0) }
            
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let descriptionData = self.descriptionData else {
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
                    results: results,
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
                let marketCap = marketCapData[item.symbol.uppercased()]?.marketCap
                let peRatio = marketCapData[item.symbol.uppercased()]?.peRatio
                let compare = compareData[item.symbol.uppercased()]
                
                let result = SearchResult(
                    symbol: item.symbol,
                    name: item.name,
                    tag: item.tag,
                    marketCap: formatMarketCap(marketCap),
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
    
    // 市值格式化
    private func formatMarketCap(_ cap: Double?) -> String? {
        guard let cap = cap else { return nil }
        return String(format: "%.1fB", cap / 1_000_000_000)
    }
}
