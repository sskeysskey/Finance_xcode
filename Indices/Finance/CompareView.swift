import SwiftUI
import DGCharts
import Charts

// MARK: - DateMarkerView
class DateMarkerView: MarkerView {
    private var text = ""
    private let textLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.font = .systemFont(ofSize: 12)
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
        
        textLabel.sizeToFit()
        let padding: CGFloat = 8
        frame.size = CGSize(width: textLabel.frame.width + padding, height: textLabel.frame.height + padding / 2)
        textLabel.frame = CGRect(x: padding / 2, y: padding / 4, width: textLabel.frame.width, height: textLabel.frame.height)
        
        super.refreshContent(entry: entry, highlight: highlight)
    }
    
    override func draw(context: CGContext, point: CGPoint) {
        var drawPosition = CGPoint(
            x: point.x - bounds.width / 2,
            y: point.y - bounds.height - 10
        )
        
        // Left boundary
        if drawPosition.x < 0 {
            drawPosition.x = 0
        }
        
        // Right boundary
        if let chartWidth = chartView?.bounds.width {
            if drawPosition.x + bounds.width > chartWidth {
                drawPosition.x = chartWidth - bounds.width
            }
        }
        
        frame.origin = drawPosition
        super.draw(context: context, point: point)
    }
}

// MARK: - CompareView
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
    
    // Start/End Date pickers expansion states
    @State private var isStartDateExpanded = false
    @State private var isEndDateExpanded = false
    
    // Track focused input field
    @FocusState private var focusedField: Int?
    
    // Default start date: year 2014
    @State private var startDate: Date = Calendar.current.date(from: DateComponents(year: 2014))!
    
    // Uppercase toggle
    @State private var shouldUppercase = true

    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // Comparison button
                    Button(action: startComparison) {
                        Text("开始比较")
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    
                    // Collapsible date pickers
                    Group {
                        DisclosureGroup(isExpanded: $isStartDateExpanded) {
                            DatePicker("", selection: $startDate, displayedComponents: .date)
                                .datePickerStyle(GraphicalDatePickerStyle())
                                .padding(.vertical)
                        } label: {
                            HStack {
                                Text("开始日期:")
                                    .font(.headline)
                                Spacer()
                                Text(startDate.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        DisclosureGroup(isExpanded: $isEndDateExpanded) {
                            DatePicker("", selection: $endDate, displayedComponents: .date)
                                .datePickerStyle(GraphicalDatePickerStyle())
                                .padding(.vertical)
                        } label: {
                            HStack {
                                Text("结束日期:")
                                    .font(.headline)
                                Spacer()
                                Text(endDate.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    
                    // Uppercase toggle
                    Toggle("", isOn: $shouldUppercase)
                        .onChange(of: shouldUppercase) { _, newValue in
                            if newValue {
                                symbols = symbols.map { $0.uppercased() }
                            }
                        }
                    
                    // Stock symbol input fields
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<symbols.count, id: \.self) { index in
                            HStack {
                                CustomTextField(
                                    placeholder: "股票代码 \(index + 1)",
                                    text: Binding(
                                        get: { symbols[index] },
                                        set: { newValue in
                                            symbols[index] = shouldUppercase
                                                ? newValue.uppercased()
                                                : newValue
                                        }
                                    ),
                                    onClear: {
                                        focusedField = index
                                    }
                                )
                                .focused($focusedField, equals: index)
                                
                                // Remove row button
                                if symbols.count > 1 {
                                    Button {
                                        symbols.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                        }
                        
                        // "Add symbol" button
                        if symbols.count < maxSymbols {
                            Button {
                                let newIndex = symbols.count
                                symbols.append("")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    focusedField = newIndex
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("添加股票代码")
                                }
                            }
                            .foregroundColor(.blue)
                        }
                    }
                    
                    // Error message
                    if let errorMessage {
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
                if initialSymbol.isEmpty {
                    symbols.append("")
                } else {
                    symbols.append(shouldUppercase ? initialSymbol.uppercased() : initialSymbol)
                }
                symbols.append("")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    focusedField = initialSymbol.isEmpty ? 0 : 1
                }
            }
        }
        .navigationDestination(isPresented: $navigateToComparison) {
            ComparisonChartView(symbols: symbols, startDate: startDate, endDate: endDate)
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("错误"),
                  message: Text(errorMessage ?? "未知错误"),
                  dismissButton: .default(Text("确定")))
        }
    }
    
    private func startComparison() {
        errorMessage = nil
        
        let trimmedSymbols = symbols
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !trimmedSymbols.isEmpty else {
            errorMessage = "请至少输入一个股票代码"
            showAlert = true
            return
        }
        
        if trimmedSymbols.count > maxSymbols {
            errorMessage = "最多只能比较 \(maxSymbols) 个股票代码"
            showAlert = true
            return
        }
        
        guard startDate <= endDate else {
            errorMessage = "开始日期必须早于或等于结束日期"
            showAlert = true
            return
        }
        
        symbols = trimmedSymbols
        navigateToComparison = true
    }
}

// MARK: - CustomTextField
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
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .opacity(0.6)
                }
                .padding(.trailing, 8)
            }
        }
    }
}

// MARK: - ComparisonChartView
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
            } else if let errorMessage {
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
            
            // First pass: fetch data and determine the shortest date range
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
                
                let currentStart = data.first?.date ?? startDate
                let currentEnd = data.last?.date ?? endDate
                
                if let existingRange = shortestDateRange {
                    shortestDateRange = (
                        start: max(existingRange.start, currentStart),
                        end: min(existingRange.end, currentEnd)
                    )
                } else {
                    shortestDateRange = (currentStart, currentEnd)
                }
                
                tempData[symbol] = data
            }
            
            guard let dateRange = shortestDateRange else {
                DispatchQueue.main.async {
                    errorMessage = "无法确定共同的日期范围"
                    isLoading = false
                }
                return
            }
            
            // Second pass: filter data by the shortest date range
            for (symbol, data) in tempData {
                var filteredData = data.filter {
                    $0.date >= dateRange.start && $0.date <= dateRange.end
                }
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

// MARK: - Array Extension
extension Array where Element == DatabaseManager.PriceData {
    func sampled(step: Int) -> [DatabaseManager.PriceData] {
        stride(from: 0, to: count, by: step).map { self[$0] }
    }
}

// MARK: - ComparisonStockLineChartView
struct ComparisonStockLineChartView: UIViewRepresentable {
    let data: [String: [DatabaseManager.PriceData]]
    let isDarkMode: Bool
    
    func makeUIView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        chartView.delegate = context.coordinator
        
        let formatter = DateValueFormatter()
        context.coordinator.dateFormatter = formatter
        
        configureChartView(chartView)
        chartView.noDataText = "No Data Available"
        
        configureXAxis(chartView.xAxis, formatter: formatter)
        
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
        
        var dataSets = [LineChartDataSet]()
        let colors: [UIColor] = [
            .systemRed,
            .systemGreen,
            .systemBlue,
            .systemPurple,
            .systemOrange
        ]
        
        for (index, (symbol, priceData)) in data.enumerated() {
            if !priceData.isEmpty {
                let prices = priceData.map(\.price)
                guard let minPrice = prices.min(),
                      let maxPrice = prices.max()
                else { continue }
                
                let priceRange = maxPrice - minPrice
                
                // Normalize prices to 0 - 100
                let entries = priceData.map {
                    let normalizedPrice = (priceRange > 0)
                        ? (($0.price - minPrice) / priceRange) * 100
                        : 50
                    return ChartDataEntry(
                        x: $0.date.timeIntervalSince1970,
                        y: normalizedPrice
                    )
                }
                
                let dataSet = createDataSet(
                    entries: entries,
                    color: colors[index % colors.count],
                    label: symbol
                )
                dataSets.append(dataSet)
            }
        }
        
        chartView.data = LineChartData(dataSets: dataSets)
        chartView.notifyDataSetChanged()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: Coordinator
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
        
        let textColor = isDarkMode ? UIColor.white : UIColor.black
        let gridColor = isDarkMode
            ? UIColor.gray.withAlphaComponent(0.3)
            : UIColor.gray.withAlphaComponent(0.2)
        
        chartView.xAxis.labelTextColor = textColor
        chartView.leftAxis.labelTextColor = textColor
        chartView.xAxis.gridColor = gridColor
        chartView.leftAxis.gridColor = gridColor
        
        chartView.backgroundColor = isDarkMode ? .black : .white
    }
    
    private func configureXAxis(_ xAxis: XAxis, formatter: DateValueFormatter) {
        xAxis.labelPosition = .bottom
        xAxis.labelRotationAngle = 0
        xAxis.labelFont = .systemFont(ofSize: 10)
        xAxis.granularity = 3600 * 24 * 30
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
        leftAxis.axisMinimum = 0
        leftAxis.axisMaximum = 100
        leftAxis.spaceTop = 0.1
        leftAxis.spaceBottom = 0.1
        
        leftAxis.valueFormatter = DefaultAxisValueFormatter { value, _ in
            String(format: "%.1f", value)
        }
    }
    
    private func createDataSet(
        entries: [ChartDataEntry],
        color: UIColor,
        label: String
    ) -> LineChartDataSet {
        let dataSet = LineChartDataSet(entries: entries, label: label)
        dataSet.setColor(color)
        dataSet.lineWidth = 1.5
        dataSet.drawCirclesEnabled = false
        dataSet.mode = .cubicBezier
        dataSet.drawFilledEnabled = false
        dataSet.drawValuesEnabled = false
        dataSet.highlightEnabled = true
        dataSet.highlightColor = .systemRed
        dataSet.highlightLineWidth = 1
        dataSet.highlightLineDashLengths = [5, 2]
        
        let gradientColors = [
            color.withAlphaComponent(0.3).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
        
        let gradient = CGGradient(
            colorsSpace: nil,
            colors: gradientColors as CFArray,
            locations: [0.0, 1.0]
        )!
        
        dataSet.fillAlpha = 0.3
        dataSet.fill = LinearGradientFill(gradient: gradient, angle: 90)
        dataSet.drawFilledEnabled = true
        
        return dataSet
    }
}

// MARK: - DateValueFormatter
class DateValueFormatter: AxisValueFormatter {
    private let dateFormatter = DateFormatter()
    private var referenceTimespan: TimeInterval = 0
    
    init(referenceTimespan: TimeInterval = 0) {
        self.referenceTimespan = referenceTimespan
    }
    
    func stringForValue(_ value: Double, axis: AxisBase?) -> String {
        let date = Date(timeIntervalSince1970: value)
        if referenceTimespan > 365 * 24 * 3600 {
            dateFormatter.dateFormat = "yyyy"
        } else {
            dateFormatter.dateFormat = "MM/dd"
        }
        return dateFormatter.string(from: date)
    }
    
    func updateTimespan(_ timespan: TimeInterval) {
        referenceTimespan = timespan
    }
}
