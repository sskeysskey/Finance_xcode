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

// 时间间隔按钮
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

    var body: some View {
        VStack(spacing: 16) {
            headerView

            // 价格和日期显示逻辑
            priceInfoView
            
            chartView
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .gray.opacity(0.2), radius: 8)
                )
            
            timeRangePicker

            // 显示错误消息
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
        
        DispatchQueue.global(qos: .userInitiated).async {
            let newData = DatabaseManager.shared.fetchHistoricalData(
                symbol: symbol,
                tableName: groupName,
                dateRange: .timeRange(selectedTimeRange)
            )

            DispatchQueue.main.async {
                chartData = newData
                isLoading = false
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
    let data: [DatabaseManager.PriceData]
    let showGrid: Bool
    let isDarkMode: Bool
    let timeRange: TimeRange
    let globalTimeMarkers: [Date: String]
    let symbolTimeMarkers: [Date: String]
    let symbol: String
    let onPriceSelection: (Double?, Bool, Date?, Date?, String?) -> Void
    @Binding var dragStartPoint: (date: Date, price: Double)?
    @Binding var dragEndPoint: (date: Date, price: Double)?
    @Binding var isInteracting: Bool
    
    @State private var selectedPointDate: Date? = nil
    @State private var isDragging: Bool = false
    
    // 使用 @State 来存储缓存，这样可以在 onAppear 中修改它
    @State private var markedDatesCache: [String: (isSymbolMarker: Bool, text: String)] = [:]
    
    // 按日期排序的数据
    private var sortedData: [DatabaseManager.PriceData] {
        data.sorted { $0.date < $1.date }
    }
    
    var body: some View {
        GeometryReader { geometry in
            Chart {
                ForEach(Array(sortedData.enumerated()), id: \.element.date) { _, pricePoint in
                    // 主线
                    LineMark(
                        x: .value("Date", pricePoint.date),
                        y: .value("Price", pricePoint.price)
                    )
                    .foregroundStyle(
                        isDarkMode ?
                            LinearGradient(
                                colors: [Color(red: 0, green: 1, blue: 0.7), Color.green],
                                startPoint: .leading,
                                endPoint: .trailing
                            ) :
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    // 区域填充
                    AreaMark(
                        x: .value("Date", pricePoint.date),
                        y: .value("Price", pricePoint.price)
                    )
                    .foregroundStyle(
                        isDarkMode ?
                            LinearGradient(
                                colors: [
                                    Color(red: 0, green: 1, blue: 0.7).opacity(0.6),
                                    Color(red: 0, green: 1, blue: 0.7).opacity(0.01)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ) :
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.6),
                                    Color.blue.opacity(0.01)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    
                    // 标记点处理
                    let dateKey = formattedDate(pricePoint.date)
                    if let markerInfo = markedDatesCache[dateKey] {
                        PointMark(
                            x: .value("Date", pricePoint.date),
                            y: .value("Price", pricePoint.price)
                        )
                        .foregroundStyle(markerInfo.isSymbolMarker ? Color.orange : Color.yellow)
                        .symbolSize(8)
                    }
                    
                    // 选择点标记
                    if let selectedDate = selectedPointDate, isSameDay(selectedDate, pricePoint.date) {
                        PointMark(
                            x: .value("Selected Date", pricePoint.date),
                            y: .value("Selected Price", pricePoint.price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                        
                        RuleMark(
                            x: .value("Selected Date", pricePoint.date)
                        )
                        .foregroundStyle(Color.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    }
                    
                    // 起始选择点
                    if let startPoint = dragStartPoint, isSameDay(startPoint.date, pricePoint.date) {
                        PointMark(
                            x: .value("Drag Start", pricePoint.date),
                            y: .value("Price", pricePoint.price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                    }
                    
                    // 结束选择点
                    if let endPoint = dragEndPoint, isSameDay(endPoint.date, pricePoint.date) {
                        PointMark(
                            x: .value("Drag End", pricePoint.date),
                            y: .value("Price", pricePoint.price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(preset: .aligned, position: .bottom) { value in
                    if shouldShowAxisMark(value) {
                        AxisValueLabel(format: timeRange.dateFormatStyle)
                    }
                    
                    if showGrid {
                        AxisGridLine()
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                    if showGrid {
                        AxisGridLine()
                    }
                }
            }
            .chartXSelection(value: $selectedPointDate)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(isDarkMode ? Color.black : Color.white)
                    .border(isDarkMode ? Color.gray.opacity(0.3) : Color.gray.opacity(0.2), width: 1)
            }
            .chartOverlay { proxy in
                GeometryReader { geoProxy in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    handleDragChanged(value: value, proxy: proxy, geoProxy: geoProxy)
                                }
                                .onEnded { _ in
                                    handleDragEnded()
                                }
                        )
                        .gesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    isDragging = true
                                }
                        )
                }
            }
            .frame(height: geometry.size.height)
        }
        .background(isDarkMode ? Color.black : Color.white)
        .onAppear {
            buildMarkedDatesCache()
        }
    }
    
    // 建立日期标记缓存以加速查找
    private func buildMarkedDatesCache() {
        var cache: [String: (isSymbolMarker: Bool, text: String)] = [:]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        // 添加全局标记
        for (date, text) in globalTimeMarkers {
            let key = dateFormatter.string(from: date)
            cache[key] = (isSymbolMarker: false, text: "\(key) \(text)")
        }
        
        // 添加股票特定标记（优先级更高）
        for (date, text) in symbolTimeMarkers {
            let key = dateFormatter.string(from: date)
            cache[key] = (isSymbolMarker: true, text: "\(key) \(text)")
        }
        
        // 将计算结果赋值给 @State 变量
        markedDatesCache = cache
    }
    
    // 处理拖动手势
    private func handleDragChanged(value: DragGesture.Value, proxy: ChartProxy, geoProxy: GeometryProxy) {
        isInteracting = true
        let location = value.location
        let xPosition = location.x - geoProxy.frame(in: .local).minX
        
        guard let dateValue = proxy.value(atX: xPosition, as: Date.self),
              let closestPoint = findClosestDataPoint(to: dateValue) else { return }
        
        selectedPointDate = closestPoint.date
        
        // 检查是特殊标记点还是普通点
        let dateKey = formattedDate(closestPoint.date)
        if let markerInfo = markedDatesCache[dateKey] {
            onPriceSelection(nil, false, nil, nil, markerInfo.text)
        } else {
            onPriceSelection(closestPoint.price, false, closestPoint.date, nil, nil)
        }
        
        // 双点测量逻辑
        if isDragging {
            if dragStartPoint == nil {
                dragStartPoint = (closestPoint.date, closestPoint.price)
            } else {
                dragEndPoint = (closestPoint.date, closestPoint.price)
                
                if let start = dragStartPoint, let end = dragEndPoint {
                    let percentChange = ((end.price - start.price) / start.price) * 100
                    onPriceSelection(percentChange, true, start.date, end.date, nil)
                }
            }
        } else {
            dragStartPoint = (closestPoint.date, closestPoint.price)
            dragEndPoint = nil
        }
    }
    
    // 拖动结束处理
    private func handleDragEnded() {
        if dragEndPoint == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if dragEndPoint == nil && !isDragging {
                    selectedPointDate = nil
                    onPriceSelection(nil, false, nil, nil, nil)
                    dragStartPoint = nil
                    isInteracting = false
                }
            }
        }
    }
    
    // 辅助方法：判断是否显示轴标记
    private func shouldShowAxisMark(_ value: AxisValue) -> Bool {
        let position = value.index
        let skipFactor = max(1, data.count / timeRange.labelCount)
        return position % skipFactor == 0
    }
    
    // 辅助方法：获取最近的数据点
    private func findClosestDataPoint(to date: Date) -> DatabaseManager.PriceData? {
        guard !sortedData.isEmpty else { return nil }
        
        return sortedData.min(by: {
            abs(date.timeIntervalSince($0.date)) < abs(date.timeIntervalSince($1.date))
        })
    }
    
    // 辅助方法：判断两个日期是否在同一天
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        Calendar.current.isDate(date1, inSameDayAs: date2)
    }
    
    // 辅助方法：格式化日期
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// 安全数组访问扩展
extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
