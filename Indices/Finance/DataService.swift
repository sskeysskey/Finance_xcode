import Foundation
import Combine
import SwiftUI

// 桥接壳：对外 API 基本不变，但全部转发给 DataService.shared
final class DataService1 {
    static let shared = DataService1()
    private init() {}
    
    // 与原 API 保持相同命名
    var descriptionData1: DescriptionData1? {
        DataService.shared.descriptionData1
    }
    
    var tagsWeightConfig: [Double: [String]] {
        DataService.shared.tagsWeightConfig
    }
    
    var compareData1: [String: String] {
        // 使用合并后 DataService 中的大写映射
        DataService.shared.compareDataUppercased
    }
    
    var sectorsData: [String: [String]] {
        DataService.shared.sectorsData
    }
    
    func loadAllData() {
        // 统一由 DataService 管理加载生命周期
        DataService.shared.forceReloadData()
    }
    
    func getCategory(for symbol: String) -> String? {
        DataService.shared.getCategory(for: symbol)
    }
}

// MARK: - 新增：High/Low 数据模型
struct HighLowItem: Identifiable, Codable {
    var id = UUID()
    let symbol: String
}

struct HighLowGroup: Identifiable {
    let id: String // 使用 timeInterval 作为 id
    let timeInterval: String
    var items: [HighLowItem]
}

// 定义模型结构
struct DescriptionData: Codable {
    let global: [String: String]?
    let stocks: [SearchStock]
    let etfs: [SearchETF]
}

// MARK: - 【新增】期权数据模型
struct OptionItem: Identifiable, Hashable {
    let id = UUID()
    let symbol: String
    let type: String       // Calls / Puts
    let expiryDate: String // Expiry Date
    let strike: String     // Strike
    let openInterest: String // Open Interest
    let change: String     // 1-Day Chg
}

struct SearchStock: Identifiable, Codable, SearchDescribableItem {
    let id = UUID()
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    let description3: [[String: String]]?
    
    enum CodingKeys: String, CodingKey {
        case symbol, name, tag, description1, description2, description3
    }
}

struct SearchETF: Identifiable, Codable, SearchDescribableItem {
    let id = UUID()
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    let description3: [[String: String]]?
    
    enum CodingKeys: String, CodingKey {
        case symbol, name, tag, description1, description2, description3
    }
}

struct MarketCapDataItem {
    let marketCap: String
    let peRatio: Double?
    let pb: Double?

    init(marketCap: Double, peRatio: Double?, pb: Double?) {
        self.marketCap = Self.formatMarketCap(marketCap)
        self.peRatio = peRatio
        self.pb = pb
    }
    
    private static func formatMarketCap(_ cap: Double) -> String {
        String(format: "%.0fB", cap / 1_000_000_000)
    }
}

// 1. 更新 EarningRelease 模型以匹配新格式
struct EarningRelease: Identifiable {
    let id = UUID()
    let symbol: String
    let timing: String // BMO, AMC, TNS
    let date: String   // 存储 "MM-dd" 格式的日期
    let fullDate: Date // 新增：存储完整的日期对象（用于计算）
}

// 【新增】: 定义一个枚举来表示财报和股价的组合趋势
enum EarningTrend {
    case positiveAndUp    // 财报为正，股价上涨（亮红色）
    case positiveAndDown  // 财报为正，股价下跌（暗红色）
    case negativeAndUp    // 财报为负，股价上涨（亮绿色）
    case negativeAndDown  // 财报为负，股价下跌（暗绿色）
    case insufficientData // 数据不足，无法判断（白色）
}

// 保留与 b.swift 相同的结构，供 SimilarViewModel 等使用
protocol SymbolItem {
    var symbol: String { get }
    var tag: [String] { get }
}

struct DescriptionData1: Codable {
    let stocks: [Stock1]
    let etfs: [ETF1]
}

struct Stock1: Codable, SymbolItem {
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    let value: String
}

struct ETF1: Codable, SymbolItem {
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    let value: String
}

class DataService: ObservableObject {
    // MARK: - Singleton
    static let shared = DataService()
    private init() {}

    // 【新增】内部状态，标记是否正在加载
    private var isLoading = false 
    
    // MARK: - Published properties
    @Published var topGainers: [Stock] = []
    @Published var topLosers: [Stock] = []
    @Published var etfGainers: [ETF] = []
    @Published var etfLosers: [ETF] = []
    
    @Published var descriptionData: DescriptionData?
    // 合并新增：轻量版本（与 b.swift 一致）
    @Published var descriptionData1: DescriptionData1?
    
    @Published var marketCapData: [String: MarketCapDataItem] = [:]
    @Published var sectorsData: [String: [String]] = [:]
    
    // 原 compareData（你已有的“合并大小写键”的策略）
    @Published var compareData: [String: String] = [:]
    // 合并新增：仅大写键映射，供 b.swift/Similar 使用
    @Published var compareDataUppercased: [String: String] = [:]
    
    @Published var sectorsPanel: SectorsPanel?
    @Published var symbolEarningData: [String: [Date: Double]] = [:]
    
    @Published var earningReleases: [EarningRelease] = []
    
    // 公开缓存：已获取的财报趋势
    @Published var earningTrends: [String: EarningTrend] = [:]
    
    // 【新增】存储 ETFs 的 Top 10 和 Bottom 10
    // 注意：这里假设 IndicesSymbol 在同一个 Target 下可见。
    // 如果报错找不到 IndicesSymbol，请将 Indices.swift 中的 IndicesSymbol 结构体定义移动到一个单独的文件或 DataService.swift 顶部。
    @Published var etfTopGainers: [IndicesSymbol] = []
    @Published var etfTopLosers: [IndicesSymbol] = []
    
    // High/Low
    @Published var highGroups: [HighLowGroup] = []
    @Published var lowGroups: [HighLowGroup] = []
    
    @Published var errorMessage: String? = nil
    
    @Published var globalTimeMarkers: [Date: String] = [:]
    @Published var symbolTimeMarkers: [String: [Date: String]] = [:]
    
    // MARK: - 新增：tags 权重（合并自 DataService1）
    @Published var tagsWeightConfig: [Double: [String]] = [:]

    // 【新增】存储 10年新高 的数据
    @Published var tenYearHighSectors: [IndicesSector] = []

    // MARK: - 【新增】期权数据存储
    // Key 是 Symbol (大写), Value 是该 Symbol 下所有的期权条目
    @Published var optionsData: [String: [OptionItem]] = [:]
    
    private var isDataLoaded = false
    private var isInitialLoad: Bool {
        let localVersion = UserDefaults.standard.string(forKey: "FinanceAppLocalDataVersion")
        return localVersion == nil || localVersion == "0.0"
    }

    // 【核心修改】：将 loadData 改为异步触发，不阻塞主线程
    func loadData() {
        // 【修改】同时检查 是否已加载 和 是否正在加载
        guard !isDataLoaded, !isLoading else {
            print("DataService: 数据已加载或正在加载中，跳过重复请求。")
            return
        }
        
        // 标记开始加载
        self.isLoading = true
        
        DispatchQueue.main.async { self.errorMessage = nil }

        Task.detached(priority: .userInitiated) {
            print("DataService: 开始在后台加载数据...")
            
            // 1. 并行或串行加载本地文件 (IO操作)
            // 注意：这里调用的是同步方法，但在 detached Task 中运行，不会卡 UI
            await self.loadDescriptionPair()
            await self.loadSectorsData()
            await self.loadCompareDataPair()
            await self.loadSectorsPanel()
            await self.loadEarningRelease()
            await self.loadHighLowData()
            await self.loadCompareStock()
            await self.loadTagsWeight()
            await self.loadCompareETFs()
            // 【新增】加载 10年新高数据
            await self.loadTenYearHighData()
            await self.loadOptionsData() // 加载期权数据

            await MainActor.run {
                self.isDataLoaded = true
                self.isLoading = false // 【新增】加载完成，重置 loading 状态
                print("DataService: 所有本地数据加载完毕 (UI已更新)。")
            }
            
            // 3. 启动网络请求 (本身就是 async 的)
            await self.loadMarketCapData()
        }
    }

    // MARK: - 公共方法：强制重新加载
    // 注意：forceReloadData 需要重置 isLoading
    func forceReloadData() {
        print("DataService: 收到强制刷新请求...")
        self.isDataLoaded = false
        self.isLoading = false // 强制刷新时允许重新进入
        self.loadData()
    }
    
    // MARK: - 【新增】加载并解析 10年新高数据
    private func loadTenYearHighData() async {
        // 使用 getLatestFileUrl 自动匹配日期后缀 (例如 10Y_newhigh_stock_251212.txt)
        guard let url = FileManagerHelper.getLatestFileUrl(for: "10Y_newhigh_stock") else {
            if !isInitialLoad {
                print("DataService: 10Y_newhigh_stock 文件未在 Documents 中找到")
            }
            return
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            
            // 临时字典用于分组： [GroupName: [Symbols]]
            var tempGroups: [String: [IndicesSymbol]] = [:]
            
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                
                // 解析行: "Basic_Materials HBM 0.32%*++ 18.68 铜,铜矿..."
                // 按空格分割，限制分割次数，确保 tags 部分保持完整（如果有空格）
                // 至少需要: Group, Symbol, Value
                let parts = trimmedLine.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                
                if parts.count >= 3 {
                    let groupName = String(parts[0])
                    let symbolStr = String(parts[1])
                    let valueStr = String(parts[2]) // e.g. "0.32%*++"
                    
                    // 处理 Price 和 Tags
                    // 原格式: Group Symbol Value Price Tags...
                    // 我们把 Price 和 Tags 合并显示在 Tags 区域，或者只显示 Tags
                    var tags: [String]? = nil
                    
                    // 尝试提取 Price 和后续描述
                    if parts.count >= 4 {
                        let price = String(parts[3])
                        var descriptionStr = ""
                        if parts.count >= 5 {
                            descriptionStr = String(parts[4])
                        }
                        
                        // 将价格和描述组合，或者只用描述。这里为了信息完整，我们将价格放在 tags 的第一个位置
                        let combinedTagStr = "\(price), " + descriptionStr
                        tags = combinedTagStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    }
                    
                    let symbolItem = IndicesSymbol(
                        symbol: symbolStr,
                        name: symbolStr, // 暂时用 symbol 当名字
                        value: valueStr,
                        tags: tags
                    )
                    
                    if tempGroups[groupName] == nil {
                        tempGroups[groupName] = []
                    }
                    tempGroups[groupName]?.append(symbolItem)
                }
            }
            
            // 将字典转换为 [IndicesSector] 数组，并按名称排序
            let sectors = tempGroups.map { (key, value) in
                IndicesSector(name: key, symbols: value)
            }.sorted { $0.name < $1.name }
            
            await MainActor.run {
                self.tenYearHighSectors = sectors
            }
            
        } catch {
            print("DataService: 解析 10Y_newhigh_stock 文件时出错: \(error)")
        }
    }
    
    // 修改：异步获取财报趋势
    // 修复了 Swift 6 并发变量捕获错误
    public func fetchEarningTrends(for symbols: [String]) {
        Task {
            for symbol in symbols {
                let upperSymbol = symbol.uppercased()
                
                // 检查缓存 (在 MainActor 上安全读取)
                let alreadyExists = await MainActor.run { self.earningTrends[upperSymbol] != nil }
                if alreadyExists { continue }
                
                // 异步获取数据
                let sortedEarnings = await DatabaseManager.shared.fetchEarningData(forSymbol: symbol).sorted { $0.date > $1.date }
                
                var calculatedTrend: EarningTrend = .insufficientData
                
                if sortedEarnings.count >= 2 {
                    let latestEarning = sortedEarnings[0]
                    let previousEarning = sortedEarnings[1]
                    
                    // 安全获取 tableName (涉及读取 sectorsData，建议在 MainActor)
                    let tableName = await MainActor.run { self.getCategory(for: symbol) }
                    
                    if let tableName = tableName {
                        // 顺序获取价格，避免 async let 导致的变量捕获问题
                        let latestClose = await DatabaseManager.shared.fetchClosingPrice(forSymbol: symbol, onDate: latestEarning.date, tableName: tableName)
                        let previousClose = await DatabaseManager.shared.fetchClosingPrice(forSymbol: symbol, onDate: previousEarning.date, tableName: tableName)
                        
                        if let latest = latestClose, let previous = previousClose {
                            if latestEarning.price > 0 {
                                calculatedTrend = (latest > previous) ? .positiveAndUp : .positiveAndDown
                            } else {
                                calculatedTrend = (latest > previous) ? .negativeAndUp : .negativeAndDown
                            }
                        }
                    }
                }
                
                // 最终更新 UI
                let finalTrend = calculatedTrend
                await MainActor.run {
                    self.earningTrends[upperSymbol] = finalTrend
                }
            }
        }
    }
    
    // 修改：异步加载市值数据
    // 标记为 @MainActor，解决 newData 捕获问题和主线程更新问题
    @MainActor
    private func loadMarketCapData() async {
        // 网络请求（URLSession 自动在后台运行，不会阻塞主线程）
        let allMarketCapInfo = await DatabaseManager.shared.fetchAllMarketCapData(from: "MNSPP")
        
        if allMarketCapInfo.isEmpty {
            if !isInitialLoad {
                self.errorMessage = "无法从服务器加载市值数据。"
            }
            return
        }
        
        var newData: [String: MarketCapDataItem] = [:]
        for info in allMarketCapInfo {
            let item = MarketCapDataItem(marketCap: info.marketCap, peRatio: info.peRatio, pb: info.pb)
            newData[info.symbol.uppercased()] = item
        }
        
        // 因为函数标记了 @MainActor，这里可以直接赋值
        self.marketCapData = newData
    }

    // MARK: - 【核心修改】加载期权数据 CSV
    private func loadOptionsData() async {
        // 匹配文件名 Options_Change_*.csv
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Options_Change") else {
            if !isInitialLoad {
                print("DataService: Options_Change 文件未在 Documents 中找到")
            }
            return
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            
            var tempOptions: [String: [OptionItem]] = [:]
            
            // 遍历每一行
            for (index, line) in lines.enumerated() {
                // 1. 跳过表头 (如果第一行包含 "Symbol" 和 "Type")
                if index == 0 && line.contains("Symbol") && line.contains("Type") {
                    continue
                }
                
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                
                // 2. 尝试 Tab 分割 (优先，因为样本看起来像 Tab)
                var parts = trimmedLine.components(separatedBy: "\t")
                
                // 如果 Tab 分割失败（只有1列），尝试逗号分割
                if parts.count <= 1 {
                    parts = trimmedLine.split(separator: ",").map { String($0) }
                }
                
                // 去除每个部分的空白
                parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
                
                // 3. 解析列 (根据样本: Symbol, Type, Expiry Date, Strike, Open Interest, 1-Day Chg)
                if parts.count >= 6 {
                    let symbol = parts[0].uppercased()
                    let type = parts[1]
                    let expiry = parts[2]
                    let strike = parts[3]
                    
                    // 【修改点 1：去除小数点】
                    // 读取原始字符串 -> 转为 Double -> 格式化为无小数点的 String
                    let rawOi = parts[4]
                    let rawChg = parts[5]
                    
                    let oi = String(format: "%.0f", Double(rawOi) ?? 0)
                    let chg = String(format: "%.0f", Double(rawChg) ?? 0)
                    
                    let item = OptionItem(
                        symbol: symbol,
                        type: type,
                        expiryDate: expiry,
                        strike: strike,
                        openInterest: oi, // 存入处理后的整数
                        change: chg      // 存入处理后的整数
                    )
                    
                    if tempOptions[symbol] == nil {
                        tempOptions[symbol] = []
                    }
                    tempOptions[symbol]?.append(item)
                }
            }
            
            // 【修复 Swift 6 错误】
            // 创建一个不可变的副本，以便安全地传递给 MainActor 闭包
            let finalOptions = tempOptions
            await MainActor.run {
                self.optionsData = finalOptions
            }
            
        } catch {
            print("DataService: 解析 Options_Change 文件时出错: \(error)")
        }
    }
    
    private func loadHighLowData() async {
        // (保留原代码)
        guard let url = FileManagerHelper.getLatestFileUrl(for: "HighLow") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

            var highGroupsDict: [String: HighLowGroup] = [:]
            var lowGroupsDict: [String: HighLowGroup] = [:]

            var currentTimeInterval: String? = nil
            var currentSection: String? = nil // "High" or "Low"

            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                    currentTimeInterval = String(trimmedLine.dropFirst().dropLast())
                    currentSection = nil
                    continue
                }

                if trimmedLine.lowercased() == "high:" {
                    currentSection = "High"
                    continue
                }

                if trimmedLine.lowercased() == "low:" {
                    currentSection = "Low"
                    continue
                }
                
                if trimmedLine.isEmpty { continue }

                if let interval = currentTimeInterval, let section = currentSection {
                    let symbols = trimmedLine.split(separator: ",").map {
                        HighLowItem(symbol: String($0).trimmingCharacters(in: .whitespaces))
                    }
                    
                    if symbols.isEmpty { continue }

                    if section == "High" {
                        if highGroupsDict[interval] == nil {
                            highGroupsDict[interval] = HighLowGroup(id: interval, timeInterval: interval, items: [])
                        }
                        highGroupsDict[interval]?.items.append(contentsOf: symbols)
                    } else if section == "Low" {
                        if lowGroupsDict[interval] == nil {
                            lowGroupsDict[interval] = HighLowGroup(id: interval, timeInterval: interval, items: [])
                        }
                        lowGroupsDict[interval]?.items.append(contentsOf: symbols)
                    }
                }
            }
            
            let timeIntervalOrder = ["5Y", "2Y", "1Y", "6 months", "3 months", "1 months"]
            let finalHigh = timeIntervalOrder.compactMap { highGroupsDict[$0] }
            let finalLow = timeIntervalOrder.compactMap { lowGroupsDict[$0] }
            
            // 回到主线程更新
            await MainActor.run {
                self.highGroups = finalHigh
                self.lowGroups = finalLow
            }

        } catch {
            await MainActor.run {
                self.errorMessage = "加载 HighLow.txt 失败: \(error.localizedDescription)"
            }
        }
    }
        
    private func loadEarningRelease() async {
        let filePrefixes = ["Earnings_Release_new", "Earnings_Release_next", "Earnings_Release_third", "Earnings_Release_fourth", "Earnings_Release_fifth"]
        let urlsToProcess = filePrefixes.compactMap { prefix in
            FileManagerHelper.getLatestFileUrl(for: prefix)
        }
        guard !urlsToProcess.isEmpty else {
            if !isInitialLoad {
                await MainActor.run { self.errorMessage = "Earnings_Release 文件未在 Documents 中找到" }
            }
            return
        }
        var allEarningReleases: [EarningRelease] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        do {
            for url in urlsToProcess {
                let content = try String(contentsOf: url, encoding: .utf8)
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                for line in lines {
                    let parts = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 3 else { continue }
                    let symbol = String(parts[0])
                    let timing = String(parts[1])
                    let fullDateStr = String(parts[2]) // "YYYY-MM-DD"
                    
                    // 解析完整日期
                    guard let fullDate = dateFormatter.date(from: fullDateStr) else { continue }
                    
                    let dateComponents = fullDateStr.split(separator: "-")
                    guard dateComponents.count == 3 else { continue }
                    let month = dateComponents[1]
                    let day = dateComponents[2]
                    let displayDate = "\(month)-\(day)"
                    
                    let release = EarningRelease(
                        symbol: symbol,
                        timing: timing,
                        date: displayDate,
                        fullDate: fullDate
                    )
                    allEarningReleases.append(release)
                }
            }
            
            // 【修复 Swift 6 警告】：创建不可变副本以供捕获
            let finalEarningReleases = allEarningReleases
            
            await MainActor.run {
                self.earningReleases = finalEarningReleases
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "加载财报文件失败: \(error.localizedDescription)"
            }
        }
    }

    private func loadCompareStock() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "CompareStock") else {
            if !isInitialLoad {
                await MainActor.run { self.errorMessage = "CompareStock 文件未在 Documents 中找到" }
            }
            return
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            
            let topGainersLines = lines.prefix(20)
            let topLosersLines = lines.suffix(20).reversed()
            
            let newTopGainers = topGainersLines.compactMap { parseStockLine(String($0)) }
            let newTopLosers = topLosersLines.compactMap { parseStockLine(String($0)) }
            
            await MainActor.run {
                self.topGainers = newTopGainers
                self.topLosers = newTopLosers
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "加载 CompareStock 文件失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 新增：加载并解析 CompareETFs.txt
    private func loadCompareETFs() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "CompareETFs") else {
            if !isInitialLoad {
                print("DataService: CompareETFs 文件未在 Documents 中找到")
            }
            return
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n").map { String($0) }
            
            // 过滤空行
            let validLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            guard !validLines.isEmpty else { return }
            
            // 获取 Top 10 (前10行)
            let top10Lines = validLines.prefix(10)
            // 获取 Bottom 10 (后10行，并倒序)
            let bottom10Lines = validLines.suffix(10).reversed()
            
            let topSymbols = top10Lines.compactMap { parseETFLineToSymbol($0) }
            let bottomSymbols = bottom10Lines.compactMap { parseETFLineToSymbol($0) }
            
            await MainActor.run {
                self.etfTopGainers = topSymbols
                self.etfTopLosers = bottomSymbols
            }
            
        } catch {
            print("DataService: 解析 CompareETFs 文件时出错: \(error)")
        }
    }
    
    // 辅助方法：将一行文本解析为 IndicesSymbol
    // 格式示例: "TUR.+     :   1.71%   81239        22.04%   土耳其, 股票"
    private func parseETFLineToSymbol(_ line: String) -> IndicesSymbol? {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        
        // 1. 处理 Symbol 部分 (左边)
        let rawSymbolPart = String(parts[0]).trimmingCharacters(in: .whitespaces)
        // 去除后缀 (.*, .+, .-, ++, -- 等)
        // 逻辑：找到第一个非字母数字字符的位置，截取前面的部分
        let symbol: String
        if let range = rawSymbolPart.range(of: "[^A-Za-z0-9]", options: .regularExpression) {
            symbol = String(rawSymbolPart[..<range.lowerBound])
        } else {
            symbol = rawSymbolPart
        }
        
        // 2. 处理数据部分 (右边)
        let dataPart = String(parts[1]).trimmingCharacters(in: .whitespaces)
        // 假设格式为: Value(百分比) Volume Percentage2 Description...
        // 使用正则提取第一段百分比和最后面的描述
        // 匹配：开头非空字符(Value) ... 中间任意 ... 结尾非空字符(Tags)
        // 或者简单按空格分割
        
        let components = dataPart.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        let value = components.first ?? ""
        
        // 尝试提取 Tags (描述)，通常在第3个字段之后，或者直接取后半部分
        // 简单的策略：如果组件超过3个，剩下的就是 tags
        var tags: [String]? = nil
        if components.count >= 4 {
            // 重新组合后面的部分作为 tags 字符串，然后按逗号分割
            // 这里的索引 3 是基于示例 "1.71% (0) 81239 (1) 22.04% (2) 土耳其, 股票 (3...)"
            // 但有时候中间数字可能少。
            // 更稳妥的方式：找到最后一个百分比数字之后的内容。
            
            // 这里为了简单有效，我们假设前3个块是数据，后面是描述
            let descriptionStartIndex = 3
            if components.count > descriptionStartIndex {
                let descriptionString = components[descriptionStartIndex...].joined(separator: " ")
                tags = descriptionString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
        } else if components.count > 1 {
             // 容错处理
             let descriptionString = components[1...].joined(separator: " ")
             tags = descriptionString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        
        // 构造 IndicesSymbol
        // name 我们暂时用 symbol 代替，或者留空，因为 UI 主要显示 symbol 和 tags
        return IndicesSymbol(symbol: symbol, name: symbol, value: value, tags: tags)
    }
    
    private func loadSectorsPanel() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Sectors_panel") else {
            if !isInitialLoad {
                await MainActor.run { self.errorMessage = "Sectors_panel 文件未在 Documents 中找到" }
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decodedData = try JSONDecoder().decode(SectorsPanel.self, from: data)
            await MainActor.run { self.sectorsPanel = decodedData }
        } catch {
            await MainActor.run { self.errorMessage = "加载 Sectors_panel.json 失败: \(error.localizedDescription)" }
        }
    }

    private func loadDescriptionPair() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "description") else {
            if !isInitialLoad {
                await MainActor.run { self.errorMessage = "description 文件未在 Documents 中找到" }
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            
            // 解重型（含 description3）
            let loadedDescriptionData = try decoder.decode(DescriptionData.self, from: data)
            // 解轻量（b.swift 使用）
            let loadedDescriptionData1 = try decoder.decode(DescriptionData1.self, from: data)
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            // 1) 全局时间标记
            var newGlobalTimeMarkers: [Date: String] = [:]
            if let global = loadedDescriptionData.global {
                for (dateString, text) in global {
                    if let date = dateFormatter.date(from: dateString) {
                        newGlobalTimeMarkers[date] = text
                    }
                }
            }
            
            // 2) 特定股票/ETF的时间标记
            var newSymbolTimeMarkers: [String: [Date: String]] = [:]
            let processItemsWithDescription3 = { (items: [SearchDescribableItem]) in
                for item in items {
                    guard let description3 = (item as? SearchStock)?.description3 ?? (item as? SearchETF)?.description3 else {
                        continue
                    }
                    var markers: [Date: String] = [:]
                    for markerDict in description3 {
                        for (dateString, text) in markerDict {
                            if let date = dateFormatter.date(from: dateString) {
                                markers[date] = text
                            }
                        }
                    }
                    if !markers.isEmpty {
                        newSymbolTimeMarkers[item.symbol.uppercased()] = markers
                    }
                }
            }
            processItemsWithDescription3(loadedDescriptionData.stocks)
            processItemsWithDescription3(loadedDescriptionData.etfs)
            
            // 【修复 Swift 6 警告】：创建不可变副本以供捕获
            let finalGlobalTimeMarkers = newGlobalTimeMarkers
            let finalSymbolTimeMarkers = newSymbolTimeMarkers
            
            await MainActor.run {
                self.descriptionData = loadedDescriptionData
                self.descriptionData1 = loadedDescriptionData1
                self.globalTimeMarkers = finalGlobalTimeMarkers
                self.symbolTimeMarkers = finalSymbolTimeMarkers
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "加载 description.json 失败: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadSectorsData() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Sectors_All") else {
            if !isInitialLoad {
                await MainActor.run { self.errorMessage = "Sectors_All 文件未在 Documents 中找到" }
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decodedData = try JSONDecoder().decode([String: [String]].self, from: data)
            await MainActor.run {
                self.sectorsData = decodedData
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "加载 Sectors_All.json 失败: \(error.localizedDescription)"
            }
        }
    }
    
    func getCategory(for symbol: String) -> String? {
        for (category, symbols) in sectorsData {
            if symbols.map({ $0.uppercased() }).contains(symbol.uppercased()) {
                return category
            }
        }
        return nil
    }
    
    // MARK: - 合并 Compare_All：同时生成两种映射
    private func loadCompareDataPair() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Compare_All") else {
            if !isInitialLoad {
                await MainActor.run { self.errorMessage = "Compare_All 文件未在 Documents 中找到" }
            }
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n")
            
            var originalCaseData: [String: String] = [:]
            var upperCaseMap: [String: String] = [:]
            
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count >= 2 {
                    let symbol = String(parts[0].trimmingCharacters(in: .whitespaces))
                    let value = String(parts[1].trimmingCharacters(in: .whitespaces))
                    originalCaseData[symbol] = value
                    upperCaseMap[symbol.uppercased()] = value
                }
            }
            
            // 【修复 Swift 6 警告】：创建不可变副本以供捕获
            let finalOriginalCaseData = originalCaseData
            let finalUpperCaseMap = upperCaseMap
            
            await MainActor.run {
                self.compareData = finalUpperCaseMap.merging(finalOriginalCaseData) { (_, new) in new }
                // 单独保留一份全大写键映射，供 Similar 使用
                self.compareDataUppercased = finalUpperCaseMap
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "加载 Compare_All.txt 失败: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadTagsWeight() async {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "tags_weight") else {
            if !isInitialLoad {
                print("DataService: tags_weight 文件未在 Documents 中找到")
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let rawData = try JSONSerialization.jsonObject(with: data, options: []) as? [String: [String]]
            var weightGroups: [Double: [String]] = [:]
            if let rawData = rawData {
                for (k, v) in rawData {
                    if let key = Double(k) {
                        weightGroups[key] = v
                    }
                }
            }
            
            // 【修复 Swift 6 警告】：创建不可变副本以供捕获
            let finalWeightGroups = weightGroups
            
            await MainActor.run {
                self.tagsWeightConfig = finalWeightGroups
            }
        } catch {
            print("DataService: 解析 tags_weight 文件时出错: \(error)")
        }
    }
    
    // ... 其他辅助方法 parseStockLine, parseETFLine, cleanSymbol 保持不变 ...
    private func cleanSymbol(_ symbol: String) -> String {
        let pattern = "^([A-Za-z-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: symbol, options: [], range: NSRange(location: 0, length: symbol.count)),
              let range = Range(match.range(at: 1), in: symbol) else {
            return symbol
        }
        return String(symbol[range])
    }

    private func parseStockLine(_ line: String) -> Stock? {
        let pattern = "^(.*?)\\s+(\\S+)\\s*:\\s*([+-]?[\\d\\.]+%)\\s*(.*)$"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        guard let match = regex?.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) else { return nil }
        
        guard let groupNameRange = Range(match.range(at: 1), in: line),
              let symbolRange = Range(match.range(at: 2), in: line),
              let valueRange = Range(match.range(at: 3), in: line),
              let descRange = Range(match.range(at: 4), in: line) else { return nil }
        
        let groupName = String(line[groupNameRange])
        let rawSymbol = String(line[symbolRange])
        let cleanedSymbol = cleanSymbol(rawSymbol)
        let value = String(line[valueRange])
        let desc = String(line[descRange])
        
        return Stock(groupName: groupName, rawSymbol: rawSymbol, symbol: cleanedSymbol, value: value, descriptions: desc)
    }

    private func parseETFLine(_ line: String) -> ETF? {
        let parts = line.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        
        let rawSymbol = String(parts[0].trimmingCharacters(in: .whitespaces))
        let cleanedSymbol = cleanSymbol(rawSymbol)
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        
        let pattern = "^([+-]?[\\d\\.]+%)\\s+\\d+\\s+[+-]?[\\d\\.]+%\\s+(.*)$"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        guard let match = regex?.firstMatch(in: rest, options: [], range: NSRange(location: 0, length: rest.utf16.count)) else { return nil }
        
        guard let valueRange = Range(match.range(at: 1), in: rest),
              let descRange = Range(match.range(at: 2), in: rest) else { return nil }
        
        let value = String(rest[valueRange])
        let descriptions = String(rest[descRange])
        
        return ETF(groupName: "ETFs", rawSymbol: rawSymbol, symbol: cleanedSymbol, value: value, descriptions: descriptions)
    }
}