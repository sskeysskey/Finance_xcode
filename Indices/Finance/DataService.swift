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
    
    private var isDataLoaded = false
    
    // High/Low
    @Published var highGroups: [HighLowGroup] = []
    @Published var lowGroups: [HighLowGroup] = []
    
    @Published var errorMessage: String? = nil
    
    @Published var globalTimeMarkers: [Date: String] = [:]
    @Published var symbolTimeMarkers: [String: [Date: String]] = [:]
    
    // MARK: - 新增：tags 权重（合并自 DataService1）
    @Published var tagsWeightConfig: [Double: [String]] = [:]
    
    // MARK: - 新增辅助属性
    /// 检查本地是否已存在数据版本。如果版本号为 nil 或 "0.0"，则认为是首次加载，此时文件不存在是正常情况。
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

    func loadData() {
        // 哨兵
        guard !isDataLoaded else {
            print("DataService: 数据已加载，跳过重复加载。")
            return
        }
        DispatchQueue.main.async {
            self.errorMessage = nil
        }
        
        // 统一加载
        loadMarketCapData()
        loadDescriptionPair()
        loadSectorsData()
        loadCompareDataPair()
        loadSectorsPanel()
        loadEarningRelease()
        loadHighLowData()
        loadCompareStock()
        loadTagsWeight()
        
        isDataLoaded = true
        print("DataService: 所有数据加载完毕。")
    }
    
    // MARK: - 合并：获取一组 symbol 的财报趋势
    public func fetchEarningTrends(for symbols: [String]) {
        let dispatchGroup = DispatchGroup()

        for symbol in symbols {
            let upperSymbol = symbol.uppercased()
            if self.earningTrends[upperSymbol] != nil {
                continue
            }
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var trend: EarningTrend = .insufficientData

                let sortedEarnings = DatabaseManager.shared.fetchEarningData(forSymbol: symbol).sorted { $0.date > $1.date }
                if sortedEarnings.count >= 2 {
                    let latestEarning = sortedEarnings[0]
                    let previousEarning = sortedEarnings[1]
                    if let tableName = self.getCategory(for: symbol) {
                        let latestClose = DatabaseManager.shared.fetchClosingPrice(forSymbol: symbol, onDate: latestEarning.date, tableName: tableName)
                        let previousClose = DatabaseManager.shared.fetchClosingPrice(forSymbol: symbol, onDate: previousEarning.date, tableName: tableName)
                        if let latest = latestClose, let previous = previousClose {
                            if latestEarning.price > 0 {
                                trend = (latest > previous) ? .positiveAndUp : .positiveAndDown
                            } else {
                                trend = (latest > previous) ? .negativeAndUp : .negativeAndDown
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.earningTrends[upperSymbol] = trend
                    dispatchGroup.leave()
                }
            }
        }
        dispatchGroup.notify(queue: .main) {
            // 所有完成后的回调（需要的话）
        }
    }
    
    // MARK: - Private methods
    
    private func loadHighLowData() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "HighLow") else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    self.errorMessage = "HighLow 文件未在 Documents 中找到"
                }
            }
            return
        }

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
            
            DispatchQueue.main.async {
                self.highGroups = timeIntervalOrder.compactMap { highGroupsDict[$0] }
                self.lowGroups = timeIntervalOrder.compactMap { lowGroupsDict[$0] }
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 HighLow.txt 失败: \(error.localizedDescription)"
            }
        }
    }
        
    private func loadEarningRelease() {
        // --- 修改点 1: 在数组中添加新的文件前缀 ---
        let filePrefixes = ["Earnings_Release_new", "Earnings_Release_next", "Earnings_Release_third"]
        let urlsToProcess = filePrefixes.compactMap { prefix in
            FileManagerHelper.getLatestFileUrl(for: prefix)
        }
        guard !urlsToProcess.isEmpty else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    // --- 修改点 2: 更新错误提示信息 ---
                    self.errorMessage = "Earnings_Release_new, Earnings_Release_next 或 Earnings_Release_third 文件未在 Documents 中找到"
                }
            }
            return
        }
        var allEarningReleases: [EarningRelease] = []
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
                    
                    let dateComponents = fullDateStr.split(separator: "-")
                    guard dateComponents.count == 3 else { continue }
                    let month = dateComponents[1]
                    let day = dateComponents[2]
                    let displayDate = "\(month)-\(day)"
                    let release = EarningRelease(symbol: symbol, timing: timing, date: displayDate)
                    allEarningReleases.append(release)
                }
            }
            DispatchQueue.main.async {
                self.earningReleases = allEarningReleases
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载财报文件失败: \(error.localizedDescription)"
            }
        }
    }

    private func loadCompareStock() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "CompareStock") else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    self.errorMessage = "CompareStock 文件未在 Documents 中找到"
                }
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
            
            DispatchQueue.main.async {
                self.topGainers = newTopGainers
                self.topLosers = newTopLosers
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 CompareStock 文件失败: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadSectorsPanel() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Sectors_panel") else {
            if !isInitialLoad {
                DispatchQueue.main.async { self.errorMessage = "Sectors_panel 文件未在 Documents 中找到" }
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decodedData = try JSONDecoder().decode(SectorsPanel.self, from: data)
            DispatchQueue.main.async { self.sectorsPanel = decodedData }
        } catch {
            DispatchQueue.main.async { self.errorMessage = "加载 Sectors_panel.json 失败: \(error.localizedDescription)" }
        }
    }

    // MARK: - 合并：一次性读取 description 文件 data，解两套模型，减少 IO
    private func loadDescriptionPair() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "description") else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    self.errorMessage = "description 文件未在 Documents 中找到"
                }
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
            
            DispatchQueue.main.async {
                self.descriptionData = loadedDescriptionData
                self.descriptionData1 = loadedDescriptionData1
                self.globalTimeMarkers = newGlobalTimeMarkers
                self.symbolTimeMarkers = newSymbolTimeMarkers
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 description.json 失败: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadSectorsData() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Sectors_All") else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    self.errorMessage = "Sectors_All 文件未在 Documents 中找到"
                }
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decodedData = try JSONDecoder().decode([String: [String]].self, from: data)
            DispatchQueue.main.async {
                self.sectorsData = decodedData
            }
        } catch {
            DispatchQueue.main.async {
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
    
    private func loadMarketCapData() {
        let allMarketCapInfo = DatabaseManager.shared.fetchAllMarketCapData(from: "MNSPP")
        
        if allMarketCapInfo.isEmpty {
            if !isInitialLoad {
                self.errorMessage = "未能从数据库 MNSPP 表加载到市值数据。"
            }
            return
        }
        
        var newData: [String: MarketCapDataItem] = [:]
        for info in allMarketCapInfo {
            let item = MarketCapDataItem(
                marketCap: info.marketCap,
                peRatio: info.peRatio,
                pb: info.pb
            )
            newData[info.symbol.uppercased()] = item
        }
        DispatchQueue.main.async {
            self.marketCapData = newData
        }
    }
    
    // MARK: - 合并 Compare_All：同时生成两种映射
    private func loadCompareDataPair() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Compare_All") else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    self.errorMessage = "Compare_All 文件未在 Documents 中找到"
                }
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
            DispatchQueue.main.async {
                // 维持你已有 compareData 的合并策略
                self.compareData = upperCaseMap.merging(originalCaseData) { (_, new) in new }
                // 单独保留一份全大写键映射，供 Similar 使用
                self.compareDataUppercased = upperCaseMap
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 Compare_All.txt 失败: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - 合并：tags_weight
    private func loadTagsWeight() {
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
            DispatchQueue.main.async {
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
