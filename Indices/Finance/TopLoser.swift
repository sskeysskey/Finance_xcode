import SwiftUI
import Foundation

// MARK: - 基础协议
protocol MarketItem: Identifiable, Codable {
    var id: String { get }
    var groupName: String { get }
    var rawSymbol: String { get }
    var symbol: String { get }
    var value: String { get }
    var descriptions: String { get }
    var numericValue: Double { get }
}

// MARK: - Stock Model
struct Stock: MarketItem {
    var id: String
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
    let marketCap: Double?
    let pe: String?
    
    var numericValue: Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0.0
    }
    
    init(groupName: String, rawSymbol: String, symbol: String, value: String, descriptions: String, marketCap: Double? = nil, pe: String? = nil) {
        self.id = UUID().uuidString
        self.groupName = groupName
        self.rawSymbol = rawSymbol
        self.symbol = symbol
        self.value = value
        self.descriptions = descriptions
        self.marketCap = marketCap
        self.pe = pe
    }
}

// MARK: - ETF Model
struct ETF: MarketItem {
    var id: String
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
    
    var numericValue: Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0.0
    }
    
    init(groupName: String, rawSymbol: String, symbol: String, value: String, descriptions: String) {
        self.id = UUID().uuidString
        self.groupName = groupName
        self.rawSymbol = rawSymbol
        self.symbol = symbol
        self.value = value
        self.descriptions = descriptions
    }
}

// MARK: - Generic Market Item View
struct MarketItemRow<T: MarketItem>: View {
    let item: T
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: item.symbol, groupName: item.groupName)) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(item.groupName) \(item.rawSymbol)")
                    .font(.headline)
                Text(item.value)
                    .font(.subheadline)
                    .foregroundColor(item.numericValue > 0 ? .green : (item.numericValue < 0 ? .red : .gray))
                Text(item.descriptions)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(5)
        }
    }
}

// MARK: - Generic List View
struct MarketListView<T: MarketItem>: View {
    let title: String
    let items: [T]
    
    var body: some View {
        List(items) { item in
            MarketItemRow(item: item)
        }
        .navigationTitle(title)
    }
}

// MARK: - Type Aliases for Convenience
typealias StockListView = MarketListView<Stock>
typealias ETFListView = MarketListView<ETF>

struct TopContentView: View {
    var body: some View {
        NavigationView {
            VStack {
                Spacer() // 保持上方为空
                CustomTabBar() // 自定义底部标签栏
            }
        }
    }
}

struct CustomTabBar: View {
    @ObservedObject var dataService = DataService()
    
    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(destination:
                StockListView(title: "Top Gainers", items: dataService.topGainers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "涨幅榜", imageName: "arrow.up")
            }
            
            NavigationLink(destination:
                StockListView(title: "Top Losers", items: dataService.topLosers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "跌幅榜", imageName: "arrow.down")
            }
            
            NavigationLink(destination:
                ETFListView(title: "ETF Gainers", items: dataService.etfGainers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "ETF涨幅", imageName: "chart.line.uptrend.xyaxis")
            }
            
            NavigationLink(destination:
                ETFListView(title: "ETF Losers", items: dataService.etfLosers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "ETF跌幅", imageName: "chart.line.downtrend.xyaxis")
            }
        }
        .frame(height: 50)
        .background(Color(.systemBackground))
    }
}

struct TabItemView: View {
    let title: String
    let imageName: String
    
    var body: some View {
        VStack {
            Image(systemName: imageName)
                .font(.system(size: 20))
            Text(title)
                .font(.caption)
        }
        .foregroundColor(.blue)
        .frame(maxWidth: .infinity)
    }
}

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
