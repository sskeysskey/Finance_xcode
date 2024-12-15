import SwiftUI

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
