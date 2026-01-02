import SwiftUI
import Charts
import Foundation

// MARK: - 【重构】共享组件：价格三联显示 (Latest IV | 涨跌幅 | Prev IV)
struct PriceTriView: View {
    let symbol: String
    
    // 【修改】Value 1: 改为 String 类型 (传入 Latest IV)
    let val1: String? 
    // Value 2: 百分比 (自动计算)
    // 【修改】Value 3: 改为 String 类型 (传入 Prev IV)
    let val3: String? 
    
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        HStack(spacing: 8) {
            // 1. 第一项：Latest IV (替代原来的 Diff)
            if let v1 = val1 {
                Text(v1)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    // 【要求】保持正红负绿 (IV通常为正，所以这里实际上几乎总是红色)
                    // 如果你想解析数值判断，可以用 Double(v1) >= 0
                    .foregroundColor(.red) 
            } else {
                Text("--")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // 2. 第二项：CompareStr (涨跌百分比) - 保持不变
            if let compareStr = dataService.compareDataUppercased[symbol.uppercased()] {
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
            
            // 3. 第三项：Previous IV (替代原来的 Latest IV)
            if let v3 = val3 {
                Text(v3)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("--")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .fixedSize(horizontal: true, vertical: false) // 防止被压缩
    }
    
    // 辅助函数 (直接复用之前的逻辑)
    private func extractPercentage(from text: String) -> String {
        let pattern = "([+-]?\\d+(\\.\\d+)?%)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return text
    }
    
    private func formatToPrecision(_ text: String, precision: Int) -> String {
        let cleanText = text.replacingOccurrences(of: "%", with: "")
        if let value = Double(cleanText) {
            return String(format: "%+.\(precision)f%%", value)
        }
        return text
    }
    
    private func getCompareColor(from text: String) -> Color {
        if text.contains("-") { return .green }
        return .red
    }
}

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
    
    // 【新增 1】控制跳转到股价图的状态
    @State private var navigateToChart = false
    
    // 【新增 1】搜索相关的状态
    @State private var showSearchBar = false      // 控制搜索框是否显示
    @State private var searchText = ""            // 输入的内容
    @State private var highlightedSymbol: String? // 当前高亮的 Symbol
    // 【新增】焦点状态控制
    @FocusState private var isSearchFieldFocused: Bool 
    
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
        // 【核心修改 1】使用 ScrollViewReader 包裹
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                
                // 【新增 2】搜索栏区域 (当点击图标时显示)
                if showSearchBar {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        
                        TextField("输入 Symbol 跳转 (如 AAPL)", text: $searchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .submitLabel(.search)
                            // 【新增 1】绑定焦点状态
                            .focused($isSearchFieldFocused) 
                            // 【新增 2】当视图出现时，自动激活焦点
                            .onAppear {
                                isSearchFieldFocused = true
                            }
                            // 键盘点击“搜索/确认”时触发
                            .onSubmit {
                                performSearch(proxy: proxy)
                            }
                        
                        Button("取消") {
                            withAnimation {
                                // 【优化】取消时先收起键盘
                                isSearchFieldFocused = false 
                                showSearchBar = false
                                searchText = ""
                                highlightedSymbol = nil // 取消高亮
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                List {
                    if sortedSymbols.isEmpty {
                        Text("暂无期权异动数据")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sortedSymbols, id: \.self) { symbol in
                            OptionListRow(
                                symbol: symbol,
                                action: { handleSelection(symbol) },
                                longPressAction: { handleLongPress(symbol) },
                                // 【新增 3】传入高亮状态
                                isHighlighted: symbol == highlightedSymbol
                            )
                            // 【关键】为每一行设置 id，以便 ScrollViewReader 能够找到它
                            .id(symbol) 
                        }
                    }
                }
                .listStyle(PlainListStyle()) // 保持列表样式一致
            }
        }
        .navigationTitle("期权异动")
        .navigationBarTitleDisplayMode(.inline)
        // 【新增】右上角按钮
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) { // 增加间距
                    
                    // 【新增 4】搜索按钮图标
                    Button(action: {
                        withAnimation {
                            showSearchBar.toggle()
                            // 如果打开搜索框，可以自动重置一下状态
                            if !showSearchBar {
                                highlightedSymbol = nil
                            }
                        }
                    }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                            .padding(8)
                            .background(Color(UIColor.secondarySystemBackground))
                            .clipShape(Circle())
                    }
                    
                    // 原有的 Rank 按钮
                    Button(action: {
                        if usageManager.canProceed(authManager: authManager, action: .viewOptionsRank) {
                            self.navigateToRank = true
                        } else {
                            self.showSubscriptionSheet = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 12, weight: .bold))
                            Text("涨跌预测榜")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .foregroundColor(.white)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue, Color.indigo]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.blue.opacity(0.3), radius: 4, x: 0, y: 2)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }
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
        // 【新增】跳转目的地
        .navigationDestination(isPresented: $navigateToChart) {
            if let sym = selectedSymbol {
                // 这里的 groupName 逻辑
                let groupName = dataService.getCategory(for: sym) ?? "US"
                ChartView(symbol: sym, groupName: groupName)
            }
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
    
    // 【修复点 1】补全 handleLongPress 函数
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

    // 【新增 5】执行搜索与跳转逻辑
    private func performSearch(proxy: ScrollViewProxy) {
        let target = searchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        guard !target.isEmpty else { return }
        
        // 在 sortedSymbols 中查找是否存在该 Symbol
        // 为了体验更好，这里做了包含匹配，如果输入 "AAP"，能找到 "AAPL"
        // 如果想严格匹配，就用 symbol == target
        if let foundSymbol = sortedSymbols.first(where: { $0.contains(target) }) {
            
            // 1. 设置高亮
            self.highlightedSymbol = foundSymbol
            
            // 2. 滚动跳转
            withAnimation(.spring()) {
                proxy.scrollTo(foundSymbol, anchor: .center) // anchor: .center 让它滚到屏幕中间
            }
            
            // 可选：找到后收起键盘，但不收起搜索框，方便用户继续看
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            
        } else {
            // 可选：没找到给个震动反馈
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            // 也可以把 highlightedSymbol 设为 nil
            self.highlightedSymbol = nil
        }
    }
}

// 拆分出的列表行视图
struct OptionListRow: View {
    let symbol: String
    let action: () -> Void
    // 【新增】接收长按事件
    let longPressAction: () -> Void
    
    // 【新增】是否高亮
    var isHighlighted: Bool = false
    
    @EnvironmentObject var dataService: DataService
    
    // 【修改】Tuple 结构变化：存储 (Latest IV, Prev IV)
    @State private var displayData: (iv: String?, prevIv: String?)? = nil
    
    var body: some View {
        // 移除 Button，改用 VStack + 手势
        VStack(alignment: .leading, spacing: 6) {
            
            // 第一行
            HStack(alignment: .center) {
                // 左侧 Symbol + Name
                HStack(spacing: 6) {
                    
                    // 【核心修改区域】只针对 Symbol 文字进行高亮
                    Text(symbol)
                        .font(.headline)
                        .fontWeight(.bold)
                        // 1. 文字颜色：高亮时变白，普通时原色
                        .foregroundColor(isHighlighted ? .white : .primary)
                        // 2. 内边距：为了让背景色不贴着字，加一点点呼吸空间
                        .padding(.horizontal, isHighlighted ? 6 : 0)
                        .padding(.vertical, isHighlighted ? 2 : 0)
                        // 3. 背景色：高亮时变蓝
                        .background(
                            isHighlighted 
                            ? Color.blue 
                            : Color.clear
                        )
                        // 4. 圆角：让高亮背景有个小圆角，更好看
                        .cornerRadius(6)
                        // 5. 动画：让颜色变化平滑过渡
                        .animation(.easeInOut, value: isHighlighted)
                    
                    let info = getInfo(for: symbol)
                    if !info.name.isEmpty {
                        Text(info.name)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .layoutPriority(0)
                
                Spacer(minLength: 8)
                
                // 【核心修改】传入 IV 数据
                if let data = displayData {
                    PriceTriView(
                        symbol: symbol,
                        val1: data.iv,      // Latest IV
                        val3: data.prevIv   // Previous IV
                    )
                    .layoutPriority(1)
                } else {
                    Text("--")
                        .foregroundColor(.secondary)
                }
                // (小箭头已移除)
            }
            
            // 第二行 Tags
            let info = getInfo(for: symbol)
            if !info.tags.isEmpty {
                Text(info.tags.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onLongPressGesture(minimumDuration: 0.5) { longPressAction() }
        .task { await loadPriceAndCalc() }
        // 这是一个小动画，让高亮出现时平滑一点
        .animation(.easeInOut, value: isHighlighted)
    }
    
    // 【核心修改】加载数据并执行算法
    // 改为调用 fetchOptionsSummary，直接利用服务器返回的 change 字段
    private func loadPriceAndCalc() async {
        if displayData != nil { return }
        
        // 调用新的 Summary 接口
        guard let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) else {
            return
        }
        
        // 【修改】不再计算 Price+Change，而是直接取 IV
        let iv = summary.iv
        let prevIv = summary.prev_iv
        
        await MainActor.run {
            self.displayData = (iv, prevIv)
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
    
    // --- 注入权限和点数管理对象 ---
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedTypeIndex = 0
    @State private var navigateToChart = false
    @State private var summaryCall: String = ""
    @State private var summaryPut: String = ""
    // 【修改】用于存储计算后的最新价格 (Price + Change)
    @State private var displayPrice: Double? = nil 
    
    // 【新增】用于存储计算后的次新价格 (Prev Price + Prev Change)
    @State private var displayPrevPrice: Double? = nil 
    
    // 【新增】用于存储从数据库获取的涨跌额 change
    @State private var dbChange: Double? = nil
    
    // --- 控制订阅页显示 ---
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
        // 【修改 1】设置一个基础标题 (用于返回按钮的文字)
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .toolbar {
            // 【修改 2】使用 principal 来自定义中间标题，支持颜色
            ToolbarItem(placement: .principal) {
                HStack(spacing: 4) {
                    // Symbol 保持原样 (或者如果还是很挤，可以改为 .subheadline)
                    Text(symbol)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // 1. 显示最新 Price + Change
                    if let priceVal = displayPrice {
                        // 【修改】移除括号，改用 smaller font (例如 size 14)
                        Text(String(format: "%.2f", priceVal)) 
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor((dbChange ?? 0) >= 0 ? .red : .green) 
                    }
                    
                    // 2. 显示次新 Price + Change
                    if let prevVal = displayPrevPrice {
                        // 【修改】移除括号，改用 smaller font (例如 size 14)
                        Text(String(format: "%.2f", prevVal))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray) 
                    }
                }
            }
            
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
                    Text("切股价")
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
            // 【修改 3】获取数据
            if let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) {
                await MainActor.run {
                    if let c = summary.call { self.summaryCall = c }
                    if let p = summary.put { self.summaryPut = p }
                    
                    // 1. 处理最新数据
                    if let chg = summary.change {
                        self.dbChange = chg
                        
                        // 【新增】计算 Price + Change
                        if let price = summary.price {
                            self.displayPrice = price + chg
                        }
                    }
                    
                    // 2. 【本次新增】处理次新数据
                    if let prevPrice = summary.prev_price, let prevChg = summary.prev_change {
                        self.displayPrevPrice = prevPrice + prevChg
                    }
                }
            }
        }
    }
    
    // MARK: - 辅助逻辑
    
    // (displayTitle 属性已不再需要，可以删除)
    
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
    
    // 【修复点 2】删除了重复的 handleLongPress，只保留这一个
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
    let longPressAction: () -> Void 
    @EnvironmentObject var dataService: DataService

    var body: some View {
        // 使用 VStack 包裹“数据行”和“Tags行”
        VStack(alignment: .leading, spacing: 6) {
            
            // --- 第一行：Symbol, Name + 右侧四个数据 ---
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
                .layoutPriority(0)
                
                Spacer(minLength: 8)
                
                // 【核心修改】使用新的字段
                PriceTriView(
                    symbol: item.symbol,
                    val1: item.iv,       // Latest IV
                    val3: item.prev_iv   // Previous IV
                )
                .layoutPriority(1)
            }
            
            // 第二行 Tags
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
    }
    
    // ... getInfo 等辅助函数保持不变 (或者你也可以把 getInfo 提出来，但暂时放在这里没问题)
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
