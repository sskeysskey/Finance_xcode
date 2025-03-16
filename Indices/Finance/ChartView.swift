import SwiftUI
import Charts

// MARK: - 时间间隔设置
enum TimeRange: String, CaseIterable {
    case oneMonth = "1M"
    case all = "ALL"
    case fiveYears = "5Y"
    case oneYear = "1Y"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case tenYears = "10Y"
    case twoYears = "2Y"

    var startDate: Date {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .twoYears:
            return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:
            return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        case .all:
            return Date.distantPast
        }
    }
    
    var duration: TimeInterval {
        switch self {
        case .oneMonth:
            return 1 * 30 * 24 * 60 * 60
        case .threeMonths:
            return 3 * 30 * 24 * 60 * 60
        case .sixMonths:
            return 6 * 30 * 24 * 60 * 60
        case .oneYear:
            return 1 * 365 * 24 * 60 * 60
        case .twoYears:
            return 2 * 365 * 24 * 60 * 60
        case .fiveYears:
            return 5 * 365 * 24 * 60 * 60
        case .tenYears:
            return 10 * 365 * 24 * 60 * 60
        case .all:
            return Double.infinity
        }
    }
    
    var labelCount: Int {
        switch self {
        case .all:
            return 10
        default:
            let numberString = self.rawValue.filter { $0.isNumber }
            return Int(numberString) ?? 1
        }
    }
}

// MARK: - 时间间隔按钮
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
    
    private func formatDescription(_ text: String) -> String {
        var formattedText = text
        
        // 1. 处理多空格为单个换行
        let spacePatterns = ["    ", "  "]
        for pattern in spacePatterns {
            formattedText = formattedText.replacingOccurrences(of: pattern, with: "\n")
        }
        
        // 2. 统一处理所有需要换行的标记符号
        let patterns = [
            "([^\\n])(\\d+、)",          // 中文数字序号
            "([^\\n])(\\d+\\.)",         // 英文数字序号
            "([^\\n])([一二三四五六七八九十]+、)", // 中文数字
            "([^\\n])(- )"               // 新增破折号标记
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                formattedText = regex.stringByReplacingMatches(
                    in: formattedText,
                    options: [],
                    range: NSRange(location: 0, length: formattedText.utf16.count),
                    withTemplate: "$1\n$2"
                )
            }
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
    @State private var shouldAnimate: Bool = true
    
    @State private var markerText: String? = nil
    @State private var highlightedPoints: Set<Date> = []
    @State private var dragStartPoint: (date: Date, price: Double)? = nil
    @State private var dragEndPoint: (date: Date, price: Double)? = nil

    var body: some View {
        VStack(spacing: 16) {
            headerView

            // 价格和日期显示逻辑
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
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.green)
                            
                        } else if let date = selectedDateStart {
                            HStack(spacing: 18) {
                                Text(formattedDate(date))
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                Text(String(format: "%.2f", price))
                                    .font(.system(size: 16, weight: .medium))
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
                .padding(.top, 0)
            } else if let markerText = markerText {
                // 当只有标记文本时(单指触摸到特殊点)
                Text(markerText)
                    .font(.system(size: 14))
                    .foregroundColor(.yellow)
                    .padding(.top, 2)
            } else {
                HStack {
                    // Description
                    NavigationLink(destination: {
                        if let descriptions = getDescriptions(for: symbol) {
                            DescriptionView(descriptions: descriptions, isDarkMode: isDarkMode)
                        } else {
                            DescriptionView(
                                descriptions: ("No description available.", ""),
                                isDarkMode: isDarkMode
                            )
                        }
                    }) {
                        Text("Description")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.top, 0)
                            .foregroundColor(.green)
                    }
                    // Compare
                    NavigationLink(destination: CompareView(initialSymbol: symbol)) {
                        Text("Compare")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.top, 0)
                            .padding(.leading, 20)
                            .foregroundColor(.green)
                    }
                    // Similar
                    NavigationLink(destination: SimilarView(symbol: symbol)) {
                        Text("Similar")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.top, 0)
                            .padding(.leading, 20)
                            .foregroundColor(.green)
                    }
                }
            }

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
        .navigationTitle("\(symbol)")
        .onChange(of: selectedTimeRange) { _, _ in
            chartData = []
            shouldAnimate = true
            loadChartData()
        }
        .onAppear {
            shouldAnimate = true
            loadChartData()
        }
        .overlay(loadingOverlay)
        .background(Color(uiColor: .systemGroupedBackground))
    }
    
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
                    
                    Text(
                        dataService.marketCapData[symbol.uppercased()]?.peRatio.map {
                            String(format: "%.0f", $0)
                        } ?? ""
                    )
                    .font(.system(size: 20))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    
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

    private var chartView: some View {
        SwiftUIChartView(
            data: chartData,
            showGrid: showGrid,
            isDarkMode: isDarkMode,
            timeRange: selectedTimeRange,
            globalTimeMarkers: dataService.globalTimeMarkers,
            symbolTimeMarkers: dataService.symbolTimeMarkers[symbol.uppercased()] ?? [:],
            symbol: symbol,
            shouldAnimate: $shouldAnimate,
            highlightedPoints: $highlightedPoints,
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

    // MARK: - Methods
    private func loadChartData() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            print("开始数据库查询...")
            let newData = DatabaseManager.shared.fetchHistoricalData(
                symbol: symbol,
                tableName: groupName,
                dateRange: .timeRange(selectedTimeRange)
            )
            print("查询完成，获取到 \(newData.count) 条数据")

            DispatchQueue.main.async {
                chartData = newData
                isLoading = false
                print("数据已更新到UI")
            }
        }
    }
    
    private func getDescriptions(for symbol: String) -> (String, String)? {
        // 检查是否为股票
        if let stock = dataService.descriptionData?.stocks.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (stock.description1, stock.description2)
        }
        // 检查是否为ETF
        if let etf = dataService.descriptionData?.etfs.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (etf.description1, etf.description2)
        }
        return nil
    }
}

// MARK: - 试图组建2 各种开关
struct SwiftUIChartView: View {
    let data: [DatabaseManager.PriceData]
    let showGrid: Bool
    let isDarkMode: Bool
    let timeRange: TimeRange
    let globalTimeMarkers: [Date: String]
    let symbolTimeMarkers: [Date: String]
    let symbol: String
    @Binding var shouldAnimate: Bool
    @Binding var highlightedPoints: Set<Date>
    let onPriceSelection: (Double?, Bool, Date?, Date?, String?) -> Void
    @Binding var dragStartPoint: (date: Date, price: Double)?
    @Binding var dragEndPoint: (date: Date, price: Double)?
    @Binding var isInteracting: Bool
    
    @State private var selectedPointDate: Date? = nil
    @State private var isDragging: Bool = false
    @State private var currentGestureValue: DragGesture.Value? = nil
    
    // 用于存储特殊标记的日期
    private var markedDates: [Date] {
        var dates: [Date] = []
        for (date, _) in globalTimeMarkers {
            dates.append(date)
        }
        for (date, _) in symbolTimeMarkers {
            dates.append(date)
        }
        return dates
    }
    
    // 辅助函数：判断某个日期是否为特殊标记日期
    private func isMarkedDate(_ date: Date) -> Bool {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        
        for markerDate in markedDates {
            let markerDateString = dateFormatter.string(from: markerDate)
            if dateString == markerDateString {
                return true
            }
        }
        return false
    }
    
    // 获取特定日期的标记文本
    private func getMarkerText(for date: Date) -> String? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        
        // 先检查股票特定标记（优先级高）
        for (markerDate, text) in symbolTimeMarkers {
            let markerDateString = dateFormatter.string(from: markerDate)
            if dateString == markerDateString {
                return "\(dateString) \(text)"
            }
        }
        
        // 再检查全局标记
        for (markerDate, text) in globalTimeMarkers {
            let markerDateString = dateFormatter.string(from: markerDate)
            if dateString == markerDateString {
                return "\(dateString) \(text)"
            }
        }
        
        return nil
    }
    
    // 辅助方法：判断标记是来自全局还是特定股票
    private func isMarkerFromSymbol(_ date: Date) -> Bool {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        
        for (markerDate, _) in symbolTimeMarkers {
            let markerDateString = dateFormatter.string(from: markerDate)
            if dateString == markerDateString {
                return true
            }
        }
        
        return false
    }
    
    private var sortedData: [DatabaseManager.PriceData] {
        data.sorted { $0.date < $1.date }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ChartContentView(
                    data: sortedData,
                    showGrid: showGrid,
                    isDarkMode: isDarkMode,
                    timeRange: timeRange,
                    selectedPointDate: selectedPointDate,
                    dragStartPoint: dragStartPoint,
                    dragEndPoint: dragEndPoint,
                    isMarkedDate: isMarkedDate,
                    isMarkerFromSymbol: isMarkerFromSymbol
                )
                .chartXAxis {
                    configureXAxis()
                }
                .chartYAxis {
                    configureYAxis()
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
                            // 添加长按手势以启动两点测量模式
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
        }
    }
    
    // 将复杂的Chart部分拆分为单独的View
    private struct ChartContentView: View {
        let data: [DatabaseManager.PriceData]
        let showGrid: Bool
        let isDarkMode: Bool
        let timeRange: TimeRange
        let selectedPointDate: Date?
        let dragStartPoint: (date: Date, price: Double)?
        let dragEndPoint: (date: Date, price: Double)?
        let isMarkedDate: (Date) -> Bool
        let isMarkerFromSymbol: (Date) -> Bool
        
        var body: some View {
            Chart {
                ForEach(data.indices, id: \.self) { index in
                    let pricePoint = data[index]
                    
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
                    
                    // 添加特殊标记点
                    if isMarkedDate(pricePoint.date) {
                        PointMark(
                            x: .value("Date", pricePoint.date),
                            y: .value("Price", pricePoint.price)
                        )
                        .foregroundStyle(isMarkerFromSymbol(pricePoint.date) ? Color.orange : Color.yellow)
                        .symbolSize(8)
                    }
                    
                    // 如果有高亮点，显示选中标记
                    if let selectedDate = selectedPointDate,
                       isSameDay(selectedDate, pricePoint.date) {
                        PointMark(
                            x: .value("Selected Date", pricePoint.date),
                            y: .value("Selected Price", pricePoint.price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                    }
                    
                    // 添加垂直的虚线标记
                    if let selectedDate = selectedPointDate,
                       isSameDay(selectedDate, pricePoint.date) {
                        RuleMark(
                            x: .value("Selected Date", pricePoint.date)
                        )
                        .foregroundStyle(Color.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    }
                    
                    // 为双点手势添加标记
                    if let startPoint = dragStartPoint,
                       isSameDay(startPoint.date, pricePoint.date) {
                        PointMark(
                            x: .value("Drag Start", pricePoint.date),
                            y: .value("Price", pricePoint.price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                    }
                    
                    if let endPoint = dragEndPoint,
                       isSameDay(endPoint.date, pricePoint.date) {
                        PointMark(
                            x: .value("Drag End", pricePoint.date),
                            y: .value("Price", pricePoint.price)
                        )
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                    }
                    
                    // 添加区域填充
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
                }
            }
        }
        
        // 辅助方法：判断两个日期是否为同一天
        private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
            let calendar = Calendar.current
            return calendar.isDate(date1, inSameDayAs: date2)
        }
    }
    
    // 配置X轴 - 拆分出来解决编译器无法在合理时间内类型检查的问题
    private func configureXAxis() -> some AxisContent {
        AxisMarks(preset: .aligned, position: .bottom) { value in
            // 判断是否显示特定的轴标记
            let shouldShowMark = shouldShowAxisMark(value)
            
            if shouldShowMark {
                AxisValueLabel(format: getDateFormat())
            }
            
            if showGrid {
                AxisGridLine()
            }
        }
    }
    
    // 配置Y轴 - 拆分出来解决编译器无法在合理时间内类型检查的问题
    private func configureYAxis() -> some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisValueLabel()
            if showGrid {
                AxisGridLine()
            }
        }
    }
    
    // 判断是否应该显示特定的轴标记
    private func shouldShowAxisMark(_ value: AxisValue) -> Bool {
        let position = value.index // 直接使用 index，因为它不是 Optional
        let totalMarks = getAxisMarkCount()
        let skipFactor = max(1, data.count / totalMarks)
        
        return position % skipFactor == 0
    }
    
    // 处理拖动手势变化
    private func handleDragChanged(value: DragGesture.Value, proxy: ChartProxy, geoProxy: GeometryProxy) {
        isInteracting = true
        let location = value.location
        let xPosition = location.x - geoProxy.frame(in: .local).minX
        
        guard let dateValue = proxy.value(atX: xPosition, as: Date.self) else { return }
        currentGestureValue = value
        
        // 找到最近的数据点
        guard let closestPoint = findClosestDataPoint(to: dateValue) else { return }
        selectedPointDate = closestPoint.date
        
        // 检查是特殊标记点还是普通点
        if let markerText = getMarkerText(for: closestPoint.date) {
            onPriceSelection(nil, false, nil, nil, markerText)
        } else {
            onPriceSelection(closestPoint.price, false, closestPoint.date, nil, nil)
        }
        
        // 检测是否为多点触控
        let touchCount = isDragging ? 2 : 1
        
        if touchCount == 1 {
            // 单点触控
            dragEndPoint = nil
            if !isDragging {
                dragStartPoint = (closestPoint.date, closestPoint.price)
            }
        } else if touchCount == 2 {
            // 双点触控
            if dragStartPoint == nil {
                dragStartPoint = (closestPoint.date, closestPoint.price)
            } else {
                dragEndPoint = (closestPoint.date, closestPoint.price)
                
                // 计算百分比变化
                if let start = dragStartPoint, let end = dragEndPoint {
                    let percentChange = ((end.price - start.price) / start.price) * 100
                    onPriceSelection(percentChange, true, start.date, end.date, nil)
                }
            }
        }
    }
    
    // 处理拖动手势结束
    private func handleDragEnded() {
        // 如果没有设置第二个点，则清除选择
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
        
        currentGestureValue = nil
    }
    
    // 辅助方法：获取X轴位置
    private func getXPosition(for date: Date, in width: CGFloat, data: [DatabaseManager.PriceData]) -> CGFloat {
        guard let minDate = data.map({ $0.date }).min(),
              let maxDate = data.map({ $0.date }).max() else { return 0 }
        
        let totalDuration = maxDate.timeIntervalSince(minDate)
        let relativePosition = date.timeIntervalSince(minDate) / totalDuration
        
        return width * CGFloat(relativePosition)
    }
    
    // 辅助方法：获取Y轴位置
    private func getYPosition(for price: Double, in height: CGFloat, data: [DatabaseManager.PriceData]) -> CGFloat {
        guard let minPrice = data.map({ $0.price }).min(),
              let maxPrice = data.map({ $0.price }).max() else { return 0 }
        
        let range = maxPrice - minPrice
        let paddedMin = minPrice - range * 0.1
        let paddedMax = maxPrice + range * 0.1
        let paddedRange = paddedMax - paddedMin
        
        // 注意Y轴坐标是从顶部开始的
        let relativePosition = 1.0 - ((price - paddedMin) / paddedRange)
        
        return height * CGFloat(relativePosition)
    }
    
    // 辅助方法：根据时间范围确定日期格式
    private func getDateFormat() -> Date.FormatStyle {
        switch timeRange {
        case .all, .twoYears, .fiveYears, .tenYears:
            return .dateTime.year()
        case .oneYear, .oneMonth, .threeMonths, .sixMonths:
            return .dateTime.month(.abbreviated)
        }
    }
    
    // 辅助方法：获取轴标记数量
    private func getAxisMarkCount() -> Int {
        switch timeRange {
        case .oneMonth:
            return 4
        case .threeMonths:
            return 3
        case .sixMonths:
            return 6
        case .oneYear:
            return 6
        case .twoYears:
            return 4
        case .fiveYears:
            return 5
        case .tenYears:
            return 5
        case .all:
            return 8
        }
    }
    
    // 辅助方法：查找距离特定日期最近的数据点
    private func findClosestDataPoint(to date: Date) -> DatabaseManager.PriceData? {
        guard !sortedData.isEmpty else { return nil }
        
        var closestPoint = sortedData[0]
        var minDifference = abs(date.timeIntervalSince(closestPoint.date))
        
        for point in sortedData {
            let difference = abs(date.timeIntervalSince(point.date))
            if difference < minDifference {
                minDifference = difference
                closestPoint = point
            }
        }
        
        return closestPoint
    }
}

// 安全数组访问扩展
extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
