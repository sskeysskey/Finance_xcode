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
    @State private var dragLocation: CGPoint?
    @State private var secondDragLocation: CGPoint?
    @State private var draggedPointIndex: Int?
    @State private var secondDraggedPointIndex: Int?
    @State private var draggedPoint: DatabaseManager.PriceData?
    @State private var secondDraggedPoint: DatabaseManager.PriceData?
    @State private var isDragging = false // 添加滑动状态跟踪
    @State private var isDualDragging = false // 添加双指滑动状态跟踪
    
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
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Chart header with drag information
            VStack {
                if let point = draggedPoint {
                    let pointDate = formatDate(point.date)
                    if let secondPoint = secondDraggedPoint {
                        let secondPointDate = formatDate(secondPoint.date)
                        // 显示两个点的情况
                        HStack {
                            Text("\(pointDate): \(formatPrice(point.price))")
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                            let percentChange = ((secondPoint.price - point.price) / point.price) * 100
                            Text("\(secondPointDate): \(formatPrice(secondPoint.price)) (\(formatPercentage(percentChange)))")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(percentChange >= 0 ? .green : .red)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemGray6))
                        .cornerRadius(8)
                    } else {
                        // 显示单个点的情况
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
                    }
                } else {
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
                        ForEach(getTimeMarkers(), id: \.id) { marker in
                            if let index = sampledChartData.firstIndex(where: { isSameDay($0.date, marker.date) }) {
                                let x = CGFloat(index) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                                let y = geometry.size.height - CGFloat((sampledChartData[index].price - minPrice) / priceRange) * geometry.size.height
                                
                                Circle()
                                    .fill(marker.isGlobal ? Color.red : Color.orange)
                                    .frame(width: 8, height: 8)
                                    .position(x: x, y: y)
                            }
                        }
                        
                        // 拖动线 1 - 使用虚线
                        if let location = dragLocation, let pointIndex = draggedPointIndex {
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
                        
                        // 拖动线 2 - 使用虚线
                        if let location = secondDragLocation, let pointIndex = secondDraggedPointIndex {
                            let x = CGFloat(pointIndex) * (geometry.size.width / CGFloat(max(1, sampledChartData.count - 1)))
                            
                            Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundColor(Color.gray)
                            
                            // 高亮显示第二个点
                            if let point = secondDraggedPoint {
                                let y = geometry.size.height - CGFloat((point.price - minPrice) / priceRange) * geometry.size.height
                                
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.green, lineWidth: 2)
                                    )
                                    .position(x: x, y: y)
                            }
                        }
                    }
                    // 改进手势处理逻辑，使用longPressGesture配合dragGesture实现连续跟随效果
                    .contentShape(Rectangle()) // 确保整个区域都能接收手势
                    .gesture(
                        // 长按手势，激活拖动状态
                        LongPressGesture(minimumDuration: 0.1)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                switch value {
                                case .first(true):
                                    // 长按开始，准备拖动
                                    isDragging = true
                                    isDualDragging = false
                                    secondDragLocation = nil
                                    secondDraggedPointIndex = nil
                                    secondDraggedPoint = nil
                                case .second(true, let drag):
                                    // 拖动中
                                    if let location = drag?.location {
                                        updateDragLocation(location)
                                    }
                                default:
                                    break
                                }
                            }
                            .onEnded { _ in
                                // 保持最后的拖动状态，不重置
                                isDragging = false
                            }
                    )
                    // 添加双指手势
                    .simultaneousGesture(
                        // 使用MagnificationGesture检测双指操作
                        MagnificationGesture(minimumScaleDelta: 0.01)
                            .onChanged { _ in
                                if !isDualDragging && draggedPoint != nil {
                                    isDualDragging = true
                                    // 保持第一个点的位置，启用第二个点
                                    secondDragLocation = dragLocation
                                    secondDraggedPointIndex = draggedPointIndex
                                    secondDraggedPoint = draggedPoint
                                }
                            }
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
            
            // 对长期数据进行采样，提高性能
            let sampledData = sampleData(newData, rate: selectedTimeRange.samplingRate())
            print("采样后数据点数: \(sampledData.count)")

            DispatchQueue.main.async {
                chartData = newData
                sampledChartData = sampledData
                isLoading = false
                // 重置拖动状态
                dragLocation = nil
                secondDragLocation = nil
                draggedPointIndex = nil
                secondDraggedPointIndex = nil
                draggedPoint = nil
                secondDraggedPoint = nil
                print("数据已更新到UI")
            }
        }
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
    
    // 更新拖动位置和选中的数据点
    private func updateDragLocation(_ location: CGPoint) {
        guard !sampledChartData.isEmpty else { return }
        
        let width = UIScreen.main.bounds.width
        let horizontalStep = width / CGFloat(max(1, sampledChartData.count - 1))
        let index = min(sampledChartData.count - 1, max(0, Int(location.x / horizontalStep)))
        
        if isDualDragging {
            // 第二个点移动
            secondDragLocation = location
            secondDraggedPointIndex = index
            if index < sampledChartData.count {
                secondDraggedPoint = sampledChartData[index]
            }
        } else {
            // 第一个点移动
            dragLocation = location
            draggedPointIndex = index
            if index < sampledChartData.count {
                draggedPoint = sampledChartData[index]
            }
        }
    }
    
    // 获取时间点标记
    private struct TimeMarker: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let isGlobal: Bool
    }
    
    private func getTimeMarkers() -> [TimeMarker] {
        var markers: [TimeMarker] = []
        
        // 添加全局时间标记
        for (date, text) in dataService.globalTimeMarkers {
            if sampledChartData.contains(where: { isSameDay($0.date, date) }) {
                markers.append(TimeMarker(date: date, text: text, isGlobal: true))
            }
        }
        
        // 添加特定股票的时间标记
        if let symbolMarkers = dataService.symbolTimeMarkers[symbol.uppercased()] {
            for (date, text) in symbolMarkers {
                if sampledChartData.contains(where: { isSameDay($0.date, date) }) {
                    markers.append(TimeMarker(date: date, text: text, isGlobal: false))
                }
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
