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
}

// MARK: - ETF Model
struct ETF: MarketItem {
    var id: String = UUID().uuidString
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
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
    @StateObject private var dataService = DataService.shared // 使用单例
    
    var body: some View {
        List(items) { item in
            MarketItemRow(item: item)
        }
        .navigationTitle(title)
    }
}

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
    @StateObject private var dataService = DataService.shared // 使用单例
    
    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(
                destination: LazyView(StockListView(title: "Top Gainers", items: dataService.topGainers))
            ) {
                TabItemView(title: "涨幅榜", imageName: "arrow.up")
            }
            
            NavigationLink(
                destination: LazyView(StockListView(title: "Top Losers", items: dataService.topLosers))
            ) {
                TabItemView(title: "跌幅榜", imageName: "arrow.down")
            }
            
            NavigationLink(
                destination: LazyView(ETFListView(title: "ETF Gainers", items: dataService.etfGainers))
            ) {
                TabItemView(title: "ETF涨幅", imageName: "chart.line.uptrend.xyaxis")
            }
            
            NavigationLink(
                destination: LazyView(ETFListView(title: "ETF Losers", items: dataService.etfLosers))
            ) {
                TabItemView(title: "ETF跌幅", imageName: "chart.line.downtrend.xyaxis")
            }
        }
        .frame(height: 50)
        .background(Color(.systemBackground))
        .onAppear {
            dataService.loadDataIfNeeded()
        }
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

// MARK: - 懒加载视图包装器
struct LazyView<Content: View>: View {
    let build: () -> Content
    
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    
    var body: Content {
        build()
    }
}
