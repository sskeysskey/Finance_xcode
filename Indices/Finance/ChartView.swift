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
        case .oneMonth: return 2
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
}

struct BubbleMarker: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
    let pointIndex: Int
    let date: Date
    var position: CGPoint = .zero
    var size: CGSize = .zero
}

// MARK: - 页面布局 ChartView
struct ChartView: View {
    let symbol: String
    let groupName: String
    private let verticalPadding: CGFloat = 20
    private let horizontalPadding: CGFloat = 15 // 【新增】左右留白宽度
    
    @State private var chartData: [DatabaseManager.PriceData] = []
    @State private var sampledChartData: [DatabaseManager.PriceData] = []
    @State private var selectedTimeRange: TimeRange = .sixMonths
    @State private var isLoading = true
    @State private var earningData: [DatabaseManager.EarningData] = []
    @State private var renderedPoints: [RenderedPoint] = []
    
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
    
    // 标记点显示控制
    @State private var showRedMarkers: Bool = false
    @State private var showOrangeMarkers: Bool = true
    @State private var showGreenMarkers: Bool = true
    
    // 成交量显示控制
    @State private var showVolume: Bool = true
    
    @State private var bubbleMarkers: [BubbleMarker] = []
    @State private var shouldUpdateBubbles: Bool = true
    @State private var showBubbles: Bool = false
    
    // 遮罩背板相关状态
    @State private var earningReleaseDate: Date? = nil
    @State private var threeWeeksBeforeRange: (start: Date, end: Date)? = nil
    @State private var oneWeekBeforeRange: (start: Date, end: Date)? = nil
    @State private var fifthWeekRange: (start: Date, end: Date)? = nil
    @State private var thirdWeekRange: (start: Date, end: Date)? = nil

    // 控制跳转到期权详情页
    @State private var navigateToOptionsDetail = false

    // 控制跳转到比对和相似页面
    @State private var navigateToCompare = false
    @State private var navigateToSimilar = false

    @State private var showSubscriptionSheet = false 
    @State private var navigateToBacktest = false 
    
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    
    // MARK: - 核心修复：引入 EnvironmentObject
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager   // 【修复】引入 AuthManager
    @EnvironmentObject var usageManager: UsageManager // 【修复】引入 UsageManager
    
    private var earningTrend: EarningTrend {
        dataService.earningTrends[symbol.uppercased()] ?? .insufficientData
    }
    
    private var currentTags: [String] {
        let upperSymbol = symbol.uppercased()
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return stock.tag
        }
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return etf.tag
        }
        return []
    }
    
    private struct RenderedPoint {
        let x: CGFloat
        let y: CGFloat
        let date: Date
        let price: Double
        let dataIndex: Int
    }
    
    // MARK: - 计算属性
    private var isDarkMode: Bool { colorScheme == .dark }
    private var chartColor: Color { isDarkMode ? Color.white : Color.blue }
    private var backgroundColor: Color { isDarkMode ? Color.black : Color.white }
    private var minPrice: Double { sampledChartData.map { $0.price }.min() ?? 0 }
    private var maxPrice: Double { sampledChartData.map { $0.price }.max() ?? 0 }
    private var priceRange: Double { max(maxPrice - minPrice, 0.01) }
    
    // 【新增】成交额最大值计算
    private var maxVolume: Double {
        // 找出最大的 (volume * price)
        let maxTurnover = sampledChartData.compactMap { point -> Double? in
            guard let vol = point.volume, vol > 0 else { return nil }
            return Double(vol) * point.price
        }.max() ?? 0
        return maxTurnover
    }
    
    private var priceDifferencePercentage: Double? {
        guard let first = firstTouchPoint?.price,
              let second = secondTouchPoint?.price else { return nil }
        return ((second - first) / first) * 100.0
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
                                Text("\(laterDate)").font(.system(size: 16, weight: .medium))
                                Text("\(formatPercentage(percentChange))")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(percentChange >= 0 ? .green : .red)
                            }
                            .padding(.horizontal).padding(.vertical, 8)
                            .background(Color(UIColor.systemGray6)).cornerRadius(8)
                            
                        } else if let point = draggedPoint {
                            let pointDate = formatDate(point.date)
                            let percentChange = calculatePriceChangePercentage(from: point)
                            let markerInfo = getMarkerInfo(for: point.date)
                            
                            VStack(spacing: 5) {
                                HStack(spacing: 8) {
                                    Text("\(pointDate)  \(formatPrice(point.price))")
                                        .font(.system(size: 16, weight: .medium))
                                    if let percentChange = percentChange {
                                        Text(formatPercentage(percentChange))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(percentChange >= 0 ? .green : .red)
                                    }
                                    if let greenText = markerInfo.green {
                                        Text(greenText)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.green)
                                    }
                                    // 【修改】显示成交额信息 (Volume * Price)
                                    if let vol = point.volume, vol > 0 {
                                        let turnover = Double(vol) * point.price // 计算成交额
                                        Text("\(formatVolume(turnover))")
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(.purple)
                                    }
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
            if isLoading {
                ProgressView().scaleEffect(1.5).padding().frame(height: 250)
            } else if sampledChartData.isEmpty {
                Text("No data available").font(.title2).foregroundColor(.gray).frame(height: 250)
            } else {
                ZStack {
                    GeometryReader { geometry in
                        Canvas { context, size in
                            drawChart(context: context, size: size)
                        }
                        
                        // 气泡 Overlay
                        .overlay(
                            ZStack {
                                if !isDragging && !isMultiTouch && showBubbles {
                                    ForEach(bubbleMarkers) { marker in
                                        if (marker.color == .red && showRedMarkers) ||
                                           (marker.color == .orange && showOrangeMarkers) ||
                                           (marker.color == .green && showGreenMarkers) {
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
                                // ✅ 修复：加上 horizontalPadding，并使用 effectiveWidth 来计算步长
                                let x = horizontalPadding + CGFloat(index) * (effectiveWidth / CGFloat(max(1, sampledChartData.count - 1)))
                                
                                Text(formatXAxisLabel(date))
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                                    .position(x: x, y: geometry.size.height - 10)
                            }
                        }
                    }
                    .overlay(
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
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                }
                .frame(height: 320)
                // 【关键修复1】强制图表区域宽度等于屏幕宽度，防止被撑大
                .frame(width: UIScreen.main.bounds.width)
                .padding(.bottom, 30)
            }
            
            // Time Range Buttons
            // 【关键修复2】强制 ScrollView 宽度不超过屏幕宽度
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
                // 居中逻辑：让 HStack 最小宽度为屏幕宽度，这样内容少时会自动居中
                .frame(minWidth: UIScreen.main.bounds.width)
            }
            .frame(height: 50)
            .frame(maxWidth: UIScreen.main.bounds.width) // 限制 ScrollView 自身宽度
            .padding(.vertical, 10)
            
            // Toggles
            HStack(spacing: 10) {
                Toggle(isOn: $showGreenMarkers) {}.toggleStyle(SwitchToggleStyle(tint: .green))
                Toggle(isOn: $showBubbles) {}.toggleStyle(SwitchToggleStyle(tint: .blue))
                Toggle(isOn: $showRedMarkers) {}.toggleStyle(SwitchToggleStyle(tint: .red))
                Toggle(isOn: $showOrangeMarkers) {}.toggleStyle(SwitchToggleStyle(tint: .orange))
                // 【新增】成交量开关
                Toggle(isOn: $showVolume) {}.toggleStyle(SwitchToggleStyle(tint: .purple))
            }
            .padding(.horizontal)
            .padding(.vertical, 30)
            
            // Action Buttons
            HStack(spacing: 20) {
                // 1. 简介 (通常不扣点，保留 NavigationLink)
                NavigationLink(destination: {
                    if let descriptions = getDescriptions(for: symbol) {
                        // 【修改】: 删除了 isDarkMode: isDarkMode
                        DescriptionView(descriptions: descriptions)
                    } else {
                        // 【修改】: 删除了 isDarkMode: isDarkMode
                        DescriptionView(descriptions: ("No description available.", ""))
                    }
                }) {
                    Text("简介").font(.system(size: 22, weight: .medium)).foregroundColor(.blue)
                }
                
                // 2. 比对 (改为 Button + 权限检查)
                Button(action: {
                    if usageManager.canProceed(authManager: authManager, action: .compare) {
                        navigateToCompare = true
                    } else {
                        showSubscriptionSheet = true
                    }
                }) {
                    Text("比对")
                        .font(.system(size: 22, weight: .medium))
                        .padding(.leading, 20)
                        .foregroundColor(.blue)
                }
                
                // 3. 相似 (改为 Button + 权限检查)
                Button(action: {
                    if usageManager.canProceed(authManager: authManager, action: .openList) {
                        navigateToSimilar = true
                    } else {
                        showSubscriptionSheet = true
                    }
                }) {
                    Text("相似")
                        .font(.system(size: 22, weight: .medium))
                        .padding(.leading, 20)
                        .foregroundColor(.blue)
                }
                
                // 【新增】期权按钮逻辑
                if dataService.optionsData.keys.contains(symbol.uppercased()) {
                    Button(action: {
                        // 【核心修改】点击 ChartView 里的期权按钮，扣除 10 点
                        // 现在 usageManager 和 authManager 已经定义，可以正常调用了
                        if usageManager.canProceed(authManager: authManager, action: .viewOptionsDetail) {
                            navigateToOptionsDetail = true
                        } else {
                             showSubscriptionSheet = true 
                        }
                    }) {
                        Text("期权")
                            .font(.system(size: 22, weight: .medium))
                            .padding(.leading, 20)
                            .foregroundColor(.purple)
                    }
                }
                
                // ⬇️⬇️⬇️ 【新增：回溯按钮】 ⬇️⬇️⬇️
                // 放在期权按钮的右边
                Button(action: {
                    // 这里你可以决定是否要加权限检查，如果不需要直接设为 true
                    // if usageManager.canProceed(...) { ... }
                    navigateToBacktest = true
                }) {
                    Text("回溯")
                        .font(.system(size: 22, weight: .medium))
                        .padding(.leading, 20)
                        .foregroundColor(.green) // 使用绿色区分，对应 Python 里的风格
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
            
            // 【新增】记录一次交互
            // 用户成功进入图表页，说明并没有被 UsageManager 拦截，是高质量的交互
            ReviewManager.shared.recordInteraction()
        }
        .navigationDestination(isPresented: $showSearchView) {
            SearchView(isSearchActive: true, dataService: dataService)
        }
        // 【新增】比对页面跳转
        .navigationDestination(isPresented: $navigateToCompare) {
            CompareView(initialSymbol: symbol)
        }
        // 【新增】相似页面跳转
        .navigationDestination(isPresented: $navigateToSimilar) {
            SimilarView(symbol: symbol)
        }
        // 【新增】期权详情页跳转
        .navigationDestination(isPresented: $navigateToOptionsDetail) {
            OptionsDetailView(symbol: symbol.uppercased())
        }
        // 在其他的 .navigationDestination 下面添加这个
        .navigationDestination(isPresented: $navigateToBacktest) {
            BacktestView(symbol: symbol)
        }
        // 【切记】在 ChartView 的 body 末尾添加 Sheet
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() } 
    }
    
    // MARK: - 绘图逻辑 (修复版：统一坐标系)
    private func drawChart(context: GraphicsContext, size: CGSize) {
        let effectiveHeight = size.height - (verticalPadding * 2)
        
        // 1. 定义统一的 Y 轴映射闭包
        let priceToY: (Double) -> CGFloat = { price in
            let normalizedY = CGFloat((price - minPrice) / priceRange)
            return size.height - verticalPadding - (normalizedY * effectiveHeight)
        }

        // 【修改】计算有效宽度和带有边距的步长
        let effectiveWidth = size.width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, sampledChartData.count - 1))
        let halfStep = horizontalStep / 2

        guard let displayStart = sampledChartData.first?.date,
            let displayEnd = sampledChartData.last?.date else { return }

        // 内部函数：计算遮罩范围
        func xBounds(from rawStart: Date, to rawEnd: Date) -> (CGFloat, CGFloat)? {
            let start = max(rawStart, displayStart)
            let end = min(rawEnd, displayEnd)
            guard start <= end else { return nil }
            guard let startIndex = sampledChartData.firstIndex(where: { $0.date >= start }),
                let endIndex = sampledChartData.lastIndex(where: { $0.date <= end }),
                startIndex <= endIndex else { return nil }

            // 【修改】加上 horizontalPadding
            var x1 = horizontalPadding + CGFloat(startIndex) * horizontalStep - halfStep
            var x2 = horizontalPadding + CGFloat(endIndex) * horizontalStep + halfStep
            if startIndex == 0 { x1 = horizontalPadding } else { x1 = max(horizontalPadding, x1) }
            if endIndex == sampledChartData.count - 1 { x2 = size.width - horizontalPadding } else { x2 = min(size.width - horizontalPadding, x2) }
            if x2 <= x1 { x2 = x1 + max(horizontalStep, 2) }
            return (x1, x2)
        }

        func drawRange(_ range: (start: Date, end: Date), tint: Color) {
            guard let (x1, x2) = xBounds(from: range.start, to: range.end) else { return }
            let shadeRect = CGRect(x: x1, y: verticalPadding, width: x2 - x1, height: size.height - verticalPadding * 2)
            context.fill(Path(shadeRect), with: .color(tint.opacity(0.15)))
        }

        // 绘制遮罩
        if let threeWeeks = threeWeeksBeforeRange { drawRange(threeWeeks, tint: .green) }
        if let oneWeek = oneWeekBeforeRange { drawRange(oneWeek, tint: .blue) }
        if let fifthWeek = fifthWeekRange { drawRange(fifthWeek, tint: .blue) }
        if let thirdWeek = thirdWeekRange { drawRange(thirdWeek, tint: .green) }
        
        // 绘制成交量 (Volume)
        if showVolume {
            let maxVol = maxVolume
            if maxVol > 0 {
                let volumeAreaHeight = size.height * 0.20
                let volumeBottomY = size.height - verticalPadding
                
                for (index, point) in sampledChartData.enumerated() {
                    if let vol = point.volume, vol > 0 {
                        // 【修改】加上 horizontalPadding
                        let x = horizontalPadding + CGFloat(index) * horizontalStep
                        let turnover = Double(vol) * point.price
                        let barHeight = CGFloat(turnover / maxVol) * volumeAreaHeight
                        let y = volumeBottomY - barHeight
                        let barWidth = max(1, horizontalStep * 0.6)
                        let barRect = CGRect(x: x - barWidth/2, y: y, width: barWidth, height: barHeight)
                        context.fill(Path(barRect), with: .color(Color.purple.opacity(0.5)))
                    }
                }
            }
        }
        
        // 3. 【核心修复】直接基于 sampledChartData 和当前 size 绘制价格线
        // 不再使用 renderedPoints，确保线和点使用相同的计算逻辑
        if !sampledChartData.isEmpty {
            var pricePath = Path()
            
            // 【修改】起点加上 horizontalPadding
            let startX = horizontalPadding
            let startY = priceToY(sampledChartData[0].price)
            pricePath.move(to: CGPoint(x: startX, y: startY))
            
            // 连接后续点
            for index in 1..<sampledChartData.count {
                // 【修改】加上 horizontalPadding
                let x = horizontalPadding + CGFloat(index) * horizontalStep
                let y = priceToY(sampledChartData[index].price)
                pricePath.addLine(to: CGPoint(x: x, y: y))
            }
            
            context.stroke(pricePath, with: .color(chartColor), lineWidth: 2)
            
            // 绘制线上的小黑点 (1M/3M/6M 模式)
            if [.oneMonth, .threeMonths, .sixMonths].contains(selectedTimeRange) {
                for (index, point) in sampledChartData.enumerated() {
                    // 【修改】加上 horizontalPadding
                    let x = horizontalPadding + CGFloat(index) * horizontalStep
                    let y = priceToY(point.price)
                    let dotRect = CGRect(x: x - 2, y: y - 2, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.black))
                }
            }
        }
        
        // 绘制零线
        if minPrice < 0 {
            let effectiveMaxPrice = max(maxPrice, 0)
            let effectiveRange = effectiveMaxPrice - minPrice
            let zeroY = size.height - verticalPadding - CGFloat((0 - minPrice) / effectiveRange) * effectiveHeight
            var zeroPath = Path()
            // 【修改】零线也适应边距
            zeroPath.move(to: CGPoint(x: horizontalPadding, y: zeroY))
            zeroPath.addLine(to: CGPoint(x: size.width - horizontalPadding, y: zeroY))
            context.stroke(zeroPath, with: .color(Color.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4]))
        }
        
        // 绘制标记点
        for marker in getTimeMarkers() {
            if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, marker.date) }) {
                let shouldShow = (marker.type == .global && showRedMarkers) ||
                            (marker.type == .symbol && showOrangeMarkers) ||
                            (marker.type == .earning && showGreenMarkers)
                if shouldShow {
                    // 【修改】加上 horizontalPadding
                    let x = horizontalPadding + CGFloat(index) * horizontalStep
                    let y = priceToY(sampledChartData[index].price)
                    let markerPath = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    context.fill(markerPath, with: .color(marker.color))
                }
            }
        }
        
        // 绘制触摸指示器
        if isMultiTouch {
            // 双指逻辑
            if let firstIndex = firstTouchPointIndex, let firstPoint = firstTouchPoint {
                // 【修改】加上 horizontalPadding
                let x = horizontalPadding + CGFloat(firstIndex) * horizontalStep
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
                // 【修改】加上 horizontalPadding
                let x = horizontalPadding + CGFloat(secondIndex) * horizontalStep
                let y = priceToY(secondPoint.price)
                var linePath = Path()
                linePath.move(to: CGPoint(x: x, y: 0))
                linePath.addLine(to: CGPoint(x: x, y: verticalPadding))
                linePath.addLine(to: CGPoint(x: x, y: size.height - verticalPadding))
                context.stroke(linePath, with: .color(Color.gray), style: StrokeStyle(lineWidth: 1, dash: [4]))
                let circlePath = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                context.fill(circlePath, with: .color(Color.white))
                context.stroke(circlePath, with: .color(chartColor), lineWidth: 2)
            }
            if let firstIndex = firstTouchPointIndex, let secondIndex = secondTouchPointIndex,
            let firstPoint = firstTouchPoint, let secondPoint = secondTouchPoint {
                // 【修改】加上 horizontalPadding
                let x1 = horizontalPadding + CGFloat(firstIndex) * horizontalStep
                let y1 = priceToY(firstPoint.price)
                let x2 = horizontalPadding + CGFloat(secondIndex) * horizontalStep
                let y2 = priceToY(secondPoint.price)
                var connectPath = Path()
                connectPath.move(to: CGPoint(x: x1, y: y1))
                connectPath.addLine(to: CGPoint(x: x2, y: y2))
                let lineColor = secondPoint.price >= firstPoint.price ? Color.green : Color.red
                context.stroke(connectPath, with: .color(lineColor), style: StrokeStyle(lineWidth: 1, dash: [2]))
            }
        } else if let pointIndex = draggedPointIndex {
            // 【修改】加上 horizontalPadding
            let x = horizontalPadding + CGFloat(pointIndex) * horizontalStep
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
    
    // MARK: - 逻辑方法
    private func updateRenderedPoints() {
        let width = UIScreen.main.bounds.width
        let height: CGFloat = 320
        let effectiveHeight = height - (verticalPadding * 2)
        // 【修改】
        let effectiveWidth = width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, sampledChartData.count - 1))
        
        renderedPoints = sampledChartData.enumerated().map { index, point in
            // 【修改】
            let x = horizontalPadding + CGFloat(index) * horizontalStep
            let normalizedY = CGFloat((point.price - minPrice) / priceRange)
            let y = height - verticalPadding - (normalizedY * effectiveHeight)
            return RenderedPoint(x: x, y: y, date: point.date, price: point.price, dataIndex: index)
        }
    }
    
    private func findClosestDataPoint(to targetDate: Date, in data: [DatabaseManager.PriceData]) -> DatabaseManager.PriceData? {
        let calendar = Calendar.current
        let targetMonth = calendar.component(.month, from: targetDate)
        let targetYear = calendar.component(.year, from: targetDate)
        let sameMonthData = data.filter { point in
            let pointMonth = calendar.component(.month, from: point.date)
            let pointYear = calendar.component(.year, from: point.date)
            return pointMonth == targetMonth && pointYear == targetYear
        }
        if !sameMonthData.isEmpty {
            return sameMonthData.min { abs($0.date.timeIntervalSince(targetDate)) < abs($1.date.timeIntervalSince(targetDate)) }
        }
        let monthRange = 1
        let extendedData = data.filter { point in
            let components = calendar.dateComponents([.month], from: targetDate, to: point.date)
            guard let monthDiff = components.month else { return false }
            return abs(monthDiff) <= monthRange
        }
        return extendedData.min { abs($0.date.timeIntervalSince(targetDate)) < abs($1.date.timeIntervalSince(targetDate)) }
    }
    
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
        guard let latestPrice = sampledChartData.last?.price else { return nil }
        return ((latestPrice - point.price) / point.price) * 100.0
    }
    
    // 【修改】格式化成交额 (支持传入 Double)
    private func formatVolume(_ amount: Double) -> String {
        if amount >= 1_000_000_000 {
            return String(format: "%.2fB", amount / 1_000_000_000)
        } else if amount >= 1_000_000 {
            return String(format: "%.2fM", amount / 1_000_000)
        } else if amount >= 1_000 {
            return String(format: "%.2fK", amount / 1_000) // 改为保留两位小数
        } else {
            return String(format: "%.2f", amount) // 小额也保留两位小数
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
            let newData = await DatabaseManager.shared.fetchHistoricalData(symbol: symbol, tableName: groupName, dateRange: .timeRange(selectedTimeRange))
            let earnings = await DatabaseManager.shared.fetchEarningData(forSymbol: symbol)
            let sampledData = sampleData(newData, rate: selectedTimeRange.samplingRate())

            await MainActor.run {
                chartData = newData
                sampledChartData = sampledData
                earningData = earnings
                
                if let latestEarningDate = earnings.max(by: { $0.date < $1.date })?.date {
                    fifthWeekRange = calculateWeekRangeForward(from: latestEarningDate, weeksForward: 5)
                    thirdWeekRange = calculateWeekRangeForward(from: latestEarningDate, weeksForward: 3)
                } else {
                    fifthWeekRange = nil
                    thirdWeekRange = nil
                }
                
                isLoading = false
                updateRenderedPoints()
                resetTouchStates()
                updateBubbleMarkers()
            }
        }
    }
    
    private func updateBubbleMarkers() {
        let width = UIScreen.main.bounds.width
        // 【修改】计算带有边距的步长
        let effectiveWidth = width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, sampledChartData.count - 1))
        let maxLabelWidth: CGFloat = 120
        var markers: [BubbleMarker] = []
        
        // Helper to add marker
        func addMarker(date: Date, text: String, color: Color) {
            if let exactIndex = sampledChartData.firstIndex(where: { isSameDay($0.date, date) }) {
                // 【修改】加上 horizontalPadding
                let x = horizontalPadding + CGFloat(exactIndex) * horizontalStep
                let y = getYForPrice(sampledChartData[exactIndex].price)
                markers.append(BubbleMarker(text: text, color: color, pointIndex: exactIndex, date: date, position: CGPoint(x: x, y: y), size: CGSize(width: min(max(text.count * 7, 40), Int(maxLabelWidth)), height: 0)))
            } else if let closestPoint = findClosestDataPoint(to: date, in: sampledChartData),
                      let closestIndex = sampledChartData.firstIndex(where: { $0.date == closestPoint.date }) {
                // 【修改】加上 horizontalPadding
                let x = horizontalPadding + CGFloat(closestIndex) * horizontalStep
                let y = getYForPrice(closestPoint.price)
                markers.append(BubbleMarker(text: text, color: color, pointIndex: closestIndex, date: closestPoint.date, position: CGPoint(x: x, y: y), size: CGSize(width: min(max(text.count * 7, 40), Int(maxLabelWidth)), height: 0)))
            }
        }
        
        for (date, text) in dataService.globalTimeMarkers { addMarker(date: date, text: text, color: .red) }
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, text) in symbolMarkers { addMarker(date: date, text: text, color: .orange) }
        }
        for earning in earningData {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MM-dd"
            let dateStr = dateFormatter.string(from: earning.date)
            
            // 计算逻辑
            var priceChangePercent: Double = 0.0
            if let exactIndex = sampledChartData.firstIndex(where: { isSameDay($0.date, earning.date) }) {
                let currentPrice = sampledChartData[exactIndex].price
                let latestPrice = sampledChartData.last?.price ?? currentPrice
                priceChangePercent = ((latestPrice - currentPrice) / currentPrice) * 100
            } else if let closestPoint = findClosestDataPoint(to: earning.date, in: sampledChartData) {
                let currentPrice = closestPoint.price
                let latestPrice = sampledChartData.last?.price ?? currentPrice
                priceChangePercent = ((latestPrice - currentPrice) / currentPrice) * 100
            }
            
            let text = "\(dateStr) \(String(format: "%.2f%%", earning.price))\n\(String(format: "%+.2f%%", priceChangePercent))"
            addMarker(date: earning.date, text: text, color: .green)
        }
        
        let optimizedMarkers = optimizeBubbleLayout(markers, canvasWidth: width, canvasHeight: 320)
        withAnimation { self.bubbleMarkers = optimizedMarkers }
    }
    
    private func getYForPrice(_ price: Double) -> CGFloat {
        let height: CGFloat = 320
        let effectiveHeight = height - (verticalPadding * 2)
        let normalizedY = CGFloat((price - minPrice) / priceRange)
        return height - verticalPadding - (normalizedY * effectiveHeight)
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
        
        // Merge results back
        for m in upperResult + lowerResult {
            if let idx = optimizedMarkers.firstIndex(where: { $0.id == m.id }) {
                optimizedMarkers[idx] = m
                // Boundary check
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !self.isDragging && !self.isMultiTouch {
                self.shouldUpdateBubbles = true
                self.updateBubbleMarkers()
            }
        }
    }
    
    private func sampleData(_ data: [DatabaseManager.PriceData], rate: Int) -> [DatabaseManager.PriceData] {
        guard rate > 1, !data.isEmpty else { return data }
        let calendar = Calendar.current
        let startDate = data.first?.date ?? Date()
        let endDate = data.last?.date ?? Date()
        let totalDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        let dataDensity = totalDays / data.count
        if dataDensity > 2 { return data }
        
        var adjustedRate = rate
        // 简化采样率逻辑，避免过长
        if selectedTimeRange == .twoYears && totalDays < 365 { adjustedRate = 1 }
        else if selectedTimeRange == .all && totalDays < 365 { adjustedRate = 1 }
        
        if adjustedRate <= 1 { return data }

        var result: [DatabaseManager.PriceData] = []
        if let first = data.first { result.append(first) }
        
        var specialDates: [Date] = []
        for (date, _) in dataService.globalTimeMarkers { if data.contains(where: { isSameDay($0.date, date) }) { specialDates.append(date) } }
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, _) in symbolMarkers { if data.contains(where: { isSameDay($0.date, date) }) { specialDates.append(date) } }
        }
        for earning in earningData { if data.contains(where: { isSameDay($0.date, earning.date) }) { specialDates.append(earning.date) } }
        
        let priceChangeThreshold = 0.005
        var lastIncludedIndex = 0
        for i in stride(from: adjustedRate, to: data.count - 1, by: adjustedRate) {
            let lastIncludedPrice = data[lastIncludedIndex].price
            let currentPrice = data[i].price
            let isSpecialDate = specialDates.contains(where: { isSameDay(data[i].date, $0) })
            
            if isSpecialDate || abs((currentPrice - lastIncludedPrice) / lastIncludedPrice) > priceChangeThreshold {
                result.append(data[i])
                lastIncludedIndex = i
            } else if i % (adjustedRate * 2) == 0 {
                result.append(data[i])
                lastIncludedIndex = i
            }
        }
        if let last = data.last, result.last?.id != last.id { result.append(last) }
        
        // Ensure special dates are included
        for date in specialDates {
            if !result.contains(where: { isSameDay($0.date, date) }) {
                if let exactMatch = data.first(where: { isSameDay($0.date, date) }) { result.append(exactMatch) }
                else if let closestPoint = findClosestDataPoint(to: date, in: data) { result.append(closestPoint) }
            }
        }
        result.sort { $0.date < $1.date }
        return result
    }
    
    private func getIndexFromLocation(_ location: CGPoint) -> Int {
        guard !sampledChartData.isEmpty else { return 0 }
        let width = UIScreen.main.bounds.width
        // 【修改】使用 effectiveWidth 和 relativeX
        let effectiveWidth = width - (horizontalPadding * 2)
        let horizontalStep = effectiveWidth / CGFloat(max(1, sampledChartData.count - 1))
        
        // 减去左侧边距得到相对 X 坐标
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
    
    private enum MarkerType { case global, symbol, earning }
    private struct TimeMarker: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let type: MarkerType
        var color: Color {
            switch type {
            case .global: return .red
            case .symbol: return .orange
            case .earning: return .green
            }
        }
    }
    
    private func getTimeMarkers() -> [TimeMarker] {
        var markers: [TimeMarker] = []
        for (date, text) in dataService.globalTimeMarkers {
            if let exactMatch = sampledChartData.first(where: { isSameDay($0.date, date) }) {
                markers.append(TimeMarker(date: exactMatch.date, text: text, type: .global))
            } else if let closestPoint = findClosestDataPoint(to: date, in: sampledChartData) {
                markers.append(TimeMarker(date: closestPoint.date, text: text, type: .global))
            }
        }
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, text) in symbolMarkers {
                if let exactMatch = sampledChartData.first(where: { isSameDay($0.date, date) }) {
                    markers.append(TimeMarker(date: exactMatch.date, text: text, type: .symbol))
                } else if let closestPoint = findClosestDataPoint(to: date, in: sampledChartData) {
                    markers.append(TimeMarker(date: closestPoint.date, text: text, type: .symbol))
                }
            }
        }
        for earning in earningData {
            let earningText = String(format: "%.2f", earning.price)
            if let exactMatch = sampledChartData.first(where: { isSameDay($0.date, earning.date) }) {
                markers.append(TimeMarker(date: exactMatch.date, text: earningText, type: .earning))
            } else if let closestPoint = findClosestDataPoint(to: earning.date, in: sampledChartData) {
                markers.append(TimeMarker(date: closestPoint.date, text: earningText, type: .earning))
            }
        }
        return markers
    }
    
    private func getMarkerInfo(for date: Date) -> MarkerDisplayInfo {
        var info = MarkerDisplayInfo()
        if showRedMarkers {
            if let text = dataService.globalTimeMarkers.first(where: { isSameDay($0.key, date) })?.value { info.red = text }
            else if let (_, text) = dataService.globalTimeMarkers.first(where: { findClosestDataPoint(to: $0.key, in: sampledChartData)?.date == date }) { info.red = text }
        }
        if showOrangeMarkers, let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            if let text = symbolMarkers.first(where: { isSameDay($0.key, date) })?.value { info.orange = text }
            else if let (_, text) = symbolMarkers.first(where: { findClosestDataPoint(to: $0.key, in: sampledChartData)?.date == date }) { info.orange = text }
        }
        if showGreenMarkers {
            if let earningPoint = earningData.first(where: { isSameDay($0.date, date) }) { info.green = String(format: "昨日财报 %.2f%%", earningPoint.price) }
            else if let earningPoint = earningData.first(where: { findClosestDataPoint(to: $0.date, in: sampledChartData)?.date == date }) { info.green = String(format: "昨日财报 %.2f%%", earningPoint.price) }
        }
        return info
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func formatPrice(_ price: Double) -> String { String(format: "%.2f", price) }
    private func formatPercentage(_ value: Double) -> String { String(format: "%.2f%%", value) }
    private func formatXAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch selectedTimeRange {
        case .oneMonth: formatter.dateFormat = "dd"
        case .threeMonths, .sixMonths, .oneYear: formatter.dateFormat = "MMM"
        case .twoYears, .fiveYears, .tenYears, .all: formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: date)
    }
    private func isSameDay(_ date1: Date, _ date2: Date) -> Bool { Calendar.current.isDate(date1, inSameDayAs: date2) }
    private func getIndexForDate(_ date: Date) -> Int? {
        sampledChartData.firstIndex { priceData in
            let calendar = Calendar.current
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
    
    func makeUIView(context: Context) -> OptimizedMultitouchView {
        let view = OptimizedMultitouchView()
        view.onSingleTouchChanged = onSingleTouchChanged
        view.onMultiTouchChanged = onMultiTouchChanged
        view.onTouchesEnded = onTouchesEnded
        view.backgroundColor = .clear
        return view
    }
    
    func updateUIView(_ uiView: OptimizedMultitouchView, context: Context) {
        uiView.onSingleTouchChanged = onSingleTouchChanged
        uiView.onMultiTouchChanged = onMultiTouchChanged
        uiView.onTouchesEnded = onTouchesEnded
    }
    
    class OptimizedMultitouchView: UIView, UIGestureRecognizerDelegate {
        var onSingleTouchChanged: ((CGPoint) -> Void)?
        var onMultiTouchChanged: ((CGPoint, CGPoint) -> Void)?
        var onTouchesEnded: (() -> Void)?
        
        private var activeTouches: [UITouch: CGPoint] = [:]
        private let bottomEdgeThreshold: CGFloat = 30.0
        private let leftEdgeThreshold: CGFloat = 30.0
        
        // 专门用来“霸占”控制权的拦截手势
        private var interceptPanGesture: UIPanGestureRecognizer!
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            setupInterceptGesture()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isMultipleTouchEnabled = true
            setupInterceptGesture()
        }
        
        // MARK: - 核心修复：终极拦截手势
        private func setupInterceptGesture() {
            interceptPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleInterceptPan(_:)))
            interceptPanGesture.delegate = self
            
            // 关键：绝对不能取消底层的 touchesBegan，否则虚线出不来
            interceptPanGesture.cancelsTouchesInView = false
            interceptPanGesture.delaysTouchesBegan = false
            
            self.addGestureRecognizer(interceptPanGesture)
        }
        
        @objc private func handleInterceptPan(_ gesture: UIPanGestureRecognizer) {
            // 这个手势专门用来“霸占”滑动的控制权，所以方法里面什么都不需要写
            // 只要它被触发，外层的返回手势就会被扼杀
        }
        
        // MARK: - UIGestureRecognizerDelegate 魔法
        
        // 1. 过滤边缘触摸：如果是贴着左边滑动，主动失效，让给系统返回
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer == interceptPanGesture {
                let location = touch.location(in: self)
                // 只要在屏幕最左侧 30pt 内，图表放弃挣扎，让系统接管
                if location.x < leftEdgeThreshold {
                    return false
                }
            }
            return true
        }
        
        // 2. 强制镇压外层手势：要求其他所有 Pan 手势（包括全屏返回、边缘返回）必须等我们失败！
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer == interceptPanGesture {
                // 如果其他手势也是滑动类型（UIPanGestureRecognizer），统统强行让步。
                // 因为我们在屏幕中央滑动时（上面的代理返回了 true），拦截手势处于活跃且成功的状态，
                // 这会导致被迫等待的外层手势（如系统返回）直接失败被取消！
                if otherGestureRecognizer is UIPanGestureRecognizer {
                    return true
                }
            }
            return false
        }
        
        // 3. 拒绝同时识别：图表滑动和系统返回，绝对不允许同时发生
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return false
        }
        
        // MARK: - 触摸事件处理
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let location = touch.location(in: self)
                if location.y > self.bounds.height - bottomEdgeThreshold { continue }
                if location.x < leftEdgeThreshold { continue } // 边缘触摸不触发虚线
                
                activeTouches[touch] = location
            }
            
            if activeTouches.isEmpty { return }
            
            if activeTouches.count >= 2 {
                updateMultiTouch()
            } else if activeTouches.count == 1 {
                if let touch = activeTouches.keys.first, let loc = activeTouches[touch] {
                    onSingleTouchChanged?(loc)
                }
            }
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                if activeTouches[touch] != nil {
                   activeTouches[touch] = touch.location(in: self)
                }
            }
            
            if activeTouches.count >= 2 {
                updateMultiTouch()
            } else if activeTouches.count == 1 {
                if let touch = activeTouches.keys.first, let loc = activeTouches[touch] {
                    onSingleTouchChanged?(loc)
                }
            }
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            handleTouchesEnd(touches)
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            handleTouchesEnd(touches)
        }
        
        private func handleTouchesEnd(_ touches: Set<UITouch>) {
            for touch in touches {
                activeTouches.removeValue(forKey: touch)
            }
            
            if activeTouches.isEmpty {
                onTouchesEnded?()
            } else if activeTouches.count == 1 {
                if let remainingTouch = activeTouches.keys.first, let loc = activeTouches[remainingTouch] {
                    onSingleTouchChanged?(loc)
                }
            } else if activeTouches.count >= 2 {
                updateMultiTouch()
            }
        }
        
        private func updateMultiTouch() {
            let touchPoints = Array(activeTouches.values)
            if touchPoints.count >= 2 {
                onMultiTouchChanged?(touchPoints[0], touchPoints[1])
            }
        }
    }
}