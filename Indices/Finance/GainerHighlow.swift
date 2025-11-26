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

// ==================== 修改开始：重构 MarketItemRow ====================
// MARK: - 单个 Market Item 行视图
struct MarketItemRow<T: MarketItem>: View {
    let item: T
    @EnvironmentObject var dataService: DataService
    
    // 【新增】权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @State private var isNavigationActive = false
    @State private var showLoginSheet = false
    @State private var showSubscriptionSheet = false

    private var earningTrend: EarningTrend {
        dataService.earningTrends[item.symbol.uppercased()] ?? .insufficientData
    }
    
    var body: some View {
        // 【修改】使用 Button 替代 NavigationLink
        Button(action: {
            if usageManager.canProceed(authManager: authManager) {
                isNavigationActive = true
            } else {
                if !authManager.isLoggedIn { showLoginSheet = true }
                else { showSubscriptionSheet = true }
            }
        }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    // 根据财报趋势设置颜色
                    Text(item.rawSymbol)
                        .font(.headline)
                        .foregroundColor(colorForEarningTrend(earningTrend))
                    
                    Spacer()
                    
                    // 涨跌幅颜色逻辑保持不变
                    Text(item.value)
                        .font(.subheadline)
//                        .foregroundColor(item.numericValue > 0 ? .green : (item.numericValue < 0 ? .red : .gray))
                }
                Text(item.descriptions)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(5)
        }
        // 【新增】导航与弹窗
        .navigationDestination(isPresented: $isNavigationActive) {
            ChartView(symbol: item.symbol, groupName: item.groupName)
        }
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue && showLoginSheet { showLoginSheet = false }
        }
        .onAppear {
            // 当单个 item 出现时，如果数据还未加载，可以触发一次
            if earningTrend == .insufficientData {
                dataService.fetchEarningTrends(for: [item.symbol])
            }
        }
    }
    
    // 辅助函数，用于根据财报趋势返回颜色
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp:
            return .red
        case .negativeAndUp:
            return .purple
        case .positiveAndDown:
            return .cyan
        case .negativeAndDown:
            return .green
        case .insufficientData:
            return .primary
        }
    }
}
// ==================== 修改结束 ====================

// ==================== 修改开始：重构 MarketListView ====================
// MARK: - 通用 MarketItem 列表视图
struct MarketListView<T: MarketItem>: View {
    let title: String
    let items: [T]
    @StateObject private var dataService = DataService.shared // 使用单例
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false
    
    var body: some View {
        // 将 dataService 注入到环境中，以便 MarketItemRow 可以访问
        List(items) { item in
            MarketItemRow(item: item)
                .environmentObject(dataService)
        }
        .navigationTitle(title)
        .onAppear {
            // 当列表出现时，为所有项目获取财报趋势数据
            let symbols = items.map { $0.symbol }
            dataService.fetchEarningTrends(for: symbols)
        }
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
// ==================== 修改结束 ====================

typealias StockListView = MarketListView<Stock>
typealias ETFListView = MarketListView<ETF>

// MARK: - 主容器视图
struct TopContentView: View {
    var body: some View {
        // 【核心修改】删除外层的 NavigationView
        // 因为 MainContentView 已经有了 NavigationStack，这里不能再嵌套 NavigationView
        // 否则会导致约束冲突，使底部栏在首次加载时高度为0或不可见。
        VStack {
            Spacer()
            CustomTabBar()
        }
        // .navigationBarHidden(true) // 不需要了
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

// MARK: - HighLowListView (核心修改)
struct HighLowListView: View {
    let title: String
    let groups: [HighLowGroup]
    
    @EnvironmentObject var dataService: DataService
    @State private var expandedSections: [String: Bool] = [:]
    
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false
    
    // 【新增】权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @State private var showLoginSheet = false
    @State private var showSubscriptionSheet = false
    
    // 【新增】导航控制
    @State private var selectedItem: HighLowItem?
    @State private var isNavigationActive = false

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
        // 【新增】程序化导航与弹窗
        .navigationDestination(isPresented: $isNavigationActive) {
            if let item = selectedItem {
                ChartView(symbol: item.symbol, groupName: dataService.getCategory(for: item.symbol) ?? "Stocks")
            }
        }
        .sheet(isPresented: $showLoginSheet) { LoginView() }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue && showLoginSheet { showLoginSheet = false }
        }
    }

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
        // 【修改】使用 Button 替代 NavigationLink
        Button(action: {
            if usageManager.canProceed(authManager: authManager) {
                selectedItem = item
                isNavigationActive = true
            } else {
                if !authManager.isLoggedIn { showLoginSheet = true }
                else { showSubscriptionSheet = true }
            }
        }) {
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