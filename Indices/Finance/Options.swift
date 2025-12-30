import SwiftUI
import Charts
import Foundation

// MARK: - 【重构】期权价格历史图表组件
struct OptionsHistoryChartView: View {
    let symbol: String
    
    // 状态管理
    @State private var historyData: [DatabaseManager.OptionHistoryItem] = []
    @State private var selectedTimeRange: TimeRangeOption = .threeMonths
    @State private var isLoading = false
    
    // 定义时间范围枚举
    enum TimeRangeOption: String, CaseIterable, Identifiable {
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case twoYears = "2Y"
        case fiveYears = "5Y"
        case tenYears = "10Y"
        
        var id: String { self.rawValue }
        
        var monthsBack: Int {
            switch self {
            case .threeMonths: return 3
            case .sixMonths: return 6
            case .oneYear: return 12
            case .twoYears: return 24
            case .fiveYears: return 60
            case .tenYears: return 120
            }
        }
    }
    
    // 过滤后的数据
    var filteredData: [DatabaseManager.OptionHistoryItem] {
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .month, value: -selectedTimeRange.monthsBack, to: Date()) else {
            return historyData
        }
        return historyData.filter { $0.date >= startDate }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // 1. 图表主体区域
            mainChartArea
            
            // 2. 时间切换条
            timeRangeSelector
        }
        .task {
            await loadData()
        }
    }
    
    // 拆分出图表主体
    @ViewBuilder
    private var mainChartArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            
            if isLoading {
                ProgressView()
            } else if historyData.isEmpty {
                Text("暂无历史价格数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if filteredData.isEmpty {
                Text("该时间段内无数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                chartContent
            }
        }
        .frame(height: 220)
        .padding(.horizontal)
    }

    // 1. 定义一个用于显示的日期格式化器
    private var chartDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd" // 显示为 12/26 格式
        return formatter
    }
    
    // 拆分出具体的 Chart 代码
    private var chartContent: some View {
        // 将 filteredData 按照日期升序排列，确保图表从左到右是时间顺序
        let sortedData = filteredData.sorted { $0.date < $1.date }
        
        return Chart {
            ForEach(sortedData) { item in
                BarMark(
                    // 【关键修改】X轴使用 String (分类)，消除周末空白
                    x: .value("Date", chartDateFormatter.string(from: item.date)),
                    y: .value("Price", item.price)
                )
                .foregroundStyle(barGradient(for: item.price))
                // 【优化】设置最大宽度，防止数据少时柱子太宽
                .cornerRadius(4)
            }
            
            // 0轴基准线
            RuleMark(y: .value("Zero", 0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.gray.opacity(0.5))
        }
        // 【关键修改】自定义 X 轴
        .chartXAxis {
            AxisMarks { value in
                // 因为 X 轴变成了 String，这里直接获取 String
                if let dateString = value.as(String.self) {
                    AxisValueLabel {
                        Text(dateString)
                            .font(.caption2)
                            .fixedSize() // 防止文字被压缩
                    }
                }
            }
        }
        // 【优化】如果数据很少，限制图表内容的宽度，不要撑满全屏（可选）
        // .chartXScale(domain: .automatic(includesZero: false)) 
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
    }
    
    // 辅助函数：生成渐变色
    private func barGradient(for price: Double) -> LinearGradient {
        let isPositive = price >= 0
        let colors: [Color] = isPositive
            ? [.red.opacity(0.8), .red.opacity(0.4)]
            : [.green.opacity(0.8), .green.opacity(0.4)]
        
        return LinearGradient(
            colors: colors,
            startPoint: isPositive ? .bottom : .top,
            endPoint: isPositive ? .top : .bottom
        )
    }
    
    // 拆分出时间选择器
    private var timeRangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(TimeRangeOption.allCases) { option in
                Button(action: {
                    withAnimation(.easeInOut) {
                        selectedTimeRange = option
                    }
                }) {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedTimeRange == option
                            ? Color.blue.opacity(0.15)
                            : Color.clear
                        )
                        .foregroundColor(
                            selectedTimeRange == option
                            ? .blue
                            : .secondary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(4)
        .background(Color(UIColor.tertiarySystemFill))
        .cornerRadius(10)
        .padding(.horizontal)
    }
    
    private func loadData() async {
        isLoading = true
        let rawData = await DatabaseManager.shared.fetchOptionsHistory(forSymbol: symbol)
        await MainActor.run {
            self.historyData = rawData
            self.isLoading = false
        }
    }
}

// MARK: - 【重构】界面 A：期权 Symbol 列表
struct OptionsListView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    
    // 【新增】控制跳转到榜单页面
    @State private var navigateToRank = false
    
    var sortedSymbols: [String] {
        let allSymbols = dataService.optionsData.keys
        let noCapSymbols = allSymbols.filter { symbol in
            guard let item = dataService.marketCapData[symbol.uppercased()] else { return true }
            return item.rawMarketCap <= 0
        }.sorted()
        
        let hasCapSymbols = allSymbols.filter { symbol in
            guard let item = dataService.marketCapData[symbol.uppercased()] else { return false }
            return item.rawMarketCap > 0
        }.sorted { s1, s2 in
            let cap1 = dataService.marketCapData[s1.uppercased()]?.rawMarketCap ?? 0
            let cap2 = dataService.marketCapData[s2.uppercased()]?.rawMarketCap ?? 0
            return cap1 > cap2
        }
        return noCapSymbols + hasCapSymbols
    }
    
    var body: some View {
        List {
            if sortedSymbols.isEmpty {
                Text("暂无期权异动数据")
                    .foregroundColor(.secondary)
            } else {
                ForEach(sortedSymbols, id: \.self) { symbol in
                    OptionListRow(symbol: symbol) {
                        handleSelection(symbol)
                    }
                }
            }
        }
        .navigationTitle("期权异动")
        .navigationBarTitleDisplayMode(.inline)
        // 【新增】右上角按钮
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    // 这里原来是 .openSpecialList，改为 .viewOptionsRank
                    if usageManager.canProceed(authManager: authManager, action: .viewOptionsRank) { 
                        self.navigateToRank = true
                    } else {
                        self.showSubscriptionSheet = true
                    }
                }) {
                    // 【修改点】设计漂亮的胶囊按钮
                    HStack(spacing: 4) {
                        // 加个小图标增加精致感
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 12, weight: .bold))
                        
                        Text("涨跌预测榜")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .foregroundColor(.white)
                    .background(
                        // 蓝紫色渐变，体现“预测/智能”的感觉
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.indigo]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule()) // 胶囊圆角
                    .shadow(color: Color.blue.opacity(0.3), radius: 4, x: 0, y: 2) // 柔和阴影
                    .overlay(
                        // 增加一道淡淡的高光描边，增加立体感
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
            }
        }
        .navigationDestination(isPresented: $navigateToDetail) {
            if let sym = selectedSymbol {
                OptionsDetailView(symbol: sym)
            }
        }
        // 【新增】跳转目的地
        .navigationDestination(isPresented: $navigateToRank) {
            OptionsRankView()
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func handleSelection(_ symbol: String) {
        if usageManager.canProceed(authManager: authManager, action: .viewOptionsDetail) {
            self.selectedSymbol = symbol
            self.navigateToDetail = true
        } else {
            self.showSubscriptionSheet = true
        }
    }
}

// 拆分出的列表行视图
struct OptionListRow: View {
    let symbol: String
    let action: () -> Void
    @EnvironmentObject var dataService: DataService
    // --- 新增：用于存储最新价格的状态 ---
    @State private var latestPrice: Double? = nil
    
    var body: some View {
        Button(action: action) {
            let info = getInfo(for: symbol)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(symbol)
                            .font(.headline)
                            .fontWeight(.bold)
                            // --- 修改点：根据最新价格上色 ---
                            .foregroundColor(priceColor)
                        
                        if !info.name.isEmpty {
                            Text(info.name)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    
                    if !info.tags.isEmpty {
                        Text(info.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)
        }
        // --- 新增：组件加载时请求历史数据获取最新价格 ---
        .task {
            await loadLatestPrice()
        }
    }

    // --- 新增：计算属性确定颜色 ---
    private var priceColor: Color {
        guard let price = latestPrice else { return .primary } // 数据未加载时用默认色
        return price >= 0 ? .red : .green // 正数为红，负数为绿
    }
    
    // --- 新增：加载数据的逻辑 ---
    private func loadLatestPrice() async {
        let history = await DatabaseManager.shared.fetchOptionsHistory(forSymbol: symbol)
        // 假设 history[0] 是最新一天的价格（根据 API 返回顺序确定）
        if let latestItem = history.first {
            await MainActor.run {
                self.latestPrice = latestItem.price
            }
        }
    }
    
    private func getInfo(for symbol: String) -> (name: String, tags: [String]) {
        let upperSymbol = symbol.uppercased()
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (stock.name, stock.tag)
        }
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (etf.name, etf.tag)
        }
        return ("", [])
    }
}

// MARK: - 【重构】界面 B：期权详情表格
struct OptionsDetailView: View {
    let symbol: String
    @EnvironmentObject var dataService: DataService
    
    // --- 新增：注入权限和点数管理对象 ---
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedTypeIndex = 0
    @State private var navigateToChart = false
    @State private var summaryCall: String = ""
    @State private var summaryPut: String = ""
    
    // --- 新增：控制订阅页显示 ---
    @State private var showSubscriptionSheet = false

    var filteredData: [OptionItem] {
        guard let items = dataService.optionsData[symbol] else { return [] }
        let filtered = items.filter { item in
            let itemType = item.type.uppercased()
            if selectedTypeIndex == 0 {
                return itemType.contains("CALL") || itemType == "C"
            } else {
                return itemType.contains("PUT") || itemType == "P"
            }
        }
        return filtered.sorted { item1, item2 in
            let val1 = Double(item1.change) ?? 0
            let val2 = Double(item2.change) ?? 0
            return abs(val1) > abs(val2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图表组件
            OptionsHistoryChartView(symbol: symbol)
                .padding(.top, 10)
                .padding(.bottom, 4)
            
            // 顶部切换开关 (Picker)
            typePickerView
            
            // 表格头
            tableHeaderView
            
            Divider()
            
            // 数据列表
            dataListView
        }
        .navigationTitle(displayTitle) // 使用我们拼接好的字符串
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // --- 修改点：在按钮点击时执行扣点检查 ---
                Button(action: {
                    if usageManager.canProceed(authManager: authManager, action: .viewChart) { 
                        // 如果有足够点数（或已订阅），则允许跳转
                        navigateToChart = true 
                    } else {
                        // 点数不足，弹出订阅/登录页
                        showSubscriptionSheet = true
                    }
                }) {
                    Text("切换股价模式")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue)
                        .cornerRadius(14)
                        .shadow(color: Color.blue.opacity(0.3), radius: 2, x: 0, y: 1)
                }
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            let groupName = dataService.getCategory(for: symbol) ?? "US"
            ChartView(symbol: symbol, groupName: groupName)
        }
        // --- 新增：挂载订阅页面 ---
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .task {
            // 获取汇总数据
            if let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) {
                await MainActor.run {
                    if let c = summary.call { self.summaryCall = c }
                    if let p = summary.put { self.summaryPut = p }
                }
            }
        }
    }

    // MARK: - 辅助逻辑
    private var displayTitle: String {
        // 1. 获取原始的 compare 字符串 (例如 "0.04%++")
        if let compareStr = dataService.compareDataUppercased[symbol.uppercased()] {
            // 2. 提取百分比部分
            let pattern = "([+-]?\\d+(\\.\\d+)?%)"
            if let range = compareStr.range(of: pattern, options: .regularExpression) {
                let percentage = String(compareStr[range])
                // 3. 返回拼接后的格式：NVDA (0.04%)
                return "\(symbol) (\(percentage))"
            }
        }
        // 如果找不到数据，则只显示 Symbol
        return symbol
    }
    
    // 拆分出 Picker
    private var typePickerView: some View {
        Picker("Type", selection: $selectedTypeIndex) {
            Text(summaryCall.isEmpty ? "Calls" : "Calls \(summaryCall)").tag(0)
            Text(summaryPut.isEmpty ? "Puts" : "Puts \(summaryPut)").tag(1)
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding()
        .background(Color(UIColor.systemBackground))
    }
    
    // 拆分出表头
    private var tableHeaderView: some View {
        HStack(spacing: 4) {
            Text("Expiry").frame(maxWidth: .infinity, alignment: .leading)
            Text("Strike").frame(width: 55, alignment: .trailing)
            Text("Dist").frame(width: 55, alignment: .trailing)
            Text("Open Int").frame(width: 65, alignment: .trailing)
            Text("1-Day").frame(width: 60, alignment: .trailing)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemBackground))
    }
    
    // 拆分出列表部分
    private var dataListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("TopAnchor")
                    
                    if filteredData.isEmpty {
                        Text("暂无数据")
                            .foregroundColor(.secondary)
                            .padding(.top, 20)
                    } else {
                        ForEach(filteredData) { item in
                            OptionRowView(item: item)
                            Divider().padding(.leading)
                        }
                    }
                }
            }
            .onChange(of: selectedTypeIndex) { _, _ in
                proxy.scrollTo("TopAnchor", anchor: .top)
            }
        }
    }
}

// MARK: - 【新增】期权榜单页面 (OptionsRankView)

struct OptionsRankView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedTab = 0 // 0: 最可能涨, 1: 最可能跌
    @State private var rankUp: [OptionRankItem] = []
    @State private var rankDown: [OptionRankItem] = []
    @State private var isLoading = true
    
    // 详情跳转
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    @State private var navigateToChart = false // 控制直接跳转股价图
    
    var currentList: [OptionRankItem] {
        selectedTab == 0 ? rankUp : rankDown
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 分段控制器
            Picker("Filter", selection: $selectedTab) {
                Text("最可能涨").tag(0)
                Text("最可能跌").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            
            // 2. 列表内容
        ZStack { // 使用 ZStack 让加载菊花盖在列表上，而不是替换列表
            if isLoading && rankUp.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("正在计算大数据榜单...")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if !isLoading && currentList.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("暂无符合条件的数据")
                        .foregroundColor(.secondary)
                    Text("当前市值筛选阀值: \(formatMarketCap(dataService.optionCapLimit))")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
            } else {
                // 只要有数据，List 就一直存在于这里，不会被销毁
                List {
                    ForEach(currentList) { item in
                        OptionRankRow(item: item, isUp: selectedTab == 0) {
                            handleSelection(item.symbol) // 这是原有的短按
                        } longPressAction: {
                            handleLongPress(item.symbol) // 【新增】传入长按逻辑
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .id(selectedTab) 
            }
        }
        }
        .navigationTitle("期权榜单")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .task {
            await loadData()
        }
        .navigationDestination(isPresented: $navigateToDetail) {
            if let sym = selectedSymbol {
                OptionsDetailView(symbol: sym)
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            if let sym = selectedSymbol {
                // 这里的 groupName 逻辑参考 OptionsDetailView 里的逻辑
                let groupName = dataService.getCategory(for: sym) ?? "US"
                ChartView(symbol: sym, groupName: groupName)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func loadData() async {
        // 关键点：如果已经有数据了，就不要设置 isLoading = true
        // 这样就不会触发 UI 的大切换，List 就不会被销毁
        if rankUp.isEmpty && rankDown.isEmpty {
            isLoading = true
        }
        
        if let (up, down) = await dataService.fetchOptionsRankData() {
            await MainActor.run {
                self.rankUp = up
                self.rankDown = down
                self.isLoading = false // 加载完成后关闭
            }
        } else {
            await MainActor.run { self.isLoading = false }
        }
    }

    
    private func handleSelection(_ symbol: String) {
        if usageManager.canProceed(authManager: authManager, action: .viewOptionsDetail) {
            self.selectedSymbol = symbol
            self.navigateToDetail = true
        } else {
            self.showSubscriptionSheet = true
        }
    }
    
    private func formatMarketCap(_ cap: Double) -> String {
        if cap >= 1_000_000_000 {
            return String(format: "%.0fB", cap / 1_000_000_000)
        } else {
            return String(format: "%.0fM", cap / 1_000_000)
        }
    }

    // 在 OptionsRankView 内部 handleSelection 下方添加：
    private func handleLongPress(_ symbol: String) {
        // 权限检查：跳转股价模式通常对应 .viewChart 行为
        if usageManager.canProceed(authManager: authManager, action: .viewChart) {
            self.selectedSymbol = symbol
            self.navigateToChart = true
            // 触发一个轻微震动反馈
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        } else {
            self.showSubscriptionSheet = true
        }
    }
}

// 【新增】榜单行视图
struct OptionRankRow: View {
    let item: OptionRankItem
    let isUp: Bool
    let action: () -> Void
    let longPressAction: () -> Void // 接收长按逻辑

    @EnvironmentObject var dataService: DataService
    // 【新增】用于存储倒数第二新的价格
    @State private var secondLatestPrice: Double? = nil

    var body: some View {
        // 使用 VStack 包裹“数据行”和“Tags行”
        VStack(alignment: .leading, spacing: 6) {
            
            // --- 第一行：Symbol, Name + 右侧三个数字 ---
            // 确保这整个部分都在一个 HStack 里
            HStack(alignment: .center) {
                
                // 左侧容器：Symbol + Name
                HStack(spacing: 6) {
                    Text(item.symbol)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    
                    let info = getInfo(for: item.symbol)
                    if !info.name.isEmpty {
                        Text(info.name)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .layoutPriority(0) // 优先级低，允许被压缩
                
                Spacer(minLength: 8) // 自动推开两侧
                
                // 右侧容器：三个核心数字（最新价、涨跌幅、昨收）
                HStack(spacing: 8) {
                    // 1. 最新 Price
                    Text(String(format: "%.1f", item.price))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(isUp ? .red : .green)
                    
                    // 2. 涨跌百分比
                    if let compareStr = dataService.compareDataUppercased[item.symbol.uppercased()] {
                        let rawPercentage = extractPercentage(from: compareStr)
                        let formattedPercentage = formatToPrecision(rawPercentage, precision: 1)
                        let themeColor = getCompareColor(from: rawPercentage)
                        
                        Text(formattedPercentage)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(themeColor)
                            .padding(.horizontal, 4)
                            .background(themeColor.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    // 3. 次新价格
                    if let prevPrice = secondLatestPrice {
                        Text(String(format: "%.1f", prevPrice))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(prevPrice > 0 ? .red : (prevPrice < 0 ? .green : .secondary))
                    } else {
                        Text("--")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.3))
                    }
                }
                .fixedSize(horizontal: true, vertical: false) // 禁止换行
                .layoutPriority(1) // 优先级高，确保先占满宽度
            }
            
            // --- 第二行：Tags ---
            let info = getInfo(for: item.symbol)
            if !info.tags.isEmpty {
                Text(info.tags.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle()) // 关键：让整个 Cell 区域可点击
        .onTapGesture {
            action() // 点击执行：进入期权详情
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            longPressAction() // 长按执行：跳转股价模式
        }
        .task {
            // 【新增】进入视图时获取历史数据以提取倒数第二个值
            await loadSecondLatestPrice()
        }
    }
    
    // --- 新增或修改辅助函数 ---
    
    /// 将类似 "1.23%" 或 "1.23" 的字符串转换为指定精度的百分比格式
    private func formatToPrecision(_ text: String, precision: Int) -> String {
        // 去掉百分号以便转换
        let cleanText = text.replacingOccurrences(of: "%", with: "")
        if let value = Double(cleanText) {
            // 使用 %.1f 格式化，并手动补回 %
            return String(format: "%+.\(precision)f%%", value) 
            // 注意：这里使用了 %+ 会自动带上正负号，如果你不需要正号，把 + 去掉即可
        }
        return text
    }

    // 【新增】颜色判断逻辑
    private func getCompareColor(from text: String) -> Color {
        // 检查是否包含负号
        if text.contains("-") {
            return .green
        } 
        // 默认或包含正号则为红色（符合“正为红色”的需求）
        return .red
    }
    
    private func loadSecondLatestPrice() async {
        // 现在 history[0] 是最新，history[1] 是次新
        let history = await DatabaseManager.shared.fetchOptionsHistory(forSymbol: item.symbol)
        
        if history.count >= 2 {
            await MainActor.run {
                // 因为后端改成了 DESC，所以索引 1 确确实实就是“次新”的价格
                self.secondLatestPrice = history[1].price
            }
        } else {
            // 如果只有一条数据，说明没有次新价格
            await MainActor.run {
                self.secondLatestPrice = nil
            }
        }
    }

    // 提取百分数：从 "0.04%++" 中提取 "0.04%"
    private func extractPercentage(from text: String) -> String {
        let pattern = "([+-]?\\d+(\\.\\d+)?%)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return text // 如果没匹配到则返回原样
    }
    
    private func getInfo(for symbol: String) -> (name: String, tags: [String]) {
        let upperSymbol = symbol.uppercased()
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (stock.name, stock.tag)
        }
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (etf.name, etf.tag)
        }
        return ("", [])
    }
}

// 拆分出单行数据视图
struct OptionRowView: View {
    let item: OptionItem
    
    var body: some View {
        HStack(spacing: 4) {
            OptionCellView(text: item.expiryDate, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            OptionCellView(text: item.strike, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
            OptionCellView(text: item.distance, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
                .font(.system(size: 12))
            OptionCellView(text: item.openInterest, alignment: .trailing)
                .frame(width: 65, alignment: .trailing)
            OptionCellView(text: item.change, alignment: .trailing)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal)
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - 辅助视图
struct OptionCellView: View {
    let text: String
    var alignment: Alignment = .leading
    
    var isNew: Bool {
        text.lowercased().contains("new")
    }
    
    var displayString: String {
        if isNew {
            return text.replacingOccurrences(of: "new", with: "", options: .caseInsensitive)
                       .trimmingCharacters(in: .whitespaces)
        }
        return text
    }
    
    var body: some View {
        Text(displayString)
            .font(.system(size: 14, weight: isNew ? .bold : .regular))
            .foregroundColor(isNew ? .orange : .primary)
            .multilineTextAlignment(textAlignment)
    }
    
    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        default: return .leading
        }
    }
}
