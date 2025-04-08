import SwiftUI

// MARK: - 基础协议
protocol MarketItem: Identifiable, Codable {
    var id: String { get }
    var groupName: String { get }
    var rawSymbol: String { get }
    var symbol: String { get }
    var value: String { get }
    var descriptions: String { get }
}

// MARK: - MarketItem 扩展
extension MarketItem {
    /// 根据 value 中的字符串数字（移除 "%" 等字符）转换为 Double
    var numericValue: Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0.0
    }
}

// MARK: - Stock Model
struct Stock: MarketItem {
    var id: String = UUID().uuidString
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
    
    init(groupName: String, rawSymbol: String, symbol: String, value: String, descriptions: String) {
        self.groupName = groupName
        self.rawSymbol = rawSymbol
        self.symbol = symbol
        self.value = value
        self.descriptions = descriptions
    }
}

// MARK: - ETF Model
struct ETF: MarketItem {
    var id: String = UUID().uuidString
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
    
    init(groupName: String, rawSymbol: String, symbol: String, value: String, descriptions: String) {
        self.groupName = groupName
        self.rawSymbol = rawSymbol
        self.symbol = symbol
        self.value = value
        self.descriptions = descriptions
    }
}

// MARK: - 单个 Market Item 行视图
struct MarketItemRow<T: MarketItem>: View {
    let item: T
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: item.symbol, groupName: item.groupName)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.rawSymbol)
                        .font(.headline)
                    Spacer()
                    Text(item.value)
                        .font(.subheadline)
                        .foregroundColor(item.numericValue > 0 ? .green : (item.numericValue < 0 ? .red : .gray))
                }
                Text(item.descriptions)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(5)
        }
    }
}

// MARK: - 通用 MarketItem 列表视图
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

// MARK: - 别名简化
typealias StockListView = MarketListView<Stock>
typealias ETFListView = MarketListView<ETF>

// MARK: - 主容器视图
struct TopContentView: View {
    var body: some View {
        NavigationView {
            VStack {
                Spacer()
                CustomTabBar()
            }
        }
    }
}

// MARK: - 自定义底部标签栏
struct CustomTabBar: View {
    @ObservedObject var dataService = DataService()
    
    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(
                destination: StockListView(title: "Top Gainers", items: dataService.topGainers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "涨幅榜", imageName: "arrow.up")
            }
            
            NavigationLink(
                destination: StockListView(title: "Top Losers", items: dataService.topLosers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "跌幅榜", imageName: "arrow.down")
            }
            
            NavigationLink(
                destination: ETFListView(title: "ETF Gainers", items: dataService.etfGainers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "ETF涨幅", imageName: "chart.line.uptrend.xyaxis")
            }
            
            NavigationLink(
                destination: ETFListView(title: "ETF Losers", items: dataService.etfLosers)
                    .onAppear { dataService.loadData() }
            ) {
                TabItemView(title: "ETF跌幅", imageName: "chart.line.downtrend.xyaxis")
            }
        }
        .frame(height: 50)
        .background(Color(.systemBackground))
    }
}

// MARK: - 标签栏子视图
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
