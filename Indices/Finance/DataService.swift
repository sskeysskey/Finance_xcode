import Foundation
import Combine

// 定义模型结构
struct DescriptionData: Codable {
    let stocks: [SearchStock]
    let etfs: [SearchETF]
}

struct MarketCapDataItem {
    let marketCap: Double
    let peRatio: Double?
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
    
    // 新增的 errorMessage 属性
    @Published var errorMessage: String? = nil
    
    func loadData() {
        loadMarketCapData()
        loadCompareStock()
        loadCompareETFs()
        loadDescriptionData()
        loadSectorsData()
        loadCompareData()
        loadSectorsPanel() // 新增这一行
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
    
    // 新增的方法
    private func loadDescriptionData() {
        guard let url = Bundle.main.url(forResource: "description", withExtension: "json") else {
            self.errorMessage = "description.json 文件未找到"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            descriptionData = try decoder.decode(DescriptionData.self, from: data)
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