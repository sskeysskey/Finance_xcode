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
            return 2 // 每3年一个刻度
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

// 1. 首先添加一个气泡视图组件
struct BubbleView: View {
    let text: String
    let color: Color
    let pointX: CGFloat
    let pointY: CGFloat
    
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(8)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(8)
            .overlay(
                // 添加小三角形指向特殊点
                GeometryReader { geo in
                    Path { path in
                        let width = geo.size.width
                        let height = geo.size.height
                        
                        path.move(to: CGPoint(x: width/2 - 5, y: height))
                        path.addLine(to: CGPoint(x: width/2, y: height + 5))
                        path.addLine(to: CGPoint(x: width/2 + 5, y: height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.2))
                }
            )
    }
}

// 2. 添加Marker结构体表示需要显示气泡的信息
struct BubbleMarker: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
    let pointIndex: Int
    let date: Date
    var position: CGPoint = .zero // 将在计算布局时设置
    var size: CGSize = .zero      // 将在计算布局时设置
}

// MARK: - 页面布局
struct ChartView: View {
    let symbol: String
    let groupName: String
    private let verticalPadding: CGFloat = 20  // 上下各20点的边距
//    private let horizontalPadding: CGFloat = 16   // 左右边距
    
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var sampledChartData: [DatabaseManager.PriceData] = [] // 采样后的数据
    @State private var selectedTimeRange: TimeRange = .sixMonths
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
    
    // 3. 在ChartView中添加状态变量存储气泡数据
    @State private var bubbleMarkers: [BubbleMarker] = []
    @State private var shouldUpdateBubbles: Bool = true
    
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
                            // 获取两个时间点
                            let date1 = firstPoint.date
                            let date2 = secondPoint.date
                            
                            // 确定显示顺序：较早的日期显示在左边
                            let (earlierDate, laterDate) = date1 < date2
                                ? (formatDate(date1), formatDate(date2))
                                : (formatDate(date2), formatDate(date1))
                            
                            // 百分比计算仍然保持原有逻辑（基于触摸顺序）
                            let percentChange = priceDifferencePercentage ?? 0
                            
                            HStack {
                                Text("\(earlierDate)")
                                    .font(.system(size: 16, weight: .medium))
                                Text("\(laterDate)")
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
                                    Text(markerText)
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.orange)
                                        .multilineTextAlignment(.leading)
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
                        // 使用 Canvas 替代 Path 提高性能
                        Canvas { context, size in
                            // 考虑边距后的实际绘制高度
                            let effectiveHeight = size.height - (verticalPadding * 2)
                            
                            // 修改所有 y 坐标计算，加入边距因素
                            let priceToY: (Double) -> CGFloat = { price in
                                let normalizedY = CGFloat((price - minPrice) / priceRange)
                                return size.height - verticalPadding - (normalizedY * effectiveHeight)
                            }
                            
                            // 绘制价格线
                            let width = size.width
                            let horizontalStep = width / CGFloat(max(1, sampledChartData.count - 1))
                            
                            var pricePath = Path()
                            if let firstPoint = sampledChartData.first {
                                let firstX = 0.0
                                let firstY = priceToY(firstPoint.price)
                                pricePath.move(to: CGPoint(x: firstX, y: firstY))
                                
                                for i in 1..<sampledChartData.count {
                                    let x = CGFloat(i) * horizontalStep
                                    let y = priceToY(sampledChartData[i].price)
                                    pricePath.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                            
                            // 绘制价格线
                            context.stroke(pricePath, with: .color(chartColor), lineWidth: 2)
                            
                            // 绘制零线 - 当最低值小于 0 时
                            if minPrice < 0 {
                                let effectiveMaxPrice = max(maxPrice, 0)
                                let effectiveRange = effectiveMaxPrice - minPrice
                                let zeroY = size.height - verticalPadding - CGFloat((0 - minPrice) / effectiveRange) * effectiveHeight
                                
                                var zeroPath = Path()
                                zeroPath.move(to: CGPoint(x: 0, y: zeroY))
                                zeroPath.addLine(to: CGPoint(x: width, y: zeroY))
                                
                                context.stroke(zeroPath, with: .color(Color.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            }
                            
                            // 绘制标记点
                            for marker in getTimeMarkers() {
                                if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, marker.date) }) {
                                    let shouldShow = (marker.type == .global && showRedMarkers) ||
                                                   (marker.type == .symbol && showOrangeMarkers) ||
                                                   (marker.type == .earning && showBlueMarkers)
                                    
                                    if shouldShow {
                                        let x = CGFloat(index) * horizontalStep
                                        let y = priceToY(sampledChartData[index].price)
                                        
                                        let markerPath = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                                        context.fill(markerPath, with: .color(marker.color))
                                    }
                                }
                            }
                            
                            // 触摸指示器相关绘制也需要使用新的 y 坐标计算方式
                            if isMultiTouch {
                                // 第一个触摸点
                                if let firstIndex = firstTouchPointIndex, let firstPoint = firstTouchPoint {
                                    let x = CGFloat(firstIndex) * horizontalStep
                                    let y = priceToY(firstPoint.price)
                                    
                                    // 第一条虚线
                                    var linePath = Path()
                                    linePath.move(to: CGPoint(x: x, y: verticalPadding))
                                    linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
                                    context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    
                                    // 第一个点的高亮显示
                                    let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                                    context.fill(circlePath, with: .color(Color.white))
                                    context.stroke(circlePath, with: .color(chartColor), lineWidth: 2)
                                }
                                
                                // 第二个触摸点
                                if let secondIndex = secondTouchPointIndex, let secondPoint = secondTouchPoint {
                                    let x = CGFloat(secondIndex) * horizontalStep
                                    let y = priceToY(secondPoint.price)  // 使用 priceToY 函数
                                    
                                    // 第二条虚线
                                    var linePath = Path()
                                    linePath.move(to: CGPoint(x: x, y: 0))
                                    linePath.addLine(to: CGPoint(x: x, y: verticalPadding))
                                    linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
                                    context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    
                                    // 第二个点的高亮显示
                                    let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                                    context.fill(circlePath, with: .color(Color.white))
                                    context.stroke(circlePath, with: .color(chartColor), lineWidth: 2)
                                }
                                
                                // 绘制两点之间的连线
                                if let firstIndex = firstTouchPointIndex, let secondIndex = secondTouchPointIndex,
                                   let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                                    let x1 = CGFloat(firstIndex) * horizontalStep
                                    let y1 = priceToY(firstPoint.price)  // 使用 priceToY 函数
                                    let x2 = CGFloat(secondIndex) * horizontalStep
                                    let y2 = priceToY(secondPoint.price)  // 使用 priceToY 函数
                                    
                                    var connectPath = Path()
                                    connectPath.move(to: CGPoint(x: x1, y: y1))
                                    connectPath.addLine(to: CGPoint(x: x2, y: y2))
                                    
                                    let lineColor = secondPoint.price >= firstPoint.price ? Color.green : Color.red
                                    context.stroke(connectPath, with: .color(lineColor), style: StrokeStyle(lineWidth: 1, dash: [2]))
                                }
                            } else if let pointIndex = draggedPointIndex {
                                let x = CGFloat(pointIndex) * horizontalStep
                                
                                var linePath = Path()
                                linePath.move(to: CGPoint(x: x, y: verticalPadding))
                                linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
                                context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                
                                if let point = draggedPoint {
                                    let y = priceToY(point.price)
                                    
                                    let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                                    context.fill(circlePath, with: .color(Color.white))
                                    context.stroke(circlePath, with: .color(chartColor), lineWidth: 2)
                                }
                            }
                        }
                        
                        // 添加以下代码显示气泡
                        .overlay(
                            ZStack {
                                // 只在不拖动的情况下显示气泡
                                if !isDragging && !isMultiTouch {
                                    ForEach(bubbleMarkers) { marker in
                                        if (marker.color == .red && showRedMarkers) ||
                                           (marker.color == .orange && showOrangeMarkers) ||
                                           (marker.color == .blue && showBlueMarkers) {
                                            BubbleView(
                                                text: marker.text,
                                                color: marker.color,
                                                pointX: marker.position.x,
                                                pointY: marker.position.y
                                            )
                                            .frame(width: marker.size.width)
                                            .position(x: marker.position.x, y: marker.position.y - 40) // 气泡位于点上方
                                            .opacity(0.9)
                                            .transition(.opacity)
                                            .animation(.easeInOut(duration: 0.3), value: marker.id)
                                        }
                                    }
                                }
                            }
                        )
                        
                        // X轴标签独立绘制，避免在Canvas内部绘制文本
                        ForEach(getXAxisTicks(), id: \.self) { date in
                            if let index = getIndexForDate(date) {
                                let x = CGFloat(index) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                Text(formatXAxisLabel(date))
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                                    .position(x: x, y: geometry.size.height + 10)
                            }
                        }
                    }
                    .overlay(
                        // 2. 优化触摸处理视图
                        OptimizedTouchHandler(
                            onSingleTouchChanged: { location in
                                // 使用防抖动技术减少过于频繁的更新
                                withAnimation(.easeOut(duration: 0.1)) {
                                    isMultiTouch = false
                                    updateDragLocation(location)
                                }
                            },
                            onMultiTouchChanged: { first, second in
                                withAnimation(.easeOut(duration: 0.1)) {
                                    isMultiTouch = true
                                    updateMultiTouchLocations(first, second)
                                }
                            },
                            onTouchesEnded: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    resetTouchStates()
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                }
                .frame(height: 320)
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text(symbol)
                        .font(.headline)
                    
                    if let marketCapItem = dataService.marketCapData[symbol.uppercased()] {
                        Text(marketCapItem.marketCap)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if let peRatio = marketCapItem.peRatio {
                            Text("\(String(format: "%.2f", peRatio))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let compareStock = dataService.compareData[symbol.uppercased()] {
                        Text(compareStock)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline) // 保持导航栏标题显示为居中
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
                // 添加调用更新气泡
                updateBubbleMarkers()
                print("数据已更新到UI")
            }
        }
    }
    
    // 添加气泡布局计算方法
    private func updateBubbleMarkers() {
        let width = UIScreen.main.bounds.width
        let horizontalStep = width / CGFloat(max(1, sampledChartData.count - 1))
        let maxLabelWidth: CGFloat = 120 // 气泡最大宽度
        
        var markers: [BubbleMarker] = []
        
        // 添加全局标记(红色)
        for (date, text) in dataService.globalTimeMarkers {
            if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, date) }) {
                let x = CGFloat(index) * horizontalStep
                let y = getYForPrice(sampledChartData[index].price)
                
                markers.append(BubbleMarker(
                    text: text,
                    color: .red,
                    pointIndex: index,
                    date: date,
                    position: CGPoint(x: x, y: y),
                    size: CGSize(width: min(max(text.count * 7, 40), Int(maxLabelWidth)), height: 0)
                ))
            }
        }
        
        // 添加股票特定标记(橙色)
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, text) in symbolMarkers {
                if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, date) }) {
                    let x = CGFloat(index) * horizontalStep
                    let y = getYForPrice(sampledChartData[index].price)
                    
                    markers.append(BubbleMarker(
                        text: text,
                        color: .orange,
                        pointIndex: index,
                        date: date,
                        position: CGPoint(x: x, y: y),
                        size: CGSize(width: min(max(text.count * 7, 40), Int(maxLabelWidth)), height: 0)
                    ))
                }
            }
        }
        
        // 添加财报标记(蓝色)
        for earning in earningData {
            if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, earning.date) }) {
                let x = CGFloat(index) * horizontalStep
                let y = getYForPrice(sampledChartData[index].price)
                
                // 财报显示格式
                let text = "财报: \(String(format: "%.2f%%", earning.price))"
                
                markers.append(BubbleMarker(
                    text: text,
                    color: .blue,
                    pointIndex: index,
                    date: earning.date,
                    position: CGPoint(x: x, y: y),
                    size: CGSize(width: min(max(text.count * 7, 40), Int(maxLabelWidth)), height: 0)
                ))
            }
        }
        
        // 优化气泡布局以减少重叠
        let optimizedMarkers = optimizeBubbleLayout(markers, canvasWidth: width, canvasHeight: 320)
        
        withAnimation {
            self.bubbleMarkers = optimizedMarkers
        }
    }
    
    // 计算给定价格对应的Y坐标
    private func getYForPrice(_ price: Double) -> CGFloat {
        // 考虑上下边距，这里假设verticalPadding = 20
        let height: CGFloat = 320 // 与Chart高度保持一致
        let effectiveHeight = height - (verticalPadding * 2)
        let normalizedY = CGFloat((price - minPrice) / priceRange)
        return height - verticalPadding - (normalizedY * effectiveHeight)
    }

    // 气泡布局优化算法
    private func optimizeBubbleLayout(_ markers: [BubbleMarker], canvasWidth: CGFloat, canvasHeight: CGFloat) -> [BubbleMarker] {
        guard !markers.isEmpty else { return [] }
        
        var optimizedMarkers = markers
        
        // 首先将气泡分为上半部分和下半部分
        let midY = canvasHeight / 2
        var upperMarkers = optimizedMarkers.filter { $0.position.y <= midY }
        var lowerMarkers = optimizedMarkers.filter { $0.position.y > midY }
        
        // 按X坐标排序
        upperMarkers.sort { $0.position.x < $1.position.x }
        lowerMarkers.sort { $0.position.x < $1.position.x }
        
        // 分层排列上半部分气泡
        var layers: [[BubbleMarker]] = []
        let bubbleHeight: CGFloat = 50 // 估计气泡高度
        let bubbleSpacing: CGFloat = 10 // 水平间距
        
        for marker in upperMarkers {
            var placed = false
            
            // 尝试放入现有层
            for i in 0..<layers.count {
                if layers[i].isEmpty || (marker.position.x - layers[i].last!.position.x > layers[i].last!.size.width / 2 + bubbleSpacing) {
                    layers[i].append(marker)
                    placed = true
                    break
                }
            }
            
            // 如果无法放入现有层，创建新层
            if !placed {
                layers.append([marker])
            }
        }
        
        // 应用计算后的Y偏移
        var offsetY: CGFloat = 20 // 顶部起始偏移
        for (_, layer) in layers.enumerated() {
            for marker in layer {
                if let index = optimizedMarkers.firstIndex(where: { $0.id == marker.id }) {
                    optimizedMarkers[index].position.y = offsetY
                }
            }
            offsetY += bubbleHeight
        }
        
        // 类似处理下半部分气泡
        layers = []
        offsetY = canvasHeight - bubbleHeight
        
        for marker in lowerMarkers {
            var placed = false
            
            for i in 0..<layers.count {
                if layers[i].isEmpty || (marker.position.x - layers[i].last!.position.x > layers[i].last!.size.width / 2 + bubbleSpacing) {
                    layers[i].append(marker)
                    placed = true
                    break
                }
            }
            
            if !placed {
                layers.append([marker])
            }
        }
        
        for (_, layer) in layers.enumerated() {
            for marker in layer {
                if let index = optimizedMarkers.firstIndex(where: { $0.id == marker.id }) {
                    optimizedMarkers[index].position.y = offsetY
                }
            }
            offsetY -= bubbleHeight
        }
        
        // 调整X坐标确保气泡不超出边界
        for i in 0..<optimizedMarkers.count {
            let halfWidth = optimizedMarkers[i].size.width / 2
            if optimizedMarkers[i].position.x - halfWidth < 0 {
                optimizedMarkers[i].position.x = halfWidth
            } else if optimizedMarkers[i].position.x + halfWidth > canvasWidth {
                optimizedMarkers[i].position.x = canvasWidth - halfWidth
            }
        }
        
        return optimizedMarkers
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
        
        // 拖动结束后，如果气泡应该显示，则更新气泡
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !self.isDragging && !self.isMultiTouch {
                self.shouldUpdateBubbles = true
                self.updateBubbleMarkers()
            }
        }
    }
    
    // 4. 优化数据采样方法
    private func sampleData(_ data: [DatabaseManager.PriceData], rate: Int) -> [DatabaseManager.PriceData] {
        guard rate > 1, !data.isEmpty else { return data }
        
        // 计算数据的实际时间跨度
        let calendar = Calendar.current
        let startDate = data.first?.date ?? Date()
        let endDate = data.last?.date ?? Date()
        let components = calendar.dateComponents([.day], from: startDate, to: endDate)
        let totalDays = components.day ?? 0
        
        // 计算数据密度：时间跨度（天）/ 数据点数量
        let dataDensity = totalDays / data.count
        
        // 如果数据密度低（每个数据点间隔超过2天），则不进行采样
        if dataDensity > 2 {
            print("数据密度低 (每\(dataDensity)天一个数据点)，不进行采样")
            return data
        }
        
        // 根据实际数据跨度动态调整采样率
        var adjustedRate = rate
        
        // 根据实际数据时长调整采样率
        if selectedTimeRange == .twoYears && totalDays < 365*2 {
            // 如果选择2Y但实际数据少于2年，使用1Y的采样率(或不采样)
            adjustedRate = totalDays < 365 ? 1 : selectedTimeRange.samplingRate() / 2
        } else if selectedTimeRange == .fiveYears && totalDays < 365*5 {
            // 如果选择5Y但实际数据少于5年，逐级降低采样率
            if totalDays < 365 {
                adjustedRate = 1
            } else if totalDays < 365*2 {
                adjustedRate = TimeRange.twoYears.samplingRate()
            } else {
                adjustedRate = max(2, selectedTimeRange.samplingRate() / 2)
            }
        } else if selectedTimeRange == .tenYears && totalDays < 365*10 {
            // 如果选择10Y但实际数据少于10年，逐级降低采样率
            if totalDays < 365 {
                adjustedRate = 1
            } else if totalDays < 365*2 {
                adjustedRate = TimeRange.twoYears.samplingRate()
            } else if totalDays < 365*5 {
                adjustedRate = TimeRange.fiveYears.samplingRate()
            } else {
                adjustedRate = max(5, selectedTimeRange.samplingRate() / 2)
            }
        } else if selectedTimeRange == .all && totalDays < 365*15 {
            // 如果选择All但实际数据少于预期，逐级降低采样率
            if totalDays < 365 {
                adjustedRate = 1
            } else if totalDays < 365*2 {
                adjustedRate = TimeRange.twoYears.samplingRate()
            } else if totalDays < 365*5 {
                adjustedRate = TimeRange.fiveYears.samplingRate()
            } else if totalDays < 365*10 {
                adjustedRate = TimeRange.tenYears.samplingRate()
            } else {
                adjustedRate = max(10, selectedTimeRange.samplingRate() / 2)
            }
        }
        
        // 如果调整后的采样率为1，则直接返回原始数据
        if adjustedRate <= 1 {
            return data
        }

        var result: [DatabaseManager.PriceData] = []
        
        // 始终包含第一个点
        if let first = data.first {
            result.append(first)
        }
        
        // 获取所有特殊事件点的日期
        var specialDates: [Date] = []
        
        // 添加全局时间标记（红点）
        for (date, _) in dataService.globalTimeMarkers {
            if data.contains(where: { isSameDay($0.date, date) }) {
                specialDates.append(date)
            }
        }
        
        // 添加特定股票的时间标记（橙点）
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, _) in symbolMarkers {
                if data.contains(where: { isSameDay($0.date, date) }) {
                    specialDates.append(date)
                }
            }
        }
        
        // 添加财报数据标记（蓝点）
        for earning in earningData {
            if data.contains(where: { isSameDay($0.date, earning.date) }) {
                specialDates.append(earning.date)
            }
        }
        
        // 使用更有效的价格变化采样策略，这种方法会保留价格变化明显的点，而不仅仅是等间隔采样
        let priceChangeThreshold = 0.005 // 0.5%的价格变化阈值
        
        var lastIncludedIndex = 0
        for i in stride(from: adjustedRate, to: data.count - 1, by: adjustedRate) {
            let lastIncludedPrice = data[lastIncludedIndex].price
            let currentPrice = data[i].price
            
            // 检查当前日期是否是特殊事件点
            let isSpecialDate = specialDates.contains(where: { isSameDay(data[i].date, $0) })
            
            // 如果是特殊事件点，或价格变化超过阈值，或者按采样率正常添加
            if isSpecialDate || abs((currentPrice - lastIncludedPrice) / lastIncludedPrice) > priceChangeThreshold {
                result.append(data[i])
                lastIncludedIndex = i
            } else if i % (adjustedRate * 2) == 0 {
                // 仍然保持一定的时间间隔采样
                result.append(data[i])
                lastIncludedIndex = i
            }
        }
        
        // 添加最后一个点
        if let last = data.last, result.last?.id != last.id {
            result.append(last)
        }
        
        // 确保所有特殊事件点都被包含在结果中
        for date in specialDates {
            // 如果特殊日期的数据点尚未包含在结果中，则添加
            if !result.contains(where: { isSameDay($0.date, date) }),
               let dataPoint = data.first(where: { isSameDay($0.date, date) }) {
                result.append(dataPoint)
            }
        }
        
        // 按日期排序结果
        result.sort { $0.date < $1.date }
        
        print("原始数据点: \(data.count), 采样后数据点: \(result.count), 采样率: \(adjustedRate)")
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
            return String(format: "昨日财报\n%.2f%%", earningPoint.price)
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
// 3. 改进的多触控处理视图
// MARK: - 多触控处理视图
struct OptimizedTouchHandler: UIViewRepresentable {
    var onSingleTouchChanged: (CGPoint) -> Void
    var onMultiTouchChanged: (CGPoint, CGPoint) -> Void
    var onTouchesEnded: () -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = OptimizedMultitouchView()
        view.onSingleTouchChanged = onSingleTouchChanged
        view.onMultiTouchChanged = onMultiTouchChanged
        view.onTouchesEnded = onTouchesEnded
        view.backgroundColor = .clear
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // 不需要更新
    }
    
    class OptimizedMultitouchView: UIView {
        var onSingleTouchChanged: ((CGPoint) -> Void)?
        var onMultiTouchChanged: ((CGPoint, CGPoint) -> Void)?
        var onTouchesEnded: (() -> Void)?
        
        private var activeTouches: [UITouch: CGPoint] = [:]
        private var lastUpdateTime: TimeInterval = 0
        private let throttleInterval: TimeInterval = 0.016 // 约60fps
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            isUserInteractionEnabled = true
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                activeTouches[touch] = touch.location(in: self)
            }
            updateTouches(force: true)
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            // 更新移动的触摸点
            for touch in touches {
                activeTouches[touch] = touch.location(in: self)
            }
            
            // 应用节流控制
            let currentTime = CACurrentMediaTime()
            if currentTime - lastUpdateTime > throttleInterval {
                updateTouches()
                lastUpdateTime = currentTime
            }
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            // 移除结束的触摸点
            for touch in touches {
                activeTouches.removeValue(forKey: touch)
            }
            
            if activeTouches.isEmpty {
                onTouchesEnded?()
            } else {
                updateTouches(force: true)
            }
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.removeAll()
            onTouchesEnded?()
        }
        
        private func updateTouches(force: Bool = false) {
            let touchCount = activeTouches.count
            
            if touchCount >= 2 {
                // 双指或多指触摸，取前两个触摸点
                let touchPoints = Array(activeTouches.values)
                onMultiTouchChanged?(touchPoints[0], touchPoints[1])
            } else if touchCount == 1 {
                // 单指触摸
                if let location = activeTouches.values.first {
                    onSingleTouchChanged?(location)
                }
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
