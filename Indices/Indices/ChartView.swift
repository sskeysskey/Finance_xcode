import SwiftUI
import DGCharts

// MARK: - TimeRange Enum
enum TimeRange: String, CaseIterable {
    case twoYears = "2Y"
    case fiveYears = "5Y"
    case oneYear = "1Y"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case tenYears = "10Y"

    var startDate: Date {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:   return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear:     return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .twoYears:    return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:   return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:    return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        }
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
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? Color.green : Color(uiColor: .systemBackground))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
    }
}

// MARK: - ChartView
struct ChartView: View {
    let symbol: String
    let groupName: String

    @State private var selectedTimeRange: TimeRange = .oneYear
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var isLoading = false
    @State private var showGrid = false
    @State private var isDarkMode = true
    @State private var selectedPrice: Double? = nil  // 保持状态变量

    var body: some View {
        VStack(spacing: 16) {
            headerView
            chartView
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .gray.opacity(0.2), radius: 8)
                )
            timeRangePicker

            // 显示选中的价格
            if let price = selectedPrice {
                Text(String(format: "Price: %.2f", price))
                    .font(.system(size: 16, weight: .medium))
                    .padding(.top, 8)
            } else {
                Text("Select a point to see price")
                    .font(.system(size: 16, weight: .medium))
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding(.vertical)  // 只保留垂直方向的 padding
        .navigationTitle("\(symbol) Chart")
        .onChange(of: selectedTimeRange) { _, _ in
            // 在加载新数据之前，先清空现有数据
            chartData = []
            loadChartData()
        }
        .onAppear { loadChartData() }
        .overlay(loadingOverlay)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - View Components
    private var headerView: some View {
        HStack {
            Text(symbol)
                .font(.system(size: 24, weight: .bold))
            Spacer()
            Toggle("", isOn: $showGrid) // 移除文字标签
                .toggleStyle(SwitchToggleStyle(tint: .green))
            Spacer()
            Button(action: { isDarkMode.toggle() }) {
                Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isDarkMode ? .yellow : .gray)
            }
            .padding(.leading, 8)
            Spacer()
        }
    }

    private var chartView: some View {
        StockLineChartView(
            data: chartData,
            showGrid: showGrid,
            isDarkMode: isDarkMode,
            timeRange: selectedTimeRange,
            selectedPrice: $selectedPrice  // 传递 Binding
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
}

extension ChartView {
    // MARK: - Methods
    private func loadChartData() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            print("开始数据库查询...")
            let newData = DatabaseManager.shared.fetchHistoricalData(
                symbol: symbol,
                tableName: groupName,
                timeRange: selectedTimeRange
            )
            print("查询完成，获取到 \(newData.count) 条数据")

            DispatchQueue.main.async {
                chartData = newData
                isLoading = false
                print("数据已更新到UI")
            }
        }
    }
}

// MARK: - StockLineChartView
struct StockLineChartView: UIViewRepresentable {
    let data: [DatabaseManager.PriceData]
    let showGrid: Bool
    let isDarkMode: Bool
    let timeRange: TimeRange
    @Binding var selectedPrice: Double?  // 使用 Binding

    class Coordinator: NSObject, ChartViewDelegate {
        var parent: StockLineChartView

        init(_ parent: StockLineChartView) {
            self.parent = parent
        }

        func chartValueSelected(_ chartView: ChartViewBase, entry: ChartDataEntry, highlight: Highlight) {
            parent.selectedPrice = entry.y  // 直接更新绑定值
        }

        func chartValueNothingSelected(_ chartView: ChartViewBase) {
            parent.selectedPrice = nil  // 清除绑定值
        }

        @objc func handleLongPressGesture(_ gestureRecognizer: UILongPressGestureRecognizer) {
            guard let chartView = gestureRecognizer.view as? LineChartView else { return }
            let touchPoint = gestureRecognizer.location(in: chartView)

            switch gestureRecognizer.state {
            case .began, .changed:
                let h = chartView.getHighlightByTouchPoint(touchPoint)
                chartView.highlightValue(h, callDelegate: true) // 调用委托方法
            case .ended, .cancelled:
                chartView.highlightValue(nil, callDelegate: true) // 清除高亮
            default:
                break
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        chartView.delegate = context.coordinator

        // 添加长按手势识别器
        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPressGesture(_:)))
        longPressGesture.minimumPressDuration = 0.0
        chartView.addGestureRecognizer(longPressGesture)

        configureChartView(chartView)
        chartView.noDataText = ""
        return chartView
    }
    
    func updateUIView(_ chartView: LineChartView, context: Context) {
        // 如果没有数据，禁用动画并清空图表
        if data.isEmpty {
            chartView.clear()
            return
        }

        // 检查数据是否有变化
        let currentEntries = chartView.data?.entryCount ?? 0
        if currentEntries != data.count {
            // 数据发生变化，更新图表
            updateChartAppearance(chartView)

            // 使用 CATransaction 来控制动画
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            updateChartData(chartView)
            CATransaction.commit()
        } else {
            // 仅更新外观，不更新数据
            updateChartAppearance(chartView)
        }
    }
    
    private func configureChartView(_ chartView: LineChartView) {
        chartView.legend.enabled = false
        chartView.rightAxis.enabled = false

        // 添加动画效果
        chartView.animate(xAxisDuration: 1.0, yAxisDuration: 1.0, easingOption: .easeInOutQuart)

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
    
    // 修改 createDataSet 方法
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
        dataSet.highlightColor = .systemOrange
        dataSet.highlightLineWidth = 1
        dataSet.highlightLineDashLengths = [5, 2]

        // 根据时间范围设置曲线张力
        dataSet.cubicIntensity = calculateLineTension(timeRange)

        return dataSet
    }
}

extension StockLineChartView {
    // 根据时间范围计算采样率
    private func calculateSamplingRate(_ timeRange: TimeRange) -> Int {
        let baseRate: Int
        switch timeRange {
        case .tenYears:   baseRate = 14
        case .fiveYears:  baseRate = 7
        case .twoYears:   baseRate = 4
        case .oneYear:    baseRate = 2
        case .sixMonths:  baseRate = 1
        case .threeMonths: baseRate = 1
        }

        // 确保最近一个月的数据点被更好地保留
        return max(1, baseRate)
    }

    // 根据时间范围计算曲线张力
    private func calculateLineTension(_ timeRange: TimeRange) -> CGFloat {
        switch timeRange {
        case .tenYears: return 0.3
        case .fiveYears: return 0.2
        case .twoYears: return 0.15
        case .oneYear: return 0.1
        case .sixMonths: return 0.075
        case .threeMonths: return 0.05
        }
    }

    // 修改降采样方法，从最新数据开始处理
    private func downsampleData(_ entries: [ChartDataEntry], samplingRate: Int) -> [ChartDataEntry] {
        guard samplingRate > 1, !entries.isEmpty else { return entries }

        // 最新的数据点始终保留
        var result: [ChartDataEntry] = [entries.last!]

        // 从倒数第二个点开始向前处理
        var accumX: Double = 0
        var accumY: Double = 0
        var count = 0

        // 从后向前遍历，但跳过最后一个点（因为已经添加）
        for i in (0...(entries.count - 2)).reversed() {
            let entry = entries[i]
            accumX += entry.x
            accumY += entry.y
            count += 1

            if count == samplingRate {
                let avgX = accumX / Double(count)
                let avgY = accumY / Double(count)
                result.insert(ChartDataEntry(x: avgX, y: avgY), at: 0)

                accumX = 0
                accumY = 0
                count = 0
            }
        }

        // 处理剩余的数据点
        if count > 0 {
            let avgX = accumX / Double(count)
            let avgY = accumY / Double(count)
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
        xAxis.valueFormatter = DateAxisValueFormatter()
        xAxis.labelRotationAngle = -45
        xAxis.labelFont = .systemFont(ofSize: 10)
        xAxis.granularity = 1
        xAxis.labelCount = 6
    }

    private func configureYAxis(_ leftAxis: YAxis) {
        leftAxis.labelFont = .systemFont(ofSize: 10)
        leftAxis.labelCount = 6
        leftAxis.decimals = 2
        leftAxis.drawGridLinesEnabled = true
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 0.5 // 添加这行
        leftAxis.zeroLineColor = .systemGray // 添加这行
        leftAxis.granularity = 1
        leftAxis.spaceTop = 0.1 // 添加这行
        leftAxis.spaceBottom = 0.1 // 添加这行
    }

    private func updateChartData(_ chartView: LineChartView) {
        let entries = data.map { ChartDataEntry(x: $0.date.timeIntervalSince1970, y: $0.price) }
        let dataSet = createDataSet(entries: entries)

        chartView.data = LineChartData(dataSet: dataSet)

        // 设置可见范围
        if !entries.isEmpty {
            let minX = entries.map(\.x).min() ?? 0
            let maxX = entries.map(\.x).max() ?? 0
            let minY = entries.map(\.y).min() ?? 0
            let maxY = entries.map(\.y).max() ?? 0
            let padding = (maxY - minY) * 0.1

            // 计算价格范围并动态设置粒度
            let priceRange = maxY - minY
            let granularity = calculateGranularity(priceRange: priceRange)

            chartView.leftAxis.granularity = granularity
            chartView.leftAxis.decimals = calculateDecimals(granularity: granularity)

            chartView.setVisibleXRange(minXRange: 30, maxXRange: maxX - minX)
            chartView.leftAxis.axisMinimum = minY - padding
            chartView.leftAxis.axisMaximum = maxY + padding

            // 移动到最新数据点
            chartView.moveViewToX(maxX)
        }

        chartView.animate(xAxisDuration: 0.5)
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

// MARK: - DateAxisValueFormatter
private class DateAxisValueFormatter: AxisValueFormatter {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        return formatter
    }()

    func stringForValue(_ value: Double, axis: AxisBase?) -> String {
        let date = Date(timeIntervalSince1970: value)
        return dateFormatter.string(from: date)
    }
}
