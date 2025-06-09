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

struct EarningRelease: Identifiable {
    let id = UUID()
    let symbol: String
    let color: Color
    let date: String
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
    @Published var marketCapData: [String: MarketCapDataItem] = [:]
    @Published var sectorsData: [String: [String]] = [:]
    @Published var compareData: [String: String] = [:]
    @Published var sectorsPanel: SectorsPanel?
    @Published var symbolEarningData: [String: [Date: Double]] = [:]
    
    @Published var earningReleases: [EarningRelease] = []
    
    // 新增：用于存储 High/Low 数据的属性
    @Published var highGroups: [HighLowGroup] = []
    @Published var lowGroups: [HighLowGroup] = []
    
    @Published var errorMessage: String? = nil
    
    @Published var globalTimeMarkers: [Date: String] = [:]
    @Published var symbolTimeMarkers: [String: [Date: String]] = [:]
    
    private var isDataLoaded = false
    private var loadingTask: Task<Void, Never>?
    private let cache = NSCache<NSString, AnyObject>()
    
    // MARK: - Public methods
    func loadDataIfNeeded() {
        guard !isDataLoaded else { return }
        
        loadingTask?.cancel()
        loadingTask = Task {
            await loadDataAsync()
        }
    }
    
    func loadData() {
        loadMarketCapData()
        loadDescriptionData()
        loadSectorsData()
        loadCompareData()
        loadSectorsPanel()
        loadEarningRelease()
        loadHighLowData() // 新增：调用加载 High/Low 数据的方法
    }
    
    // MARK: - Private methods
    
    /// 新增：加载和解析 highlow.txt 文件
    private func loadHighLowData() {
        guard let url = Bundle.main.url(forResource: "highlow", withExtension: "txt") else {
            DispatchQueue.main.async {
                self.errorMessage = "highlow.txt 文件未找到"
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
                    currentSection = nil // 重置 section
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

                // 处理 symbol 列表
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
            
            // 定义显示顺序，确保UI列表顺序一致
            let timeIntervalOrder = ["5Y", "2Y", "1Y", "6 months", "3 months", "1 months"]
            
            DispatchQueue.main.async {
                self.highGroups = timeIntervalOrder.compactMap { highGroupsDict[$0] }
                self.lowGroups = timeIntervalOrder.compactMap { lowGroupsDict[$0] }
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 highlow.txt 失败: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadDataAsync() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadCompareStockAsync() }
            group.addTask { await self.loadCompareETFsAsync() }
        }
        
        await MainActor.run {
            self.isDataLoaded = true
        }
    }
    
    private func loadFromCache<T>(_ key: String) -> T? {
        return cache.object(forKey: key as NSString) as? T
    }
    
    private func saveToCache<T>(_ value: T, forKey key: String) {
        cache.setObject(value as AnyObject, forKey: key as NSString)
    }
    
    private func loadEarningRelease() {
        guard let url = Bundle.main.url(forResource: "Earnings_Release_new", withExtension: "txt") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            
            earningReleases = lines.compactMap { line -> EarningRelease? in
                let parts = line.split(separator: ":")
                let firstPart = String(parts[0]).trimmingCharacters(in: .whitespaces)
                
                let symbol = firstPart.trimmingCharacters(in: .whitespaces)
                var color: Color = .gray
                
                if parts.count > 1 {
                    let colorIdentifier = String(parts[1].prefix(1))
                    color = self.getColor(for: colorIdentifier)
                }
                
                let dateParts = line.split(separator: ":").last?
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: "-")
                
                if let month = dateParts?[1], let day = dateParts?[2] {
                    let dateStr = "\(month)-\(day)"
                    return EarningRelease(symbol: symbol, color: color, date: dateStr)
                }
                
                return nil
            }
        } catch {
            self.errorMessage = "加载 Earnings_Release_new.txt 失败: \(error.localizedDescription)"
        }
    }
    
    private func getColor(for identifier: String) -> Color {
        switch identifier {
        case "Y": return .yellow
        case "C": return .cyan
        case "B": return .green
        case "W": return .white
        case "O": return .orange
        case "b": return .blue
        default: return .gray
        }
    }
    
    private func loadCompareStockAsync() async {
            if let cached: ([Stock], [Stock]) = loadFromCache("compareStock") {
                await MainActor.run {
                    self.topGainers = cached.0
                    self.topLosers = cached.1
                }
                return
            }
            
            guard let url = Bundle.main.url(forResource: "CompareStock", withExtension: "txt") else { return }
            
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let lines = content.split(separator: "\n")
                
                let topGainersLines = lines.prefix(20)
                let topLosersLines = lines.suffix(20).reversed()
                
                let newTopGainers = topGainersLines.compactMap { parseStockLine(String($0)) }
                let newTopLosers = topLosersLines.compactMap { parseStockLine(String($0)) }
                
                saveToCache((newTopGainers, newTopLosers), forKey: "compareStock")
                await MainActor.run {
                    self.topGainers = newTopGainers
                    self.topLosers = newTopLosers
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "加载 CompareStock.txt 失败: \(error.localizedDescription)"
                }
            }
        }
        
        private func loadCompareETFsAsync() async {
            if let cached: ([ETF], [ETF]) = loadFromCache("compareETFs") {
                await MainActor.run {
                    self.etfGainers = cached.0
                    self.etfLosers = cached.1
                }
                return
            }
            
            guard let url = Bundle.main.url(forResource: "CompareETFs", withExtension: "txt") else { return }
            
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let lines = content.split(separator: "\n")
                
                let parsedETFs = lines.compactMap { parseETFLine(String($0)) }
                let etfGainersList = parsedETFs.filter { $0.numericValue > 0 }
                    .sorted { $0.numericValue > $1.numericValue }
                    .prefix(20)
                let etfLosersList = parsedETFs.filter { $0.numericValue < 0 }
                    .sorted { $0.numericValue < $1.numericValue }
                    .prefix(20)
                
                let newETFGainers = Array(etfGainersList)
                let newETFLosers = Array(etfLosersList)
                
                saveToCache((newETFGainers, newETFLosers), forKey: "compareETFs")
                await MainActor.run {
                    self.etfGainers = newETFGainers
                    self.etfLosers = newETFLosers
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "加载 CompareETFs.txt 失败: \(error.localizedDescription)"
                }
            }
        }
    
    private func loadSectorsPanel() {
        guard let url = Bundle.main.url(forResource: "Sectors_panel", withExtension: "json") else {
            DispatchQueue.main.async { self.errorMessage = "Sectors_panel.json 文件未找到" }
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
    
    private func loadDescriptionData() {
        guard let url = Bundle.main.url(forResource: "description", withExtension: "json") else {
            self.errorMessage = "description.json 文件未找到"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            descriptionData = try decoder.decode(DescriptionData.self, from: data)
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            
            if let global = descriptionData?.global {
                for (dateString, text) in global {
                    if let date = dateFormatter.date(from: dateString) {
                        globalTimeMarkers[date] = text
                    }
                }
            }
            
            let processItems: ([SearchDescribableItem]) -> Void = { items in
                for item in items {
                    if let description3 = (item as? SearchStock)?.description3 ?? (item as? SearchETF)?.description3 {
                        var markers: [Date: String] = [:]
                        for markerDict in description3 {
                            for (dateString, text) in markerDict {
                                if let date = dateFormatter.date(from: dateString) {
                                    markers[date] = text
                                }
                            }
                        }
                        if !markers.isEmpty {
                            self.symbolTimeMarkers[item.symbol.uppercased()] = markers
                        }
                    }
                }
            }

            if let stocks = descriptionData?.stocks { processItems(stocks) }
            if let etfs = descriptionData?.etfs { processItems(etfs) }

        } catch {
            self.errorMessage = "加载 description.json 失败: \(error.localizedDescription)"
        }
    }
    
    private func loadSectorsData() {
        guard let url = Bundle.main.url(forResource: "Sectors_All", withExtension: "json") else {
            self.errorMessage = "Sectors_All.json 文件未找到"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            sectorsData = try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            self.errorMessage = "加载 Sectors_All.json 失败: \(error.localizedDescription)"
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
        guard let url = Bundle.main.url(forResource: "marketcap_pe", withExtension: "txt") else {
            self.errorMessage = "marketcap_pe.txt 文件未找到"
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n")
            
            for line in lines {
                let parts = line.split(separator: ":")
                if parts.count >= 2 {
                    let symbol = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
                    let values = parts[1].split(separator: ",")
                    
                    if values.count >= 2, let marketCap = Double(values[0].trimmingCharacters(in: .whitespaces)) {
                        let peRatioString = values[1].trimmingCharacters(in: .whitespaces)
                        let peRatio = peRatioString == "--" ? nil : Double(peRatioString)
                        
                        var pb: Double? = nil
                        if values.count >= 3 {
                            pb = Double(values[2].trimmingCharacters(in: .whitespaces))
                        }
                        
                        marketCapData[symbol] = MarketCapDataItem(marketCap: marketCap, peRatio: peRatio, pb: pb)
                    }
                }
            }
        } catch {
            self.errorMessage = "加载 marketcap_pe.txt 失败: \(error.localizedDescription)"
        }
    }
    
    private func loadCompareData() {
        guard let url = Bundle.main.url(forResource: "Compare_All", withExtension: "txt") else {
            self.errorMessage = "Compare_All.txt 文件未找到"
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
            compareData = upperCaseMap.merging(originalCaseData) { (_, new) in new }
        } catch {
            self.errorMessage = "加载 Compare_All.txt 失败: \(error.localizedDescription)"
        }
    }
    
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
