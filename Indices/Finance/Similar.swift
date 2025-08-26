import SwiftUI
import Foundation
import Combine

// 【新增】: 定义一个枚举来表示财报和股价的组合趋势
enum EarningTrend {
    case positiveAndUp    // 财报为正，股价上涨（亮红色）
    case positiveAndDown  // 财报为正，股价下跌（暗红色）
    case negativeAndUp    // 财报为负，股价上涨（亮绿色）
    case negativeAndDown  // 财报为负，股价下跌（暗绿色）
    case insufficientData // 数据不足，无法判断（白色）
}

struct MatchedSymbol {
    let symbol: String
    let matchedTags: [(tag: String, weight: Double)]
    let allTags: [String]
}

struct RelatedSymbol: Identifiable {
    let id = UUID()
    let symbol: String
    let totalWeight: Double
    let compareValue: String
    let allTags: [String]
    let marketCap: Double?
    // 【修改】: 使用新的 EarningTrend 枚举
    let earningTrend: EarningTrend
}

struct SimilarView: View {
    // 【注意】: 这里仍然使用主 DataService，因为它被传递给 ChartView 和 SearchView
    @EnvironmentObject var dataService: DataService
    @ObservedObject var viewModel: SimilarViewModel
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false
    
    let symbol: String
    
    init(symbol: String) {
        self.symbol = symbol
        self.viewModel = SimilarViewModel(symbol: symbol)
    }
    
    var body: some View {
        VStack {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            } else if viewModel.isLoading {
                ProgressView("Loading...")
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.relatedSymbols, id: \.id) { item in
                            // 【注意】: 此处的 getCategory 来自于 @EnvironmentObject var dataService
                            NavigationLink(destination: ChartView(symbol: item.symbol, groupName: dataService.getCategory(for: item.symbol) ?? "Unknown")) {
                                VStack(alignment: .leading, spacing: 8) {
                                    // 上面一行：symbol、totalWeight、compareValue、marketCap
                                    HStack(spacing: 12) {
                                        // 【修改】: 根据 EarningTrend 设置颜色
                                        Text(item.symbol)
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundColor(colorForEarningTrend(item.earningTrend))
                                            .shadow(radius: 1)
                                        
                                        // 2) score(totalWeight) 颜色：灰色
                                        Text("\(item.totalWeight, specifier: "%.2f")")
                                            .font(.subheadline)
                                            .foregroundColor(.gray)
                                        
                                        // 3) compare_all 文本颜色：根据内容动态变化
                                        Text("\(item.compareValue)")
                                            .font(.subheadline)
                                            // 【修改】: 使用辅助函数动态设置文本颜色
                                            .foregroundColor(colorForCompareValue(item.compareValue))
                                        
                                        Spacer()
                                    }
                                    
                                    // 下面一行：tags
                                    Text(item.allTags.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)  // 确保标签只显示一行
                                        .truncationMode(.tail)  // 如果文本过长，在末尾显示省略号
                                }
                                .padding()
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationBarTitle("Similar Symbols", displayMode: .inline)
        // 新增：在导航栏添加工具栏
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    // 点击按钮时，触发导航
                    showSearchView = true
                }) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        // 新增：定义导航的目标视图
        .navigationDestination(isPresented: $showSearchView) {
            // 传入 dataService 并设置 isSearchActive 为 true，让搜索框自动激活
            SearchView(isSearchActive: true, dataService: dataService)
        }
    }
    
    // 【新增】：用于根据 compareValue 决定颜色的辅助函数
    private func colorForCompareValue(_ value: String) -> Color {
        if value.contains("前") || value.contains("后") || value.contains("未") {
            return .orange
        } else {
            return .white
        }
    }
    
    // 【新增】: 根据 EarningTrend 返回相应颜色的辅助函数
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp:
            return .red // 红色
        case .negativeAndUp:
            return .purple // 紫色
        case .positiveAndDown:
            return .cyan // 蓝色
        case .negativeAndDown:
            return .green // 绿色
        case .insufficientData:
            return .white // 默认白色
        }
    }
}

class SimilarViewModel: ObservableObject {
    @Published var relatedSymbols: [RelatedSymbol] = []
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private let symbol: String
    private let dbQueue = DispatchQueue(label: "com.finance.db.queue") // 新增：创建串行队列
    
    init(symbol: String) {
        self.symbol = symbol
        loadSimilarSymbols()
    }
    
    private func loadSimilarSymbols() {
        isLoading = true
        
        // 使用串行队列处理数据库操作
        dbQueue.async {
            // 正确地使用 DataService1 单例
            let dataService1 = DataService1.shared
            
            // 预取 MNSPP 市值映射
            let marketCapMap: [String: Double] = {
                let rows = DatabaseManager.shared.fetchAllMarketCapData(from: "MNSPP")
                var dict: [String: Double] = [:]
                dict.reserveCapacity(rows.count)
                for row in rows {
                    dict[row.symbol.uppercased()] = row.marketCap
                }
                return dict
            }()
            
            // 获取 symbol 的 tags 及权重
            let targetTagsWithWeight = self.findTagsBySymbol(symbol: self.symbol, data: dataService1.descriptionData1)
            
            guard !targetTagsWithWeight.isEmpty else {
                DispatchQueue.main.async {
                    self.errorMessage = "未找到该 symbol 的 tags"
                    self.isLoading = false
                }
                return
            }
            
            // 查找相似的 symbols
            let relatedSymbolsDict = self.findSymbolsByTags(targetTagsWithWeight: targetTagsWithWeight, weightGroups: dataService1.tagsWeightConfig, data: dataService1.descriptionData1)
            
            var stocks = relatedSymbolsDict["stocks"] ?? []
            var etfs = relatedSymbolsDict["etfs"] ?? []
            stocks.removeAll { $0.symbol.uppercased() == self.symbol.uppercased() }
            etfs.removeAll { $0.symbol.uppercased() == self.symbol.uppercased() }
            
            // 创建 RelatedSymbol 数组
            let createRelatedSymbol = { (item: MatchedSymbol) -> RelatedSymbol in
                let totalWeight = item.matchedTags.reduce(0.0) { $0 + $1.weight }
                let compareValue = dataService1.compareData1[item.symbol.uppercased()] ?? ""
                let allTags = item.allTags
                let mc = marketCapMap[item.symbol.uppercased()]
                
                // --- 开始新的财报趋势计算逻辑 ---
                var trend: EarningTrend = .insufficientData

                let sortedEarnings = DatabaseManager.shared.fetchEarningData(forSymbol: item.symbol).sorted { $0.date > $1.date }

                if sortedEarnings.count >= 2 {
                    let latestEarningReport = sortedEarnings[0]
                    let previousEarningReport = sortedEarnings[1]

                    // 【核心修正】: 调用 DataService1 中新增的 getCategory 方法
                    if let tableName = dataService1.getCategory(for: item.symbol) {
                        let latestClosePrice = DatabaseManager.shared.fetchClosingPrice(
                            forSymbol: item.symbol, onDate: latestEarningReport.date, tableName: tableName
                        )
                        let previousClosePrice = DatabaseManager.shared.fetchClosingPrice(
                            forSymbol: item.symbol, onDate: previousEarningReport.date, tableName: tableName
                        )

                        if let latestPrice = latestClosePrice, let previousPrice = previousClosePrice {
                            let earningValue = latestEarningReport.price
                            
                            if earningValue > 0 {
                                trend = (latestPrice > previousPrice) ? .positiveAndUp : .positiveAndDown
                            } else {
                                trend = (latestPrice > previousPrice) ? .negativeAndUp : .negativeAndDown
                            }
                        }
                    }
                }
                // --- 结束新的财报趋势计算逻辑 ---

                return RelatedSymbol(symbol: item.symbol, totalWeight: totalWeight, compareValue: compareValue, allTags: allTags, marketCap: mc, earningTrend: trend)
            }
            
            let stocksRelated = stocks.map(createRelatedSymbol)
            let etfsRelated = etfs.map(createRelatedSymbol)
            
            let allSymbols = (stocksRelated + etfsRelated).filter { !$0.compareValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            
            let sortedSymbols = allSymbols.sorted { a, b in
                if a.totalWeight != b.totalWeight {
                    return a.totalWeight > b.totalWeight
                }
                let amc = a.marketCap ?? -Double.greatestFiniteMagnitude
                let bmc = b.marketCap ?? -Double.greatestFiniteMagnitude
                if amc != bmc {
                    return amc > bmc
                }
                return a.symbol < b.symbol
            }.prefix(50)
            
            DispatchQueue.main.async {
                self.relatedSymbols = Array(sortedSymbols)
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func findTagsBySymbol(symbol: String, data: DescriptionData1?) -> [(tag: String, weight: Double)] {
        guard let data = data else { return [] }
        var tagsWithWeight: [(String, Double)] = []
        
        for category in ["stocks", "etfs"] {
            let items: [SymbolItem]
            if category == "stocks" {
                items = data.stocks
            } else {
                items = data.etfs
            }
            
            for item in items {
                if item.symbol.uppercased() == symbol.uppercased() {
                    for tag in item.tag {
                        if let weightKey = DataService1.shared.tagsWeightConfig.first(where: { $0.value.contains(tag) })?.key {
                            tagsWithWeight.append((tag, weightKey))
                        } else {
                            tagsWithWeight.append((tag, 1.0)) // 默认权重
                        }
                    }
                    return tagsWithWeight
                }
            }
        }
        return tagsWithWeight
    }
    
    private func findSymbolsByTags(targetTagsWithWeight: [(tag: String, weight: Double)], weightGroups: [Double: [String]], data: DescriptionData1?) -> [String: [MatchedSymbol]] {
        var relatedSymbols: [String: [MatchedSymbol]] = ["stocks": [], "etfs": []]
        
        // 创建目标标签字典，键为小写标签，值为权重
        var targetTagsDict: [String: Double] = [:]
        for (tag, weight) in targetTagsWithWeight {
            targetTagsDict[tag.lowercased()] = weight
        }
        
        guard let data = data else { return relatedSymbols }
        
        for category in ["stocks", "etfs"] {
            let items: [SymbolItem]
            if category == "stocks" {
                items = data.stocks
            } else {
                items = data.etfs
            }
            
            for item in items {
                var matchedTags: [(tag: String, weight: Double)] = []
                var usedTags = Set<String>()
                
                // 第一阶段：完全匹配
                for tag in item.tag {
                    let tagLower = tag.lowercased()
                    if let weight = targetTagsDict[tagLower], !usedTags.contains(tagLower) {
                        matchedTags.append((tag, weight))
                        usedTags.insert(tagLower)
                    }
                }
                
                // 第二阶段：部分匹配
                for tag in item.tag {
                    let tagLower = tag.lowercased()
                    if usedTags.contains(tagLower) { continue }
                    for (targetTag, weight) in targetTagsDict {
                        if (tagLower.contains(targetTag) || targetTag.contains(tagLower)) && tagLower != targetTag && !usedTags.contains(targetTag) {
                            // 如果原始权重大于1，给1分；否则给原始权重分数
                            let matchWeight = weight > 1.0 ? 1.0 : weight
                            matchedTags.append((tag, matchWeight))
                            usedTags.insert(targetTag)
                            break
                        }
                    }
                }
                
                if !matchedTags.isEmpty {
                    relatedSymbols[category]?.append(MatchedSymbol(symbol: item.symbol, matchedTags: matchedTags, allTags: item.tag))
                }
            }
        }
        
        // 按总权重降序排序
        for category in relatedSymbols.keys {
            relatedSymbols[category]?.sort { (a, b) -> Bool in
                let totalA = a.matchedTags.reduce(0.0) { $0 + $1.weight }
                let totalB = b.matchedTags.reduce(0.0) { $0 + $1.weight }
                return totalA > totalB
            }
        }
        
        return relatedSymbols
    }
}
