import SwiftUI
import Charts
import Foundation

// MARK: - 【新增】5列数据显示组件 (Latest IV | Prev IV | Compare | Prev Price | Latest Price)
struct PriceFiveColumnView: View {
    let symbol: String
    
    // 1. Latest IV (大)
    let latestIv: String?
    // 2. Prev IV (小)
    let prevIv: String?
    
    // 4. Prev Price (小)
    let prevPrice: Double?
    // 5. Latest Price (大)
    let latestPrice: Double?
    let latestChange: Double? // 用于判断颜色
    
    @EnvironmentObject var dataService: DataService

    var body: some View {
        HStack(spacing: 6) { // 稍微紧凑一点的间距
            
            // 1. Latest IV (大字体)
            Text(latestIv ?? "--")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                // 【修改点】调用辅助函数判断颜色
                .foregroundColor(getIvColor(latestIv)) 
                .fixedSize()
            
            // 2. Previous IV (小字体)
            Text(prevIv ?? "--")
                .font(.system(size: 12, design: .monospaced)) // 正常/偏小
                .foregroundColor(.secondary)
                .fixedSize()
            
            // 2. 第二项：CompareStr (涨跌百分比) - 保持不变
            if let compareStr = dataService.compareDataUppercased[symbol.uppercased()] {
                let rawPercentage = extractPercentage(from: compareStr)
                let formattedPercentage = formatToPrecision(rawPercentage, precision: 1)
                let themeColor = getCompareColor(from: rawPercentage)
                
                Text(formattedPercentage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeColor)
                    .padding(.horizontal, 2)
                    .background(themeColor.opacity(0.1))
                    .cornerRadius(4)
                    .fixedSize()
            }
            
            // 4. Previous Price (小字体)
            if let pPrice = prevPrice {
                Text(String(format: "%.2f", pPrice))
                    .font(.system(size: 12, design: .monospaced)) // 正常/偏小
                    .foregroundColor(.gray)
                    .fixedSize()
            } else {
                Text("--")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            
            // 5. Latest Price (大字体)
            if let lPrice = latestPrice {
                Text(String(format: "%.2f", lPrice))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    
                    // 【修改了这里】：直接根据 lPrice 的值判断颜色
                    // 正数(>=0)变红，负数(<0)变绿
                    .foregroundColor(lPrice >= 0 ? .red : .green)
                    
                    .fixedSize()
            } else {
                Text("--")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // 复用之前的辅助函数
    private func extractPercentage(from text: String) -> String {
        let pattern = "([+-]?\\d+(\\.\\d+)?%)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return text
    }

    // 【新增辅助函数】解析 IV 字符串并返回颜色
    private func getIvColor(_ text: String?) -> Color {
        guard let text = text else { return .secondary }
        // 去除可能存在的百分号或其他符号
        let cleanText = text.replacingOccurrences(of: "%", with: "")
        // 转为 Double 判断
        if let value = Double(cleanText) {
            return value >= 0 ? .red : .green
        }
        // 解析失败默认红色 (因为 IV 通常是正数)
        return .red
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
// 包含 TabView 容器和时间选择器逻辑
struct OptionsHistoryChartView: View {
    let symbol: String
    
    // 状态管理
    @State private var historyData: [DatabaseManager.OptionHistoryItem] = []
    // 默认值设为 .threeMonths (或者你想改成 .oneMonth 也可以)
    @State private var selectedTimeRange: TimeRangeOption = .oneMonth
    @State private var isLoading = false
    
    // 控制当前显示的页面索引 (0: IV, 1: Price)
    @State private var currentPage = 0
    
    // 定义时间范围枚举
    enum TimeRangeOption: String, CaseIterable, Identifiable {
        // 【修改点 1】修改 Case 定义：增加 1M，保留 3M/1Y/10Y，删除 6M/2Y/5Y
        case oneMonth = "1M"
        case threeMonths = "3M"
        case oneYear = "1Y"
        case tenYears = "10Y"
        
        var id: String { self.rawValue }
        
        var monthsBack: Int {
            switch self {
            // 【修改点 2】更新对应的月份数值
            case .oneMonth: return 1
            case .threeMonths: return 3
            case .oneYear: return 12
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
        VStack(spacing: 8) {
            
            // 1. 【新增】顶部指示点 (Page Indicator)
            // 只有当有数据时才显示指示器
            if !historyData.isEmpty {
                HStack(spacing: 8) {
                    Circle()
                        .fill(currentPage == 0 ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                    Circle()
                        .fill(currentPage == 1 ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                .padding(.top, 4)
                .animation(.easeInOut, value: currentPage)
            }
            
            // 2. 图表主体区域 (包含 Loading 和 TabView)
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                
                if isLoading {
                    ProgressView()
                } else if historyData.isEmpty {
                    Text("暂无历史数据")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if filteredData.isEmpty {
                    Text("该时间段内无数据")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // 【核心修改】使用 TabView 实现左右滑动
                    TabView(selection: $currentPage) {
                        
                        // 页面 0: IV 图表 (默认)
                        SingleChartContent(
                            data: filteredData,
                            dataType: .iv
                        )
                        .tag(0)
                        
                        // 页面 1: Price 图表
                        SingleChartContent(
                            data: filteredData,
                            dataType: .price
                        )
                        .tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never)) // 隐藏系统自带的底部指示器
                }
            }
            .frame(height: 240) // 稍微增加高度以容纳 TabView
            .padding(.horizontal)
            
            // 3. 时间切换条 (公用)
            timeRangeSelector
        }
        .task {
            await loadData()
        }
    }
    
    // 【关键修复】这里把 timeRangeSelector 和 loadData 放回了 struct 内部
    
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

// MARK: - 【新增】单一图表绘制组件
// 负责具体的 Chart 绘制逻辑
struct SingleChartContent: View {
    let data: [DatabaseManager.OptionHistoryItem]
    let dataType: ChartDataType
    
    enum ChartDataType {
        case price
        case iv
        
        var title: String {
            switch self {
            case .price: return "Calls+Puts" // 【修改点 1】标题改为 Calls+Puts
            case .iv: return "IV Trend"
            }
        }
        
        // baseColor 属性实际上在下面 barGradient 里被覆盖了，这里保留或删除都可以，不影响
        var baseColor: Color {
            switch self {
            case .price: return .red
            case .iv: return .red // 让 IV 基础色也变为红色
            }
        }
    }
    
    // 1. 日期格式化 (显示用)
    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd"
        return formatter
    }
    
    // 2. 唯一ID格式化 (X轴唯一性)
    private var uniqueIDFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // 小标题，提示当前是什么图
            Text(dataType.title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.top, 8)
            
            chartBody
        }
    }
    
    private var chartBody: some View {
        // 1. 数据排序
        let sortedData = data.sorted { $0.date < $1.date }
        
        // 2. 准备 X 轴的唯一 ID
        let allDateIDs = sortedData.map { uniqueIDFormatter.string(from: $0.date) }
        
        // 3. 计算步长
        let stride = getAxisStride(count: sortedData.count)
        
        // 4. 计算 Tick Values
        let totalCount = allDateIDs.count
        let tickValues = allDateIDs.enumerated().compactMap { index, idValue in
            let distanceFromEnd = totalCount - 1 - index
            if distanceFromEnd % stride == 0 {
                return idValue
            }
            return nil
        }
        
        return Chart {
            ForEach(sortedData) { item in
                // 根据类型获取数值
                let value = (dataType == .price) ? item.price : item.iv
                
                BarMark(
                    x: .value("Date", uniqueIDFormatter.string(from: item.date)),
                    y: .value("Value", value)
                )
                // 【修改点 2】颜色逻辑现在统一了，正数自动变红
                .foregroundStyle(barGradient(for: value))
                .cornerRadius(4)
            }
            
            // 0 线
            RuleMark(y: .value("Zero", 0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.gray.opacity(0.5))
        }
        .chartXAxis {
            AxisMarks(values: tickValues) { value in
                if let fullDateString = value.as(String.self),
                   let dateObject = uniqueIDFormatter.date(from: fullDateString) {
                    
                    AxisValueLabel(centered: true) {
                        let dayString = dayFormatter.string(from: dateObject)
                        Text(dayString)
                            .font(.system(size: 10, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .lineSpacing(0)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }
    
    // 辅助：获取步长
    private func getAxisStride(count: Int) -> Int {
        switch count {
        case 0...10: return 1
        case 11...30: return 3
        case 31...70: return 5
        case 71...150: return 10
        default: return 20
        }
    }
    
    // 辅助：渐变色
    // 【修改点 2 核心】：移除了 if dataType == .iv 的判断
    // 现在无论什么图表，只要数值是正数(>=0)就是红色渐变，负数是绿色渐变
    private func barGradient(for value: Double) -> LinearGradient {
        
        let isPositive = value >= 0
        let colors: [Color] = isPositive
            ? [.red.opacity(0.8), .red.opacity(0.4)]   // 正数 = 红色
            : [.green.opacity(0.8), .green.opacity(0.4)] // 负数 = 绿色
        
        return LinearGradient(
            colors: colors,
            startPoint: isPositive ? .bottom : .top,
            endPoint: isPositive ? .top : .bottom
        )
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

    // 【修改状态变量名，或者直接复用 navigateToRank，这里建议复用但改个注释】
    @State private var navigateToBigOrders = false // 原 navigateToRank
    
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
                        // 复用原来的权限检查，或者创建新的枚举 .viewBigOrders
                        if usageManager.canProceed(authManager: authManager, action: .viewOptionsRank) {
                            self.navigateToBigOrders = true
                        } else {
                            self.showSubscriptionSheet = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            // 图标改为美元符号或列表符号，体现“大单”
                            Image(systemName: "dollarsign.circle.fill") 
                                .font(.system(size: 14, weight: .bold))
                            Text("期权大单") // 修改文字
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .foregroundColor(.white)
                        .background(
                            // 改用深金色/黑金渐变，或者保持蓝紫色，这里用蓝紫显得科技感
                            LinearGradient(
                                gradient: Gradient(colors: [Color.purple, Color.blue]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.purple.opacity(0.3), radius: 4, x: 0, y: 2)
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
        // 【修改】跳转目的地
        .navigationDestination(isPresented: $navigateToBigOrders) {
            OptionBigOrdersView() // 跳转到新页面
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
    
    // 【修改点 1】Tuple 结构扩展：存储 IV 和 价格信息
    @State private var displayData: (
        iv: String?, 
        prevIv: String?, 
        latestPrice: Double?, 
        prevPrice: Double?, 
        change: Double?
    )? = nil
    
    var body: some View {
        // 移除 Button，改用 VStack + 手势
        VStack(alignment: .leading, spacing: 6) {
            
            // 第一行
            HStack(alignment: .center) {
                // 左侧 Symbol (移除 Name)
                Text(symbol)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(isHighlighted ? .white : .primary)
                    .padding(.horizontal, isHighlighted ? 6 : 0)
                    .padding(.vertical, isHighlighted ? 2 : 0)
                    .background(isHighlighted ? Color.blue : Color.clear)
                    .cornerRadius(6)
                    .animation(.easeInOut, value: isHighlighted)
                    .layoutPriority(0)
                
                // 【修改点 2】移除 Name 的显示代码
                // 原来的 if !info.name.isEmpty { ... } 代码块删除
                
                Spacer(minLength: 8)
                
                // 【修改点 3】使用新的 5列组件
                if let data = displayData {
                    PriceFiveColumnView(
                        symbol: symbol,
                        latestIv: data.iv,
                        prevIv: data.prevIv,
                        prevPrice: data.prevPrice,
                        latestPrice: data.latestPrice,
                        latestChange: data.change
                    )
                    .layoutPriority(1)
                } else {
                    Text("--")
                        .foregroundColor(.secondary)
                }
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
    
    // 【修改点 4】计算价格数据
    private func loadPriceAndCalc() async {
        if displayData != nil { return }
        
        // 调用新的 Summary 接口
        guard let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) else {
            return
        }
        
        // 提取 IV
        let iv = summary.iv
        let prevIv = summary.prev_iv
        
        // 计算最新价格
        var latestPrice: Double? = nil
        if let p = summary.price, let c = summary.change {
            latestPrice = p + c
        }
        
        // 计算次新价格
        var prevPrice: Double? = nil
        if let pp = summary.prev_price, let pc = summary.prev_change {
            prevPrice = pp + pc
        }
        
        // 保存 change 用于判断颜色
        let change = summary.change
        
        await MainActor.run {
            self.displayData = (iv, prevIv, latestPrice, prevPrice, change)
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
            // 【修改点】ToolbarItem (principal) 只需要显示 Symbol
            ToolbarItem(placement: .principal) {
                // 移除原来的 HStack 和 Price 显示逻辑
                Text(symbol)
                    .font(.headline)
                    .foregroundColor(.primary)
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
            Text("Strike").frame(width: 50, alignment: .trailing)
            Text("Dist").frame(width: 50, alignment: .trailing)
            Text("OI").frame(width: 55, alignment: .trailing)
            Text("1-Day").frame(width: 55, alignment: .trailing)
            Text("Price").frame(width: 55, alignment: .trailing) // 【新增表头】
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
            
            // 【新增步骤 1】过滤 "最可能涨" 列表
            // 逻辑：只要 (IV > 0) 或 (Price > 0) 即可保留。
            // 如果 (IV < 0 且 Price < 0)，则剔除。
            let filteredUp = up.filter { item in
                let ivVal = parseIvValue(item.iv)
                let priceVal = (item.price ?? 0) + (item.change ?? 0)
                
                // 保留条件：IV 是正数 OR 价格是正数
                return ivVal > 0 || priceVal > 0
            }
            
            // 【新增步骤 2】过滤 "最可能跌" 列表
            // 逻辑：只要 (IV < 0) 或 (Price < 0) 即可保留。
            // 如果 (IV > 0 且 Price > 0)，则剔除。
            let filteredDown = down.filter { item in
                let ivVal = parseIvValue(item.iv)
                let priceVal = (item.price ?? 0) + (item.change ?? 0)
                
                // 保留条件：IV 是负数 OR 价格是负数
                return ivVal < 0 || priceVal < 0
            }

            await MainActor.run {
                self.rankUp = filteredUp
                self.rankDown = filteredDown
                self.isLoading = false
            }
        } else {
            await MainActor.run { self.isLoading = false }
        }
    }

    // 【新增辅助函数】解析 IV 字符串为 Double (去掉百分号)
    private func parseIvValue(_ text: String?) -> Double {
        guard let t = text else { return 0.0 }
        let clean = t.replacingOccurrences(of: "%", with: "")
        return Double(clean) ?? 0.0
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
        // 使用 VStack 垂直排列三行内容
        VStack(alignment: .leading, spacing: 8) {
            
            // --- 第一行：Symbol + Name ---
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.symbol)
                    .font(.system(size: 18, weight: .bold, design: .monospaced)) // 稍微加大字号突出显示
                    .foregroundColor(.primary)
                
                let info = getInfo(for: item.symbol)
                if !info.name.isEmpty {
                    Text(info.name)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
                Spacer()
            }
            
            // --- 第二行：五个数字 (PriceFiveColumnView) ---
            // 依然需要先计算价格
            let latestPriceVal = (item.price != nil && item.change != nil) ? (item.price! + item.change!) : nil
            let prevPriceVal = (item.prev_price != nil && item.prev_change != nil) ? (item.prev_price! + item.prev_change!) : nil
            
            PriceFiveColumnView(
                symbol: item.symbol,
                latestIv: item.iv,        // Latest IV
                prevIv: item.prev_iv,     // Previous IV
                prevPrice: prevPriceVal,  // Prev Price
                latestPrice: latestPriceVal, // Latest Price
                latestChange: item.change
            )
            // 因为 VStack 是 leading 对齐，这里不需要 Spacer，它会自动靠左显示
            
            // --- 第三行：Tags ---
            let info = getInfo(for: item.symbol)
            if !info.tags.isEmpty {
                Text(info.tags.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundColor(.gray) // 使用稍微淡一点的颜色
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle()) // 保证点击区域覆盖整个块
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
                .frame(width: 50, alignment: .trailing)
            
            OptionCellView(text: item.distance, alignment: .trailing)
                .frame(width: 50, alignment: .trailing)
                .font(.system(size: 11)) // 缩小一点点防止拥挤
            
            OptionCellView(text: item.openInterest, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
            
            OptionCellView(text: item.change, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
            
            // 【新增 Price 单元格】
            OptionCellView(text: item.price, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(.blue) // 用蓝色区分一下价格列，或者保持原样
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

// MARK: - 【新增】期权大单页面 (替代原 OptionsRankView)
struct OptionBigOrdersView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 跳转详情
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            
            if dataService.optionBigOrders.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("暂无大单数据")
                        .foregroundColor(.secondary)
                    Text("请确保 Options_History 文件已更新")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // 顶部说明
                        HStack {
                            Image(systemName: "chart.bar.doc.horizontal.fill")
                                .foregroundColor(.blue)
                            Text("机构资金流向监控")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(dataService.optionBigOrders.count) 笔交易")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal)
                        .padding(.top, 10)
                        
                        ForEach(dataService.optionBigOrders) { order in
                            BigOrderCard(order: order)
                                .onTapGesture {
                                    handleSelection(order.symbol)
                                }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("期权大单")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToDetail) {
            if let sym = selectedSymbol {
                OptionsDetailView(symbol: sym)
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
}

// 单个大单卡片视图
struct BigOrderCard: View {
    let order: OptionBigOrder
    @EnvironmentObject var dataService: DataService
    
    // 逻辑：Call 为红色(看涨)，Put 为绿色(看跌)
    // 如果你的 App 习惯相反，请互换颜色
    var isCall: Bool {
        return order.type.uppercased().contains("CALL") || order.type.uppercased() == "C"
    }
    
    var themeColor: Color {
        isCall ? .red : .green
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 上半部分：主要信息
            HStack(alignment: .center) {
                // 1. Symbol + Name
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(order.symbol)
                            .font(.title3)
                            .fontWeight(.heavy)
                            .foregroundColor(.primary)
                        
                        // Type Badge
                        Text(isCall ? "CALL" : "PUT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(themeColor)
                            .cornerRadius(4)
                    }
                    
                    // 获取中文名称
                    let info = getInfo(for: order.symbol)
                    if !info.name.isEmpty {
                        Text(info.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // 2. 金额 (Price) - 重点突出
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatLargeNumber(order.price))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(themeColor)
                    
                    Text("成交额")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            
            Divider()
                .padding(.horizontal, 16)
            
            // 下半部分：详细参数
            HStack(spacing: 0) {
                // Expiry
                DetailColumn(title: "到期日", value: formatDate(order.expiry))
                
                // Strike
                DetailColumn(title: "行权价", value: order.strike)
                
                // Distance (加粗显示，因为很重要)
                VStack(spacing: 4) {
                    Text("价外程度")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(order.distance)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(order.distance.contains("-") ? .green : .red)
                }
                .frame(maxWidth: .infinity)
                
                // 1-Day Change
                VStack(spacing: 4) {
                    Text("权利金变动")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatChange(order.dayChange))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground)) // 略微不同的背景色
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
    
    // 辅助视图：列
    struct DetailColumn: View {
        let title: String
        let value: String
        
        var body: some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    // 格式化金额 (e.g. 17903952 -> $17.9M)
    func formatLargeNumber(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            return String(format: "$%.2fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "$%.2fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "$%.0fK", value / 1_000)
        } else {
            return String(format: "$%.0f", value)
        }
    }
    
    // 简单格式化日期 (2026/03/20 -> 03/20)
    func formatDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "/")
        if parts.count >= 3 {
            return "\(parts[1])/\(parts[2])"
        }
        return dateStr
    }
    
    func formatChange(_ change: String) -> String {
        // 如果是纯数字，可以加个 + 号
        if let val = Double(change), val > 0 {
            return "+\(change)"
        }
        return change
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