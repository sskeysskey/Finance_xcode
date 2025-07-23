import Foundation
import Combine
import SwiftUI

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

// ==================== 修改开始 ====================
// 1. 更新 EarningRelease 模型以匹配新格式
struct EarningRelease: Identifiable {
    let id = UUID()
    let symbol: String
    let timing: String // BMO, AMC, TNS
    let date: String   // 存储 "MM-dd" 格式的日期
}
// ==================== 修改结束 ====================


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
    @Published var marketCapData: [String: MarketCapDataItem] = [:]
    @Published var sectorsData: [String: [String]] = [:]
    @Published var compareData: [String: String] = [:]
    @Published var sectorsPanel: SectorsPanel?
    @Published var symbolEarningData: [String: [Date: Double]] = [:]
    
    @Published var earningReleases: [EarningRelease] = []
    
    // MARK: - 修改 1：添加一个私有状态，用于跟踪数据是否已加载
    private var isDataLoaded = false
    
    // 新增：用于存储 High/Low 数据的属性
    @Published var highGroups: [HighLowGroup] = []
    @Published var lowGroups: [HighLowGroup] = []
    
    @Published var errorMessage: String? = nil
    
    @Published var globalTimeMarkers: [Date: String] = [:]
    @Published var symbolTimeMarkers: [String: [Date: String]] = [:]
    
    // MARK: - 新增辅助属性
    /// 检查本地是否已存在数据版本。如果版本号为 nil 或 "0.0"，则认为是首次加载，此时文件不存在是正常情况。
    private var isInitialLoad: Bool {
        let localVersion = UserDefaults.standard.string(forKey: "FinanceAppLocalDataVersion")
        return localVersion == nil || localVersion == "0.0"
    }
    
    // MARK: - 修改 2：创建一个新的公共方法，用于强制重新加载数据
        /// 强制重新加载所有数据。此方法会重置加载状态，通常在手动刷新或数据文件更新后调用。
        func forceReloadData() {
            print("DataService: 收到强制刷新请求，将重新加载所有数据。")
            // 重置加载状态标志
            self.isDataLoaded = false
            // 调用原始的加载方法
            self.loadData()
        }

    func loadData() {
        // MARK: - 修改 3：在 loadData 方法的入口处添加“哨兵”检查
        // 如果数据已经加载过，则直接返回，避免重复执行。
        guard !isDataLoaded else {
            print("DataService: 数据已加载，跳过重复加载。")
            return
        }
        // 在加载前清除旧的错误信息
        DispatchQueue.main.async {
            self.errorMessage = nil
        }
        
        loadMarketCapData()
        loadDescriptionData()
        loadSectorsData()
        loadCompareData()
        loadSectorsPanel()
        loadEarningRelease()
        loadHighLowData()
        loadCompareStock()
        
        isDataLoaded = true
        print("DataService: 所有数据加载完毕。")
    }
    
    // MARK: - Private methods
    
    private func loadHighLowData() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "HighLow") else {
            // MARK: - 修改
            // 仅在非首次加载时才报告错误
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
        
    // ==================== 修改开始 ====================
    // 2. 重写 loadEarningRelease 方法以解析新格式
    private func loadEarningRelease() {
        // 1. 定义要查找的两个文件前缀
        let filePrefixes = ["Earnings_Release_new", "Earnings_Release_next"]
        
        // 2. 获取这两个文件的最新 URL
        //    使用 compactMap 可以方便地过滤掉未找到的文件（返回 nil 的情况）
        let urlsToProcess = filePrefixes.compactMap { prefix in
            FileManagerHelper.getLatestFileUrl(for: prefix)
        }

        // 3. 检查是否至少找到了一个文件
        guard !urlsToProcess.isEmpty else {
            if !isInitialLoad {
                DispatchQueue.main.async {
                    // 更新错误信息，使其更明确
                    self.errorMessage = "Earnings_Release_new 或 Earnings_Release_next 文件未在 Documents 中找到"
                }
            }
            return
        }
        
        // 4. 创建一个数组来存储所有解析出的数据
        var allEarningReleases: [EarningRelease] = []
        
        do {
            // 5. 遍历所有找到的 URL
            for url in urlsToProcess {
                let content = try String(contentsOf: url, encoding: .utf8)
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                
                // 内部解析逻辑保持不变
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
                    // 将解析结果添加到总数组中
                    allEarningReleases.append(release)
                }
            }
            
            // 6. 所有文件都处理完毕后，在主线程上更新发布的属性
            DispatchQueue.main.async {
                self.earningReleases = allEarningReleases
            }
            
        } catch {
            DispatchQueue.main.async {
                // 更新错误信息
                self.errorMessage = "加载财报文件失败: \(error.localizedDescription)"
            }
        }
    }
    // ==================== 修改结束 ====================

    private func loadCompareStock() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "CompareStock") else {
            // MARK: - 修改
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
            // MARK: - 修改
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
    
    // 在 DataService.swift 中

    private func loadDescriptionData() {
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
            let loadedDescriptionData = try decoder.decode(DescriptionData.self, from: data)
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            
            // --- 开始修改 ---

            // 1. 处理全局时间标记 (这部分逻辑是正确的，保持不变)
            var newGlobalTimeMarkers: [Date: String] = [:]
            if let global = loadedDescriptionData.global {
                for (dateString, text) in global {
                    if let date = dateFormatter.date(from: dateString) {
                        newGlobalTimeMarkers[date] = text
                    }
                }
            }
            
            // 2. 处理特定股票/ETF的时间标记
            var newSymbolTimeMarkers: [String: [Date: String]] = [:]
            
            // 定义一个可重用的闭包来处理包含 description3 的项目
            let processItemsWithDescription3 = { (items: [SearchDescribableItem]) in
                for item in items {
                    // 使用可选链和类型转换来获取 description3
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
                        // 将解析出的标记存入字典，键为大写的 symbol
                        newSymbolTimeMarkers[item.symbol.uppercased()] = markers
                    }
                }
            }
            
            // 3. 显式调用闭包，分别处理 stocks 和 etfs 数组
            processItemsWithDescription3(loadedDescriptionData.stocks)
            processItemsWithDescription3(loadedDescriptionData.etfs)
            
            // --- 结束修改 ---

            DispatchQueue.main.async {
                self.descriptionData = loadedDescriptionData
                self.globalTimeMarkers = newGlobalTimeMarkers
                // 现在 newSymbolTimeMarkers 将包含正确解析的数据
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
            // MARK: - 修改
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
            // MARK: - 修改
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
    
    private func loadCompareData() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Compare_All") else {
            // MARK: - 修改
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
                let parts = line.split(separator: ":")
                if parts.count >= 2 {
                    let symbol = String(parts[0].trimmingCharacters(in: .whitespaces))
                    let value = String(parts[1].trimmingCharacters(in: .whitespaces))
                    originalCaseData[symbol] = value
                    upperCaseMap[symbol.uppercased()] = value
                }
            }
            DispatchQueue.main.async {
                self.compareData = upperCaseMap.merging(originalCaseData) { (_, new) in new }
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 Compare_All.txt 失败: \(error.localizedDescription)"
            }
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
