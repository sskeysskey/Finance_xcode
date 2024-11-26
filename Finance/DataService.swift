import Foundation

class DataService: ObservableObject {
    @Published var topGainers: [Stock] = []
    @Published var topLosers: [Stock] = []
    @Published var etfGainers: [ETF] = []
    @Published var etfLosers: [ETF] = []
    @Published var marketCapData: [String: (marketCap: Double, pe: String)] = [:]
    
    func loadData() {
        loadMarketCapPE()
        loadCompareStock()
        loadCompareETFs()
    }
    
    private func loadMarketCapPE() {
        guard let url = Bundle.main.url(forResource: "marketcap_pe", withExtension: "txt") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            for line in lines {
                let components = line.split(separator: ":")
                if components.count == 2 {
                    let symbol = String(components[0].trimmingCharacters(in: .whitespaces))
                    let details = components[1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    if details.count >= 2, let marketCap = Double(details[0]) {
                        marketCapData[symbol] = (marketCap, details[1])
                    }
                }
            }
        } catch {
            print("Error loading marketcap_pe.txt: \(error)")
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
        
        let marketCap = marketCapData[cleanedSymbol]?.marketCap // 使用清理后的symbol
        let pe = marketCapData[cleanedSymbol]?.pe               // 使用清理后的symbol
        
        return Stock(groupName: groupName, rawSymbol: rawSymbol, symbol: cleanedSymbol, value: value, descriptions: desc, marketCap: marketCap, pe: pe)
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
