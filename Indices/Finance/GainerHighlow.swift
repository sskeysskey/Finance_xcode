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

struct HighLowListView: View {
    let title: String
    let groups: [HighLowGroup]
    
    @EnvironmentObject var dataService: DataService
    @State private var expandedSections: [String: Bool] = [:]
    
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false

    var body: some View {
        List {
            ForEach(groups) { group in
                // 确保分组内有项目才显示
                if !group.items.isEmpty {
                    Section(header: sectionHeader(for: group)) {
                        // 根据展开/折叠状态决定是否显示内容
                        if expandedSections[group.id, default: true] {
                            ForEach(group.items) { item in
                                rowView(for: item)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(title)
        .onAppear(perform: initializeExpandedStates)
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

    /// 分组的头部视图，包含标题和折叠/展开按钮
    @ViewBuilder
    private func sectionHeader(for group: HighLowGroup) -> some View {
        HStack {
            Text(group.timeInterval)
                .font(.headline)
                .foregroundColor(.primary)
            
            // ==================== 代码修改开始 ====================
            // 如果分组是折叠状态，则显示分组内的项目总数
            if !expandedSections[group.id, default: true] {
                Text("(\(group.items.count))")
                    .font(.headline) // 使用与标题相同的字体，使其大小一致
                    .foregroundColor(.secondary) // 使用次要颜色，以作区分
                    .padding(.leading, 4) // 与标题保持一点间距
            }
            // ==================== 代码修改结束 ====================
            
            Spacer()
            
            Image(systemName: (expandedSections[group.id, default: true]) ? "chevron.down" : "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                expandedSections[group.id, default: true].toggle()
            }
        }
    }

    /// 列表中的单行视图，展示 symbol、百分比值和其关联的 tags
    private func rowView(for item: HighLowItem) -> some View {
        // 获取 symbol 所属的分类，用于导航到 ChartView
        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
        
        return NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 4) {
                // 上半部分：Symbol 和 百分比值
                HStack {
                    Text(item.symbol)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.blue) // 使用蓝色以示可点击
                    
                    Spacer() // 将百分比推到右边
                    
                    // 从 dataService.compareData 查找并显示百分比
                    // 使用 .uppercased() 来确保匹配的健壮性
                    if let compareValue = dataService.compareData[item.symbol.uppercased()] {
                        Text(compareValue)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 下半部分：Tags
                if let tags = getTags(for: item.symbol), !tags.isEmpty {
                    Text(tags.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 初始化每个分组的展开/折叠状态
    private func initializeExpandedStates() {
        for group in groups {
            // 只有当该分组的状态未被设置时才进行初始化
            if expandedSections[group.id] == nil {
                // 如果分组内的项目超过5个，则默认折叠 (false)，否则展开 (true)
                expandedSections[group.id] = (group.items.count <= 5)
            }
        }
    }

    /// 根据 symbol 获取其在 description.json 中定义的 tags
    private func getTags(for symbol: String) -> [String]? {
        let upperSymbol = symbol.uppercased()
        
        if let stockTags = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol })?.tag {
            return stockTags
        }
        
        if let etfTags = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol })?.tag {
            return etfTags
        }
        
        return nil
    }
}
