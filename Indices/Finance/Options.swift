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
                .foregroundColor(getIvColor(latestIv)) 
                .fixedSize()
            
            // 2. Previous IV (小字体)
            Text(prevIv ?? "--")
                .font(.system(size: 12, design: .monospaced)) // 正常/偏小
                .foregroundColor(.secondary)
                .fixedSize()
            
            // 3. CompareStr (涨跌百分比)
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
                    .foregroundColor(lPrice >= 0 ? .red : .green)
                    .fixedSize()
            } else {
                Text("--")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // 辅助函数
    private func extractPercentage(from text: String) -> String {
        let pattern = "([+-]?\\d+(\\.\\d+)?%)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return text
    }

    private func getIvColor(_ text: String?) -> Color {
        guard let text = text else { return .secondary }
        let cleanText = text.replacingOccurrences(of: "%", with: "")
        if let value = Double(cleanText) {
            return value >= 0 ? .red : .green
        }
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

// MARK: - 【修改后】Strike vs Price 分布图组件 (优化X轴空间)
struct OptionsStrikePriceChartView: View {
    let allItems: [OptionItem]
    
    @State private var selectedExpiry: String = ""
    @State private var selectedType: ChartType = .all
    
    enum ChartType: String, CaseIterable, Identifiable {
        case all = "All"
        case call = "Call"
        case put = "Put"
        var id: String { self.rawValue }
    }
    
    struct ChartDataPoint: Identifiable {
        let id = UUID()
        let strike: Double
        let price: Double
        let type: String
    }
    
    var uniqueExpiries: [String] {
        let expiries = Set(allItems.map { $0.expiryDate })
        return expiries.sorted()
    }
    
    // 计算图表数据
    var chartData: [ChartDataPoint] {
        let targetExpiry = selectedExpiry.isEmpty ? (uniqueExpiries.first ?? "") : selectedExpiry
        
        let filtered = allItems.filter { $0.expiryDate == targetExpiry }
            .compactMap { item -> ChartDataPoint? in
                let cleanStrike = item.strike.replacingOccurrences(of: ",", with: "")
                guard let strikeVal = Double(cleanStrike) else { return nil }
                
                let cleanPrice = item.price.replacingOccurrences(of: ",", with: "")
                guard let priceVal = Double(cleanPrice) else { return nil }
                
                // 过滤掉 Price 为 0 的点
                if priceVal <= 0 { return nil }
                
                let type = (item.type.uppercased().contains("CALL") || item.type.uppercased() == "C") ? "Call" : "Put"
                
                // 根据开关过滤
                if selectedType == .call && type != "Call" { return nil }
                if selectedType == .put && type != "Put" { return nil }
                
                return ChartDataPoint(strike: strikeVal, price: priceVal, type: type)
            }
            .sorted { $0.strike < $1.strike } // 确保按 Strike 排序，方便取首尾
        
        return filtered
    }
    
    // 获取所有的 Strike 值用于 X 轴标签
    var allStrikes: [Double] {
        // 使用 Set 去重，然后排序
        let strikes = Set(chartData.map { $0.strike })
        return strikes.sorted()
    }
    
    // 【关键修改】计算 X 轴的显示范围
    var xDomain: ClosedRange<Double> {
        guard let min = chartData.first?.strike,
              let max = chartData.last?.strike else {
            return 0...100 // 默认值防崩溃
        }
        
        // 如果只有一个点，或者最小等于最大，手动给一点范围，否则图表会报错
        if min == max {
            return (min - 1)...(max + 1)
        }
        
        return min...max
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 顶部控制栏
            HStack {
                Text("Strike vs Price")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Call/Put 切换开关
                Picker("Type", selection: $selectedType) {
                    ForEach(ChartType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .scaleEffect(0.8)
                
                Spacer()
                
                // 日期选择
                Menu {
                    ForEach(uniqueExpiries, id: \.self) { expiry in
                        Button(expiry) {
                            selectedExpiry = expiry
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(selectedExpiry.isEmpty ? (uniqueExpiries.first ?? "Select Date") : selectedExpiry)
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .zIndex(1)
            
            // 图表区域
            if chartData.isEmpty {
                Spacer()
                Text("该筛选条件下无数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                Chart {
                    ForEach(chartData) { point in
                        LineMark(
                            x: .value("Strike", point.strike),
                            y: .value("Price", point.price)
                        )
                        .foregroundStyle(by: .value("Type", point.type))
                        .interpolationMethod(.catmullRom)
                        
                        PointMark(
                            x: .value("Strike", point.strike),
                            y: .value("Price", point.price)
                        )
                        .foregroundStyle(by: .value("Type", point.type))
                        .symbolSize(30)
                    }
                }
                .chartForegroundStyleScale([
                    "Call": .red,
                    "Put": .green
                ])
                // 【关键修改】设置 X 轴范围，强制撑满
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    // 每一个 Strike 都显示出来
                    AxisMarks(values: allStrikes) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: Decimal.FormatStyle.number.precision(.fractionLength(0)), orientation: .vertical)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if selectedExpiry.isEmpty, let first = uniqueExpiries.first {
                selectedExpiry = first
            }
        }
    }
}

// MARK: - 【新增】3列数据显示组件
struct PriceThreeColumnView: View {
    let symbol: String
    let latestIv: String?
    let prevIv: String?
    
    @EnvironmentObject var dataService: DataService

    var body: some View {
        HStack(spacing: 6) {
            Text(latestIv ?? "--")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(getIvColor(latestIv))
                .fixedSize()
            
            Text(prevIv ?? "--")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize()
            
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
        }
    }
    
    private func extractPercentage(from text: String) -> String {
        let pattern = "([+-]?\\d+(\\.\\d+)?%)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return text
    }

    private func getIvColor(_ text: String?) -> Color {
        guard let text = text else { return .secondary }
        let cleanText = text.replacingOccurrences(of: "%", with: "")
        if let value = Double(cleanText) {
            return value >= 0 ? .red : .green
        }
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
struct OptionsHistoryChartView: View {
    let symbol: String
    let currentOptions: [OptionItem] 
    
    @State private var historyData: [DatabaseManager.OptionHistoryItem] = []
    @State private var selectedTimeRange: TimeRangeOption = .oneMonth
    @State private var isLoading = false
    @State private var currentPage = 0 
    
    enum TimeRangeOption: String, CaseIterable, Identifiable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case oneYear = "1Y"
        case tenYears = "10Y"
        
        var id: String { self.rawValue }
        
        var monthsBack: Int {
            switch self {
            case .oneMonth: return 1
            case .threeMonths: return 3
            case .oneYear: return 12
            case .tenYears: return 120
            }
        }
    }
    
    var filteredData: [DatabaseManager.OptionHistoryItem] {
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .month, value: -selectedTimeRange.monthsBack, to: Date()) else {
            return historyData
        }
        return historyData.filter { $0.date >= startDate }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            
            // 1. 顶部指示点
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(currentPage == index ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut, value: currentPage)
            
            // 2. 图表主体
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
                    TabView(selection: $currentPage) {
                        
                        // Page 0: Strike vs Price
                        OptionsStrikePriceChartView(allItems: currentOptions)
                            .tag(0)
                            .padding(.bottom, 10)
                        
                        // Page 1: IV
                        if isLoading {
                            ProgressView().tag(1)
                        } else if historyData.isEmpty {
                            Text("暂无历史数据").tag(1)
                        } else {
                            SingleChartContent(data: filteredData, dataType: .iv)
                                .tag(1)
                        }
                        
                        // Page 2: Price
                        if isLoading {
                            ProgressView().tag(2)
                        } else if historyData.isEmpty {
                            Text("暂无历史数据").tag(2)
                        } else {
                            SingleChartContent(data: filteredData, dataType: .price)
                                .tag(2)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .frame(height: 280)
            .padding(.horizontal)
            
            // 3. 时间切换条
            timeRangeSelector
                .opacity(currentPage == 0 ? 0 : 1)
                .animation(.easeInOut, value: currentPage)
        }
        .task {
            await loadData()
        }
    }
    
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
struct SingleChartContent: View {
    let data: [DatabaseManager.OptionHistoryItem]
    let dataType: ChartDataType
    
    enum ChartDataType {
        case price
        case iv
        
        var title: String {
            switch self {
            case .price: return "Calls+Puts"
            case .iv: return "IV Trend"
            }
        }
    }
    
    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd"
        return formatter
    }
    
    private var uniqueIDFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    
    var body: some View {
        VStack(spacing: 4) {
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
        let sortedData = data.sorted { $0.date < $1.date }
        let allDateIDs = sortedData.map { uniqueIDFormatter.string(from: $0.date) }
        let stride = getAxisStride(count: sortedData.count)
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
                let value = (dataType == .price) ? item.price : item.iv
                
                BarMark(
                    x: .value("Date", uniqueIDFormatter.string(from: item.date)),
                    y: .value("Value", value)
                )
                .foregroundStyle(barGradient(for: value))
                .cornerRadius(4)
            }
            
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
    
    private func getAxisStride(count: Int) -> Int {
        switch count {
        case 0...10: return 1
        case 11...30: return 3
        case 31...70: return 5
        case 71...150: return 10
        default: return 20
        }
    }
    
    private func barGradient(for value: Double) -> LinearGradient {
        let isPositive = value >= 0
        let colors: [Color] = isPositive
            ? [.red.opacity(0.8), .red.opacity(0.4)]
            : [.green.opacity(0.8), .green.opacity(0.4)]
        
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
    @State private var navigateToBigOrders = false
    @State private var navigateToChart = false
    
    @State private var showSearchBar = false
    @State private var searchText = ""
    @State private var highlightedSymbol: String?
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
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showSearchBar {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        
                        TextField("输入 Symbol 跳转 (如 AAPL)", text: $searchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .submitLabel(.search)
                            .focused($isSearchFieldFocused) 
                            .onAppear {
                                isSearchFieldFocused = true
                            }
                            .onSubmit {
                                performSearch(proxy: proxy)
                            }
                        
                        Button("取消") {
                            withAnimation {
                                isSearchFieldFocused = false 
                                showSearchBar = false
                                searchText = ""
                                highlightedSymbol = nil
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
                                isHighlighted: symbol == highlightedSymbol
                            )
                            .id(symbol) 
                        }
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationTitle("期权异动")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation {
                            showSearchBar.toggle()
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
                    
                    Button(action: {
                        if usageManager.canProceed(authManager: authManager, action: .viewOptionsRank) {
                            self.navigateToBigOrders = true
                        } else {
                            self.showSubscriptionSheet = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "dollarsign.circle.fill") 
                                .font(.system(size: 14, weight: .bold))
                            Text("期权大单")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .foregroundColor(.white)
                        .background(
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
        .navigationDestination(isPresented: $navigateToBigOrders) {
            OptionBigOrdersView()
        }
        .navigationDestination(isPresented: $navigateToChart) {
            if let sym = selectedSymbol {
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
    
    private func handleLongPress(_ symbol: String) {
        if usageManager.canProceed(authManager: authManager, action: .viewChart) {
            self.selectedSymbol = symbol
            self.navigateToChart = true
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        } else {
            self.showSubscriptionSheet = true
        }
    }

    private func performSearch(proxy: ScrollViewProxy) {
        let target = searchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !target.isEmpty else { return }
        
        if let foundSymbol = sortedSymbols.first(where: { $0.contains(target) }) {
            self.highlightedSymbol = foundSymbol
            withAnimation(.spring()) {
                proxy.scrollTo(foundSymbol, anchor: .center)
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            self.highlightedSymbol = nil
        }
    }
}

struct OptionListRow: View {
    let symbol: String
    let action: () -> Void
    let longPressAction: () -> Void
    var isHighlighted: Bool = false
    
    @EnvironmentObject var dataService: DataService
    
    @State private var displayData: (
        iv: String?, 
        prevIv: String?, 
        latestPrice: Double?, 
        prevPrice: Double?, 
        change: Double?
    )? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
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
                
                Spacer(minLength: 8)
                
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
        .animation(.easeInOut, value: isHighlighted)
    }
    
    private func loadPriceAndCalc() async {
        if displayData != nil { return }
        guard let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) else {
            return
        }
        
        let iv = summary.iv
        let prevIv = summary.prev_iv
        
        var latestPrice: Double? = nil
        if let p = summary.price, let c = summary.change {
            latestPrice = p + c
        }
        
        var prevPrice: Double? = nil
        if let pp = summary.prev_price, let pc = summary.prev_change {
            prevPrice = pp + pc
        }
        
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
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedTypeIndex = 0
    @State private var navigateToChart = false
    @State private var summaryCall: String = ""
    @State private var summaryPut: String = ""
    @State private var displayPrice: Double? = nil 
    @State private var displayPrevPrice: Double? = nil 
    @State private var dbChange: Double? = nil
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
            OptionsHistoryChartView(
                symbol: symbol,
                currentOptions: dataService.optionsData[symbol] ?? []
            )
            .padding(.top, 10)
            .padding(.bottom, 4)
            
            typePickerView
            tableHeaderView
            Divider()
            dataListView
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(symbol)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    if usageManager.canProceed(authManager: authManager, action: .viewChart) { 
                        navigateToChart = true 
                    } else {
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
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .task {
            if let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) {
                await MainActor.run {
                    if let c = summary.call { self.summaryCall = c }
                    if let p = summary.put { self.summaryPut = p }
                    
                    if let chg = summary.change {
                        self.dbChange = chg
                        if let price = summary.price {
                            self.displayPrice = price + chg
                        }
                    }
                    
                    if let prevPrice = summary.prev_price, let prevChg = summary.prev_change {
                        self.displayPrevPrice = prevPrice + prevChg
                    }
                }
            }
        }
    }
    
    private var typePickerView: some View {
        Picker("Type", selection: $selectedTypeIndex) {
            Text(summaryCall.isEmpty ? "Calls" : "Calls \(summaryCall)").tag(0)
            Text(summaryPut.isEmpty ? "Puts" : "Puts \(summaryPut)").tag(1)
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding()
        .background(Color(UIColor.systemBackground))
    }
    
    private var tableHeaderView: some View {
        HStack(spacing: 4) {
            Text("Expiry").frame(maxWidth: .infinity, alignment: .leading)
            Text("Strike").frame(width: 50, alignment: .trailing)
            Text("Dist").frame(width: 50, alignment: .trailing)
            Text("OI").frame(width: 55, alignment: .trailing)
            Text("1-Day").frame(width: 55, alignment: .trailing)
            Text("Price").frame(width: 55, alignment: .trailing)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemBackground))
    }
    
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
    
    @State private var selectedTab = 0
    @State private var rankUp: [OptionRankItem] = []
    @State private var rankDown: [OptionRankItem] = []
    @State private var isLoading = true
    
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    @State private var navigateToChart = false
    
    var currentList: [OptionRankItem] {
        selectedTab == 0 ? rankUp : rankDown
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $selectedTab) {
                Text("最可能涨").tag(0)
                Text("最可能跌").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            
            ZStack {
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
                    List {
                        ForEach(currentList) { item in
                            OptionRankRow(item: item, isUp: selectedTab == 0) {
                                handleSelection(item.symbol)
                            } longPressAction: {
                                handleLongPress(item.symbol)
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
                let groupName = dataService.getCategory(for: sym) ?? "US"
                ChartView(symbol: sym, groupName: groupName)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func loadData() async {
        if rankUp.isEmpty && rankDown.isEmpty {
            isLoading = true
        }
        
        if let (up, down) = await dataService.fetchOptionsRankData() {
            let filteredUp = up.filter { item in
                let ivVal = parseIvValue(item.iv)
                let priceVal = (item.price ?? 0) + (item.change ?? 0)
                return ivVal > 0 || priceVal > 0
            }
            
            let filteredDown = down.filter { item in
                let ivVal = parseIvValue(item.iv)
                let priceVal = (item.price ?? 0) + (item.change ?? 0)
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
    
    private func handleLongPress(_ symbol: String) {
        if usageManager.canProceed(authManager: authManager, action: .viewChart) {
            self.selectedSymbol = symbol
            self.navigateToChart = true
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        } else {
            self.showSubscriptionSheet = true
        }
    }
}

struct OptionRankRow: View {
    let item: OptionRankItem
    let isUp: Bool
    let action: () -> Void
    let longPressAction: () -> Void 
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.symbol)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
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
            
            let latestPriceVal = (item.price != nil && item.change != nil) ? (item.price! + item.change!) : nil
            let prevPriceVal = (item.prev_price != nil && item.prev_change != nil) ? (item.prev_price! + item.prev_change!) : nil
            
            PriceFiveColumnView(
                symbol: item.symbol,
                latestIv: item.iv,
                prevIv: item.prev_iv,
                prevPrice: prevPriceVal,
                latestPrice: latestPriceVal,
                latestChange: item.change
            )
            
            let info = getInfo(for: item.symbol)
            if !info.tags.isEmpty {
                Text(info.tags.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            longPressAction()
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

struct OptionRowView: View {
    let item: OptionItem
    
    var body: some View {
        HStack(spacing: 4) {
            OptionCellView(text: formatExpiry(item.expiryDate), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            OptionCellView(text: item.strike, alignment: .trailing)
                .frame(width: 50, alignment: .trailing)
            
            OptionCellView(text: item.distance, alignment: .trailing)
                .frame(width: 50, alignment: .trailing)
                .font(.system(size: 11))
            
            OptionCellView(text: item.openInterest, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
            
            OptionCellView(text: item.change, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
            
            OptionCellView(text: formatPrice(item.price), alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(.blue)
        }
        .padding(.vertical, 10)
        .padding(.horizontal)
        .background(Color(UIColor.systemBackground))
    }
    
    private func formatExpiry(_ dateStr: String) -> String {
        if dateStr.count >= 4 {
            let shortYear = String(dateStr.dropFirst(2))
            return shortYear
        }
        return dateStr
    }
    
    private func formatPrice(_ priceStr: String) -> String {
        guard let value = Double(priceStr) else { return priceStr }
        
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", value / 1_000)
        } else {
            return String(format: "%.0f", value)
        }
    }
}

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
    
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    @State private var navigateToRank = false 
    
    struct SymbolGroup: Identifiable {
        var id: String { symbol }
        let symbol: String
        var orders: [OptionBigOrder]
    }
    
    struct DateGroup: Identifiable {
        var id: String { date }
        let date: String
        var symbolGroups: [SymbolGroup]
    }
    
    var groupedData: [DateGroup] {
        var dateGroups: [DateGroup] = []
        let source = dataService.optionBigOrders
        
        for order in source {
            if dateGroups.isEmpty || dateGroups.last?.date != order.date {
                let newDateGroup = DateGroup(date: order.date, symbolGroups: [])
                dateGroups.append(newDateGroup)
            }
            
            let dateIndex = dateGroups.count - 1
            var currentSymbolGroups = dateGroups[dateIndex].symbolGroups
            
            if currentSymbolGroups.isEmpty || currentSymbolGroups.last?.symbol != order.symbol {
                let newSymbolGroup = SymbolGroup(symbol: order.symbol, orders: [])
                currentSymbolGroups.append(newSymbolGroup)
            }
            
            let symbolIndex = currentSymbolGroups.count - 1
            currentSymbolGroups[symbolIndex].orders.append(order)
            dateGroups[dateIndex].symbolGroups = currentSymbolGroups
        }
        return dateGroups
    }
    
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
                    LazyVStack(spacing: 20) {
                        let groups = groupedData
                        let latestDateString = groups.first?.date
                        
                        ForEach(groups) { dateGroup in
                            DateGroupView(
                                dateGroup: dateGroup,
                                isLatestDate: dateGroup.date == latestDateString
                            ) { symbol in
                                handleSelection(symbol)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("期权大单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    if usageManager.canProceed(authManager: authManager, action: .viewOptionsRank) {
                        self.navigateToRank = true
                    } else {
                        self.showSubscriptionSheet = true
                    }
                }) {
                    Text("期权榜单")
                        .font(.system(size: 14, weight: .bold))
                }
            }
        }
        .navigationDestination(isPresented: $navigateToDetail) {
            if let sym = selectedSymbol {
                OptionsDetailView(symbol: sym)
            }
        }
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

// MARK: - 【第一层视图】日期分组 (DateGroupView)
struct DateGroupView: View {
    let dateGroup: OptionBigOrdersView.DateGroup
    let isLatestDate: Bool
    let onTapOrder: (String) -> Void
    
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.blue)
                    
                    Text(formatDateFull(dateGroup.date))
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text("\(dateGroup.symbolGroups.count) 只股票")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemGroupedBackground))
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                VStack(spacing: 12) {
                    ForEach(dateGroup.symbolGroups) { symbolGroup in
                        SymbolGroupView(
                            group: symbolGroup,
                            onTapOrder: onTapOrder,
                            isLatestDate: isLatestDate 
                        )
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    func formatDateFull(_ dateStr: String) -> String {
        return dateStr 
    }
}

// MARK: - 【第二层视图】Symbol 分组 (SymbolGroupView)

struct SymbolGroupView: View {
    let group: OptionBigOrdersView.SymbolGroup
    let onTapOrder: (String) -> Void
    let isLatestDate: Bool

    @EnvironmentObject var dataService: DataService
    
    @State private var isExpanded: Bool = false
    @State private var isAnimating: Bool = false
    @State private var ivData: (latest: String?, prev: String?)? = nil
    
    var shortCount: Int {
        group.orders.filter { $0.distance.contains("-") }.count
    }
    
    var longCount: Int {
        group.orders.filter { !$0.distance.contains("-") }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            
            // 1. 组头 (Header)
            HStack(alignment: .center) {
                Text(group.symbol)
                    .font(.title3)
                    .fontWeight(.heavy)
                    .foregroundColor(.primary)
                
                if isLatestDate {
                    if let data = ivData {
                        PriceThreeColumnView(
                            symbol: group.symbol,
                            latestIv: data.latest,
                            prevIv: data.prev
                        )
                        .padding(.leading, 4)
                    } else {
                        Text("--")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    if shortCount > 0 {
                        Text("\(shortCount)空")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                    if longCount > 0 {
                        Text("\(longCount)多")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                    if shortCount == 0 && longCount == 0 {
                        Text("0单")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(UIColor.tertiarySystemFill))
                .cornerRadius(6)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .contentShape(Rectangle())
            .onTapGesture {
                if isAnimating { return }
                isAnimating = true
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isAnimating = false
                }
            }
            .zIndex(1)
            
            // 2. 组内容
            if isExpanded {
                VStack(spacing: 12) {
                    ForEach(group.orders) { order in
                        BigOrderCard(order: order)
                            .onTapGesture {
                                if !isAnimating {
                                    onTapOrder(order.symbol)
                                }
                            }
                    }
                }
                .padding(.vertical, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(isExpanded && !isAnimating)
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground).opacity(0.5))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .clipped()
        .task {
            if isLatestDate {
                await loadIvData()
            }
        }
    }
    
    private func loadIvData() async {
        if ivData != nil { return }
        if let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: group.symbol) {
            await MainActor.run {
                self.ivData = (summary.iv, summary.prev_iv)
            }
        }
    }
}

// MARK: - 【第三层视图】单个大单卡片 (BigOrderCard)
struct BigOrderCard: View {
    let order: OptionBigOrder
    @EnvironmentObject var dataService: DataService
    
    var isCall: Bool {
        return order.type.uppercased().contains("CALL") || order.type.uppercased() == "C"
    }
    var themeColor: Color { isCall ? .red : .green }
    
    var priceColor: Color {
        return order.distance.contains("-") ? .green : .red
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(isCall ? "CALL" : "PUT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(themeColor)
                    .cornerRadius(6)
                
                Spacer()
                
                HStack(spacing: 2) {
                    Text(formatLargeNumber(order.price))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(priceColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider().padding(.horizontal, 16)
            
            HStack(spacing: 0) {
                DetailColumn(title: "到期日", value: formatDate(order.expiry))
                DetailColumn(title: "行权价", value: order.strike)
                DetailColumn(title: "价外程度", value: order.distance, isHighlight: true, highlightColor: priceColor)
                DetailColumn(title: "变动", value: formatChange(order.dayChange))
            }
            .padding(.vertical, 10)
            .background(Color(UIColor.tertiarySystemGroupedBackground))
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 12)
    }
    
    // 辅助视图：列 (确保在 body 外部定义)
    struct DetailColumn: View {
        let title: String
        let value: String
        var isHighlight: Bool = false
        var highlightColor: Color = .primary
        
        var body: some View {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: isHighlight ? .bold : .medium))
                    .foregroundColor(isHighlight ? highlightColor : .primary)
            }
            .frame(maxWidth: .infinity)
            .overlay(
                HStack {
                    Spacer()
                    Rectangle().fill(Color.gray.opacity(0.15)).frame(width: 1, height: 16)
                }, alignment: .trailing
            )
        }
    }
    
    func formatLargeNumber(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "$%.2fB", value / 1_000_000_000) }
        else if value >= 1_000_000 { return String(format: "$%.2fM", value / 1_000_000) }
        else if value >= 1_000 { return String(format: "$%.0fK", value / 1_000) }
        else { return String(format: "$%.0f", value) }
    }
    
    func formatDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "/")
        if parts.count >= 3 { return "\(parts[1])/\(parts[2])" }
        return dateStr
    }
    
    func formatChange(_ change: String) -> String {
        if let val = Double(change), val > 0 { return "+\(change)" }
        return change
    }
}