import SwiftUI
import Combine

// MARK: - 时间间隔切换
enum TimeRange {
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case all
    case twoYears
    case fiveYears
    case tenYears
    
    var title: String {
        switch self {
        case .oneMonth: return "1M"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .all: return "All"
        case .twoYears: return "2Y"
        case .fiveYears: return "5Y"
        case .tenYears: return "10Y"
        
        }
    }
    
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
        case .all:
            return calendar.date(byAdding: .year, value: -100, to: now) ?? now
        case .twoYears:
            return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:
            return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        }
    }
    
    func xAxisTickInterval() -> Calendar.Component {
        switch self {
        case .oneMonth:
            return .day
        case .threeMonths, .sixMonths:
            return .month
        case .oneYear:
            return .month
        case .twoYears, .fiveYears, .tenYears:
            return .year
        case .all:
            return .year
        }
    }
    
    func xAxisTickValue() -> Int {
        switch self {
        case .oneMonth:
            return 2 // 每2天一个刻度
        case .threeMonths:
            return 1 // 每1个月一个刻度
        case .sixMonths:
            return 1 // 每1个月一个刻度
        case .oneYear:
            return 1 // 每1个月一个刻度
        case .twoYears, .fiveYears, .tenYears:
            return 1 // 每1年一个刻度
        case .all:
            return 3 // 每3年一个刻度
        }
    }
    
    // 添加采样率控制，优化长期数据加载
    func samplingRate() -> Int {
        switch self {
        case .oneMonth, .threeMonths, .sixMonths, .oneYear:
            return 1 // 不采样，使用所有数据点
        case .twoYears:
            return 2 // 每2个数据点取1个
        case .fiveYears:
            return 5 // 每5个数据点取1个
        case .tenYears:
            return 10 // 每10个数据点取1个
        case .all:
            return 15 // 每15个数据点取1个
        }
    }
}

// MARK: - 页面布局
struct ChartView: View {
    let symbol: String
    let groupName: String
    
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var sampledChartData: [DatabaseManager.PriceData] = [] // 采样后的数据
    @State private var selectedTimeRange: TimeRange = .oneYear
    @State private var isLoading = true
    
    @State private var earningData: [DatabaseManager.EarningData] = []
    
    // 单指滑动状态
    @State private var dragLocation: CGPoint?
    @State private var draggedPointIndex: Int?
    @State private var draggedPoint: DatabaseManager.PriceData?
    @State private var isDragging = false
    
    // 双指滑动状态
    @State private var isMultiTouch = false
    @State private var firstTouchLocation: CGPoint?
    @State private var secondTouchLocation: CGPoint?
    @State private var firstTouchPointIndex: Int?
    @State private var secondTouchPointIndex: Int?
    @State private var firstTouchPoint: DatabaseManager.PriceData?
    @State private var secondTouchPoint: DatabaseManager.PriceData?
    
    // 标记点显示控制
    @State private var showRedMarkers: Bool = false     // 全局标记(红色)默认关闭
    @State private var showOrangeMarkers: Bool = true   // 股票特定标记(橙色)默认开启
    @State private var showBlueMarkers: Bool = true     // 财报标记(蓝色)默认开启
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var dataService: DataService
    
    // 页面配置
    private var isDarkMode: Bool {
        colorScheme == .dark
    }
    
    private var chartColor: Color {
        isDarkMode ? Color.white : Color.blue
    }
    
    private var backgroundColor: Color {
        isDarkMode ? Color.black : Color.white
    }
    
    private var minPrice: Double {
        sampledChartData.map { $0.price }.min() ?? 0
    }
    
    private var maxPrice: Double {
        sampledChartData.map { $0.price }.max() ?? 0
    }
    
    private var priceRange: Double {
        max(maxPrice - minPrice, 0.01) // 避免除零
    }
    
    // 计算两点之间的价格变化百分比
    private var priceDifferencePercentage: Double? {
        guard let first = firstTouchPoint?.price,
              let second = secondTouchPoint?.price else {
            return nil
        }
        
        return ((second - first) / first) * 100.0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 固定高度的信息显示区域
            VStack {
                // 事件文本或时间价格信息区域
                ZStack(alignment: .top) {
                    // 背景空白区域，保持固定高度
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 80) // 固定三行文本的高度
                    
                    VStack {
                        if isMultiTouch, let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                            // 双指模式：显示两点的信息和价格变化百分比
                            let firstDate = formatDate(firstPoint.date)
                            let secondDate = formatDate(secondPoint.date)
                            let percentChange = priceDifferencePercentage ?? 0
                            
                            HStack {
                                Text("\(firstDate)")
                                    .font(.system(size: 16, weight: .medium))
                                Text("\(secondDate)")
                                    .font(.system(size: 16, weight: .medium))
                                Text("\(formatPercentage(percentChange))")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(percentChange >= 0 ? .green : .red)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(8)
                            
                        } else if let point = draggedPoint {
                            // 单指模式：显示单点信息和标记
                            let pointDate = formatDate(point.date)
                            
                            // 计算价格变化百分比
                            let percentChange = calculatePriceChangePercentage(from: point)
                            
                            HStack {
                                Text("\(pointDate)  \(formatPrice(point.price))")
                                    .font(.system(size: 16, weight: .medium))
                                
                                if let percentChange = percentChange {
                                    Text(formatPercentage(percentChange))
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(percentChange >= 0 ? .green : .red)
                                }
                                
                                // 显示全局或特定标记信息
                                if let markerText = getMarkerText(for: point.date) {
                                    Spacer()
                                    Text(markerText)
                                        .font(.system(size: 14))
                                        .foregroundColor(.orange)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                }
            }
            
            // Chart
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
                    .frame(height: 250) // 固定高度与图表一致
            } else if sampledChartData.isEmpty {
                Text("No data available")
                    .font(.title2)
                    .foregroundColor(.gray)
                    .frame(height: 250) // 固定高度与图表一致
            } else {
                // Chart canvas
                ZStack {
                    GeometryReader { geometry in
                        // 绘制零线 - 当最低值小于 0 时，我们确保图表上方包含 0
                        if minPrice < 0 {
                            // 使用 0 作为上边界（如果所有值都是负的，maxPrice 就替换为 0）
                            let effectiveMaxPrice = max(maxPrice, 0)
                            let effectiveRange = effectiveMaxPrice - minPrice
                            let zeroY = geometry.size.height - CGFloat((0 - minPrice) / effectiveRange) * geometry.size.height
                            
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: zeroY))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: zeroY))
                            }
                            .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        }
                        
                        // 绘制价格线
                        Path { path in
                            let width = geometry.size.width
                            let height = geometry.size.height
                            let horizontalStep = width / CGFloat(max(1, sampledChartData.count - 1))
                            
                            if let firstPoint = sampledChartData.first {
                                let firstX = 0.0
                                let firstY = height - CGFloat((firstPoint.price - minPrice) / priceRange) * height
                                path.move(to: CGPoint(x: firstX, y: firstY))
                                
                                for i in 1..<sampledChartData.count {
                                    let x = CGFloat(i) * horizontalStep
                                    let y = height - CGFloat((sampledChartData[i].price - minPrice) / priceRange) * height
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(chartColor, lineWidth: 2)
                        
                        // 绘制 X 轴刻度
                        ForEach(getXAxisTicks(), id: \.self) { date in
                            if let index = getIndexForDate(date) {
                                let x = CGFloat(index) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                let tickHeight: CGFloat = 5
                                
                                // 刻度线
                                Path { path in
                                    path.move(to: CGPoint(x: x, y: geometry.size.height))
                                    path.addLine(to: CGPoint(x: x, y: geometry.size.height - tickHeight))
                                }
                                .stroke(Color.gray, lineWidth: 1)
                                
                                // 刻度标签
                                Text(formatXAxisLabel(date))
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                                    .position(x: x, y: geometry.size.height + 10)
                            }
                        }
                        
                        // 绘制特殊时间点标记
                        ForEach(getTimeMarkers(), id: \.id) { marker in
                            if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, marker.date) }) {
                                // 根据标记类型和显示状态决定是否显示标记点
                                let shouldShow = (marker.type == .global && showRedMarkers) ||
                                                 (marker.type == .symbol && showOrangeMarkers) ||
                                                 (marker.type == .earning && showBlueMarkers)
                                
                                if shouldShow {
                                    let x = CGFloat(index) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                    let y = geometry.size.height - CGFloat((sampledChartData[index].price - minPrice) / priceRange) * geometry.size.height
                                    
                                    Circle()
                                        .fill(marker.color)
                                        .frame(width: 8, height: 8)
                                        .position(x: x, y: y)
                                }
                            }
                        }
                        
                        if isMultiTouch {
                            // 双指模式：绘制两条虚线
                            if let firstIndex = firstTouchPointIndex, let firstPoint = firstTouchPoint {
                                let x = CGFloat(firstIndex) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                let y = geometry.size.height - CGFloat((firstPoint.price - minPrice) / priceRange) * geometry.size.height
                                
                                // 第一条虚线
                                Path { path in
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                                }
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundColor(Color.gray)
                                
                                // 第一个点的高亮显示
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(chartColor, lineWidth: 2)
                                    )
                                    .position(x: x, y: y)
                            }
                            
                            if let secondIndex = secondTouchPointIndex, let secondPoint = secondTouchPoint {
                                let x = CGFloat(secondIndex) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                let y = geometry.size.height - CGFloat((secondPoint.price - minPrice) / priceRange) * geometry.size.height
                                
                                // 第二条虚线
                                Path { path in
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                                }
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundColor(Color.gray)
                                
                                // 第二个点的高亮显示
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(chartColor, lineWidth: 2)
                                    )
                                    .position(x: x, y: y)
                            }
                            
                            // 绘制两点之间的连线
                            if let firstIndex = firstTouchPointIndex, let secondIndex = secondTouchPointIndex,
                               let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                                let x1 = CGFloat(firstIndex) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                let y1 = geometry.size.height - CGFloat((firstPoint.price - minPrice) / priceRange) * geometry.size.height
                                let x2 = CGFloat(secondIndex) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                let y2 = geometry.size.height - CGFloat((secondPoint.price - minPrice) / priceRange) * geometry.size.height
                                
                                Path { path in
                                    path.move(to: CGPoint(x: x1, y: y1))
                                    path.addLine(to: CGPoint(x: x2, y: y2))
                                }
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [2]))
                                .foregroundColor(
                                    secondPoint.price >= firstPoint.price ? Color.green : Color.red
                                )
                            }
                        } else if let pointIndex = draggedPointIndex {
                            // 单指模式：绘制单条虚线
                            let x = CGFloat(pointIndex) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                            
                            Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundColor(Color.gray)
                            
                            // 高亮显示当前点
                            if let point = draggedPoint {
                                let y = geometry.size.height - CGFloat((point.price - minPrice) / priceRange) * geometry.size.height
                                
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(chartColor, lineWidth: 2)
                                    )
                                    .position(x: x, y: y)
                            }
                        }
                    }
                    // 使用自定义触摸处理视图以支持多指触控
                    .overlay(
                        MultiTouchHandler(
                            onSingleTouchChanged: { location in
                                isMultiTouch = false
                                updateDragLocation(location)
                            },
                            onMultiTouchChanged: { first, second in
                                isMultiTouch = true
                                updateMultiTouchLocations(first, second)
                            },
                            onTouchesEnded: {
                                // 当所有触摸结束时重置状态
                                resetTouchStates()
                            },
                            onFirstTouchEnded: {
                                // 第一个触摸结束，转为单指模式
                                isMultiTouch = false
                                // 如果第二个触摸点存在，将它设为单指模式的触摸点
                                if let secondLocation = secondTouchLocation {
                                    updateDragLocation(secondLocation)
                                }
                            },
                            onSecondTouchEnded: {
                                // 第二个触摸结束，转为单指模式
                                isMultiTouch = false
                                // 如果第一个触摸点存在，将它设为单指模式的触摸点
                                if let firstLocation = firstTouchLocation {
                                    updateDragLocation(firstLocation)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                }
                .frame(height: 250)
                .padding(.bottom, 30) // 为 X 轴标签留出空间
            }
            
            // Time range buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach([TimeRange.oneMonth, .threeMonths, .sixMonths, .oneYear, .all, .twoYears, .fiveYears, .tenYears], id: \.title) { range in
                        Button(action: {
                            selectedTimeRange = range
                            loadChartData()
                        }) {
                            Text(range.title)
                                .font(.system(size: 14, weight: selectedTimeRange == range ? .bold : .regular))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(
                                    selectedTimeRange == range ?
                                        Color.blue.opacity(0.2) :
                                        Color.clear
                                )
                                .foregroundColor(selectedTimeRange == range ? .blue : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            
            .padding(.vertical, 10)
            
            // 标记点显示控制开关
            HStack(spacing: 10) {
                // 橙色标记点(股票特定)开关
                Toggle(isOn: $showOrangeMarkers) {
                }
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                
                // 红色标记点(全局)开关
                Toggle(isOn: $showRedMarkers) {
                }
                .toggleStyle(SwitchToggleStyle(tint: .red))
                
                // 蓝色标记点(财报)开关
                Toggle(isOn: $showBlueMarkers) {
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
            }
            
            .padding(.vertical, 30)
            
            // Action buttons
            HStack(spacing: 20) {
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
                        .foregroundColor(.blue)
                }
                // Compare
                NavigationLink(destination: CompareView(initialSymbol: symbol)) {
                    Text("Compare")
                        .font(.system(size: 16, weight: .medium))
                        .padding(.leading, 20)
                        .foregroundColor(.blue)
                }
                // Similar
                NavigationLink(destination: SimilarView(symbol: symbol)) {
                    Text("Similar")
                        .font(.system(size: 16, weight: .medium))
                        .padding(.leading, 20)
                        .foregroundColor(.blue)
                }
            }
            
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            
            Spacer() // 添加Spacer让所有内容靠顶部
        }
        .background(backgroundColor.edgesIgnoringSafeArea(.all))
        .navigationBarTitle(symbol, displayMode: .inline)
        .onAppear {
            loadChartData()
        }
    }
    
    // MARK: - X轴刻度绘制
    private func getXAxisTicks() -> [Date] {
        guard !sampledChartData.isEmpty else { return [] }
        
        var ticks: [Date] = []
        let calendar = Calendar.current
        let component = selectedTimeRange.xAxisTickInterval()
        let interval = selectedTimeRange.xAxisTickValue()
        
        if let startDate = sampledChartData.first?.date, let endDate = sampledChartData.last?.date {
            var currentDate = startDate
            
            while currentDate <= endDate {
                ticks.append(currentDate)
                if let nextDate = calendar.date(byAdding: component, value: interval, to: currentDate) {
                    currentDate = nextDate
                } else {
                    break
                }
            }
            // 如果最后一次生成的日期与 endDate 不在同一天（或同月/同年，取决于 granularity），则补充 endDate
            if let lastTick = ticks.last, !calendar.isDate(lastTick, equalTo: endDate, toGranularity: tickGranularity()) {
                ticks.append(endDate)
            }
        }
        
        return ticks
    }

    // 根据时间区间确定刻度的比较精度
    private func tickGranularity() -> Calendar.Component {
        switch selectedTimeRange {
        case .oneMonth:
            return .day
        case .threeMonths, .sixMonths, .oneYear:
            return .month
        case .twoYears, .fiveYears, .tenYears, .all:
            return .year
        }
    }
    
    // 计算价格变化百分比
    private func calculatePriceChangePercentage(from point: DatabaseManager.PriceData) -> Double? {
        guard let latestPrice = sampledChartData.last?.price else { return nil }
        return ((latestPrice - point.price) / point.price) * 100.0
    }
    
    // MARK: - Helper Methods
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
            
            // 获取财报数据
            let earnings = DatabaseManager.shared.fetchEarningData(forSymbol: symbol)
            print("获取到 \(earnings.count) 条财报数据")
            
            // 对长期数据进行采样，提高性能
            let sampledData = sampleData(newData, rate: selectedTimeRange.samplingRate())
            print("采样后数据点数: \(sampledData.count)")

            DispatchQueue.main.async {
                chartData = newData
                sampledChartData = sampledData
                earningData = earnings
                isLoading = false
                // 重置触摸状态
                resetTouchStates()
                print("数据已更新到UI")
            }
        }
    }
    
    // 重置所有触摸状态
    private func resetTouchStates() {
        // 重置单指状态
        dragLocation = nil
        draggedPointIndex = nil
        draggedPoint = nil
        isDragging = false
        
        // 重置双指状态
        isMultiTouch = false
        firstTouchLocation = nil
        secondTouchLocation = nil
        firstTouchPointIndex = nil
        secondTouchPointIndex = nil
        firstTouchPoint = nil
        secondTouchPoint = nil
    }
    
    // 数据采样函数，用于优化大量数据的显示
    private func sampleData(_ data: [DatabaseManager.PriceData], rate: Int) -> [DatabaseManager.PriceData] {
        guard rate > 1, !data.isEmpty else { return data }
        
        var result: [DatabaseManager.PriceData] = []
        
        // 始终包含第一个和最后一个点
        if let first = data.first {
            result.append(first)
        }
        
        // 按采样率添加中间点
        for i in stride(from: rate, to: data.count - 1, by: rate) {
            result.append(data[i])
        }
        
        // 添加最后一个点
        if let last = data.last, result.last?.id != last.id {
            result.append(last)
        }
        
        return result
    }
    
    // 从触摸位置计算数据索引
    private func getIndexFromLocation(_ location: CGPoint) -> Int {
        guard !sampledChartData.isEmpty else { return 0 }
        
        let width = UIScreen.main.bounds.width
        let horizontalStep = width / CGFloat(max(1, sampledChartData.count - 1))
        
        // 计算相对位置
        let relativeX = location.x
        
        // 特殊处理最后一个点的情况
        if relativeX >= width - horizontalStep {
            return sampledChartData.count - 1
        }
        
        // 其他位置的正常计算
        let index = Int(round(relativeX / horizontalStep))
        return min(sampledChartData.count - 1, max(0, index))
    }
    
    // 更新单指拖动状态
    private func updateDragLocation(_ location: CGPoint) {
        guard !sampledChartData.isEmpty else { return }
        
        let index = getIndexFromLocation(location)
        
        dragLocation = location
        draggedPointIndex = index
        draggedPoint = sampledChartData[safe: index]
        isDragging = true
    }
    
    // 更新双指触摸状态
    private func updateMultiTouchLocations(_ first: CGPoint, _ second: CGPoint) {
        guard !sampledChartData.isEmpty else { return }
        
        let firstIndex = getIndexFromLocation(first)
        let secondIndex = getIndexFromLocation(second)
        
        firstTouchLocation = first
        secondTouchLocation = second
        firstTouchPointIndex = firstIndex
        secondTouchPointIndex = secondIndex
        firstTouchPoint = sampledChartData[safe: firstIndex]
        secondTouchPoint = sampledChartData[safe: secondIndex]
    }
    
    // 修改TimeMarker结构
    private enum MarkerType {
        case global // 红点
        case symbol // 橙色点
        case earning // 蓝点
    }

    private struct TimeMarker: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let type: MarkerType
        
        var color: Color {
            switch type {
            case .global: return .red
            case .symbol: return .orange
            case .earning: return .blue
            }
        }
    }
    
    private func getTimeMarkers() -> [TimeMarker] {
        var markers: [TimeMarker] = []
        
        // 添加全局时间标记
        for (date, text) in dataService.globalTimeMarkers {
            if sampledChartData.contains(where: { isSameDay($0.date, date) }) {
                markers.append(TimeMarker(date: date, text: text, type: .global))
            }
        }
        
        // 添加特定股票的时间标记
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, text) in symbolMarkers {
                if sampledChartData.contains(where: { isSameDay($0.date, date) }) {
                    markers.append(TimeMarker(date: date, text: text, type: .symbol))
                }
            }
        }
        
        // 添加财报数据标记
        for earning in earningData {
            if sampledChartData.contains(where: { isSameDay($0.date, earning.date) }) {
                // 将价格转换为字符串作为标记文本
                let earningText = String(format: "%.2f", earning.price)
                markers.append(TimeMarker(date: earning.date, text: earningText, type: .earning))
            }
        }
        
        return markers
    }
    
    private func getMarkerText(for date: Date) -> String? {
        // 检查全局标记，只有在显示红色标记的情况下返回
        if showRedMarkers, let text = dataService.globalTimeMarkers.first(where: { isSameDay($0.key, date) })?.value {
            return text
        }
        
        // 检查特定股票标记，只有在显示橙色标记的情况下返回
        if showOrangeMarkers, let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()],
           let text = symbolMarkers.first(where: { isSameDay($0.key, date) })?.value {
            return text
        }
        
        // 检查财报数据标记，只有在显示蓝色标记的情况下返回
        if showBlueMarkers, let earningPoint = earningData.first(where: { isSameDay($0.date, date) }) {
            return String(format: "%.2f", earningPoint.price)
        }
        
        return nil
    }
    
    // 格式化方法
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func formatPrice(_ price: Double) -> String {
        return String(format: "%.2f", price)
    }
    
    private func formatPercentage(_ value: Double) -> String {
        return String(format: "%.2f%%", value)
    }
    
    private func formatXAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        switch selectedTimeRange {
        case .oneMonth:
            formatter.dateFormat = "dd"
        case .threeMonths, .sixMonths, .oneYear:
            formatter.dateFormat = "MMM"
        case .twoYears, .fiveYears, .tenYears, .all:
            formatter.dateFormat = "yyyy"
        }
        
        return formatter.string(from: date)
    }
    
    // 日期比较方法
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.isDate(date1, inSameDayAs: date2)
    }
    
    private func getIndexForDate(_ date: Date) -> Int? {
        return sampledChartData.firstIndex { priceData in
            let calendar = Calendar.current
            
            switch selectedTimeRange {
            case .oneMonth:
                return calendar.isDate(priceData.date, inSameDayAs: date)
            case .threeMonths, .sixMonths, .oneYear:
                return calendar.isDate(priceData.date, equalTo: date, toGranularity: .month)
            case .twoYears, .fiveYears, .tenYears, .all:
                return calendar.isDate(priceData.date, equalTo: date, toGranularity: .year)
            }
        }
    }
}

// MARK: - 多触控处理视图
struct MultiTouchHandler: UIViewRepresentable {
    var onSingleTouchChanged: (CGPoint) -> Void
    var onMultiTouchChanged: (CGPoint, CGPoint) -> Void
    var onTouchesEnded: () -> Void
    var onFirstTouchEnded: () -> Void
    var onSecondTouchEnded: () -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = MultitouchView()
        view.onSingleTouchChanged = onSingleTouchChanged
        view.onMultiTouchChanged = onMultiTouchChanged
        view.onTouchesEnded = onTouchesEnded
        view.onFirstTouchEnded = onFirstTouchEnded
        view.onSecondTouchEnded = onSecondTouchEnded
        view.backgroundColor = .clear
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // 不需要更新
    }
    
    class MultitouchView: UIView {
        var onSingleTouchChanged: ((CGPoint) -> Void)?
        var onMultiTouchChanged: ((CGPoint, CGPoint) -> Void)?
        var onTouchesEnded: (() -> Void)?
        var onFirstTouchEnded: (() -> Void)?
        var onSecondTouchEnded: (() -> Void)?
        
        private var firstTouch: UITouch?
        private var secondTouch: UITouch?
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            
            if firstTouch == nil {
                firstTouch = touch
                updateTouches()
            } else if secondTouch == nil {
                secondTouch = touch
                updateTouches()
            }
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            updateTouches()
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            // 不管哪个触控点结束，都重置所有触控状态，确保多指模式清空
            firstTouch = nil
            secondTouch = nil
            onTouchesEnded?()
            updateTouches()
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            firstTouch = nil
            secondTouch = nil
            onTouchesEnded?()
        }
        
        private func updateTouches() {
            if let first = firstTouch, let second = secondTouch {
                // 双指触摸
                let firstLocation = first.location(in: self)
                let secondLocation = second.location(in: self)
                onMultiTouchChanged?(firstLocation, secondLocation)
            } else if let first = firstTouch {
                // 单指触摸
                let location = first.location(in: self)
                onSingleTouchChanged?(location)
            }
        }
    }
}

// MARK: - 数组安全索引扩展
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
