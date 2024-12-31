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
        case .oneMonth: return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:   return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear:     return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .twoYears:    return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:   return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:    return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        case .all:         return Date.distantPast  // 返回一个很早的日期
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
        case .all:         return Double.infinity   // 设置为无限大的时间间隔
        }
    }
    
    // 添加 labelCount 计算属性
    var labelCount: Int {
        switch self {
        case .all:  return 10  // 为 ALL 设置合适的标签数量
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
        case .all:
            dateFormatter.dateFormat = "yyyy"
        case .twoYears, .fiveYears, .tenYears:
            dateFormatter.dateFormat = "yyyy"
        case .oneYear:
            dateFormatter.dateFormat = "MMM"
        case .oneMonth, .threeMonths, .sixMonths:
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(descriptions.0)
                        .font(.title2)
                        .foregroundColor(isDarkMode ? .white : .black)
                        .padding(.bottom, 18) // 添加底部间距
                    
                    Text(descriptions.1)
                        .font(.title2)
                        .foregroundColor(isDarkMode ? .white : .black)
                }
                .padding()
            }
            Spacer()
        }
        .navigationBarTitle("Description", displayMode: .inline)
        .background(isDarkMode ? Color.black.edgesIgnoringSafeArea(.all) : Color.white.edgesIgnoringSafeArea(.all))
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
//    @State private var selectedDate: Date? = nil
    // 新增两个日期状态变量
    @State private var selectedDateStart: Date? = nil
    @State private var selectedDateEnd: Date? = nil
    @State private var isInteracting: Bool = false
    @State private var shouldAnimate: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            headerView

            // 价格和日期显示逻辑
            if let price = selectedPrice {
                HStack {
                    if isDifferencePercentage, let startDate = selectedDateStart, let endDate = selectedDateEnd {
                        Text("\(formattedDate(startDate))   \(formattedDate(endDate))")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                        Text(String(format: "%.2f%%", price))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.green)
                    } else if let date = selectedDateStart { // 单点选择
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
                .padding(.top, 0)
            } else {
                HStack {
                    // 替换为 NavigationLink
                    NavigationLink(destination: {
                        if let descriptions = getDescriptions(for: symbol) {
                            DescriptionView(descriptions: descriptions, isDarkMode: isDarkMode)
                        } else {
                            DescriptionView(descriptions: ("No description available.", ""), isDarkMode: isDarkMode)
                        }
                    }) {
                        Text("Description")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.top, 0)
                            .foregroundColor(.green)
                    }
                    // 新增 Compare 按钮
                    NavigationLink(destination: CompareView(initialSymbol: symbol)) {
                        Text("Compare")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.top, 0)
                            .padding(.leading, 20)
                            .foregroundColor(.green)
                    }
                    // 新增 Similar 按钮
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
    
    // 格式化日期的方法
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
                        .lineLimit(1)  // 添加这行
                        .fixedSize(horizontal: true, vertical: false)  // 添加这行
                    
                    Text(dataService.marketCapData[symbol.uppercased()]?.peRatio.map { String(format: "%.0f", $0) } ?? "")
                        .font(.system(size: 20))
                        .lineLimit(1)  // 添加这行
                        .fixedSize(horizontal: true, vertical: false)  // 添加这行
                    
                    Text(dataService.compareData[symbol.uppercased()]?.description ?? "--")
                        .font(.system(size: 20))
                        .lineLimit(1)  // 添加这行
                        .fixedSize(horizontal: true, vertical: false)  // 添加这行
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)  // 添加这行
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
        StockLineChartView(
            data: chartData,
            showGrid: showGrid,
            isDarkMode: isDarkMode,
            timeRange: selectedTimeRange,
            onSelectedPriceChange: { price, isPercentage, startDate, endDate in
                selectedPrice = price
                isDifferencePercentage = isPercentage
                selectedDateStart = startDate
                selectedDateEnd = endDate
            },
            isInteracting: $isInteracting,  // 传递绑定
            shouldAnimate: $shouldAnimate // 传递 shouldAnimate
        )
        .frame(height: 350)
        .padding(.vertical, 1)  // 只保留垂直方向的少量 padding
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
    
    // 获取当前symbol的描述信息
    private func getDescriptions(for symbol: String) -> (String, String)? {
        // 检查是否为股票
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
            return (stock.description1, stock.description2)
        }
        // 检查是否为ETF
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
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
    let onSelectedPriceChange: (Double?, Bool, Date?, Date?) -> Void
    @Binding var isInteracting: Bool
    @Binding var shouldAnimate: Bool

    class Coordinator: NSObject, ChartViewDelegate {
        var parent: StockLineChartView
        var firstTouchHighlight: Highlight?
        var secondTouchHighlight: Highlight?
        var isShowingPercentage = false  // 添加这个标志

        init(_ parent: StockLineChartView) {
            self.parent = parent
        }

        func chartValueSelected(_ chartView: ChartViewBase, entry: ChartDataEntry, highlight: Highlight) {
            // 处理单点选择
            if secondTouchHighlight == nil {
                // 处理单点选择，传递日期
                let date = Date(timeIntervalSince1970: entry.x)
                parent.onSelectedPriceChange(entry.y, false, date, nil)
            }
        }

        func chartValueNothingSelected(_ chartView: ChartViewBase) {
            parent.onSelectedPriceChange(nil, false, nil, nil)
            firstTouchHighlight = nil
            secondTouchHighlight = nil
            self.parent.shouldAnimate = false
        }

        @objc func handleMultiTouchGesture(_ gestureRecognizer: MultiTouchLongPressGestureRecognizer) {
            guard let chartView = gestureRecognizer.view as? LineChartView else { return }
            
            switch gestureRecognizer.state {
            case .began, .changed:
                // 用户开始或正在交互
                parent.isInteracting = true
                let touchPoints = gestureRecognizer.touchPoints
                
                // 处理触摸点并更新高亮
                updateHighlights(for: touchPoints, in: chartView)
                
            case .ended, .cancelled:
                // 用户结束交互，清除所有状态
                parent.isInteracting = false
                chartView.highlightValues(nil)
                firstTouchHighlight = nil
                secondTouchHighlight = nil
                parent.onSelectedPriceChange(nil, false, nil, nil)
                
                // 用户结束交互时，不执行动画
                parent.shouldAnimate = false
                
            default:
                break
            }
        }
        
        private func updateHighlights(for touchPoints: [CGPoint], in chartView: LineChartView) {
            // 更新第一个触摸点
            if let firstPoint = touchPoints.first {
                firstTouchHighlight = chartView.getHighlightByTouchPoint(firstPoint)
            } else {
                firstTouchHighlight = nil
            }
            
            // 更新第二个触摸点
            if touchPoints.count > 1 {
                secondTouchHighlight = chartView.getHighlightByTouchPoint(touchPoints[1])
            } else {
                secondTouchHighlight = nil
            }
            
            updateChartHighlights(chartView)
            
            // 计算并更新价格差异百分比
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
            guard let firstHighlight = firstTouchHighlight,
                  let secondHighlight = secondTouchHighlight,
                  let firstEntry = chartView.data?.dataSet(at: 0)?.entryForXValue(firstHighlight.x, closestToY: firstHighlight.y),
                  let secondEntry = chartView.data?.dataSet(at: 0)?.entryForXValue(secondHighlight.x, closestToY: secondHighlight.y) else {
                if let firstHighlight = firstTouchHighlight,
                   let firstEntry = chartView.data?.dataSet(at: 0)?.entryForXValue(firstHighlight.x, closestToY: firstHighlight.y) {
                    // 只有一个触摸点时显示具体价格和日期
                    isShowingPercentage = false
                    let date = Date(timeIntervalSince1970: firstEntry.x)
                    parent.onSelectedPriceChange(firstEntry.y, false, date, nil)
                }
                return
            }
            
            // 根据时间戳决定哪个是较早的点
            let (earlierEntry, laterEntry) = firstEntry.x < secondEntry.x ?
                (firstEntry, secondEntry) : (secondEntry, firstEntry)
            
            // 计算价格变化百分比
            let priceDiffPercentage = ((laterEntry.y - earlierEntry.y) / earlierEntry.y) * 100
            isShowingPercentage = true
            let startDate = Date(timeIntervalSince1970: earlierEntry.x)
            let endDate = Date(timeIntervalSince1970: laterEntry.x)
            parent.onSelectedPriceChange(priceDiffPercentage, true, startDate, endDate)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        chartView.delegate = context.coordinator

        // 配置手势识别器
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
        if isInteracting {
            return
        }

        if data.isEmpty {
            chartView.clear()
            return
        }

        // 始终配置 X 轴
        configureXAxis(chartView.xAxis)
        
        // 始终更新图表的外观，以确保网格和模式切换生效
        updateChartAppearance(chartView)
        updateChartData(chartView)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        CATransaction.commit()
    }
    
    private func configureChartView(_ chartView: LineChartView) {
        chartView.legend.enabled = false
        chartView.rightAxis.enabled = false

        // 添加动画效果
//        chartView.animate(xAxisDuration: 1.0, yAxisDuration: 1.0, easingOption: .easeInOutQuart)

        configureXAxis(chartView.xAxis)
        configureYAxis(chartView.leftAxis)

        chartView.dragEnabled = true
        chartView.setScaleEnabled(true)
        chartView.pinchZoomEnabled = true
        chartView.highlightPerTapEnabled = true // 我们通过手势处理高亮
        chartView.highlightPerDragEnabled = true

        // 添加双击重置功能
        chartView.doubleTapToZoomEnabled = true
    }
    
    private func updateChartAppearance(_ chartView: LineChartView) {
        // 主题相关设置
        let textColor = isDarkMode ? UIColor.white : UIColor.black
        let gridColor = isDarkMode ? UIColor.gray.withAlphaComponent(0.3) : UIColor.gray.withAlphaComponent(0.2)

        chartView.xAxis.labelTextColor = textColor
        chartView.leftAxis.labelTextColor = textColor
        chartView.xAxis.gridColor = gridColor
        chartView.leftAxis.gridColor = gridColor

        // 网格显示控制
        chartView.xAxis.drawGridLinesEnabled = showGrid
        chartView.leftAxis.drawGridLinesEnabled = showGrid

        // 背景颜色
        chartView.backgroundColor = isDarkMode ? .black : .white
    }
    
    private func createDataSet(entries: [ChartDataEntry]) -> LineChartDataSet {
        // 使用预处理方法处理数据
        let processedEntries = preprocessData(entries, timeRange: timeRange)
        let dataSet = LineChartDataSet(entries: processedEntries, label: "Price")
    
        // 检查价格是否为负值
        let isNegative = processedEntries.contains { $0.y < 0 }

        // 根据模式选择颜色
        if isDarkMode {
            // 暗黑模式使用霓虹色
            let neonColor = UIColor(red: 0/255, green: 255/255, blue: 178/255, alpha: 1.0)
            let gradientColors = [
                neonColor.withAlphaComponent(0.8).cgColor,
                neonColor.withAlphaComponent(0.0).cgColor
            ]
            dataSet.setColor(neonColor)
            let gradient = CGGradient(colorsSpace: nil,
                                colors: isNegative ? gradientColors as CFArray : gradientColors as CFArray,
                                locations: [0.0, 1.0])!
            dataSet.fill = LinearGradientFill(gradient: gradient, angle: isNegative ? 270 : 90)
        } else {
            // 明亮模式使用系统蓝色
            let gradientColors = [
                UIColor.systemBlue.withAlphaComponent(0.8).cgColor,
                UIColor.systemBlue.withAlphaComponent(0.0).cgColor
            ]
            dataSet.setColor(.systemBlue)
            let gradient = CGGradient(colorsSpace: nil,
                                colors: isNegative ? gradientColors as CFArray : gradientColors as CFArray,
                                locations: [0.0, 1.0])!
            dataSet.fill = LinearGradientFill(gradient: gradient, angle: isNegative ? 270 : 90)
        }

        // 其他设置保持不变
        dataSet.drawCirclesEnabled = false
        dataSet.mode = .cubicBezier
        dataSet.lineWidth = 1.0
        dataSet.drawFilledEnabled = true
        dataSet.drawValuesEnabled = false
        dataSet.highlightEnabled = true
        dataSet.highlightColor = .systemRed
        dataSet.highlightLineWidth = 1
        dataSet.highlightLineDashLengths = [5, 2]

        // 根据时间范围设置曲线张力
        dataSet.cubicIntensity = CGFloat(calculateLineTension(timeRange))

        return dataSet
    }
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

// 安全数组访问扩展
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

extension StockLineChartView {
    // 根据时间范围计算采样率
    private func calculateSamplingRate(_ timeRange: TimeRange) -> Int {
        let baseRate: Int
        switch timeRange {
        case .all:        baseRate = 15  // 为全部数据设置更高的采样率
        case .tenYears:   baseRate = 14
        case .fiveYears:  baseRate = 7
        case .twoYears:   baseRate = 4
        case .oneYear:    baseRate = 2
        case .sixMonths:  baseRate = 1
        case .threeMonths: baseRate = 1
        case .oneMonth: baseRate = 1
        }

        // 确保最近一个月的数据点被更好地保留
        return max(1, baseRate)
    }

    // 根据时间范围计算曲线张力
    private func calculateLineTension(_ timeRange: TimeRange) -> Double {
        switch timeRange {
        case .all:        return 0.4  // 为全部数据设置适当的张力
        case .tenYears: return 0.3
        case .fiveYears: return 0.2
        case .twoYears: return 0.15
        case .oneYear: return 0.1
        case .sixMonths: return 0.075
        case .threeMonths: return 0.05
        case .oneMonth: return 0.025
        }
    }

    // 修改降采样方法，从最新数据开始处理
    private func downsampleData(_ entries: [ChartDataEntry], samplingRate: Int) -> [ChartDataEntry] {
        // 基础检查：采样率必须大于1，且数组不能为空
        guard samplingRate > 1, !entries.isEmpty else { return entries }
        
        // 如果只有一个元素，直接返回
        guard entries.count > 1 else { return entries }
        
        // 最新的数据点始终保留
        var result: [ChartDataEntry] = [entries.last!]
        
        // 计算需要处理的元素数量
        let count = entries.count - 1  // 减去最后一个已经添加的点
        
        var accumX: Double = 0
        var accumY: Double = 0
        var sampleCount = 0
        
        // 从后向前遍历，但跳过最后一个点
        for i in (0..<count).reversed() {
            let entry = entries[i]
            accumX += entry.x
            accumY += entry.y
            sampleCount += 1
            
            if sampleCount == samplingRate {
                let avgX = accumX / Double(sampleCount)
                let avgY = accumY / Double(sampleCount)
                result.insert(ChartDataEntry(x: avgX, y: avgY), at: 0)
                
                // 重置累加器
                accumX = 0
                accumY = 0
                sampleCount = 0
            }
        }

        // 处理剩余的数据点
        if sampleCount > 0 {
            let avgX = accumX / Double(sampleCount)
            let avgY = accumY / Double(sampleCount)
            result.insert(ChartDataEntry(x: avgX, y: avgY), at: 0)
        }

        return result
    }

    // 添加数据预处理方法
    private func preprocessData(_ entries: [ChartDataEntry], timeRange: TimeRange) -> [ChartDataEntry] {
        guard !entries.isEmpty else { return entries }

        // 计算一个月前的时间戳
        let oneMonthAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970

        // 将数据分为两部分：最近一个月和更早的数据
        let (recentData, olderData): ([ChartDataEntry], [ChartDataEntry]) = entries.reduce(into: ([], [])) { result, entry in
            if entry.x >= oneMonthAgo {
                result.0.append(entry)
            } else {
                result.1.append(entry)
            }
        }

        // 对更早的数据进行降采样
        let samplingRate = calculateSamplingRate(timeRange)
        let sampledOlderData = downsampleData(olderData, samplingRate: samplingRate)

        // 合并数据，确保最近的数据点完整保留
        return sampledOlderData + recentData
    }

    private func configureXAxis(_ xAxis: XAxis) {
        xAxis.labelPosition = .bottom
        xAxis.valueFormatter = DateAxisValueFormatter(timeRange: timeRange)
        xAxis.labelRotationAngle = 0
        xAxis.labelFont = .systemFont(ofSize: 10)
        
        // 特别处理.all的情况
        if case .all = timeRange {
            // 获取数据的时间跨度
            if let firstDate = data.first?.date.timeIntervalSince1970,
               let lastDate = data.last?.date.timeIntervalSince1970 {
                let totalYears = (lastDate - firstDate) / (365 * 24 * 60 * 60)
                
                // 根据总年数动态调整标签数量
                if totalYears <= 5 {
                    xAxis.labelCount = 5
                    xAxis.granularity = 365 * 24 * 60 * 60  // 1年
                } else {
                    // 对于更长的时间跨度，减少标签数量
                    xAxis.labelCount = min(Int(totalYears) / 2, 8)  // 最多显示8个标签
                    xAxis.granularity = (lastDate - firstDate) / Double(xAxis.labelCount)
                }
            }
        } else {
            // 原有的其他时间范围处理逻辑
            switch timeRange {
            case .twoYears, .fiveYears, .tenYears:
                xAxis.granularity = 365 * 24 * 60 * 60
                xAxis.labelCount = timeRange.labelCount
            default:
                xAxis.granularity = 30 * 24 * 60 * 60
                switch timeRange {
                case .threeMonths: xAxis.labelCount = 3
                case .sixMonths: xAxis.labelCount = 6
                case .oneYear: xAxis.labelCount = 6
                default: xAxis.labelCount = 12
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
        let entries = data.map { ChartDataEntry(x: $0.date.timeIntervalSince1970, y: $0.price) }
        let dataSet = createDataSet(entries: entries)
        
        // 禁用零线
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
            
            // 使用 max() 函数修正语法
            let adjustedMinY = minY > 0 ? max((minY - padding), 0) : minY - padding
            
            chartView.setVisibleXRange(minXRange: 30, maxXRange: maxX - minX)
            chartView.leftAxis.axisMinimum = adjustedMinY
            chartView.leftAxis.axisMaximum = maxY + padding
            
            chartView.moveViewToX(maxX)
        }
        
        // 添加动画效果
        if shouldAnimate {
            chartView.animate(xAxisDuration: 0.5)
        }
    }

    // 添加计算粒度的辅助方法
    private func calculateGranularity(priceRange: Double) -> Double {
        // 直接使用 abs(priceRange) 进行比较，无需创建中间变量
        switch abs(priceRange) {
        case 0..<1: return 0.1
        case 1..<5: return 0.2
        case 5..<10: return 0.5
        case 10..<50: return 1
        case 50..<100: return 2
        case 100..<500: return 5
        case 500..<1000: return 10
        default: return max(abs(priceRange) / 50, 1)
        }
    }

    // 添加计算小数位数的辅助方法
    private func calculateDecimals(granularity: Double) -> Int {
        if granularity >= 1 {
            return 0
        } else {
            // 将粒度转换为字符串,计算小数点后的位数
            return String(granularity).split(separator: ".").last?.count ?? 2
        }
    }
}
