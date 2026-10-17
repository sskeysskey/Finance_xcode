import SwiftUI
import Combine
import UIKit

// MARK: - 基础扩展 (解决 safe subscript 报错)
extension Collection {
    /// 安全访问数组元素，越界返回 nil
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 时间间隔切换
enum TimeRange {
    case oneMonth, threeMonths, sixMonths, oneYear, all, twoYears, fiveYears, tenYears
    
    var title: String {
        switch self {
        case .oneMonth: return "1"
        case .threeMonths: return "3"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .all: return "All"
        case .twoYears: return "2"
        case .fiveYears: return "5"
        case .tenYears: return "10"
        }
    }
    
    var startDate: Date {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .oneMonth: return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all: return calendar.date(byAdding: .year, value: -100, to: now) ?? now
        case .twoYears: return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears: return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears: return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        }
    }
    
    func xAxisTickInterval() -> Calendar.Component {
        switch self {
        case .oneMonth: return .day
        case .threeMonths, .sixMonths, .oneYear: return .month
        case .twoYears, .fiveYears, .tenYears, .all: return .year
        }
    }
    
    func xAxisTickValue() -> Int {
        switch self {
        case .oneMonth: return 1
        case .all: return 2
        default: return 1
        }
    }
    
    func samplingRate() -> Int {
        switch self {
        case .oneMonth, .threeMonths, .sixMonths, .oneYear: return 1
        case .twoYears: return 2
        case .fiveYears: return 5
        case .tenYears: return 10
        case .all: return 15
        }
    }
}

// MARK: - 气泡视图组件
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

// MARK: - 数据结构定义
struct MarkerDisplayInfo {
    var red: String?
    var orange: String?
    var green: String?
    var buy: String? = nil    // 【新增】买入信息
    var sell: String? = nil   // 【新增】卖出信息
}

// 【新增】气泡类型（替代按颜色判断，修复财报气泡永不显示的 bug）
enum BubbleKind {
    case global, symbol, earning, buy, sell
}

struct BubbleMarker: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
    let pointIndex: Int
    let date: Date
    var position: CGPoint = .zero
    var size: CGSize = .zero
    var kind: BubbleKind = .global
}

// MARK: - 页面布局 ChartView
struct ChartView: View {
    let symbol: String
    let groupName: String
    private let verticalPadding: CGFloat = 20
    private let horizontalPadding: CGFloat = 15
    private let chartHeight: CGFloat = 310   // 【统一】图表 Canvas 实际高度
    
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var sampledChartData: [DatabaseManager.PriceData] = []
    @State private var selectedTimeRange: TimeRange = .sixMonths
    @State private var isLoading = true
    @State private var earningData: [DatabaseManager.EarningData] = []
    
    @State private var showSearchView = false
    
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

    @State private var accumulatedScale: CGFloat = 1.0
    
    // 标记点显示控制
    @State private var showRedMarkers: Bool = false
    @State private var showOrangeMarkers: Bool = true
    @State private var showGreenMarkers: Bool = true
    // 【新增】买卖点显示控制（与 mac 端默认一致：开启）
    @State private var showBuyMarkers: Bool = true
    @State private var showSellMarkers: Bool = true
    
    @State private var showVolume: Bool = true
    @State private var showColoredLines: Bool = true
    
    @State private var bubbleMarkers: [BubbleMarker] = []
    @State private var showBubbles: Bool = false
    
    // 【新增】预计算：采样数据索引 → 该点上的全部标记（避免每帧 O(N·M) 计算）
    @State private var markerIndex: [Int: IndexedMarkers] = [:]
    // 【新增】加载序号，防止快速切换时间范围时旧请求覆盖新数据
    @State private var loadGeneration: Int = 0
    
    // 遮罩背板相关状态
    @State private var earningReleaseDate: Date? = nil
    @State private var threeWeeksBeforeRange: (start: Date, end: Date)? = nil
    @State private var oneWeekBeforeRange: (start: Date, end: Date)? = nil
    @State private var fifthWeekRange: (start: Date, end: Date)? = nil
    @State private var thirdWeekRange: (start: Date, end: Date)? = nil

    @State private var navigateToOptionsDetail = false
    @State private var navigateToCompare = false
    @State private var navigateToSimilar = false
    @State private var showSubscriptionSheet = false
    @State private var navigateToBacktest = false
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    private var earningTrend: EarningTrend {
        dataService.earningTrends[symbol.uppercased()] ?? .insufficientData
    }

    private let timeRangeOrder: [TimeRange] = [.oneMonth, .threeMonths, .sixMonths, .oneYear, .twoYears, .fiveYears, .tenYears, .all]
    
    private var currentTags: [String] {
        let upperSymbol = symbol.uppercased()
        if let tags = dataService.symbolTagsMap[upperSymbol] { return tags }
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return stock.tag
        }
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return etf.tag
        }
        return []
    }
    
    // 【新增】某个采样点上的所有标记
    private struct IndexedMarkers {
        var global: [String] = []
        var symbol: [String] = []
        var earning: [DatabaseManager.EarningData] = []
        var buy: FTTradeAgg? = nil
        var sell: FTTradeAgg? = nil
    }
    
    // MARK: - 复用的格式化器
    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let mdFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()
    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd"; return f
    }()
    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let yearLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy"; return f
    }()
    
    // MARK: - 计算属性
    private var isDarkMode: Bool { colorScheme == .dark }
    private var chartColor: Color { isDarkMode ? Color.white : Color.blue }
    private var backgroundColor: Color { isDarkMode ? Color.black : Color.white }
    private var minPrice: Double { sampledChartData.map { $0.price }.min() ?? 0 }
    private var maxPrice: Double { sampledChartData.map { $0.price }.max() ?? 0 }

    private var hasOHLC: Bool {
        sampledChartData.contains { $0.open != nil }
    }
    
    // 【新增】本 symbol 的买卖记录
    private var symbolTrades: [FTTradeDay] {
        dataService.tradeRecords[FTTradeStore.normSymbol(symbol)] ?? []
    }
    private var hasTrades: Bool { !symbolTrades.isEmpty }
    private var tradeSummaryText: String {
        let b = symbolTrades.reduce(0) { $0 + ($1.buy?.count ?? 0) }
        let s = symbolTrades.reduce(0) { $0 + ($1.sell?.count ?? 0) }
        return "实盘 买\(b)·卖\(s)"
    }
    
    private var priceDifferencePercentage: Double? {
        guard let first = firstTouchPoint, let second = secondTouchPoint else { return nil }
        let earlierPrice = first.date < second.date ? first.price : second.price
        let laterPrice = first.date < second.date ? second.price : first.price
        guard earlierPrice != 0 else { return nil }
        return ((laterPrice - earlierPrice) / earlierPrice) * 100.0
    }
    
    private var turnoverDifferencePercentage: Double? {
        guard let first = firstTouchPoint, let second = secondTouchPoint else { return nil }
        let earlierPoint = first.date < second.date ? first : second
        let laterPoint = first.date < second.date ? second : first
        guard let earlierVol = earlierPoint.volume, earlierVol > 0,
              let laterVol = laterPoint.volume, laterVol > 0 else {
            return nil
        }
        let earlierTurnover = Double(earlierVol) * earlierPoint.price
        let laterTurnover = Double(laterVol) * laterPoint.price
        guard earlierTurnover != 0 else { return nil }
        return ((laterTurnover - earlierTurnover) / earlierTurnover) * 100.0
    }

    // MARK: - 捏合缩放处理
    private func handlePinchScale(_ scale: CGFloat) {
        accumulatedScale *= scale
        let zoomInThreshold: CGFloat = 1.3
        let zoomOutThreshold: CGFloat = 0.7
        
        if accumulatedScale > zoomInThreshold {
            shiftTimeRange(direction: -1)
            accumulatedScale = 1.0
        } else if accumulatedScale < zoomOutThreshold {
            shiftTimeRange(direction: 1)
            accumulatedScale = 1.0
        }
    }
    
    private func shiftTimeRange(direction: Int) {
        guard let currentIndex = timeRangeOrder.firstIndex(of: selectedTimeRange) else { return }
        let newIndex = currentIndex + direction
        if newIndex >= 0 && newIndex < timeRangeOrder.count {
            let newRange = timeRangeOrder[newIndex]
            if newRange != selectedTimeRange {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                selectedTimeRange = newRange
                loadChartData()
            }
        }
    }
    
    private func isBubbleVisible(_ kind: BubbleKind) -> Bool {
        switch kind {
        case .global: return showRedMarkers
        case .symbol: return showOrangeMarkers
        case .earning: return showGreenMarkers
        case .buy: return showBuyMarkers
        case .sell: return showSellMarkers
        }
    }
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Tags
            if !currentTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(currentTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.gray.opacity(0.15))
                                .foregroundColor(.secondary)
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 20)
                .padding(.top, 5)
            }
            
            // Info Area
            VStack {
                ZStack(alignment: .top) {
                    Rectangle().fill(Color.clear).frame(height: 80)
                    
                    VStack(spacing: 5) {
                        if isMultiTouch, let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                            let date1 = firstPoint.date
                            let date2 = secondPoint.date
                            let (earlierDate, laterDate) = date1 < date2 ? (formatDate(date1), formatDate(date2)) : (formatDate(date2), formatDate(date1))
                            let percentChange = priceDifferencePercentage ?? 0
                            
                            HStack {
                                Text("\(earlierDate)").font(.system(size: 16, weight: .medium))
                                Text("-").font(.system(size: 16, weight: .medium)).foregroundColor(.gray)
                                Text("\(laterDate)").font(.system(size: 16, weight: .medium))
                                
                                Text("\(formatPercentage(percentChange))")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(percentChange >= 0 ? .red : .green)
                                
                                if let turnoverChange = turnoverDifferencePercentage {
                                    Text("\(formatPercentage(turnoverChange))")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(turnoverChange >= 0 ? .red : .green)
                                }
                            }
                            .padding(.horizontal).padding(.vertical, 8)
                            .background(Color(UIColor.systemGray6)).cornerRadius(8)
                            
                        } else if let point = draggedPoint, let pointIdx = draggedPointIndex {
                            let pointDate = formatDate(point.date)
                            let percentChange = calculatePriceChangePercentage(from: point)
                            let markerInfo = getMarkerInfo(at: pointIdx)
                            
                            VStack(spacing: 5) {
                                HStack(spacing: 8) {
                                    Text("\(pointDate)  \(formatPrice(point.price))")
                                        .font(.system(size: 16, weight: .medium))
                                    if let percentChange = percentChange {
                                        Text(formatPercentage(percentChange))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(percentChange >= 0 ? .red : .green)
                                    }
                                    if let greenText = markerInfo.green {
                                        Text(greenText)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.green)
                                    }
                                    if let vol = point.volume, vol > 0 {
                                        let turnover = Double(vol) * point.price
                                        Text("\(formatVolume(turnover))")
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(.purple)
                                    }
                                }
                                
                                // 【新增】买卖信息
                                if let buyText = markerInfo.buy {
                                    Text("▲ " + buyText)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.ftBuy)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                }
                                if let sellText = markerInfo.sell {
                                    Text("▼ " + sellText)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.ftSell)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                }
                                
                                if let orangeText = markerInfo.orange {
                                    Text(orangeText.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.orange)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                }
                                if let redText = markerInfo.red {
                                    Text(redText.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.red)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color(UIColor.systemGray6)).cornerRadius(8)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal).padding(.top, 10)
                    .frame(maxWidth: .infinity)
                }
            }
            
            // Chart Area
            if sampledChartData.isEmpty {
                if isLoading {
                    ProgressView().scaleEffect(1.5).padding().frame(height: 250)
                } else {
                    Text("No data available").font(.title2).foregroundColor(.gray).frame(height: 250)
                }
            } else {
                ZStack {
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                            Canvas { context, size in
                                drawChart(context: context, size: size)
                            }
                            .overlay(
                                ZStack {
                                    if !isDragging && !isMultiTouch && showBubbles {
                                        ForEach(bubbleMarkers) { marker in
                                            if isBubbleVisible(marker.kind) {
                                                BubbleView(
                                                    text: marker.text,
                                                    color: marker.color,
                                                    pointX: marker.position.x,
                                                    pointY: marker.position.y
                                                )
                                                .frame(width: marker.size.width)
                                                .position(x: marker.position.x, y: marker.position.y - 40)
                                                .opacity(0.9)
                                                .transition(.opacity)
                                                .animation(.easeInOut(duration: 0.3), value: marker.id)
                                            }
                                        }
                                    }
                                }
                            )
                            
                            // X轴标签
                            ForEach(getXAxisTicks(), id: \.self) { date in
                                if let index = getIndexForDate(date) {
                                    let effectiveWidth = geometry.size.width - (horizontalPadding * 2)
                                    let x = horizontalPadding + CGFloat(index) * (effectiveWidth / CGFloat(max(1, sampledChartData.count - 1)))
                                    
                                    Text(formatXAxisLabel(date))
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                        .position(x: x, y: geometry.size.height - 10)
                                }
                            }
                        }
                        .frame(height: chartHeight)
                        
                        Color.clear.frame(height: 30)
                    }
                    OptimizedTouchHandler(
                        onSingleTouchChanged: { location in
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
                        },
                        onPinch: { scale in
                            handlePinchScale(scale)
                        }
                    )
                }
                .frame(width: UIScreen.main.bounds.width)
                // 【优化】切换区间时保留旧图，只显示小转圈，不打断捏合手势
                .overlay(alignment: .topTrailing) {
                    if isLoading {
                        ProgressView().padding(.trailing, 12).padding(.top, 4)
                    }
                }
            }
            
            // Time Range Buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach([TimeRange.oneMonth, .threeMonths, .sixMonths, .oneYear, .all, .twoYears, .fiveYears, .tenYears], id: \.title) { range in
                        Button(action: {
                            selectedTimeRange = range
                            loadChartData()
                        }) {
                            Text(range.title)
                                .font(.system(size: 14, weight: selectedTimeRange == range ? .bold : .regular))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(selectedTimeRange == range ? Color.blue.opacity(0.2) : Color.clear)
                                .foregroundColor(selectedTimeRange == range ? .blue : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(minWidth: UIScreen.main.bounds.width)
            }
            .frame(height: 50)
            .frame(maxWidth: UIScreen.main.bounds.width)
            .padding(.vertical, 10)
            
            // Toggles
            VStack(spacing: 4) {
                HStack(spacing: 15) {
                    Toggle(isOn: $showGreenMarkers) { Text("财报").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .blue))
                    Toggle(isOn: $showBubbles) { Text("气泡").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .cyan))
                    Toggle(isOn: $showRedMarkers) { Text("全局事件").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .red))
                }
                .padding(.horizontal, 20)
                
                HStack(spacing: 15) {
                    Toggle(isOn: $showOrangeMarkers) { Text("个股事件").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .orange))
                    Toggle(isOn: $showVolume) { Text("成交额").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .purple))
                    Toggle(isOn: $showColoredLines) { Text("涨跌").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .green))
                }
                .padding(.horizontal, 20)
                
                // 【新增】买卖点开关：仅当该标的有成交记录时显示
                if hasTrades {
                    HStack(spacing: 15) {
                        Toggle(isOn: $showBuyMarkers) { Text("买入▲").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .ftBuy))
                        Toggle(isOn: $showSellMarkers) { Text("卖出▼").font(.system(size: 12)) }.toggleStyle(SwitchToggleStyle(tint: .ftSell))
                        Text(tradeSummaryText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 10)
            
            // Action Buttons
            HStack(spacing: 20) {
                NavigationLink(destination: {
                    if let descriptions = getDescriptions(for: symbol) {
                        DescriptionView(descriptions: descriptions)
                    } else {
                        DescriptionView(descriptions: ("No description available.", ""))
                    }
                }) {
                    Text("简介").font(.system(size: 22, weight: .medium)).foregroundColor(.blue)
                }
                
                Button(action: {
                    navigateToCompare = true
                }) {
                    Text("比对")
                        .font(.system(size: 22, weight: .medium))
                        .padding(.leading, 10)
                        .foregroundColor(.blue)
                }
                
                Button(action: {
                    PointsCoordinator.shared.attempt(action: .openList, itemKey: "similar_\(symbol)",
                        displayName: "查看 \(symbol) 的相似股票", authManager: authManager) {
                        navigateToSimilar = true
                    }
                }) {
                    Text("相似")
                        .font(.system(size: 22, weight: .medium))
                        .padding(.leading, 10)
                        .foregroundColor(.blue)
                }
                
                if dataService.optionsData.keys.contains(symbol.uppercased()) {
                    Button(action: {
                        PointsCoordinator.shared.attempt(action: .viewOptionsDetail, itemKey: symbol,
                            displayName: "查看 \(symbol) 期权详情", authManager: authManager) {
                            navigateToOptionsDetail = true
                        }
                    }) {
                        Text("期权")
                            .font(.system(size: 22, weight: .medium))
                            .padding(.leading, 10)
                            .foregroundColor(.purple)
                    }
                }
                
                Button(action: {
                    navigateToBacktest = true
                }) {
                    Text("回溯")
                        .font(.system(size: 22, weight: .medium))
                        .padding(.leading, 10)
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            
            Spacer()
        }
        .background(backgroundColor.edgesIgnoringSafeArea(.all))
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text(symbol).font(.headline).foregroundColor(colorForEarningTrend(earningTrend))
                    if let marketCapItem = dataService.marketCapData[symbol.uppercased()] {
                        Text(marketCapItem.marketCap).font(.subheadline).foregroundColor(.secondary)
                        if let peRatio = marketCapItem.peRatio {
                            Text("\(String(format: "%.2f", peRatio))").font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    if let compareStock = dataService.compareData[symbol.uppercased()] {
                        Text(compareStock).font(.subheadline).foregroundColor(colorForCompareValue(compareStock))
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showSearchView = true }) {
                    Image(systemName: "magnifyingglass").imageScale(.small).font(.system(size: 14)).padding(0)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadChartData()
            dataService.fetchEarningTrends(for: [symbol])
            ReviewManager.shared.recordInteraction()
        }
        .navigationDestination(isPresented: $showSearchView) {
            SearchView(isSearchActive: true, dataService: dataService)
        }
        .navigationDestination(isPresented: $navigateToCompare) {
            CompareView(initialSymbol: symbol)
        }
        .navigationDestination(isPresented: $navigateToSimilar) {
            SimilarView(symbol: symbol)
        }
        .navigationDestination(isPresented: $navigateToOptionsDetail) {
            OptionsDetailView(symbol: symbol.uppercased())
        }
        .navigationDestination(isPresented: $navigateToBacktest) {
            BacktestView(symbol: symbol)
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    // MARK: - 绘图逻辑
    private func drawChart(context: GraphicsContext, size: CGSize) {
        let data = sampledChartData
        guard let displayStart = data.first?.date, let displayEnd = data.last?.date else { return }
        
        // 【性能修复】只计算一次价格范围（原先每个点都会 O(N) 重算）
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for p in data { lo = min(lo, p.price); hi = max(hi, p.price) }
        let range = max(hi - lo, 0.01)
        
        let effectiveHeight = size.height - (verticalPadding * 2)
        let priceToY: (Double) -> CGFloat = { price in
            let normalizedY = CGFloat((price - lo) / range)
            return size.height - verticalPadding - (normalizedY * effectiveHeight)
        }

        let effectiveWidth = size.width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, data.count - 1))
        let halfStep = horizontalStep / 2
        let xAt: (Int) -> CGFloat = { idx in horizontalPadding + CGFloat(idx) * horizontalStep }

        func xBounds(from rawStart: Date, to rawEnd: Date) -> (CGFloat, CGFloat)? {
            let start = max(rawStart, displayStart)
            let end = min(rawEnd, displayEnd)
            guard start <= end else { return nil }
            guard let startIndex = data.firstIndex(where: { $0.date >= start }),
                  let endIndex = data.lastIndex(where: { $0.date <= end }),
                  startIndex <= endIndex else { return nil }

            var x1 = xAt(startIndex) - halfStep
            var x2 = xAt(endIndex) + halfStep
            if startIndex == 0 { x1 = horizontalPadding } else { x1 = max(horizontalPadding, x1) }
            if endIndex == data.count - 1 { x2 = size.width - horizontalPadding } else { x2 = min(size.width - horizontalPadding, x2) }
            if x2 <= x1 { x2 = x1 + max(horizontalStep, 2) }
            return (x1, x2)
        }

        func drawRange(_ r: (start: Date, end: Date), tint: Color) {
            guard let (x1, x2) = xBounds(from: r.start, to: r.end) else { return }
            let shadeRect = CGRect(x: x1, y: verticalPadding, width: x2 - x1, height: size.height - verticalPadding * 2)
            context.fill(Path(shadeRect), with: .color(tint.opacity(0.15)))
        }

        if let threeWeeks = threeWeeksBeforeRange { drawRange(threeWeeks, tint: .green) }
        if let oneWeek = oneWeekBeforeRange { drawRange(oneWeek, tint: .blue) }
        if let fifthWeek = fifthWeekRange { drawRange(fifthWeek, tint: .blue) }
        if let thirdWeek = thirdWeekRange { drawRange(thirdWeek, tint: .green) }
        
        // 成交额
        if showVolume {
            var maxVol: Double = 0
            for p in data { if let v = p.volume, v > 0 { maxVol = max(maxVol, Double(v) * p.price) } }
            if maxVol > 0 {
                let volumeAreaHeight = size.height * 0.20
                let volumeBottomY = size.height - verticalPadding
                let barWidth = max(1, horizontalStep * 0.6)
                for (index, point) in data.enumerated() {
                    if let vol = point.volume, vol > 0 {
                        let x = xAt(index)
                        let turnover = Double(vol) * point.price
                        let barHeight = CGFloat(turnover / maxVol) * volumeAreaHeight
                        let barRect = CGRect(x: x - barWidth/2, y: volumeBottomY - barHeight, width: barWidth, height: barHeight)
                        context.fill(Path(barRect), with: .color(Color.purple.opacity(0.5)))
                    }
                }
            }
        }
        
        // 价格线
        if data.count >= 2 {
            if showColoredLines && hasOHLC {
                for index in 1..<data.count {
                    var segmentPath = Path()
                    segmentPath.move(to: CGPoint(x: xAt(index - 1), y: priceToY(data[index - 1].price)))
                    segmentPath.addLine(to: CGPoint(x: xAt(index), y: priceToY(data[index].price)))
                    
                    let segColor: Color
                    if let openPrice = data[index].open {
                        let closePrice = data[index].price
                        if closePrice > openPrice { segColor = .red }
                        else if closePrice < openPrice { segColor = .green }
                        else { segColor = chartColor }
                    } else {
                        segColor = chartColor
                    }
                    context.stroke(segmentPath, with: .color(segColor), lineWidth: 2)
                }
            } else {
                var pricePath = Path()
                pricePath.move(to: CGPoint(x: xAt(0), y: priceToY(data[0].price)))
                for index in 1..<data.count {
                    pricePath.addLine(to: CGPoint(x: xAt(index), y: priceToY(data[index].price)))
                }
                context.stroke(pricePath, with: .color(chartColor), lineWidth: 2)
            }
        }
        
        if [.oneMonth, .threeMonths, .sixMonths].contains(selectedTimeRange) {
            for (index, point) in data.enumerated() {
                let dotRect = CGRect(x: xAt(index) - 2, y: priceToY(point.price) - 2, width: 3, height: 3)
                context.fill(Path(ellipseIn: dotRect), with: .color(.black))
            }
        }
        
        // 零线（与价格线同一坐标系）
        if lo < 0 && hi >= 0 {
            let zeroY = priceToY(0)
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: horizontalPadding, y: zeroY))
            zeroPath.addLine(to: CGPoint(x: size.width - horizontalPadding, y: zeroY))
            context.stroke(zeroPath, with: .color(Color.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4]))
        }
        
        // 标记点（使用预计算索引）+ 买卖三角
        func triangle(x: CGFloat, y: CGFloat, up: Bool) -> Path {
            let w: CGFloat = 11, h: CGFloat = 9, gap: CGFloat = 5
            var p = Path()
            if up {
                // 买入：价格点下方，尖朝上
                let top = min(y + gap, size.height - h)
                p.move(to: CGPoint(x: x, y: top))
                p.addLine(to: CGPoint(x: x - w/2, y: top + h))
                p.addLine(to: CGPoint(x: x + w/2, y: top + h))
            } else {
                // 卖出：价格点上方，尖朝下
                let bottom = max(y - gap, h)
                p.move(to: CGPoint(x: x, y: bottom))
                p.addLine(to: CGPoint(x: x - w/2, y: bottom - h))
                p.addLine(to: CGPoint(x: x + w/2, y: bottom - h))
            }
            p.closeSubpath()
            return p
        }
        
        for (idx, m) in markerIndex {
            guard idx >= 0, idx < data.count else { continue }
            let x = xAt(idx)
            let y = priceToY(data[idx].price)
            
            var color: Color? = nil
            if showRedMarkers && !m.global.isEmpty { color = .red }
            if showOrangeMarkers && !m.symbol.isEmpty { color = .orange }
            if showGreenMarkers && !m.earning.isEmpty { color = .blue }
            if let c = color {
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(c))
            }
            
            if showBuyMarkers && m.buy != nil {
                let t = triangle(x: x, y: y, up: true)
                context.fill(t, with: .color(.ftBuy))
                context.stroke(t, with: .color(.white.opacity(0.85)), lineWidth: 0.8)
            }
            if showSellMarkers && m.sell != nil {
                let t = triangle(x: x, y: y, up: false)
                context.fill(t, with: .color(.ftSell))
                context.stroke(t, with: .color(.white.opacity(0.85)), lineWidth: 0.8)
            }
        }
        
        // 触摸指示器
        if isMultiTouch {
            if let firstIndex = firstTouchPointIndex, let firstPoint = firstTouchPoint {
                let x = xAt(firstIndex)
                let y = priceToY(firstPoint.price)
                var linePath = Path()
                linePath.move(to: CGPoint(x: x, y: verticalPadding))
                linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
                context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
                let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                context.fill(circlePath, with: .color(Color.white))
                context.stroke(circlePath, with: .color(chartColor), lineWidth: 2)
            }
            if let secondIndex = secondTouchPointIndex, let secondPoint = secondTouchPoint {
                let x = xAt(secondIndex)
                let y = priceToY(secondPoint.price)
                var linePath = Path()
                linePath.move(to: CGPoint(x: x, y: verticalPadding))
                linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
                context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
                let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                context.fill(circlePath, with: .color(Color.white))
                context.stroke(circlePath, with: .color(chartColor), lineWidth: 2)
            }
            if let firstIndex = firstTouchPointIndex, let secondIndex = secondTouchPointIndex,
               let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                var connectPath = Path()
                connectPath.move(to: CGPoint(x: xAt(firstIndex), y: priceToY(firstPoint.price)))
                connectPath.addLine(to: CGPoint(x: xAt(secondIndex), y: priceToY(secondPoint.price)))
                let lineColor = secondPoint.price >= firstPoint.price ? Color.green : Color.red
                context.stroke(connectPath, with: .color(lineColor), style: StrokeStyle(lineWidth: 1, dash: [2]))
            }
        } else if let pointIndex = draggedPointIndex {
            let x = xAt(pointIndex)
            var linePath = Path()
            linePath.move(to: CGPoint(x: x, y: verticalPadding))
            linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
            context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
            if let point = draggedPoint {
                let y = priceToY(point.price)
                // 有买卖点时圆圈描边改为买卖色（对应 mac 端 highlight 变色）
                var ringColor = chartColor
                if let m = markerIndex[pointIndex] {
                    if showBuyMarkers && m.buy != nil { ringColor = .ftBuy }
                    if showSellMarkers && m.sell != nil { ringColor = .ftSell }
                }
                let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                context.fill(circlePath, with: .color(Color.white))
                context.stroke(circlePath, with: .color(ringColor), lineWidth: 2)
            }
        }
    }
    
    // MARK: - 逻辑方法
    private func calculateWeekRange(from targetDate: Date, weeksBack: Int) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        guard let weeksBefore = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: targetDate) else { return nil }
        let weekday = calendar.component(.weekday, from: weeksBefore)
        let daysToMonday = weekday == 1 ? -6 : 2 - weekday
        guard let weekStart = calendar.date(byAdding: .day, value: daysToMonday, to: weeksBefore),
              let weekEnd = calendar.date(byAdding: .day, value: 4, to: weekStart) else { return nil }
        return (start: weekStart, end: weekEnd)
    }
    
    private func calculateWeekRangeForward(from targetDate: Date, weeksForward: Int) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        guard let weeksAfter = calendar.date(byAdding: .weekOfYear, value: weeksForward, to: targetDate) else { return nil }
        let weekday = calendar.component(.weekday, from: weeksAfter)
        let daysToMonday = weekday == 1 ? -6 : 2 - weekday
        guard let weekStart = calendar.date(byAdding: .day, value: daysToMonday, to: weeksAfter),
              let weekEnd = calendar.date(byAdding: .day, value: 4, to: weekStart) else { return nil }
        return (start: weekStart, end: weekEnd)
    }

    private func findEarningReleaseDate() -> Date? {
        dataService.earningReleases.first(where: { $0.symbol.uppercased() == symbol.uppercased() })?.fullDate
    }
    
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp: return .red
        case .negativeAndUp: return .purple
        case .positiveAndDown: return .cyan
        case .negativeAndDown: return .green
        case .insufficientData: return .primary
        }
    }
    
    private func colorForCompareValue(_ value: String) -> Color {
        (value.contains("前") || value.contains("后") || value.contains("未")) ? .orange : .secondary
    }
    
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
                } else { break }
            }
            if let lastTick = ticks.last, !calendar.isDate(lastTick, equalTo: endDate, toGranularity: tickGranularity()) {
                ticks.append(endDate)
            }
        }
        return ticks
    }

    private func tickGranularity() -> Calendar.Component {
        switch selectedTimeRange {
        case .oneMonth: return .day
        case .threeMonths, .sixMonths, .oneYear: return .month
        case .twoYears, .fiveYears, .tenYears, .all: return .year
        }
    }
    
    private func calculatePriceChangePercentage(from point: DatabaseManager.PriceData) -> Double? {
        guard let latestPrice = sampledChartData.last?.price, point.price != 0 else { return nil }
        return ((latestPrice - point.price) / point.price) * 100.0
    }
    
    private func formatVolume(_ amount: Double) -> String {
        if amount >= 1_000_000_000 {
            return String(format: "%.2fB", amount / 1_000_000_000)
        } else if amount >= 1_000_000 {
            return String(format: "%.2fM", amount / 1_000_000)
        } else if amount >= 1_000 {
            return String(format: "%.2fK", amount / 1_000)
        } else {
            return String(format: "%.2f", amount)
        }
    }
    
    private func getDescriptions(for symbol: String) -> (String, String)? {
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
            return (stock.description1, stock.description2)
        }
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
            return (etf.description1, etf.description2)
        }
        return nil
    }
    
    private func loadChartData() {
        loadGeneration += 1
        let generation = loadGeneration
        let range = selectedTimeRange
        
        isLoading = true
        earningReleaseDate = findEarningReleaseDate()
        if let releaseDate = earningReleaseDate {
            threeWeeksBeforeRange = calculateWeekRange(from: releaseDate, weeksBack: 3)
            oneWeekBeforeRange = calculateWeekRange(from: releaseDate, weeksBack: 1)
        } else {
            threeWeeksBeforeRange = nil
            oneWeekBeforeRange = nil
        }
        
        Task {
            let newData = await DatabaseManager.shared.fetchHistoricalData(symbol: symbol, tableName: groupName, dateRange: .timeRange(range))
            let earnings = await DatabaseManager.shared.fetchEarningData(forSymbol: symbol)

            await MainActor.run {
                // 【修复竞态】已有更新的加载请求，丢弃本次结果
                guard generation == loadGeneration else { return }
                
                let specialKeys = collectSpecialDayKeys(earnings: earnings)
                let sampled = sampleData(newData, rate: range.samplingRate(), range: range, specialKeys: specialKeys)
                
                chartData = newData
                sampledChartData = sampled
                earningData = earnings
                markerIndex = buildMarkerIndex(for: sampled, earnings: earnings)
                
                if let latestEarningDate = earnings.max(by: { $0.date < $1.date })?.date {
                    fifthWeekRange = calculateWeekRangeForward(from: latestEarningDate, weeksForward: 5)
                    thirdWeekRange = calculateWeekRangeForward(from: latestEarningDate, weeksForward: 3)
                } else {
                    fifthWeekRange = nil
                    thirdWeekRange = nil
                }
                
                isLoading = false
                resetTouchStates()
                updateBubbleMarkers()
            }
        }
    }
    
    // MARK: - 【新增】标记预计算
    /// 所有需要在抽样中保留的日期（事件 / 财报 / 买卖）
    private func collectSpecialDayKeys(earnings: [DatabaseManager.EarningData]) -> Set<Int> {
        let cal = Calendar.current
        var keys = Set<Int>()
        for d in dataService.globalTimeMarkers.keys { keys.insert(FTDay.key(d, calendar: cal)) }
        if let sm = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for d in sm.keys { keys.insert(FTDay.key(d, calendar: cal)) }
        }
        for e in earnings { keys.insert(FTDay.key(e.date, calendar: cal)) }
        for t in symbolTrades { keys.insert(t.dayKey) }
        return keys
    }
    
    private func nearestIndex(to date: Date, in data: [DatabaseManager.PriceData]) -> Int {
        var low = 0, high = data.count - 1
        while low < high {
            let mid = (low + high) / 2
            if data[mid].date < date { low = mid + 1 } else { high = mid }
        }
        if low > 0 && abs(data[low - 1].date.timeIntervalSince(date)) <= abs(data[low].date.timeIntervalSince(date)) {
            return low - 1
        }
        return low
    }
    
    /// 把所有标记映射到采样数据的索引（同日精确匹配，否则就近）
    private func buildMarkerIndex(for data: [DatabaseManager.PriceData],
                                  earnings: [DatabaseManager.EarningData]) -> [Int: IndexedMarkers] {
        guard let first = data.first?.date, let last = data.last?.date else { return [:] }
        let cal = Calendar.current
        var keyToIndex: [Int: Int] = [:]
        for (i, p) in data.enumerated() {
            let k = FTDay.key(p.date, calendar: cal)
            if keyToIndex[k] == nil { keyToIndex[k] = i }
        }
        
        func resolve(_ date: Date, maxGapDays: Double?) -> Int? {
            if date < first || date > last { return nil }
            if let i = keyToIndex[FTDay.key(date, calendar: cal)] { return i }
            let i = nearestIndex(to: date, in: data)
            if let g = maxGapDays, abs(data[i].date.timeIntervalSince(date)) > g * 86400 { return nil }
            return i
        }
        
        var map: [Int: IndexedMarkers] = [:]
        
        for (d, t) in dataService.globalTimeMarkers.sorted(by: { $0.key < $1.key }) {
            if let i = resolve(d, maxGapDays: 31) { map[i, default: IndexedMarkers()].global.append(t) }
        }
        if let sm = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (d, t) in sm.sorted(by: { $0.key < $1.key }) {
                if let i = resolve(d, maxGapDays: 31) { map[i, default: IndexedMarkers()].symbol.append(t) }
            }
        }
        for e in earnings.sorted(by: { $0.date < $1.date }) {
            if let i = resolve(e.date, maxGapDays: 31) { map[i, default: IndexedMarkers()].earning.append(e) }
        }
        // 买卖点：与 mac 端一致，取区间内最近的交易日
        for day in symbolTrades {
            guard let i = resolve(day.date, maxGapDays: nil) else { continue }
            if let b = day.buy {
                var cur = map[i, default: IndexedMarkers()].buy ?? FTTradeAgg()
                cur.merge(b)
                map[i, default: IndexedMarkers()].buy = cur
            }
            if let s = day.sell {
                var cur = map[i, default: IndexedMarkers()].sell ?? FTTradeAgg()
                cur.merge(s)
                map[i, default: IndexedMarkers()].sell = cur
            }
        }
        return map
    }
    
    private func updateBubbleMarkers() {
        let data = sampledChartData
        guard !data.isEmpty else { bubbleMarkers = []; return }
        
        let width = UIScreen.main.bounds.width
        let effectiveWidth = width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, data.count - 1))
        let maxLabelWidth: CGFloat = 120
        
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for p in data { lo = min(lo, p.price); hi = max(hi, p.price) }
        let range = max(hi - lo, 0.01)
        let effectiveHeight = chartHeight - verticalPadding * 2
        let yFor: (Double) -> CGFloat = { price in
            chartHeight - verticalPadding - CGFloat((price - lo) / range) * effectiveHeight
        }
        let latest = data.last?.price
        let cal = Calendar.current
        
        var markers: [BubbleMarker] = []
        func add(_ idx: Int, _ text: String, _ color: Color, _ kind: BubbleKind) {
            let x = horizontalPadding + CGFloat(idx) * horizontalStep
            let y = yFor(data[idx].price)
            let w = min(max(CGFloat(text.count * 7), 40), maxLabelWidth)
            markers.append(BubbleMarker(text: text, color: color, pointIndex: idx, date: data[idx].date,
                                        position: CGPoint(x: x, y: y), size: CGSize(width: w, height: 0), kind: kind))
        }
        
        for idx in markerIndex.keys.sorted() {
            guard idx < data.count, let m = markerIndex[idx] else { continue }
            for t in m.global { add(idx, t, .red, .global) }
            for t in m.symbol { add(idx, t, .orange, .symbol) }
            for e in m.earning {
                let cur = data[idx].price
                let pct = (cur != 0 && latest != nil) ? ((latest! - cur) / cur) * 100 : 0
                let text = "\(Self.mdFormatter.string(from: e.date)) \(String(format: "%.2f%%", e.price))\n\(String(format: "%+.2f%%", pct))"
                add(idx, text, .blue, .earning)
            }
            let dayKey = FTDay.key(data[idx].date, calendar: cal)
            if let b = m.buy {
                add(idx, FTTradeStore.bubbleText(side: .buy, agg: b, dayKey: dayKey, latest: latest), .ftBuy, .buy)
            }
            if let s = m.sell {
                add(idx, FTTradeStore.bubbleText(side: .sell, agg: s, dayKey: dayKey, latest: latest), .ftSell, .sell)
            }
        }
        
        let optimizedMarkers = optimizeBubbleLayout(markers, canvasWidth: width, canvasHeight: chartHeight)
        withAnimation { self.bubbleMarkers = optimizedMarkers }
    }

    private func optimizeBubbleLayout(_ markers: [BubbleMarker], canvasWidth: CGFloat, canvasHeight: CGFloat) -> [BubbleMarker] {
        guard !markers.isEmpty else { return [] }
        var optimizedMarkers = markers
        let midY = canvasHeight / 2
        var upperMarkers = optimizedMarkers.filter { $0.position.y <= midY }
        var lowerMarkers = optimizedMarkers.filter { $0.position.y > midY }
        upperMarkers.sort { $0.position.x < $1.position.x }
        lowerMarkers.sort { $0.position.x < $1.position.x }
        
        func layoutLayer(markers: [BubbleMarker], startY: CGFloat, stepY: CGFloat) -> [BubbleMarker] {
            var result = markers
            var layers: [[BubbleMarker]] = []
            let bubbleSpacing: CGFloat = 10
            for marker in markers {
                var placed = false
                for i in 0..<layers.count {
                    if layers[i].isEmpty || (marker.position.x - layers[i].last!.position.x > layers[i].last!.size.width / 2 + bubbleSpacing) {
                        layers[i].append(marker)
                        placed = true
                        break
                    }
                }
                if !placed { layers.append([marker]) }
            }
            var currentY = startY
            for layer in layers {
                for marker in layer {
                    if let index = result.firstIndex(where: { $0.id == marker.id }) {
                        result[index].position.y = currentY
                    }
                }
                currentY += stepY
            }
            return result
        }
        
        let upperResult = layoutLayer(markers: upperMarkers, startY: 20, stepY: 50)
        let lowerResult = layoutLayer(markers: lowerMarkers, startY: canvasHeight - 50, stepY: -50)
        
        for m in upperResult + lowerResult {
            if let idx = optimizedMarkers.firstIndex(where: { $0.id == m.id }) {
                optimizedMarkers[idx] = m
                let halfWidth = optimizedMarkers[idx].size.width / 2
                if optimizedMarkers[idx].position.x - halfWidth < 0 { optimizedMarkers[idx].position.x = halfWidth }
                else if optimizedMarkers[idx].position.x + halfWidth > canvasWidth { optimizedMarkers[idx].position.x = canvasWidth - halfWidth }
            }
        }
        return optimizedMarkers
    }
    
    private func resetTouchStates() {
        dragLocation = nil
        draggedPointIndex = nil
        draggedPoint = nil
        isDragging = false
        isMultiTouch = false
        firstTouchLocation = nil
        secondTouchLocation = nil
        firstTouchPointIndex = nil
        secondTouchPointIndex = nil
        firstTouchPoint = nil
        secondTouchPoint = nil
        // 【优化】气泡只依赖数据，加载时已计算，这里不再每次抬手重算
    }
    
    /// 【重写】抽样：特殊日期（事件/财报/买卖）一律保留；使用日期键 Set，避免 O(N·M)
    private func sampleData(_ data: [DatabaseManager.PriceData], rate: Int, range: TimeRange, specialKeys: Set<Int>) -> [DatabaseManager.PriceData] {
        guard rate > 1, data.count > 2 else { return data }
        let cal = Calendar.current
        let totalDays = cal.dateComponents([.day], from: data.first!.date, to: data.last!.date).day ?? 0
        if totalDays / data.count > 2 { return data }
        
        var adjustedRate = rate
        if (range == .twoYears || range == .all) && totalDays < 365 { adjustedRate = 1 }
        if adjustedRate <= 1 { return data }
        
        var included = Set<Int>([0, data.count - 1])
        let priceChangeThreshold = 0.005
        var lastIncludedIndex = 0
        for i in stride(from: adjustedRate, to: data.count - 1, by: adjustedRate) {
            let lastPrice = data[lastIncludedIndex].price
            let bigMove = lastPrice != 0 ? abs((data[i].price - lastPrice) / lastPrice) > priceChangeThreshold : true
            if bigMove || i % (adjustedRate * 2) == 0 {
                included.insert(i)
                lastIncludedIndex = i
            }
        }
        if !specialKeys.isEmpty {
            for (i, p) in data.enumerated() where specialKeys.contains(FTDay.key(p.date, calendar: cal)) {
                included.insert(i)
            }
        }
        return included.sorted().map { data[$0] }
    }
    
    private func getIndexFromLocation(_ location: CGPoint) -> Int {
        guard !sampledChartData.isEmpty else { return 0 }
        let width = UIScreen.main.bounds.width
        let effectiveWidth = width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, sampledChartData.count - 1))
        let relativeX = location.x - horizontalPadding
        if relativeX <= 0 { return 0 }
        if relativeX >= effectiveWidth { return sampledChartData.count - 1 }
        let index = Int(round(relativeX / horizontalStep))
        return min(sampledChartData.count - 1, max(0, index))
    }
    
    private func updateDragLocation(_ location: CGPoint) {
        guard !sampledChartData.isEmpty else { return }
        let index = getIndexFromLocation(location)
        dragLocation = location
        draggedPointIndex = index
        draggedPoint = sampledChartData[safe: index]
        isDragging = true
    }
    
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
    
    /// 【重写】O(1) 获取某索引上的标记信息
    private func getMarkerInfo(at index: Int) -> MarkerDisplayInfo {
        var info = MarkerDisplayInfo()
        guard let m = markerIndex[index] else { return info }
        if showRedMarkers { info.red = m.global.first }
        if showOrangeMarkers { info.orange = m.symbol.first }
        if showGreenMarkers, let e = m.earning.first { info.green = String(format: "昨日财报 %.2f%%", e.price) }
        let latest = sampledChartData.last?.price
        if showBuyMarkers, let b = m.buy { info.buy = FTTradeStore.detailText(side: .buy, agg: b, latest: latest) }
        if showSellMarkers, let s = m.sell { info.sell = FTTradeStore.detailText(side: .sell, agg: s, latest: latest) }
        return info
    }
    
    private func formatDate(_ date: Date) -> String { Self.ymdFormatter.string(from: date) }
    private func formatPrice(_ price: Double) -> String { String(format: "%.2f", price) }
    private func formatPercentage(_ value: Double) -> String { String(format: "%.2f%%", value) }
    private func formatXAxisLabel(_ date: Date) -> String {
        switch selectedTimeRange {
        case .oneMonth: return Self.dayLabelFormatter.string(from: date)
        case .threeMonths, .sixMonths, .oneYear: return Self.monthLabelFormatter.string(from: date)
        case .twoYears, .fiveYears, .tenYears, .all: return Self.yearLabelFormatter.string(from: date)
        }
    }
    private func getIndexForDate(_ date: Date) -> Int? {
        let calendar = Calendar.current
        return sampledChartData.firstIndex { priceData in
            switch selectedTimeRange {
            case .oneMonth: return calendar.isDate(priceData.date, inSameDayAs: date)
            case .threeMonths, .sixMonths, .oneYear: return calendar.isDate(priceData.date, equalTo: date, toGranularity: .month)
            case .twoYears, .fiveYears, .tenYears, .all: return calendar.isDate(priceData.date, equalTo: date, toGranularity: .year)
            }
        }
    }
}

extension UIView {
    func findNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController.navigationController
            }
            responder = nextResponder
        }
        return nil
    }
}

// MARK: - 优化的多触控处理 (支持方向性判断、状态无缝切换、底部防误触、完美拦截右滑返回)
struct OptimizedTouchHandler: UIViewRepresentable {
    var onSingleTouchChanged: (CGPoint) -> Void
    var onMultiTouchChanged: (CGPoint, CGPoint) -> Void
    var onTouchesEnded: () -> Void
    var onPinch: (CGFloat) -> Void
    
    func makeUIView(context: Context) -> OptimizedMultitouchView {
        let view = OptimizedMultitouchView()
        view.onSingleTouchChanged = onSingleTouchChanged
        view.onMultiTouchChanged = onMultiTouchChanged
        view.onTouchesEnded = onTouchesEnded
        view.onPinch = onPinch
        view.backgroundColor = .clear
        return view
    }
    
    func updateUIView(_ uiView: OptimizedMultitouchView, context: Context) {
        uiView.onSingleTouchChanged = onSingleTouchChanged
        uiView.onMultiTouchChanged = onMultiTouchChanged
        uiView.onTouchesEnded = onTouchesEnded
        uiView.onPinch = onPinch
    }
    
    class OptimizedMultitouchView: UIView, UIGestureRecognizerDelegate {
        var onSingleTouchChanged: ((CGPoint) -> Void)?
        var onMultiTouchChanged: ((CGPoint, CGPoint) -> Void)?
        var onTouchesEnded: (() -> Void)?
        var onPinch: ((CGFloat) -> Void)?
        
        private var activeTouches: [UITouch: CGPoint] = [:]
        private let bottomEdgeThreshold: CGFloat = 0.0
        private let leftEdgeThreshold: CGFloat = 30.0
        
        private var interceptPanGesture: UIPanGestureRecognizer!
        private var pinchGesture: UIPinchGestureRecognizer!
        
        private var firstTouchTime: Date?
        private var isComparisonLocked: Bool = false
        private var isZoomLocked: Bool = false
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            setupGestures()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isMultipleTouchEnabled = true
            setupGestures()
        }
        
        private func setupGestures() {
            interceptPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleInterceptPan(_:)))
            interceptPanGesture.delegate = self
            interceptPanGesture.cancelsTouchesInView = false
            interceptPanGesture.delaysTouchesBegan = false
            self.addGestureRecognizer(interceptPanGesture)
            
            pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinchGesture.delegate = self
            pinchGesture.cancelsTouchesInView = false
            self.addGestureRecognizer(pinchGesture)
        }
        
        @objc private func handleInterceptPan(_ gesture: UIPanGestureRecognizer) {
            // 霸占滑动控制权
        }
        
        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if isComparisonLocked {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
            switch gesture.state {
            case .began:
                isZoomLocked = true
                onTouchesEnded?()
            case .changed:
                if isZoomLocked {
                    onPinch?(gesture.scale)
                    gesture.scale = 1.0
                }
            case .ended, .cancelled, .failed:
                isZoomLocked = false
            default:
                break
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer == interceptPanGesture || gestureRecognizer == pinchGesture {
                let location = touch.location(in: self)
                if location.x < leftEdgeThreshold {
                    return false
                }
            }
            return true
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer == interceptPanGesture {
                if otherGestureRecognizer is UIPanGestureRecognizer {
                    return true
                }
            }
            return false
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer == pinchGesture || otherGestureRecognizer == pinchGesture {
                return true
            }
            return false
        }
        
        private func purgeStaleTouches(event: UIEvent?) {
            let validPhases: [UITouch.Phase] = [.began, .moved, .stationary]
            for key in activeTouches.keys {
                if !validPhases.contains(key.phase) {
                    activeTouches.removeValue(forKey: key)
                }
            }
            if let allTouches = event?.touches(for: self) {
                for key in activeTouches.keys {
                    if !allTouches.contains(key) {
                        activeTouches.removeValue(forKey: key)
                    }
                }
            }
        }
        
        private func dispatchTouchState() {
            if isZoomLocked { return }
            if activeTouches.isEmpty {
                onTouchesEnded?()
            } else if activeTouches.count == 1 {
                if let loc = activeTouches.values.first {
                    onSingleTouchChanged?(loc)
                }
            } else {
                let points = Array(activeTouches.values.prefix(2))
                onMultiTouchChanged?(points[0], points[1])
            }
        }
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            purgeStaleTouches(event: event)
            let wasEmpty = activeTouches.isEmpty
            for touch in touches {
                let location = touch.location(in: self)
                if location.y > self.bounds.height - bottomEdgeThreshold { continue }
                if location.x < leftEdgeThreshold { continue }
                activeTouches[touch] = location
            }
            if wasEmpty && !activeTouches.isEmpty {
                firstTouchTime = Date()
                isComparisonLocked = false
                isZoomLocked = false
            } else if activeTouches.count >= 2 {
                if let firstTime = firstTouchTime, Date().timeIntervalSince(firstTime) > 0.15 {
                    if !isZoomLocked {
                        isComparisonLocked = true
                    }
                }
            }
            dispatchTouchState()
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            purgeStaleTouches(event: event)
            for touch in touches {
                if activeTouches[touch] != nil {
                   activeTouches[touch] = touch.location(in: self)
                }
            }
            dispatchTouchState()
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches { activeTouches.removeValue(forKey: touch) }
            purgeStaleTouches(event: event)
            if activeTouches.isEmpty {
                isComparisonLocked = false
                isZoomLocked = false
                firstTouchTime = nil
            }
            dispatchTouchState()
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches { activeTouches.removeValue(forKey: touch) }
            purgeStaleTouches(event: event)
            if activeTouches.isEmpty {
                isComparisonLocked = false
                isZoomLocked = false
                firstTouchTime = nil
            }
            dispatchTouchState()
        }
    }
}