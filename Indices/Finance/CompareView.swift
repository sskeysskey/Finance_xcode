import SwiftUI
import DGCharts
import Charts

class DateMarkerView: MarkerView {
    private var text = ""
    private let textLabel: UILabel = {
        let label = UILabel()
        label.textColor = UIColor.white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.font = UIFont.systemFont(ofSize: 12)
        label.textAlignment = .center
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.numberOfLines = 1
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textLabel)
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        addSubview(textLabel)
    }
    
    override func refreshContent(entry: ChartDataEntry, highlight: Highlight) {
        let date = Date(timeIntervalSince1970: entry.x)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        text = dateFormatter.string(from: date)
        textLabel.text = text
        
        // 调整标签的大小以适应文本
        textLabel.sizeToFit()
        let padding: CGFloat = 8
        self.frame.size = CGSize(width: textLabel.frame.width + padding, height: textLabel.frame.height + padding / 2)
        textLabel.frame = CGRect(x: padding / 2, y: padding / 4, width: textLabel.frame.width, height: textLabel.frame.height)
        
        super.refreshContent(entry: entry, highlight: highlight)
    }
    
    override func draw(context: CGContext, point: CGPoint) {
        // 调整标记位置，使其不超出图表边界
        var drawPosition = CGPoint(x: point.x - self.bounds.width / 2, y: point.y - self.bounds.height - 10)
        
        // 确保标记不会超出左边界
        if drawPosition.x < 0 {
            drawPosition.x = 0
        }
        
        // 确保标记不会超出右边界
        if drawPosition.x + self.bounds.width > self.chartView?.bounds.width ?? 0 {
            drawPosition.x = (self.chartView?.bounds.width ?? 0) - self.bounds.width
        }
        
        self.frame.origin = drawPosition
        super.draw(context: context, point: point)
    }
}

struct CompareView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var dataService: DataService
    
    let initialSymbol: String
    private let maxSymbols = 10
    
    @State private var symbols: [String] = []
    @State private var endDate: Date = Date()
    @State private var errorMessage: String? = nil
    @State private var navigateToComparison = false
    @State private var showAlert = false
    // 添加日期选择器的折叠状态
    @State private var isStartDateExpanded = false
    @State private var isEndDateExpanded = false
    
    // 添加一个状态变量来追踪当前聚焦的输入框
    @FocusState private var focusedField: Int?
    
    // 修改默认起始时间为2024年
    @State private var startDate: Date = Calendar.current.date(from: DateComponents(year: 2004))!
    
    // 输入框大小写状态切换
    @State private var shouldUppercase = true

    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 将开始比较按钮移到最上方
                    Button(action: startComparison) {
                        Text("开始比较")
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    
                    // 可折叠的日期选择器
                    Group {
                        DisclosureGroup(
                            isExpanded: $isStartDateExpanded,
                            content: {
                                DatePicker("", selection: $startDate, displayedComponents: .date)
                                    .datePickerStyle(GraphicalDatePickerStyle())
                                    .padding(.vertical)
                            },
                            label: {
                                HStack {
                                    Text("开始日期:")
                                        .font(.headline)
                                    Spacer()
                                    Text(startDate.formatted(date: .abbreviated, time: .omitted))
                                        .foregroundColor(.gray)
                                }
                            }
                        )
                        
                        DisclosureGroup(
                            isExpanded: $isEndDateExpanded,
                            content: {
                                DatePicker("", selection: $endDate, displayedComponents: .date)
                                    .datePickerStyle(GraphicalDatePickerStyle())
                                    .padding(.vertical)
                            },
                            label: {
                                HStack {
                                    Text("结束日期:")
                                        .font(.headline)
                                    Spacer()
                                    Text(endDate.formatted(date: .abbreviated, time: .omitted))
                                        .foregroundColor(.gray)
                                }
                            }
                        )
                    }
                    
                    // 添加大写转换开关
                    Toggle(isOn: $shouldUppercase) {
                    }
                    .onChange(of: shouldUppercase) { oldValue, newValue in
                        // 当开关状态改变时，更新所有现有的股票代码
                        if newValue {
                            symbols = symbols.map { $0.uppercased() }
                        }
                    }
                    
                    // 股票代码输入框
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<symbols.count, id: \.self) { index in
                            HStack {
                                CustomTextField(
                                    placeholder: "股票代码 \(index + 1)",
                                    text: Binding(
                                        get: { symbols[index] },
                                        set: { newValue in
                                            symbols[index] = shouldUppercase ? newValue.uppercased() : newValue
                                        }
                                    ),
                                    onClear: {
                                        focusedField = index
                                    }
                                )
                                .focused($focusedField, equals: index)
                                
                                // 保留原有的删除整行按钮
                                if symbols.count > 1 {
                                    Button(action: {
                                        symbols.remove(at: index)
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                        }

                        if symbols.count < maxSymbols {
                            Button(action: {
                                let newIndex = symbols.count
                                symbols.append("")
                                // 设置焦点到新添加的输入框
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    focusedField = newIndex
                                }
                            }) {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("添加股票代码")
                                }
                            }
                            .foregroundColor(.blue)
                        }
                    }
                    
                    // 显示错误消息
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
                .padding()
            }
            Spacer()
        }
        .onAppear {
            if symbols.isEmpty {
                // 如果initialSymbol为空，只添加一个空字符串
                if initialSymbol.isEmpty {
                    symbols.append("")
                } else {
                    symbols.append(shouldUppercase ? initialSymbol.uppercased() : initialSymbol)
                }
                symbols.append("")
                
                // 使用延迟来确保视图完全加载后设置焦点
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // 如果initialSymbol为空，聚焦第一个输入框
                    // 否则聚焦第二个输入框
                    focusedField = initialSymbol.isEmpty ? 0 : 1
                }
            }
        }
        .navigationDestination(isPresented: $navigateToComparison) {
            ComparisonChartView(symbols: symbols, startDate: startDate, endDate: endDate)
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("错误"), message: Text(errorMessage ?? "未知错误"), dismissButton: .default(Text("确定")))
        }
    }
    
    private func startComparison() {
        // 清除之前的错误消息
        errorMessage = nil
        
        // 清理符号输入，移除空白
        let trimmedSymbols = symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        
        // 检查是否至少有一个符号
        guard !trimmedSymbols.isEmpty else {
            errorMessage = "请至少输入一个股票代码"
            showAlert = true
            return
        }
        
        // 检查是否超过最大数量
        if trimmedSymbols.count > maxSymbols {
            errorMessage = "最多只能比较 \(maxSymbols) 个股票代码"
            showAlert = true
            return
        }
        
        // 检查日期有效性
        guard startDate <= endDate else {
            errorMessage = "开始日期必须早于或等于结束日期"
            showAlert = true
            return
        }
        
        // 设置 symbols、startDate、endDate，并导航
        symbols = trimmedSymbols
        navigateToComparison = true
    }
}

struct CustomTextField: View {
    let placeholder: String
    @Binding var text: String
    let onClear: () -> Void
    @FocusState private var isFocused: Bool
    
    var body: some View {
        ZStack(alignment: .trailing) {
            TextField(placeholder, text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($isFocused)
            
            if !text.isEmpty {
                Button(action: {
                    text = ""
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .opacity(0.6)
                }
                .padding(.trailing, 8) // 调整clearButton的右侧边距
            }
        }
    }
}

struct ComparisonChartView: View {
    let symbols: [String]
    let startDate: Date
    let endDate: Date
    
    @EnvironmentObject var dataService: DataService
    @State private var chartData: [String: [DatabaseManager.PriceData]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("加载数据...")
                    .scaleEffect(1.5, anchor: .center)
            } else if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            } else {
                ComparisonStockLineChartView(data: chartData, isDarkMode: true)
                    .frame(height: 400)
                    .padding()
            }
            Spacer()
        }
        .onAppear {
            loadComparisonData()
        }
    }
    
    private func loadComparisonData() {
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            var tempData: [String: [DatabaseManager.PriceData]] = [:]
            var shortestDateRange: (start: Date, end: Date)?
            
            // 第一次遍历：获取所有数据并确定最短的日期范围
            for symbol in symbols {
                guard let tableName = dataService.getCategory(for: symbol) else {
                    DispatchQueue.main.async {
                        errorMessage = "找不到股票代码 \(symbol) 的分类信息"
                        isLoading = false
                    }
                    return
                }
                
                let data = DatabaseManager.shared.fetchHistoricalData(
                    symbol: symbol,
                    tableName: tableName,
                    dateRange: .customRange(start: startDate, end: endDate)
                )
                
                if data.isEmpty {
                    DispatchQueue.main.async {
                        errorMessage = "没有找到股票代码 \(symbol) 在指定日期范围内的数据"
                        isLoading = false
                    }
                    return
                }
                
                // 获取当前数据集的日期范围
                let currentStart = data.first?.date ?? startDate
                let currentEnd = data.last?.date ?? endDate
                
                // 更新最短日期范围
                if let existing = shortestDateRange {
                    shortestDateRange = (
                        start: max(existing.start, currentStart),
                        end: min(existing.end, currentEnd)
                    )
                } else {
                    shortestDateRange = (currentStart, currentEnd)
                }
                
                tempData[symbol] = data
            }
            
            // 确保我们有有效的日期范围
            guard let dateRange = shortestDateRange else {
                DispatchQueue.main.async {
                    errorMessage = "无法确定共同的日期范围"
                    isLoading = false
                }
                return
            }
            
            // 第二次遍历：根据最短日期范围过滤所有数据
            for (symbol, data) in tempData {
                var filteredData = data.filter {
                    $0.date >= dateRange.start && $0.date <= dateRange.end
                }
                
                // 采样处理
                filteredData = filteredData.sampled(step: 5)
                tempData[symbol] = filteredData
            }
            
            DispatchQueue.main.async {
                chartData = tempData
                isLoading = false
            }
        }
    }
}

extension Array where Element == DatabaseManager.PriceData {
    func sampled(step: Int) -> [DatabaseManager.PriceData] {
        var result: [DatabaseManager.PriceData] = []
        for (index, data) in self.enumerated() {
            if index % step == 0 {
                result.append(data)
            }
        }
        return result
    }
}

struct ComparisonStockLineChartView: UIViewRepresentable {
    let data: [String: [DatabaseManager.PriceData]]
    let isDarkMode: Bool
    
    func makeUIView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        chartView.delegate = context.coordinator
        
        // 创建自定义格式化器
        let formatter = DateValueFormatter()
        context.coordinator.dateFormatter = formatter  // 保存引用
        
        configureChartView(chartView)
        chartView.noDataText = "No Data Available"
        configureXAxis(chartView.xAxis, formatter: formatter)
        
        // 创建并配置自定义 Marker
        let marker = DateMarkerView()
        marker.chartView = chartView
        chartView.marker = marker
        
        return chartView
    }
    
    func updateUIView(_ chartView: LineChartView, context: Context) {
        if data.isEmpty {
            chartView.clear()
            return
        }
        
        // 计算时间跨度
        var minDate = Date.distantFuture
        var maxDate = Date.distantPast
        
        for (_, priceData) in data {
            if let firstDate = priceData.first?.date,
               let lastDate = priceData.last?.date {
                minDate = min(minDate, firstDate)
                maxDate = max(maxDate, lastDate)
            }
        }
        
        let timespan = maxDate.timeIntervalSince(minDate)
        context.coordinator.dateFormatter?.updateTimespan(timespan)

        
        var dataSets: [LineChartDataSet] = []
        let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue, .systemPurple, .systemOrange]
        
        for (index, (symbol, priceData)) in data.enumerated() {
            if !priceData.isEmpty {
                // 找出最大最小值
                let prices = priceData.map { $0.price }
                guard let minPrice = prices.min(),
                      let maxPrice = prices.max() else { continue }
                
                let priceRange = maxPrice - minPrice
                
                // 归一化处理：将所有价格映射到0-100的范围内
                let entries = priceData.map { priceData -> ChartDataEntry in
                    let normalizedPrice = priceRange > 0 ?
                        ((priceData.price - minPrice) / priceRange) * 100 : 50
                    return ChartDataEntry(x: priceData.date.timeIntervalSince1970,
                                        y: normalizedPrice)
                }
                
                let dataSet = createDataSet(entries: entries,
                                          color: colors[index % colors.count],
                                          label: "\(symbol)")
                dataSets.append(dataSet)
            }
        }
        
        let combinedData = LineChartData(dataSets: dataSets)
        chartView.data = combinedData
        chartView.notifyDataSetChanged()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - Coordinator
    class Coordinator: NSObject, ChartViewDelegate {
        var parent: ComparisonStockLineChartView
        var dateFormatter: DateValueFormatter?
        
        init(_ parent: ComparisonStockLineChartView) {
            self.parent = parent
        }
    }
    
    // MARK: - Private Methods
    private func configureChartView(_ chartView: LineChartView) {
        chartView.legend.enabled = true
        chartView.legend.horizontalAlignment = .left
        chartView.rightAxis.enabled = false
        chartView.dragEnabled = true
        chartView.setScaleEnabled(true)
        chartView.pinchZoomEnabled = true
        chartView.highlightPerTapEnabled = true
        chartView.highlightPerDragEnabled = true

        configureYAxis(chartView.leftAxis)
        
        // 主题相关设置
        let textColor = isDarkMode ? UIColor.white : UIColor.black
        let gridColor = isDarkMode ? UIColor.gray.withAlphaComponent(0.3) : UIColor.gray.withAlphaComponent(0.2)
        
        chartView.xAxis.labelTextColor = textColor
        chartView.leftAxis.labelTextColor = textColor
        chartView.xAxis.gridColor = gridColor
        chartView.leftAxis.gridColor = gridColor
        
        // 背景颜色
        chartView.backgroundColor = isDarkMode ? .black : .white
    }
    
    private func configureXAxis(_ xAxis: XAxis, formatter: DateValueFormatter) {
        xAxis.labelPosition = .bottom
        xAxis.labelRotationAngle = 0
        xAxis.labelFont = .systemFont(ofSize: 10)
        xAxis.granularity = 3600 * 24 * 30  // 至少间隔30天
        xAxis.valueFormatter = formatter
        xAxis.drawGridLinesEnabled = true
    }
    
    private func configureYAxis(_ leftAxis: YAxis) {
        leftAxis.labelFont = .systemFont(ofSize: 10)
        leftAxis.labelCount = 6
        leftAxis.decimals = 1
        leftAxis.drawGridLinesEnabled = true
        leftAxis.drawZeroLineEnabled = true
        leftAxis.zeroLineWidth = 0.5
        leftAxis.zeroLineColor = .gray
        
        // 设置Y轴范围为0-100
        leftAxis.axisMinimum = 0
        leftAxis.axisMaximum = 100
        leftAxis.spaceTop = 0.1
        leftAxis.spaceBottom = 0.1
        
        // 自定义Y轴标签
        leftAxis.valueFormatter = DefaultAxisValueFormatter { value, _ in
            return String(format: "%.1f", value)
        }
    }

    private func createDataSet(entries: [ChartDataEntry], color: UIColor, label: String) -> LineChartDataSet {
        let dataSet = LineChartDataSet(entries: entries, label: label)
        dataSet.setColor(color)
        dataSet.lineWidth = 1.5
        dataSet.drawCirclesEnabled = false
        // 更改为贝塞尔曲线模式
        dataSet.mode = .cubicBezier
        dataSet.drawFilledEnabled = false
        dataSet.drawValuesEnabled = false
        dataSet.highlightEnabled = true
        dataSet.highlightColor = .systemRed
        dataSet.highlightLineWidth = 1
        dataSet.highlightLineDashLengths = [5, 2]
        
        // 添加渐变效果
        let gradientColors = [
            color.withAlphaComponent(0.3).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
        let gradient = CGGradient(colorsSpace: nil,
                                 colors: gradientColors as CFArray,
                                 locations: [0.0, 1.0])!
        dataSet.fillAlpha = 0.3
        dataSet.fill = LinearGradientFill(gradient: gradient, angle: 90)
        dataSet.drawFilledEnabled = true
        
        return dataSet
    }
}

class DateValueFormatter: AxisValueFormatter {
    private let dateFormatter = DateFormatter()
    private var referenceTimespan: TimeInterval = 0
    
    init(referenceTimespan: TimeInterval = 0) {
        self.referenceTimespan = referenceTimespan
    }
    
    func stringForValue(_ value: Double, axis: AxisBase?) -> String {
        let date = Date(timeIntervalSince1970: value)
        
        // 根据时间跨度选择不同的日期格式
        if referenceTimespan > 365 * 24 * 3600 { // 超过1年
            dateFormatter.dateFormat = "yyyy"
        } else {
            dateFormatter.dateFormat = "MM/dd"
        }
        
        return dateFormatter.string(from: date)
    }
    
    func updateTimespan(_ timespan: TimeInterval) {
        self.referenceTimespan = timespan
    }
}
