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
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false

    
    var body: some View {
        List(items) { item in
            MarketItemRow(item: item)
        }
        .navigationTitle(title)
        // 新增：在导航栏添加工具栏
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    // 点击按钮时，触发导航
                    showSearchView = true
                }) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        // 新增：定义导航的目标视图
        .navigationDestination(isPresented: $showSearchView) {
            // 传入 dataService 并设置 isSearchActive 为 true，让搜索框自动激活
            SearchView(isSearchActive: true, dataService: dataService)
        }
    }
}

typealias StockListView = MarketListView<Stock>
typealias ETFListView = MarketListView<ETF>

// MARK: - 主容器视图
struct TopContentView: View {
    var body: some View {
        // 注意：这里的 NavigationView 可能会导致双重导航栏。
        // 如果在 MainContentView 中已经有一个 NavigationStack，这里可能不需要 NavigationView。
        // 但为了保持原结构，暂时保留。
        NavigationView {
            VStack {
                Spacer()
                CustomTabBar()
            }
            // .navigationBarHidden(true) // 可以考虑隐藏内层的导航栏避免冲突
        }
    }
}

// MARK: - 自定义底部标签栏 (已修改)
struct CustomTabBar: View {
    @StateObject private var dataService = DataService.shared // 使用单例
    
    var body: some View {
        HStack(spacing: 0) {
            // 1. 涨幅榜
            NavigationLink(
                destination: LazyView(StockListView(title: "Top Gainers", items: dataService.topGainers))
            ) {
                TabItemView(title: "涨幅榜", imageName: "arrow.up")
            }
            
            // 2. 跌幅榜
            NavigationLink(
                destination: LazyView(StockListView(title: "Top Losers", items: dataService.topLosers))
            ) {
                TabItemView(title: "跌幅榜", imageName: "arrow.down")
            }
            
            // 3. 新增：Low 列表
            NavigationLink(
                destination: LazyView(HighLowListView(title: "Lows", groups: dataService.lowGroups))
            ) {
                // 使用雪花图标代表 Low
                TabItemView(title: "Low", imageName: "snowflake")
            }
            
            // 4. 新增：High 列表
            NavigationLink(
                destination: LazyView(HighLowListView(title: "Highs", groups: dataService.highGroups))
            ) {
                // 使用火焰图标代表 High
                TabItemView(title: "High", imageName: "flame")
            }
        }
        .frame(height: 50)
        .background(Color(.systemBackground))
        .onAppear {
            // loadDataIfNeeded 仅加载一次，如果需要每次都刷新，应调用 loadData()
            // 这里我们假设数据在应用启动时已通过 MainContentView 的 onAppear 加载
             dataService.loadDataIfNeeded()
             // 确保 high/low 数据也被加载
             dataService.loadData()
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
