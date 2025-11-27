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
    
    // High/Low
    @Published var highGroups: [HighLowGroup] = []
    @Published var lowGroups: [HighLowGroup] = []
    
    @Published var errorMessage: String? = nil
    
    @Published var globalTimeMarkers: [Date: String] = [:]
    @Published var symbolTimeMarkers: [String: [Date: String]] = [:]
    
    // MARK: - 新增：tags 权重（合并自 DataService1）
    @Published var tagsWeightConfig: [Double: [String]] = [:]
    
    private var isDataLoaded = false
    private var isInitialLoad: Bool {
        let localVersion = UserDefaults.standard.string(forKey: "FinanceAppLocalDataVersion")
        return localVersion == nil || localVersion == "0.0"
    }
    
    // MARK: - 公共方法：强制重新加载
    func forceReloadData() {
        print("DataService: 收到强制刷新请求，将重新加载所有数据。")
        self.isDataLoaded = false
        self.loadData()
    }

    // 【核心修改】：将 loadData 改为异步触发，不阻塞主线程
    func loadData() {
        // 哨兵
        guard !isDataLoaded else {
            print("DataService: 数据已加载，跳过重复加载。")
            return
        }
        
        DispatchQueue.main.async {
            self.errorMessage = nil
        }
        
        // 使用 Task.detached 将繁重的工作移出主线程
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
            
            // 2. 标记加载完成
            await MainActor.run {
                self.isDataLoaded = true
                print("DataService: 所有本地数据加载完毕 (UI已更新)。")
            }
            
            // 3. 启动网络请求 (本身就是 async 的)
            await self.loadMarketCapData()
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
            await MainActor.run {
                self.earningReleases = allEarningReleases
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
            
            await MainActor.run {
                self.descriptionData = loadedDescriptionData
                self.descriptionData1 = loadedDescriptionData1
                self.globalTimeMarkers = newGlobalTimeMarkers
                self.symbolTimeMarkers = newSymbolTimeMarkers
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
    
    // 【已删除】：底部重复的同步版本 loadMarketCapData() 已被移除，
    // 以解决 "async call in a function that does not support concurrency" 的歧义问题。
    
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
            await MainActor.run {
                self.compareData = upperCaseMap.merging(originalCaseData) { (_, new) in new }
                // 单独保留一份全大写键映射，供 Similar 使用
                self.compareDataUppercased = upperCaseMap
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
            await MainActor.run {
                self.tagsWeightConfig = weightGroups
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
