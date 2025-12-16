import SwiftUI
import Foundation
import Combine

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
    
    // ==================== 修改开始 ====================
    // 1. 将 @ObservedObject 改为 @StateObject
    //    @StateObject 确保 ViewModel 的实例在视图的生命周期内只创建一次，
    //    即使在导航返回后，ViewModel 及其数据（包括滚动位置所依赖的列表）也能保持不变。
    @StateObject private var viewModel: SimilarViewModel
    // ==================== 修改结束 ====================

    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false
    
    // 【新增】权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    // 【修改】移除 showLoginSheet
    @State private var showSubscriptionSheet = false
    
    // 【新增】导航控制
    @State private var selectedSymbolItem: RelatedSymbol?
    @State private var isNavigationActive = false
    
    let symbol: String
    
    // ==================== 修改开始 ====================
    // 2. 修改 init 方法以正确初始化 @StateObject
    //    我们需要使用特殊的 `_viewModel` 属性来包裹 StateObject 的初始化过程。
    //    这是为带有参数的 @StateObject 进行初始化的标准方式。
    init(symbol: String) {
        self.symbol = symbol
        self._viewModel = StateObject(wrappedValue: SimilarViewModel(symbol: symbol))
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
                // ScrollView 现在会因为 ViewModel 的持久化而保持其滚动位置
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.relatedSymbols, id: \.id) { item in
                            // 【修改】使用 Button 替代 NavigationLink
                            Button(action: {
                                // 【修改】使用 .viewChart
                                if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                                    selectedSymbolItem = item
                                    isNavigationActive = true
                                } else {
                                    // 【核心修改】直接弹出订阅页
                                    showSubscriptionSheet = true
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    // 上面一行：symbol、totalWeight、compareValue、marketCap
                                    HStack(spacing: 12) {
                                        // 1) Symbol 颜色：根据 EarningTrend 动态变化
                                        Text(item.symbol)
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundColor(colorForEarningTrend(item.earningTrend))
                                            .shadow(radius: 1) // 稍微加点阴影让亮色在白底上更突出
                                        
                                        // 2) Score (totalWeight) 颜色：使用 secondary
                                        Text("\(item.totalWeight, specifier: "%.2f")")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary) // 【修改】从 gray 改为 secondary
                                        
                                        // 【修改点 1】: 将 Spacer() 移到这里
                                        // 这会将左边的内容顶在左侧，右边的内容顶在最右侧
                                        Spacer()
                                        
                                        // 3) Compare Value 文本
                                        // 【修改点 2】: 放在 Spacer 之后，实现靠右对齐
                                        Text("\(item.compareValue)")
                                            .font(.subheadline)
                                            // 使用新的逻辑判断颜色
                                            .foregroundColor(colorForCompareValue(item.compareValue))
                                    }
                                    
                                    // 下面一行：tags
                                    Text(item.allTags.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundColor(.secondary) // 【修改】从 gray 改为 secondary
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .padding()
                                // 【修改】使用 systemGray6 作为卡片背景，适配深色/浅色模式
                                .background(Color(.systemGray6)) 
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle()) // 【新增】防止 Button 点击时的默认灰色覆盖效果太丑
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationBarTitle("Similar Symbols", displayMode: .inline)
        // 【新增】程序化导航
        .navigationDestination(isPresented: $isNavigationActive) {
            if let item = selectedSymbolItem {
                ChartView(symbol: item.symbol, groupName: dataService.getCategory(for: item.symbol) ?? "Unknown")
            }
        }
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
        // 【修改】移除了 LoginView 的 sheet
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    // 【核心修改】: 增强了解析逻辑，支持 "09前-1.51%" 这种格式
    private func colorForCompareValue(_ value: String) -> Color {
        // 1. 先去掉 % 及后面的内容
        // 例子 A: "09前-1.51%" -> 得到 "09前-1.51"
        // 例子 B: "-0.26%*"   -> 得到 "-0.26"
        guard let valueBeforePercent = value.components(separatedBy: "%").first else {
            return .primary
        }
        
        var numberString = valueBeforePercent
        
        // 2. 检查是否包含中文分隔符 "前" 或 "后"
        // 如果包含，我们只需要分隔符后面的部分
        if valueBeforePercent.contains("前") {
            // "09前-1.51" -> 分割成 ["09", "-1.51"] -> 取最后一个 "-1.51"
            numberString = valueBeforePercent.components(separatedBy: "前").last ?? numberString
        } else if valueBeforePercent.contains("后") {
            // "09后-0.48" -> 分割成 ["09", "-0.48"] -> 取最后一个 "-0.48"
            numberString = valueBeforePercent.components(separatedBy: "后").last ?? numberString
        }
        
        // 3. 转为 Double 并判断颜色
        // trimmingCharacters 用于防止解析出来的字符串前后可能有空格
        if let doubleValue = Double(numberString.trimmingCharacters(in: .whitespaces)) {
            if doubleValue > 0 {
                return .red      // 正数
            } else if doubleValue < 0 {
                return .green    // 负数
            }
        }
        
        // 0 或者解析失败（比如纯文本）显示 Primary 颜色
        return .primary
    }
    
    // 【核心修复】: 修复 Light Mode 下不可见的问题，并优化对比度
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
            // 【修改】: 以前是 .white，导致浅色模式不可见。改为 .primary
            return .primary 
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
        
        // 使用 Task 替代 dbQueue
        Task {
            let dataService1 = DataService1.shared
            
            // 1. 异步获取市值映射
            let rows = await DatabaseManager.shared.fetchAllMarketCapData(from: "MNSPP")
            var marketCapMap: [String: Double] = [:]
            marketCapMap.reserveCapacity(rows.count)
            for row in rows {
                marketCapMap[row.symbol.uppercased()] = row.marketCap
            }
            
            // 2. 计算 Tags (内存操作)
            let targetTagsWithWeight = self.findTagsBySymbol(symbol: self.symbol, data: dataService1.descriptionData1)
            
            guard !targetTagsWithWeight.isEmpty else {
                await MainActor.run {
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
            
            // 3. 处理结果并异步获取财报趋势
            // 由于需要对每个结果进行网络请求，这里使用 TaskGroup 并发处理以提高速度
            var processedSymbols: [RelatedSymbol] = []
            let allCandidates = stocks + etfs
            
            await withTaskGroup(of: RelatedSymbol?.self) { group in
                for item in allCandidates {
                    group.addTask {
                        let totalWeight = item.matchedTags.reduce(0.0) { $0 + $1.weight }
                        let compareValue = dataService1.compareData1[item.symbol.uppercased()] ?? ""
                        // 过滤掉没有 compareValue 的
                        if compareValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                        
                        let allTags = item.allTags
                        let mc = marketCapMap[item.symbol.uppercased()]
                        
                        // 异步获取财报趋势
                        var trend: EarningTrend = .insufficientData
                        let sortedEarnings = await DatabaseManager.shared.fetchEarningData(forSymbol: item.symbol).sorted { $0.date > $1.date }
                        
                        if sortedEarnings.count >= 2 {
                            let latestEarning = sortedEarnings[0]
                            let previousEarning = sortedEarnings[1]
                            
                            if let tableName = dataService1.getCategory(for: item.symbol) {
                                async let latestClose = DatabaseManager.shared.fetchClosingPrice(forSymbol: item.symbol, onDate: latestEarning.date, tableName: tableName)
                                async let previousClose = DatabaseManager.shared.fetchClosingPrice(forSymbol: item.symbol, onDate: previousEarning.date, tableName: tableName)
                                
                                if let latest = await latestClose, let previous = await previousClose {
                                    if latestEarning.price > 0 {
                                        trend = (latest > previous) ? .positiveAndUp : .positiveAndDown
                                    } else {
                                        trend = (latest > previous) ? .negativeAndUp : .negativeAndDown
                                    }
                                }
                            }
                        }
                        
                        return RelatedSymbol(symbol: item.symbol, totalWeight: totalWeight, compareValue: compareValue, allTags: allTags, marketCap: mc, earningTrend: trend)
                    }
                }
                
                for await result in group {
                    if let res = result {
                        processedSymbols.append(res)
                    }
                }
            }
            
            // 排序
            let sortedSymbols = processedSymbols.sorted { a, b in
                if a.totalWeight != b.totalWeight { return a.totalWeight > b.totalWeight }
                let amc = a.marketCap ?? -Double.greatestFiniteMagnitude
                let bmc = b.marketCap ?? -Double.greatestFiniteMagnitude
                if amc != bmc { return amc > bmc }
                return a.symbol < b.symbol
            }.prefix(50)
            
            await MainActor.run {
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