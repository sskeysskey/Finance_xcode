import SwiftUI
import Charts

// MARK: - 时间间隔设置
enum TimeRange: String, CaseIterable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case twoYears = "2Y"
    case fiveYears = "5Y"
    case tenYears = "10Y"
    case all = "ALL"
    
    // 统一的日期计算
    var startDate: Date {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .oneMonth:    return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:   return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear:     return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .twoYears:    return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:   return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:    return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        case .all:         return Date.distantPast
        }
    }
    
    // 简化的时间间隔计算，避免不必要的乘法
    var duration: TimeInterval {
        let day: TimeInterval = 24 * 60 * 60
        let month = 30 * day
        let year = 365 * day
        
        switch self {
        case .oneMonth:    return month
        case .threeMonths: return 3 * month
        case .sixMonths:   return 6 * month
        case .oneYear:     return year
        case .twoYears:    return 2 * year
        case .fiveYears:   return 5 * year
        case .tenYears:    return 10 * year
        case .all:         return Double.infinity
        }
    }
    
    // 轴标记数量优化
    var labelCount: Int {
        switch self {
        case .oneMonth:    return 4
        case .threeMonths: return 3
        case .sixMonths:   return 6
        case .oneYear:     return 6
        case .twoYears:    return 4
        case .fiveYears:   return 5
        case .tenYears:    return 5
        case .all:         return 8
        }
    }
    
    // 日期格式化样式
    var dateFormatStyle: Date.FormatStyle {
        switch self {
        case .oneMonth, .threeMonths, .sixMonths, .oneYear:
            return .dateTime.month(.abbreviated)
        case .twoYears, .fiveYears, .tenYears, .all:
            return .dateTime.year()
        }
    }
}

struct TimeRangeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? Color.green : Color(uiColor: .systemBackground))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
    }
}

// MARK: - DescriptionView
struct DescriptionView: View {
    let descriptions: (String, String) // (description1, description2)
    let isDarkMode: Bool
    
    // 预编译正则表达式，避免重复创建
    private static let spacePatterns = ["    ", "  "]
    private static let regexPatterns: [NSRegularExpression] = {
        let patterns = [
            "([^\\n])(\\d+、)",          // 中文数字序号
            "([^\\n])(\\d+\\.)",         // 英文数字序号
            "([^\\n])([一二三四五六七八九十]+、)", // 中文数字
            "([^\\n])(- )"               // 新增破折号标记
        ]
        
        return patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [])
        }
    }()
    
    private func formatDescription(_ text: String) -> String {
        var formattedText = text
        
        // 1. 空格替换为换行
        for pattern in Self.spacePatterns {
            formattedText = formattedText.replacingOccurrences(of: pattern, with: "\n")
        }
        
        // 2. 应用正则表达式
        for regex in Self.regexPatterns {
            formattedText = regex.stringByReplacingMatches(
                in: formattedText,
                options: [],
                range: NSRange(location: 0, length: formattedText.utf16.count),
                withTemplate: "$1\n$2"
            )
        }
        
        // 3. 清理多余换行
        while formattedText.contains("\n\n") {
            formattedText = formattedText.replacingOccurrences(of: "\n\n", with: "\n")
        }
        
        return formattedText
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(formatDescription(descriptions.0))
                        .font(.title2)
                        .foregroundColor(isDarkMode ? .white : .black)
                        .padding(.bottom, 18)
                    
                    Text(formatDescription(descriptions.1))
                        .font(.title2)
                        .foregroundColor(isDarkMode ? .white : .black)
                }
                .padding()
            }
            Spacer()
        }
        .navigationBarTitle("Description", displayMode: .inline)
        .background(
            isDarkMode ?
                Color.black.edgesIgnoringSafeArea(.all) :
                Color.white.edgesIgnoringSafeArea(.all)
        )
    }
}

// MARK: - ChartView
struct ChartView: View {
    let symbol: String
    let groupName: String
    
    @EnvironmentObject var dataService: DataService

    @State private var selectedTimeRange: TimeRange = .oneYear
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var isLoading = false
    @State private var showGrid = false
    @State private var isDarkMode = true
    @State private var selectedPrice: Double? = nil
    @State private var isDifferencePercentage: Bool = false
    @State private var selectedDateStart: Date? = nil
    @State private var selectedDateEnd: Date? = nil
    @State private var isInteracting: Bool = false
    @State private var markerText: String? = nil
    @State private var dragStartPoint: (date: Date, price: Double)? = nil
    @State private var dragEndPoint: (date: Date, price: Double)? = nil

    // 缓存的描述数据
    @State private var cachedDescriptions: (String, String)? = nil
    // 新增盈利数据的状态变量
    @State private var earningData: [Date: Double] = [:]

    var body: some View {
        VStack(spacing: 16) {
            headerView

            // 价格和日期显示逻辑
            priceInfoView
            
            // 关键性能优化：添加稳定id确保视图不会频繁重建
            chartView
                .id("chart-\(selectedTimeRange.rawValue)") // 只在时间范围变化时重建
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .gray.opacity(0.2), radius: 8)
                )
            
            timeRangePicker

            if let errorMessage = dataService.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.system(size: 14))
                    .padding()
            }
            Spacer()
        }
        .padding(.vertical)
        .navigationTitle(symbol)
        .onChange(of: selectedTimeRange) { _, _ in
            loadChartData()
        }
        .onAppear {
            // 预加载描述数据以减少后续操作
            cachedDescriptions = getDescriptions(for: symbol)
            loadChartData()
        }
        .overlay(loadingOverlay)
        .background(Color(uiColor: .systemGroupedBackground))
    }
    
    // 日期格式化辅助函数
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 视图组件
    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 12) {
                    Text(dataService.marketCapData[symbol.uppercased()]?.marketCap ?? "")
                        .font(.system(size: 20))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    
                    if let peRatio = dataService.marketCapData[symbol.uppercased()]?.peRatio {
                        Text(String(format: "%.0f", peRatio))
                            .font(.system(size: 20))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    Text(dataService.compareData[symbol.uppercased()]?.description ?? "--")
                        .font(.system(size: 20))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            
            Spacer()
            
            Toggle("", isOn: $showGrid)
                .toggleStyle(SwitchToggleStyle(tint: .green))
            
            Spacer()
            
            Button(action: { isDarkMode.toggle() }) {
                Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isDarkMode ? .yellow : .gray)
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal)
    }

    // MARK: - 提取价格信息视图
    private var priceInfoView: some View {
        Group {
            if let price = selectedPrice {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if isDifferencePercentage,
                           let startDate = selectedDateStart,
                           let endDate = selectedDateEnd {
                            Text("\(formattedDate(startDate))   \(formattedDate(endDate))")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                            Text(String(format: "%.2f%%", price))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.green)
                        } else if let date = selectedDateStart {
                            HStack(spacing: 18) {
                                Text(formattedDate(date))
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                Text(String(format: "%.2f", price))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    
                    // 标记文本显示
                    if let text = markerText {
                        Text(text)
                            .font(.system(size: 14))
                            .foregroundColor(.yellow)
                            .padding(.top, 2)
                    }
                }
            } else if let markerText = markerText {
                // 当只有标记文本时(单指触摸到特殊点)
                Text(markerText)
                    .font(.system(size: 14))
                    .foregroundColor(.yellow)
            } else {
                navigationLinks
            }
        }
    }
    
    private var navigationLinks: some View {
        HStack {
            // Description
            NavigationLink(destination: {
                if let descriptions = cachedDescriptions {
                    DescriptionView(descriptions: descriptions, isDarkMode: isDarkMode)
                } else {
                    DescriptionView(
                        descriptions: ("No description available.", ""),
                        isDarkMode: isDarkMode
                    )
                }
            }) {
                Text("Description")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.green)
            }
            // Compare
            NavigationLink(destination: CompareView(initialSymbol: symbol)) {
                Text("Compare")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.leading, 20)
                    .foregroundColor(.green)
            }
            // Similar
            NavigationLink(destination: SimilarView(symbol: symbol)) {
                Text("Similar")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.leading, 20)
                    .foregroundColor(.green)
            }
        }
    }

    private var chartView: some View {
        OptimizedChartView(
            data: chartData,
            showGrid: showGrid,
            isDarkMode: isDarkMode,
            timeRange: selectedTimeRange,
            globalTimeMarkers: dataService.globalTimeMarkers,
            symbolTimeMarkers: dataService.symbolTimeMarkers[symbol.uppercased()] ?? [:],
            symbolEarningData: earningData,  // 新增参数
            symbol: symbol,
            onPriceSelection: { price, isPercentage, startDate, endDate, text in
                selectedPrice = price
                isDifferencePercentage = isPercentage
                selectedDateStart = startDate
                selectedDateEnd = endDate
                markerText = text
            },
            dragStartPoint: $dragStartPoint,
            dragEndPoint: $dragEndPoint,
            isInteracting: $isInteracting
        )
        .frame(height: 350)
        .padding(.vertical, 1)
    }

    private var timeRangePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    TimeRangeButton(
                        title: range.rawValue,
                        isSelected: selectedTimeRange == range
                    ) {
                        withAnimation { selectedTimeRange = range }
                    }
                }
            }
        }
    }

    private var loadingOverlay: some View {
        Group {
            if isLoading {
                ZStack {
                    Color.black.opacity(0.2)
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(radius: 10)
                        )
                }
            }
        }
    }

    private func loadChartData() {
        isLoading = true
        chartData = [] // 清空之前的数据
        
        // 计算适合当前时间范围的最大数据点
        let maxPoints: Int
        switch selectedTimeRange {
        case .oneMonth, .threeMonths:
            maxPoints = 90 // 每天的数据
        case .sixMonths:
            maxPoints = 180
        case .oneYear:
            maxPoints = 250 // 工作日数据
        case .twoYears:
            maxPoints = 350
        case .fiveYears, .tenYears, .all:
            maxPoints = 500
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let newData = DatabaseManager.shared.fetchSampledHistoricalData(
                symbol: self.symbol,
                tableName: self.groupName,
                dateRange: .timeRange(self.selectedTimeRange),
                maxPoints: maxPoints
            )
            
            let newEarningData = DatabaseManager.shared.fetchEarningData(forSymbol: self.symbol.uppercased())
            
            DispatchQueue.main.async {
                self.chartData = newData
                self.earningData = newEarningData
                self.isLoading = false
            }
        }
    }
    
    private func getDescriptions(for symbol: String) -> (String, String)? {
        let uppercaseSymbol = symbol.uppercased()
        
        // 首先检查股票
        if let stock = dataService.descriptionData?.stocks.first(where: {
            $0.symbol.uppercased() == uppercaseSymbol
        }) {
            return (stock.description1, stock.description2)
        }
        
        // 然后检查ETF
        if let etf = dataService.descriptionData?.etfs.first(where: {
            $0.symbol.uppercased() == uppercaseSymbol
        }) {
            return (etf.description1, etf.description2)
        }
        
        return nil
    }
}

// MARK: - 优化后的图表视图
struct OptimizedChartView: View {
    // 保持原有属性
    let data: [DatabaseManager.PriceData]
    let showGrid: Bool
    let isDarkMode: Bool
    let timeRange: TimeRange
    let globalTimeMarkers: [Date: String]
    let symbolTimeMarkers: [Date: String]
    let symbolEarningData: [Date: Double]
    let symbol: String
    let onPriceSelection: (Double?, Bool, Date?, Date?, String?) -> Void
    @Binding var dragStartPoint: (date: Date, price: Double)?
    @Binding var dragEndPoint: (date: Date, price: Double)?
    @Binding var isInteracting: Bool
    
    // 选择和交互状态
    @State private var selectedPointDate: Date? = nil
    @State private var isDragging: Bool = false
    @State private var isProcessingGesture = false
    
    enum MarkerType {
        case global, symbol, earning
    }
    
    // 预计算属性 - 不在view中计算
    private var sortedData: [DatabaseManager.PriceData] {
        data.sorted { $0.date < $1.date }
    }
    
    // 优化后的数据采样 - 减少数据点
    private var displayData: [DatabaseManager.PriceData] {
        // 根据时间范围确定合适的采样率
        let maxPoints: Int
        switch timeRange {
        case .oneMonth: maxPoints = 30
        case .threeMonths: maxPoints = 60
        case .sixMonths: maxPoints = 90
        case .oneYear: maxPoints = 120
        case .twoYears: maxPoints = 150
        case .fiveYears, .tenYears, .all: maxPoints = 200
        }
        
        guard sortedData.count > maxPoints else { return sortedData }
        
        // 简单均匀采样
        let step = max(1, sortedData.count / maxPoints)
        let indices = stride(from: 0, to: sortedData.count, by: step)
        
        // 使用预分配内存的数组而非动态追加
        let result = indices.compactMap { sortedData[safe: $0] }
        
        // 确保包含最后一个点
        if let last = sortedData.last, result.last?.id != last.id {
            var finalResult = Array(result)
            finalResult.append(last)
            return finalResult
        }
        
        return Array(result)
    }
    
    // 最小化价格范围计算，使用更稳定的范围
    private var priceRange: ClosedRange<Double> {
        // 如果没有数据，返回默认范围
        guard !displayData.isEmpty else { return 0...100 }
        
        let prices = displayData.map { $0.price }
        if let min = prices.min(), let max = prices.max() {
            let range = max - min
            let padding = range * 0.05 // 5% 边距
            return (min - padding)...(max + padding)
        }
        return 0...100
    }
    
    var body: some View {
        GeometryReader { geometry in
            Chart {
                // 1. 单次渲染主线 - 使用优化后的数据
                ForEach(displayData, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(isDarkMode ? Color.green : Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                
                // 2. 有选择地渲染区域 - 只在小数据集时
                if displayData.count < 120 {
                    ForEach(displayData, id: \.date) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Price", point.price)
                        )
                        .foregroundStyle(
                            isDarkMode ?
                                Color.green.opacity(0.3).gradient :
                                Color.blue.opacity(0.3).gradient
                        )
                        .opacity(0.5) // 进一步减轻渲染负担
                    }
                }
                
                // 3. 仅在需要时渲染选择点
                if let selected = selectedPointDate,
                   let point = findClosestDataPoint(to: selected) {
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(Color.purple)
                    .symbolSize(14)
                }
                
                // 4. 渲染重要标记点 - 但限制数量
                let earningPoints = Array(symbolEarningData.keys)
                    .filter { $0 >= timeRange.startDate }
                    .prefix(10) // 最多显示10个点以优化性能
                
                ForEach(earningPoints, id: \.self) { date in
                    if let price = findPriceForDate(date) {
                        PointMark(
                            x: .value("Date", date),
                            y: .value("Price", price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                    }
                }
            }
            // 固定Y轴范围以避免动态计算
            .chartYScale(domain: priceRange)
            
            // 简化轴显示
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: timeRange.labelCount)) { value in
                    AxisGridLine(stroke: showGrid ? StrokeStyle(lineWidth: 0.5) : StrokeStyle(lineWidth: 0))
                    AxisValueLabel(format: timeRange.dateFormatStyle)
                }
            }
            
            // 减少Y轴格式化的计算量
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel()
                    if showGrid {
                        AxisGridLine()
                    }
                }
            }
            
            // 简化选择区域实现
            .chartOverlay { proxy in
                GeometryReader { geoProxy in
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            // 利用限流防止手势过度触发
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isProcessingGesture {
                                        isProcessingGesture = true
                                        
                                        // 简化手势处理逻辑
                                        let xPosition = value.location.x - geoProxy.frame(in: .local).minX
                                        if let date = proxy.value(atX: xPosition, as: Date.self),
                                           let point = findClosestDataPoint(to: date) {
                                            
                                            selectedPointDate = point.date
                                            onPriceSelection(point.price, false, point.date, nil, nil)
                                            dragStartPoint = (point.date, point.price)
                                        }
                                        
                                        // 防抖处理
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            isProcessingGesture = false
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    // 结束时简化处理
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        if !isDragging {
                                            selectedPointDate = nil
                                            onPriceSelection(nil, false, nil, nil, nil)
                                            dragStartPoint = nil
                                            isInteracting = false
                                        }
                                    }
                                }
                        )
                        // 简化双击开启测量逻辑
                        .onTapGesture(count: 2) {
                            // 延迟触发双击以避免冲突
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isDragging = true
                            }
                        }
                }
            }
        }
        .frame(height: 350)
        .background(isDarkMode ? Color.black : Color.white)
    }
    
    // 优化后的查找方法 - 使用二分查找以提高大数据集效率
    private func findClosestDataPoint(to date: Date) -> DatabaseManager.PriceData? {
        guard !displayData.isEmpty else { return nil }
        
        // 对于小数据集，使用简单查找
        if displayData.count < 100 {
            return displayData.min(by: {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            })
        }
        
        // 对于大数据集，使用优化的方法
        let targetInterval = date.timeIntervalSince1970
        
        // 初始查找范围
        var low = 0
        var high = displayData.count - 1
        
        // 二分查找最接近的点
        while low <= high {
            let mid = (low + high) / 2
            let midDate = displayData[mid].date
            let midInterval = midDate.timeIntervalSince1970
            
            if midInterval == targetInterval {
                return displayData[mid]
            } else if midInterval < targetInterval {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        
        // 检查边界情况
        let lowPoint = low < displayData.count ? displayData[low] : nil
        let highPoint = high >= 0 ? displayData[high] : nil
        
        // 返回距离目标最近的点
        if let lowPoint = lowPoint, let highPoint = highPoint {
            let lowDiff = abs(lowPoint.date.timeIntervalSince1970 - targetInterval)
            let highDiff = abs(highPoint.date.timeIntervalSince1970 - targetInterval)
            return lowDiff < highDiff ? lowPoint : highPoint
        }
        
        return lowPoint ?? highPoint
    }
    
    // 简化的价格查询方法
    private func findPriceForDate(_ date: Date) -> Double? {
        if let point = findClosestDataPoint(to: date) {
            return point.price
        }
        return nil
    }
    
    // 辅助方法：判断两个日期是否在同一天
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
}

// 安全数组访问扩展
extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
