import SwiftUI
import DGCharts

// MARK: - TimeRange Enum
enum TimeRange: String, CaseIterable {
    case oneMonth = "1 Month"
    case threeMonths = "3 Months"
    case sixMonths = "6 Months"
    case oneYear = "1 Year"
    case twoYears = "2 Years"
    case fiveYears = "5 Years"
    case tenYears = "10 Years"
    
    var startDate: Date {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .oneMonth:   return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:   return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear:     return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .twoYears:    return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:   return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:    return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        }
    }
}

// MARK: - ChartView
struct ChartView: View {
    // MARK: - Properties
    let symbol: String
    let groupName: String
    
    @State private var selectedTimeRange: TimeRange = .tenYears
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var isLoading = false
    
    // MARK: - Body
    var body: some View {
        VStack {
            timeRangePicker
            chartView
            Spacer()
        }
        .navigationTitle("\(symbol) Chart")
        .onChange(of: selectedTimeRange) { _, _ in loadChartData() }
        .onAppear { loadChartData() }
        .overlay(loadingOverlay)
    }
    
    // MARK: - View Components
    private var timeRangePicker: some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding()
    }
    
    private var chartView: some View {
        StockLineChartView(data: chartData)
            .frame(height: 300)
            .padding()
    }
    
    private var loadingOverlay: some View {
        Group {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.7))
            }
        }
    }
    
    // MARK: - Methods
    private func loadChartData() {
        print("=== ChartView Debug ===")
        print("开始加载图表数据")
        print("Symbol: \(symbol)")
        print("GroupName: \(groupName)")
        print("TimeRange: \(selectedTimeRange)")
        
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
    // MARK: - Properties
    let data: [DatabaseManager.PriceData]
    
    // MARK: - UIViewRepresentable
    func makeUIView(context: Context) -> LineChartView {
        let chartView = LineChartView()
        configureChartView(chartView)
        return chartView
    }
    
    func updateUIView(_ chartView: LineChartView, context: Context) {
        updateChartData(chartView)
    }
    
    // MARK: - Configuration Methods
    private func configureChartView(_ chartView: LineChartView) {
        chartView.legend.enabled = false
        chartView.rightAxis.enabled = false
        
        configureXAxis(chartView.xAxis)
        configureYAxis(chartView.leftAxis)
        
        chartView.dragEnabled = true
        chartView.setScaleEnabled(true)
        chartView.pinchZoomEnabled = true
    }
    
    private func configureXAxis(_ xAxis: XAxis) {
        xAxis.labelPosition = .bottom
        xAxis.valueFormatter = DateAxisValueFormatter()
        xAxis.labelRotationAngle = -45
    }
    
    private func configureYAxis(_ leftAxis: YAxis) {
        leftAxis.labelCount = 6
        leftAxis.drawGridLinesEnabled = true
    }
    
    private func updateChartData(_ chartView: LineChartView) {
        let entries = data.map { ChartDataEntry(x: $0.date.timeIntervalSince1970, y: $0.price) }
        let dataSet = createDataSet(entries: entries)
        
        chartView.data = LineChartData(dataSet: dataSet)
        chartView.animate(xAxisDuration: 0.5)
    }
    
    private func createDataSet(entries: [ChartDataEntry]) -> LineChartDataSet {
        let dataSet = LineChartDataSet(entries: entries, label: "Price")
        
        dataSet.drawCirclesEnabled = false
        dataSet.mode = .cubicBezier
        dataSet.lineWidth = 2
        dataSet.setColor(NSUIColor.systemBlue)
        dataSet.fillColor = NSUIColor.systemBlue
        dataSet.fillAlpha = 0.1
        dataSet.drawFilledEnabled = true
        dataSet.drawValuesEnabled = false
        
        return dataSet
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
