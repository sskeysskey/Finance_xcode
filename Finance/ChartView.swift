import SwiftUI
import DGCharts

struct ChartView: View {
    let symbol: String
    let groupName: String
    @State private var selectedTimeRange: TimeRange = .tenYears
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var isLoading = false
    
    var body: some View {
        VStack {
            // 时间范围选择器
            Picker("Time Range", selection: $selectedTimeRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            // 图表视图
            StockLineChartView(data: chartData)
                .frame(height: 300)
                .padding()
            
            Spacer()
        }
        .navigationTitle("\(symbol) Chart")
        .onChange(of: selectedTimeRange) { oldValue, newValue in
            loadChartData()
        }
        .onAppear {
            loadChartData()
        }
        .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(1.5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.white.opacity(0.7))
                        }
                    }
                )
    }
    
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
                        self.chartData = newData
                        self.isLoading = false
                        print("数据已更新到UI")
                    }
                }
        }
}

struct StockLineChartView: UIViewRepresentable {
    let data: [DatabaseManager.PriceData]
    
    func makeUIView(context: Context) -> DGCharts.LineChartView {
        let chartView = DGCharts.LineChartView()
        
        // 基本设置
        chartView.legend.enabled = false
        chartView.rightAxis.enabled = false
        
        // 配置X轴
        chartView.xAxis.labelPosition = .bottom
        chartView.xAxis.valueFormatter = DateAxisValueFormatter()
        chartView.xAxis.labelRotationAngle = -45
        
        // 配置Y轴
        let leftAxis = chartView.leftAxis
        leftAxis.labelCount = 6
        leftAxis.drawGridLinesEnabled = true
        
        // 其他设置
        chartView.dragEnabled = true
        chartView.setScaleEnabled(true)
        chartView.pinchZoomEnabled = true
        
        return chartView
    }
    
    func updateUIView(_ chartView: DGCharts.LineChartView, context: Context) {
        // 创建数据项
        let entries = data.map { priceData -> ChartDataEntry in
            return ChartDataEntry(x: priceData.date.timeIntervalSince1970,
                                y: priceData.price)
        }
        
        // 创建数据集
        let dataSet = LineChartDataSet(entries: entries, label: "Price")
        
        // 配置数据集样式
        dataSet.drawCirclesEnabled = false
        dataSet.mode = .cubicBezier
        dataSet.lineWidth = 2
        dataSet.setColor(NSUIColor.systemBlue)
        dataSet.fillColor = NSUIColor.systemBlue
        dataSet.fillAlpha = 0.1
        dataSet.drawFilledEnabled = true
        dataSet.drawValuesEnabled = false
        
        // 设置数据
        let lineChartData = LineChartData(dataSet: dataSet)
        chartView.data = lineChartData
        
        // 动画
        chartView.animate(xAxisDuration: 0.5)
    }
}

class DateAxisValueFormatter: AxisValueFormatter {
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
