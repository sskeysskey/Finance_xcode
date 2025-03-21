import SwiftUI
import Combine

// MARK: - TimeRange
enum TimeRange {
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case twoYears
    case fiveYears
    case tenYears
    case all
    
    var title: String {
        switch self {
        case .oneMonth: return "1M"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .twoYears: return "2Y"
        case .fiveYears: return "5Y"
        case .tenYears: return "10Y"
        case .all: return "All"
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
        case .twoYears:
            return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:
            return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        case .all:
            return calendar.date(byAdding: .year, value: -100, to: now) ?? now
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

// MARK: - ChartView
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
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var dataService: DataService
    
    // MARK: - Computed Properties
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
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Chart header with drag information
            VStack {
                if isMultiTouch, let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                    // 双指模式：显示两点的信息和价格变化百分比
                    let firstDate = formatDate(firstPoint.date)
                    let secondDate = formatDate(secondPoint.date)
                    let percentChange = priceDifferencePercentage ?? 0
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(firstDate): \(formatPrice(firstPoint.price))")
                                .font(.system(size: 16, weight: .medium))
                            Text("\(secondDate): \(formatPrice(secondPoint.price))")
                                .font(.system(size: 16, weight: .medium))
                            Text("Change: \(formatPercentage(percentChange))")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(percentChange >= 0 ? .green : .red)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
                    
                    // 空白占位
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 40)
                } else if let point = draggedPoint {
                    // 单指模式：显示单点信息和标记
                    let pointDate = formatDate(point.date)
                    
                    HStack {
                        Text("\(pointDate): \(formatPrice(point.price))")
                            .font(.system(size: 16, weight: .medium))
                        
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
                    
                    // 空白占位
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 40)
                }
            }
            .padding(.horizontal)
            
            // Chart
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
                    .frame(maxHeight: .infinity)
            } else if sampledChartData.isEmpty {
                Text("No data available")
                    .font(.title2)
                    .foregroundColor(.gray)
                    .frame(maxHeight: .infinity)
            } else {
                // Chart canvas
                ZStack {
                    GeometryReader { geometry in
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
                        if !isMultiTouch { // 只在单指模式下显示标记
                            ForEach(getTimeMarkers(), id: \.id) { marker in
                                if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, marker.date) }) {
                                    let x = CGFloat(index) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                    let y = geometry.size.height - CGFloat((sampledChartData[index].price - minPrice) / priceRange) * geometry.size.height
                                    
                                    Circle()
                                        .fill(marker.color) // 使用标记的颜色属性
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
                .padding(.top, 20)
                .padding(.bottom, 30) // 为 X 轴标签留出空间
            }
            
            // Time range buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach([TimeRange.oneMonth, .threeMonths, .sixMonths, .oneYear, .twoYears, .fiveYears, .tenYears, .all], id: \.title) { range in
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
                .padding(.bottom, 8)
            }
            
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
            .padding(.vertical, 16)
        }
        .padding(.top)
        .background(backgroundColor.edgesIgnoringSafeArea(.all))
        .navigationBarTitle(symbol, displayMode: .inline)
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: Button(action: {
            presentationMode.wrappedValue.dismiss()
        }) {
            Image(systemName: "chevron.left")
                .foregroundColor(.blue)
            Text("Back")
                .foregroundColor(.blue)
        })
        .onAppear {
            loadChartData()
        }
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
        return min(sampledChartData.count - 1, max(0, Int(location.x / horizontalStep)))
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
                let earningText = String(format: "Earnings: %.2f", earning.price)
                markers.append(TimeMarker(date: earning.date, text: earningText, type: .earning))
            }
        }
        
        return markers
    }
    
    private func getMarkerText(for date: Date) -> String? {
        // 检查全局标记
        if let text = dataService.globalTimeMarkers.first(where: { isSameDay($0.key, date) })?.value {
            return text
        }
        
        // 检查特定股票标记
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()],
           let text = symbolMarkers.first(where: { isSameDay($0.key, date) })?.value {
            return text
        }
        
        // 检查财报数据标记
        if let earningPoint = earningData.first(where: { isSameDay($0.date, date) }) {
            return String(format: "Earnings: %.2f", earningPoint.price)
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
        return String(format: "$%.2f", price)
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
    
    // 根据时间范围获取X轴刻度
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
                
                // 添加下一个刻度
                if let nextDate = calendar.date(byAdding: component, value: interval, to: currentDate) {
                    currentDate = nextDate
                } else {
                    break
                }
            }
        }
        
        return ticks
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
            if touches.contains(where: { $0 == firstTouch }) {
                // 第一个手指离开
                if secondTouch != nil {
                    // 如果第二个手指仍在，将其设为第一个
                    firstTouch = secondTouch
                    secondTouch = nil
                    onFirstTouchEnded?()
                } else {
                    // 如果没有第二个手指，则结束所有触摸
                    firstTouch = nil
                    onTouchesEnded?()
                }
            } else if touches.contains(where: { $0 == secondTouch }) {
                // 第二个手指离开
                secondTouch = nil
                onSecondTouchEnded?()
            }
            
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

struct SectorPerformance: Codable {
    let title: String
    let performance: [SubSectorPerformance]
}

struct SubSectorPerformance: Codable, Identifiable {
    let id = UUID()
    let name: String
    let value: Double
    let color: String
    
    private enum CodingKeys: String, CodingKey {
        case name, value, color
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(Double.self, forKey: .value)
        color = try container.decode(String.self, forKey: .color)
    }
    
    init(name: String, value: Double, color: String) {
        self.name = name
        self.value = value
        self.color = color
    }
}
