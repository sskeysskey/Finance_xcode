import SwiftUI
import DGCharts

// MARK: - TimeRange Enum
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

// MARK: - DateAxisValueFormatter
private class DateAxisValueFormatter: AxisValueFormatter {
    private let dateFormatter: DateFormatter
    private let timeRange: TimeRange

    init(timeRange: TimeRange) {
        self.timeRange = timeRange
        dateFormatter = DateFormatter()
        
        switch timeRange {
        case .all, .twoYears, .fiveYears, .tenYears:
            dateFormatter.dateFormat = "yyyy"
        case .oneYear, .oneMonth, .threeMonths, .sixMonths:
            dateFormatter.dateFormat = "MMM"
        }
    }

    func stringForValue(_ value: Double, axis: AxisBase?) -> String {
        let date = Date(timeIntervalSince1970: value)
        return dateFormatter.string(from: date)
    }
}

// MARK: - TimeRangeButton
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
    
    @State private var markerText: String? = nil // 添加新属性

    var body: some View {
        VStack(spacing: 16) {
            headerView

            // 修改价格和日期显示逻辑，添加标记文本显示
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
                    
                    // 添加标记文本显示
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

            // 修改图表视图，传递新的参数
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

    // MARK: - View Components
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

    // 修改图表视图
    private var chartView: some View {
        StockLineChartView(
            data: chartData,
            showGrid: showGrid,
            isDarkMode: isDarkMode,
            timeRange: selectedTimeRange,
            onSelectedPriceChange: { price, isPercentage, startDate, endDate, text in
                selectedPrice = price
                isDifferencePercentage = isPercentage
                selectedDateStart = startDate
                selectedDateEnd = endDate
                markerText = text
            },
            globalTimeMarkers: dataService.globalTimeMarkers,
            symbolTimeMarkers: dataService.symbolTimeMarkers[symbol.uppercased()] ?? [:],
            symbol: symbol,
            isInteracting: $isInteracting,
            shouldAnimate: $shouldAnimate
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

// MARK: - StockLineChartView
struct StockLineChartView: UIViewRepresentable {
    let data: [DatabaseManager.PriceData]
    let showGrid: Bool
    let isDarkMode: Bool
    let timeRange: TimeRange
    let onSelectedPriceChange: (Double?, Bool, Date?, Date?, String?) -> Void  // 修改回调添加额外文本参数
    let globalTimeMarkers: [Date: String]  // 全局时间点标记
    let symbolTimeMarkers: [Date: String]  // 当前股票的特定时间点标记
    let symbol: String  // 当前显示的股票代码
    @Binding var isInteracting: Bool
    @Binding var shouldAnimate: Bool

    class Coordinator: NSObject, ChartViewDelegate {
        var parent: StockLineChartView
        var firstTouchHighlight: Highlight?
        var secondTouchHighlight: Highlight?
        var isShowingPercentage = false
        var specialMarkerText: String? = nil  // 添加变量存储特殊点文本

        init(_ parent: StockLineChartView) {
            self.parent = parent
        }
        
        /// 辅助方法：格式化日期为字符串（例如 "yyyy-MM-dd"）
        private func formatDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        func chartValueSelected(_ chartView: ChartViewBase, entry: ChartDataEntry, highlight: Highlight) {
            // 单点选择
            if secondTouchHighlight == nil {
                let date = Date(timeIntervalSince1970: entry.x)
                
                // 检查是否是特殊时间点
                let markerText = getMarkerTextForDate(date)
                
                // 如果是特殊点，则在 markerText 前先显示日期
                if let text = markerText {
                    let dateStr = formatDate(date)
                    let combinedText = "\(dateStr) \(text)"
                    parent.onSelectedPriceChange(nil, false, nil, nil, combinedText)
                } else {
                    parent.onSelectedPriceChange(entry.y, false, date, nil, nil)
                }
            }
        }
        
        private func getMarkerTextForDate(_ date: Date) -> String? {
            // 首先用日期格式化器获取精确到天的日期来比较
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: date)
            
            // 重新解析为日期，确保只比较年月日
            if let normalizedDate = dateFormatter.date(from: dateString) {
                // 检查是否匹配全局标记
                for (markerDate, text) in parent.globalTimeMarkers {
                    let markerDateString = dateFormatter.string(from: markerDate)
                    if let normalizedMarkerDate = dateFormatter.date(from: markerDateString),
                       normalizedDate == normalizedMarkerDate {
                        return text
                    }
                }
                
                // 检查是否匹配特定股票标记
                for (markerDate, text) in parent.symbolTimeMarkers {
                    let markerDateString = dateFormatter.string(from: markerDate)
                    if let normalizedMarkerDate = dateFormatter.date(from: markerDateString),
                       normalizedDate == normalizedMarkerDate {
                        return text
                    }
                }
            }
            
            return nil
        }

        func chartValueNothingSelected(_ chartView: ChartViewBase) {
            parent.onSelectedPriceChange(nil, false, nil, nil, nil)  // 添加第五个参数 nil
            firstTouchHighlight = nil
            secondTouchHighlight = nil
            parent.shouldAnimate = false
        }

        @objc func handleMultiTouchGesture(_ gestureRecognizer: MultiTouchLongPressGestureRecognizer) {
            guard let chartView = gestureRecognizer.view as? LineChartView else { return }
            
            switch gestureRecognizer.state {
            case .began, .changed:
                parent.isInteracting = true
                let touchPoints = gestureRecognizer.touchPoints
                updateHighlights(for: touchPoints, in: chartView)
            case .ended, .cancelled:
                parent.isInteracting = false
                chartView.highlightValues(nil)
                firstTouchHighlight = nil
                secondTouchHighlight = nil
                parent.onSelectedPriceChange(nil, false, nil, nil, nil)  // 添加第五个参数 nil
                parent.shouldAnimate = false
            default:
                break
            }
        }
        
        private func updateHighlights(for touchPoints: [CGPoint], in chartView: LineChartView) {
            if let firstPoint = touchPoints.first {
                firstTouchHighlight = chartView.getHighlightByTouchPoint(firstPoint)
            } else {
                firstTouchHighlight = nil
            }
            
            if touchPoints.count > 1 {
                secondTouchHighlight = chartView.getHighlightByTouchPoint(touchPoints[1])
            } else {
                secondTouchHighlight = nil
            }
            
            updateChartHighlights(chartView)
            calculatePriceDifference(chartView)
        }
        
        private func updateChartHighlights(_ chartView: LineChartView) {
            var highlights: [Highlight] = []
            if let firstHighlight = firstTouchHighlight {
                highlights.append(firstHighlight)
            }
            if let secondHighlight = secondTouchHighlight {
                highlights.append(secondHighlight)
            }
            chartView.highlightValues(highlights)
        }
        
        private func calculatePriceDifference(_ chartView: LineChartView) {
            // 修改回调，添加特殊点文本
            guard let firstHighlight = firstTouchHighlight,
                  let secondHighlight = secondTouchHighlight,
                  let firstEntry = chartView.data?.dataSet(at: 0)?
                      .entryForXValue(firstHighlight.x, closestToY: firstHighlight.y),
                  let secondEntry = chartView.data?.dataSet(at: 0)?
                      .entryForXValue(secondHighlight.x, closestToY: secondHighlight.y) else {
                // 只有一个触摸点
                if let firstHighlight = firstTouchHighlight,
                   let singleEntry = chartView.data?.dataSet(at: 0)?
                    .entryForXValue(firstHighlight.x, closestToY: firstHighlight.y) {
                    isShowingPercentage = false
                    let date = Date(timeIntervalSince1970: singleEntry.x)
                    let markerText = getMarkerTextForDate(date)
                    
                    // 如果是特殊点，则在 markerText 前增加时间显示
                    if let text = markerText {
                        let dateStr = formatDate(date)
                        let combinedText = "\(dateStr) \(text)"
                        parent.onSelectedPriceChange(nil, false, nil, nil, combinedText)
                    } else {
                        parent.onSelectedPriceChange(singleEntry.y, false, date, nil, nil)
                    }
                }
                return
            }
            
            // 根据时间戳确定先后
            let (earlierEntry, laterEntry) = firstEntry.x < secondEntry.x
                ? (firstEntry, secondEntry)
                : (secondEntry, firstEntry)
            
            let priceDiffPercentage = ((laterEntry.y - earlierEntry.y) / earlierEntry.y) * 100
            isShowingPercentage = true
            let startDate = Date(timeIntervalSince1970: earlierEntry.x)
            let endDate = Date(timeIntervalSince1970: laterEntry.x)
            
            // 双指交互下，无论是否有特殊点，都只显示日期和价格差异
            // 不传递markerText，这样就不会显示事件文本
            parent.onSelectedPriceChange(priceDiffPercentage, true, startDate, endDate, nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        chartView.delegate = context.coordinator

        let multiTouchGesture = MultiTouchLongPressGestureRecognizer()
        multiTouchGesture.addTarget(context.coordinator, action: #selector(Coordinator.handleMultiTouchGesture(_:)))
        multiTouchGesture.cancelsTouchesInView = false
        multiTouchGesture.delaysTouchesEnded = false

        chartView.gestureRecognizers?.forEach { existingGesture in
            existingGesture.require(toFail: multiTouchGesture)
        }

        chartView.addGestureRecognizer(multiTouchGesture)
        configureChartView(chartView)
        chartView.noDataText = ""
        configureXAxis(chartView.xAxis)
        return chartView
    }
    
    func updateUIView(_ chartView: LineChartView, context: Context) {
        // 如果正在交互，不更新数据以防止突出显示被重置
        if isInteracting { return }
        if data.isEmpty {
            chartView.clear()
            return
        }

        configureXAxis(chartView.xAxis)
        updateChartAppearance(chartView)
        updateChartData(chartView)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        CATransaction.commit()
    }
    
    private func configureChartView(_ chartView: LineChartView) {
        chartView.legend.enabled = false
        chartView.rightAxis.enabled = false
        chartView.dragEnabled = true
        chartView.setScaleEnabled(true)
        chartView.pinchZoomEnabled = true
        chartView.highlightPerTapEnabled = true
        chartView.highlightPerDragEnabled = true
        chartView.doubleTapToZoomEnabled = true
        configureXAxis(chartView.xAxis)
        configureYAxis(chartView.leftAxis)
    }
    
    private func updateChartAppearance(_ chartView: LineChartView) {
        let textColor = isDarkMode ? UIColor.white : UIColor.black
        let gridColor = isDarkMode
            ? UIColor.gray.withAlphaComponent(0.3)
            : UIColor.gray.withAlphaComponent(0.2)

        chartView.xAxis.labelTextColor = textColor
        chartView.leftAxis.labelTextColor = textColor
        chartView.xAxis.gridColor = gridColor
        chartView.leftAxis.gridColor = gridColor

        chartView.xAxis.drawGridLinesEnabled = showGrid
        chartView.leftAxis.drawGridLinesEnabled = showGrid
        chartView.backgroundColor = isDarkMode ? .black : .white
    }
    
    private func createDataSet(entries: [ChartDataEntry]) -> LineChartDataSet {
        // 先预处理
        let processedEntries = preprocessData(entries, timeRange: timeRange)
        let dataSet = LineChartDataSet(entries: processedEntries, label: "Price")
        
        // 检查是否有负值
        let hasNegative = processedEntries.contains { $0.y < 0 }

        if isDarkMode {
            let neonColor = UIColor(red: 0/255, green: 255/255, blue: 178/255, alpha: 1.0)
            let gradientColors = [
                neonColor.withAlphaComponent(0.8).cgColor,
                neonColor.withAlphaComponent(0.0).cgColor
            ]
            dataSet.setColor(neonColor)
            let gradient = CGGradient(
                colorsSpace: nil,
                colors: gradientColors as CFArray,
                locations: [0.0, 1.0]
            )!
            // 负值时的方向同样保持一致
            dataSet.fill = LinearGradientFill(gradient: gradient, angle: hasNegative ? 270 : 90)
        } else {
            let gradientColors = [
                UIColor.systemBlue.withAlphaComponent(0.8).cgColor,
                UIColor.systemBlue.withAlphaComponent(0.0).cgColor
            ]
            dataSet.setColor(.systemBlue)
            let gradient = CGGradient(
                colorsSpace: nil,
                colors: gradientColors as CFArray,
                locations: [0.0, 1.0]
            )!
            dataSet.fill = LinearGradientFill(gradient: gradient, angle: hasNegative ? 270 : 90)
        }

        dataSet.drawCirclesEnabled = false
        dataSet.mode = .cubicBezier
        dataSet.lineWidth = 1.0
        dataSet.drawFilledEnabled = true
        dataSet.drawValuesEnabled = false
        dataSet.highlightEnabled = true
        dataSet.highlightColor = .systemRed
        dataSet.highlightLineWidth = 1
        dataSet.highlightLineDashLengths = [5, 2]
        dataSet.cubicIntensity = CGFloat(calculateLineTension(timeRange))
        
        return dataSet
    }

    // 自定义多点触控手势识别器
    class MultiTouchLongPressGestureRecognizer: UIGestureRecognizer {
        private var touchDict: [UITouch: CGPoint] = [:]
        
        var activeTouches: [UITouch] {
            Array(touchDict.keys).sorted { $0.timestamp < $1.timestamp }
        }
        
        var touchPoints: [CGPoint] {
            activeTouches.compactMap { touchDict[$0] }
        }
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { touch in
                touchDict[touch] = touch.location(in: view)
            }
            if state == .possible {
                state = .began
            } else {
                state = .changed
            }
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { touch in
                touchDict[touch] = touch.location(in: view)
            }
            state = .changed
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { touch in
                touchDict.removeValue(forKey: touch)
            }
            if touchDict.isEmpty {
                state = .ended
            } else {
                state = .changed
            }
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { touch in
                touchDict.removeValue(forKey: touch)
            }
            if touchDict.isEmpty {
                state = .cancelled
            } else {
                state = .changed
            }
        }
        
        override func reset() {
            super.reset()
            touchDict.removeAll()
        }
    }

    // MARK: - 数据预处理与配置
    private func calculateSamplingRate(_ timeRange: TimeRange) -> Int {
        switch timeRange {
        case .all:
            return 15
        case .tenYears:
            return 14
        case .fiveYears:
            return 7
        case .twoYears:
            return 4
        case .oneYear:
            return 2
        case .sixMonths, .threeMonths, .oneMonth:
            return 1
        }
    }

    private func calculateLineTension(_ timeRange: TimeRange) -> Double {
        switch timeRange {
        case .all:
            return 0.4
        case .tenYears:
            return 0.3
        case .fiveYears:
            return 0.2
        case .twoYears:
            return 0.15
        case .oneYear:
            return 0.1
        case .sixMonths:
            return 0.075
        case .threeMonths:
            return 0.05
        case .oneMonth:
            return 0.025
        }
    }

    private func downsampleData(_ entries: [ChartDataEntry], samplingRate: Int) -> [ChartDataEntry] {
        guard samplingRate > 1, !entries.isEmpty else { return entries }
        guard entries.count > 1 else { return entries }
        
        var result: [ChartDataEntry] = [entries.last!]
        let count = entries.count - 1
        
        var accumX: Double = 0
        var accumY: Double = 0
        var sampleCount = 0
        
        for i in (0..<count).reversed() {
            let entry = entries[i]
            accumX += entry.x
            accumY += entry.y
            sampleCount += 1
            
            if sampleCount == samplingRate {
                let avgX = accumX / Double(sampleCount)
                let avgY = accumY / Double(sampleCount)
                result.insert(ChartDataEntry(x: avgX, y: avgY), at: 0)
                
                accumX = 0
                accumY = 0
                sampleCount = 0
            }
        }

        if sampleCount > 0 {
            let avgX = accumX / Double(sampleCount)
            let avgY = accumY / Double(sampleCount)
            result.insert(ChartDataEntry(x: avgX, y: avgY), at: 0)
        }
        
        return result
    }

    private func preprocessData(_ entries: [ChartDataEntry], timeRange: TimeRange) -> [ChartDataEntry] {
        guard !entries.isEmpty else { return entries }
        
        let oneMonthAgo = Date()
            .addingTimeInterval(-30 * 24 * 60 * 60)
            .timeIntervalSince1970
        
        let (recentData, olderData) = entries.reduce(into: ([ChartDataEntry](), [ChartDataEntry]())) {
            if $1.x >= oneMonthAgo {
                $0.0.append($1)
            } else {
                $0.1.append($1)
            }
        }
        
        let samplingRate = calculateSamplingRate(timeRange)
        let sampledOlderData = downsampleData(olderData, samplingRate: samplingRate)
        return sampledOlderData + recentData
    }

    private func configureXAxis(_ xAxis: XAxis) {
        xAxis.labelPosition = .bottom
        xAxis.valueFormatter = DateAxisValueFormatter(timeRange: timeRange)
        xAxis.labelRotationAngle = 0
        xAxis.labelFont = .systemFont(ofSize: 10)
        
        if case .all = timeRange {
            if let firstDate = data.first?.date.timeIntervalSince1970,
               let lastDate = data.last?.date.timeIntervalSince1970 {
                let totalYears = (lastDate - firstDate) / (365 * 24 * 60 * 60)
                if totalYears <= 5 {
                    xAxis.labelCount = 5
                    xAxis.granularity = 365 * 24 * 60 * 60
                } else {
                    xAxis.labelCount = min(Int(totalYears) / 2, 8)
                    xAxis.granularity = (lastDate - firstDate) / Double(xAxis.labelCount)
                }
            }
        } else {
            switch timeRange {
            case .twoYears, .fiveYears, .tenYears:
                xAxis.granularity = 365 * 24 * 60 * 60
                xAxis.labelCount = timeRange.labelCount
            default:
                xAxis.granularity = 30 * 24 * 60 * 60
                switch timeRange {
                case .threeMonths:
                    xAxis.labelCount = 3
                case .sixMonths:
                    xAxis.labelCount = 6
                case .oneYear:
                    xAxis.labelCount = 6
                default:
                    xAxis.labelCount = 12
                }
            }
        }
        
        xAxis.granularityEnabled = true
        xAxis.drawGridLinesEnabled = showGrid
    }

    private func configureYAxis(_ leftAxis: YAxis) {
        leftAxis.labelFont = .systemFont(ofSize: 10)
        leftAxis.labelCount = 6
        leftAxis.decimals = 2
        leftAxis.drawGridLinesEnabled = true
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 0.5
        leftAxis.zeroLineColor = .systemGray
        leftAxis.granularity = 1
        leftAxis.spaceTop = 0.1
        leftAxis.spaceBottom = 0.1
    }

    private func updateChartData(_ chartView: LineChartView) {
        let entries = data.map {
            ChartDataEntry(x: $0.date.timeIntervalSince1970, y: $0.price)
        }
        let dataSet = createDataSet(entries: entries)
        
        // 添加特殊点标记
        addSpecialMarkers(to: dataSet)
        
        chartView.leftAxis.drawZeroLineEnabled = false
        chartView.data = LineChartData(dataSet: dataSet)
        
        if !entries.isEmpty {
            let minX = entries.map(\.x).min() ?? 0
            let maxX = entries.map(\.x).max() ?? 0
            let minY = entries.map(\.y).min() ?? 0
            let maxY = entries.map(\.y).max() ?? 0
            let padding = (maxY - minY) * 0.1

            let priceRange = maxY - minY
            let granularity = calculateGranularity(priceRange: priceRange)
            
            chartView.leftAxis.granularity = granularity
            chartView.leftAxis.decimals = calculateDecimals(granularity: granularity)
            
            let adjustedMinY = minY > 0
                ? max((minY - padding), 0)
                : (minY - padding)
            
            chartView.setVisibleXRange(minXRange: 30, maxXRange: maxX - minX)
            chartView.leftAxis.axisMinimum = adjustedMinY
            chartView.leftAxis.axisMaximum = maxY + padding
            
            chartView.moveViewToX(maxX)
        }
        
        if shouldAnimate {
            chartView.animate(xAxisDuration: 0.5)
        }
    }
    
    private func addSpecialMarkers(to dataSet: LineChartDataSet) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        // 查找特殊日期对应的数据点
        for entry in dataSet.entries {
            let entryDate = Date(timeIntervalSince1970: entry.x)
            let entryDateString = dateFormatter.string(from: entryDate)
            
            // 检查全局标记
            for (date, _) in globalTimeMarkers {
                let markerDateString = dateFormatter.string(from: date)
                if markerDateString == entryDateString {
                    // 添加黄色标记
                    let circleImage = UIImage.circleImage(with: .yellow, size: CGSize(width: 8, height: 8))
                    entry.icon = circleImage
                }
            }
            
            // 检查特定股票标记
            for (date, _) in symbolTimeMarkers {
                let markerDateString = dateFormatter.string(from: date)
                if markerDateString == entryDateString {
                    // 添加橙色标记（优先级高于全局标记）
                    let circleImage = UIImage.circleImage(with: .orange, size: CGSize(width: 8, height: 8))
                    entry.icon = circleImage
                }
            }
        }
    }

    private func calculateGranularity(priceRange: Double) -> Double {
        switch abs(priceRange) {
        case 0..<1:
            return 0.1
        case 1..<5:
            return 0.2
        case 5..<10:
            return 0.5
        case 10..<50:
            return 1
        case 50..<100:
            return 2
        case 100..<500:
            return 5
        case 500..<1000:
            return 10
        default:
            return max(abs(priceRange) / 50, 1)
        }
    }

    private func calculateDecimals(granularity: Double) -> Int {
        if granularity >= 1 {
            return 0
        } else {
            // 计算小数位数
            return String(granularity)
                .split(separator: ".")
                .last?
                .count ?? 2
        }
    }
}

// 安全数组访问扩展
extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension UIImage {
    static func circleImage(with color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.cgContext.setFillColor(color.cgColor)
            ctx.cgContext.fillEllipse(in: rect)
        }
    }
}
