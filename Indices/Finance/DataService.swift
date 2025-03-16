import Foundation
import Combine
import SwiftUI  // 添加这行

// 定义模型结构
struct DescriptionData: Codable {
    let global: [String: String]?  // 添加全局时间点标记
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
    let marketCap: String // 改为 String 类型
    let peRatio: Double?
    
    init(marketCap: Double, peRatio: Double?) {
        self.marketCap = Self.formatMarketCap(marketCap)
        self.peRatio = peRatio
    }
    
    // 将格式化方法移到结构体内部作为静态方法
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
    @Published var topGainers: [Stock] = []
    @Published var topLosers: [Stock] = []
    @Published var etfGainers: [ETF] = []
    @Published var etfLosers: [ETF] = []
    
    // 新增的 Published 属性
    @Published var descriptionData: DescriptionData?
    @Published var marketCapData: [String: MarketCapDataItem] = [:]
    @Published var sectorsData: [String: [String]] = [:]
    @Published var compareData: [String: String] = [:]
    @Published var sectorsPanel: SectorsPanel?
    @Published var symbolEarningData: [String: [Date: Double]] = [:]
    
    // 添加新的属性
    @Published var earningReleases: [EarningRelease] = []
    
    // 新增的 errorMessage 属性
    @Published var errorMessage: String? = nil
    
    // 在 DataService 类中添加新的属性来存储时间点标记
    @Published var globalTimeMarkers: [Date: String] = [:]
    @Published var symbolTimeMarkers: [String: [Date: String]] = [:]
    
    func loadData() {
        loadMarketCapData()
        loadCompareStock()
        loadCompareETFs()
        loadDescriptionData()
        loadSectorsData()
        loadCompareData()
        loadSectorsPanel()
        loadEarningRelease() // 添加这行
    }
    
    // 添加新的加载方法
    private func loadEarningRelease() {
        guard let url = Bundle.main.url(forResource: "Earnings_Release_new", withExtension: "txt") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            
            earningReleases = lines.compactMap { line -> EarningRelease? in
                let parts = line.split(separator: ":")
                let firstPart = String(parts[0]).trimmingCharacters(in: .whitespaces)
                
                // 提取基础symbol和颜色标识
                let symbol = firstPart.trimmingCharacters(in: .whitespaces)
                var color: Color = .gray // 默认颜色
                
                if parts.count > 1 {
                    let colorIdentifier = String(parts[1].prefix(1))
                    color = self.getColor(for: colorIdentifier)
                }
                
                // 提取日期
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
        case "Y":
            return .yellow
        case "C":
            return .cyan
        case "B":
            return .green
        case "W":
            return .white
        case "O":
            return .orange
        case "b":
            return .blue
        default:
            return .gray
        }
    }
    
    private func loadCompareStock() {
        guard let url = Bundle.main.url(forResource: "CompareStock", withExtension: "txt") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            
            let topGainersLines = lines.prefix(20)
            let topLosersLines = lines.suffix(20).reversed()
            
            topGainers = topGainersLines.compactMap { parseStockLine(String($0)) }
            topLosers = topLosersLines.compactMap { parseStockLine(String($0)) }
        } catch {
            print("Error loading comparestock.txt: \(error)")
        }
    }
    
    private func loadCompareETFs() {
        guard let url = Bundle.main.url(forResource: "CompareETFs", withExtension: "txt") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            
            let parsedETFs = lines.compactMap { parseETFLine(String($0)) }
            let etfGainersList = parsedETFs.filter { $0.numericValue > 0 }.sorted { $0.numericValue > $1.numericValue }.prefix(20)
            let etfLosersList = parsedETFs.filter { $0.numericValue < 0 }.sorted { $0.numericValue < $1.numericValue }.prefix(20)
            
            etfGainers = Array(etfGainersList)
            etfLosers = Array(etfLosersList)
        } catch {
            print("Error loading compareetfs.txt: \(error)")
        }
    }
    
    private func loadSectorsPanel() {
        guard let url = Bundle.main.url(forResource: "Sectors_panel", withExtension: "json") else {
            DispatchQueue.main.async {
                self.errorMessage = "Sectors_panel.json 文件未找到"
            }
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let decodedData = try decoder.decode(SectorsPanel.self, from: data)
            DispatchQueue.main.async {
                self.sectorsPanel = decodedData
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "加载 Sectors_panel.json 失败: \(error.localizedDescription)"
            }
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
            
            // 解析全局时间点标记
            if let global = descriptionData?.global {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                
                for (dateString, text) in global {
                    if let date = dateFormatter.date(from: dateString) {
                        globalTimeMarkers[date] = text
                    }
                }
            }
            
            // 解析特定股票的时间点标记
            if let stocks = descriptionData?.stocks {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                
                for stock in stocks {
                    if let description3 = stock.description3 {
                        var markers: [Date: String] = [:]
                        
                        for markerDict in description3 {
                            for (dateString, text) in markerDict {
                                if let date = dateFormatter.date(from: dateString) {
                                    markers[date] = text
                                }
                            }
                        }
                        
                        if !markers.isEmpty {
                            symbolTimeMarkers[stock.symbol.uppercased()] = markers
                        }
                    }
                }
            }
            
            // 解析特定ETF的时间点标记
            if let etfs = descriptionData?.etfs {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                
                for etf in etfs {
                    if let description3 = etf.description3 {
                        var markers: [Date: String] = [:]
                        
                        for markerDict in description3 {
                            for (dateString, text) in markerDict {
                                if let date = dateFormatter.date(from: dateString) {
                                    markers[date] = text
                                }
                            }
                        }
                        
                        if !markers.isEmpty {
                            symbolTimeMarkers[etf.symbol.uppercased()] = markers
                        }
                    }
                }
            }
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
                    
                    if values.count >= 2 {
                        if let marketCap = Double(values[0].trimmingCharacters(in: .whitespaces)) {
                            let peRatioString = values[1].trimmingCharacters(in: .whitespaces)
                            let peRatio = peRatioString == "--" ? nil : Double(peRatioString)
                            marketCapData[symbol] = MarketCapDataItem(marketCap: marketCap, peRatio: peRatio)
                        }
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
            
            // 创建两个字典：一个保存原始大小写，一个保存大写用于查找
            var originalCaseData: [String: String] = [:]
            var upperCaseMap: [String: String] = [:]
            
            for line in lines {
                let parts = line.split(separator: ":")
                if parts.count >= 2 {
                    let symbol = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    
                    // 保存原始大小写的版本
                    originalCaseData[symbol] = value
                    // 保存大写版本用于查找
                    upperCaseMap[symbol.uppercased()] = value
                }
            }
            
            // 合并两个字典，优先使用原始大小写的值
            compareData = upperCaseMap.merging(originalCaseData) { (_, new) in new }
        } catch {
            self.errorMessage = "加载 Compare_All.txt 失败: \(error.localizedDescription)"
        }
    }
    
    // 首先添加一个私有的帮助函数
    private func cleanSymbol(_ symbol: String) -> String {
        // 使用正则表达式匹配最后一个字母之前的所有内容（包括该字母）
        let pattern = "^([A-Za-z-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: symbol, options: [], range: NSRange(location: 0, length: symbol.count)),
              let range = Range(match.range(at: 1), in: symbol) else {
            return symbol // 如果无法匹配，返回原始字符串
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
        let cleanedSymbol = cleanSymbol(rawSymbol) // 使用清理函数
        let value = String(line[valueRange])
        let desc = String(line[descRange])
        
        return Stock(groupName: groupName, rawSymbol: rawSymbol, symbol: cleanedSymbol, value: value, descriptions: desc)
    }

    private func parseETFLine(_ line: String) -> ETF? {
        let parts = line.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        
        let rawSymbol = String(parts[0].trimmingCharacters(in: .whitespaces))
        let cleanedSymbol = cleanSymbol(rawSymbol) // 使用清理函数
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
