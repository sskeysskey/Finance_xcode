import SwiftUI
import Charts // 导入苹果原生的 Charts 框架

// MARK: - CompareView (此视图基本不变，仅导航目标有变化)
struct CompareView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var dataService: DataService
    
    // 【新增】权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    // 【修改】移除 showLoginSheet
    @State private var showSubscriptionSheet = false
    
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
    @State private var startDate: Date = Calendar.current.date(from: DateComponents(year: 2024))!
    
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
                    
                    // Stock symbol input fields
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<symbols.count, id: \.self) { index in
                            HStack {
                                CustomTextField(
                                    placeholder: "股票代码 \(index + 1)",
                                    text: $symbols[index],
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
                    symbols.append(initialSymbol)
                }
                symbols.append("")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    focusedField = initialSymbol.isEmpty ? 0 : 1
                }
            }
        }
        .navigationDestination(isPresented: $navigateToComparison) {
            // 导航目标变为新的 ComparisonChartView
            ComparisonChartView(symbols: symbols, startDate: startDate, endDate: endDate)
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("错误"), message: Text(errorMessage ?? "未知错误"), dismissButton: .default(Text("确定")))
        }
        // 【修改】移除了 LoginView 的 sheet
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    func formatSymbol(_ symbol: String) -> String {
        guard let url = Bundle.main.url(forResource: "Sectors_All", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sectorData = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: [String]] else {
            return symbol
        }
        
        for (_, symbolList) in sectorData {
            for originalJsonSymbol in symbolList {
                if originalJsonSymbol == symbol {
                    return originalJsonSymbol
                }
            }
        }
        return symbol
    }
    
    private func startComparison() {
        // 【新增】权限检查
        guard usageManager.canProceed(authManager: authManager) else {
            // 【核心修改】直接弹出订阅页
            showSubscriptionSheet = true
            return
        }
        
        errorMessage = nil
        let trimmedSymbols = symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmedSymbols.isEmpty else { errorMessage = "请至少输入一个股票代码"; showAlert = true; return }
        if trimmedSymbols.count > maxSymbols { errorMessage = "最多只能比较 \(maxSymbols) 个股票代码"; showAlert = true; return }
        guard startDate <= endDate else { errorMessage = "开始日期必须早于或等于结束日期"; showAlert = true; return }
        symbols = trimmedSymbols.map { formatSymbol($0) }
        navigateToComparison = true
    }
}

// MARK: - CustomTextField (无变化)
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

// MARK: - ComparisonChartView (此视图结构更新，使用新的原生图表)
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
                // 调用新的原生 Swift Charts 视图
                NativeComparisonChartView(data: chartData, isDarkMode: true)
                    .frame(height: 350)
                    .padding(.horizontal, 4)
                    .padding(.vertical)
            }
            Spacer()
        }
        .onAppear {
            loadComparisonData()
        }
    }
    
    // loadComparisonData 函数保持不变
    private func loadComparisonData() {
        isLoading = true
        errorMessage = nil
        
        // 使用 Task
        Task {
            var tempData: [String: [DatabaseManager.PriceData]] = [:]
            var shortestDateRange: (start: Date, end: Date)?
            var errorMsg: String? = nil
            
            // 并发获取数据
            await withTaskGroup(of: (String, [DatabaseManager.PriceData]?).self) { group in
                for symbol in symbols {
                    group.addTask {
                        guard let tableName = await MainActor.run(body: { dataService.getCategory(for: symbol) }) else {
                            return (symbol, nil) // 找不到分类
                        }
                        
                        let data = await DatabaseManager.shared.fetchHistoricalData(
                            symbol: symbol,
                            tableName: tableName,
                            dateRange: .customRange(start: startDate, end: endDate)
                        )
                        return (symbol, data)
                    }
                }
                
                for await (symbol, data) in group {
                    if let data = data, !data.isEmpty {
                        tempData[symbol] = data
                    } else {
                        // 只要有一个失败，就标记错误（或者你可以选择忽略失败的）
                        if errorMsg == nil { errorMsg = "未找到 \(symbol) 的数据" }
                    }
                }
            }
            
            if let error = errorMsg {
                await MainActor.run {
                    self.errorMessage = error
                    self.isLoading = false
                }
                return
            }
            
            // 数据处理逻辑 (CPU 密集)
            for (symbol, data) in tempData {
                let sortedData = data.sorted { $0.date < $1.date }
                tempData[symbol] = sortedData
                
                let currentStart = sortedData.first?.date ?? startDate
                let currentEnd = sortedData.last?.date ?? endDate
                
                if let existingRange = shortestDateRange {
                    shortestDateRange = (
                        start: max(existingRange.start, currentStart),
                        end: min(existingRange.end, currentEnd)
                    )
                } else {
                    shortestDateRange = (currentStart, currentEnd)
                }
            }
            
            guard let dateRange = shortestDateRange else {
                await MainActor.run {
                    self.errorMessage = "无法确定共同的日期范围"
                    self.isLoading = false
                }
                return
            }
            
            for (symbol, data) in tempData {
                var filteredData = data.filter {
                    $0.date >= dateRange.start && $0.date <= dateRange.end
                }
                filteredData = filteredData.lttbSampled(threshold: 150)
                tempData[symbol] = filteredData
            }
            
            await MainActor.run {
                chartData = tempData
                isLoading = false
            }
        }
    }
}

// MARK: - Array Extension (LTTB 采样算法，无变化)
extension Array where Element == DatabaseManager.PriceData {
    func lttbSampled(threshold: Int) -> [DatabaseManager.PriceData] {
        let count = self.count
        guard threshold >= 3, count > threshold else {
            return self
        }
        
        var sampled: [DatabaseManager.PriceData] = []
        sampled.append(self[0])
        var a = 0
        
        let bucketSize = Double(count - 2) / Double(threshold - 2)
        
        for i in 0..<(threshold - 2) {
            let bucketStart = Int(floor(Double(i) * bucketSize)) + 1
            let bucketEnd = Int(floor(Double(i + 1) * bucketSize)) + 1
            let nextBucketEnd = Swift.min(bucketEnd, count)
            
            var avgX = 0.0, avgY = 0.0
            let rangeCount = Double(nextBucketEnd - bucketStart)
            for j in bucketStart..<nextBucketEnd {
                avgX += self[j].date.timeIntervalSince1970
                avgY += self[j].price
            }
            avgX /= rangeCount
            avgY /= rangeCount
            
            let currentBucket = bucketStart..<Swift.min(bucketEnd, count)
            
            var maxArea = -Double.infinity
            var maxAreaIndex = currentBucket.lowerBound
            let pointA = self[a]
            let ax = pointA.date.timeIntervalSince1970
            let ay = pointA.price
            
            for j in currentBucket {
                let bx = self[j].date.timeIntervalSince1970
                let by = self[j].price
                let area = abs((ax - avgX) * (by - ay) - (ax - bx) * (avgY - ay))
                if area > maxArea {
                    maxArea = area
                    maxAreaIndex = j
                }
            }
            
            sampled.append(self[maxAreaIndex])
            a = maxAreaIndex
        }
        
        sampled.append(self[count - 1])
        return sampled
    }
}

// MARK: - NativeComparisonChartView (全新的原生 Swift Charts 视图)
struct NativeComparisonChartView: View {
    let data: [String: [DatabaseManager.PriceData]]
    let isDarkMode: Bool
    
    // 用于交互式标记的状态
    @State private var selectedDate: Date?
    @State private var selectedPrices: [String: Double] = [:]

    // 颜色映射
    private let colors: [Color] = [.red, .green, .blue, .purple, .orange]

    var body: some View {
        // 1. 数据归一化处理
        let normalizedData = normalizeData(data)
        
        // 2. 计算整体时间范围，用于X轴格式化
        let (minDate, maxDate) = findDateRange(from: data)
        let timeSpan = maxDate.timeIntervalSince(minDate)

        // 3. 构建图表
        Chart {
            // 遍历每个股票代码的数据
            ForEach(normalizedData, id: \.symbol) { series in
                // 绘制带渐变填充的面积图
                AreaMark(
                    x: .value("Date", series.data.first!.date),
                    yStart: .value("Normalized Price", 0),
                    yEnd: .value("Normalized Price", series.data.first!.normalizedPrice)
                )
                .foregroundStyle(
                    LinearGradient(
                        gradient: Gradient(colors: [series.color.opacity(0.4), series.color.opacity(0.0)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom) // 平滑曲线

                // 绘制曲线
                ForEach(series.data, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Normalized Price", point.normalizedPrice)
                    )
                    .interpolationMethod(.catmullRom) // 平滑曲线
                }
                
                .foregroundStyle(by: .value("Symbol", series.symbol))
                // 优化点: 确保线上没有可见的数据点标记，让曲线本身成为焦点
                .symbolSize(0)
            }
            
            // 添加交互式标记的垂直线
            if let selectedDate {
                RuleMark(x: .value("Selected Date", selectedDate))
                    .foregroundStyle(Color.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 2]))
                    .zIndex(-1) // 确保在曲线下方
                    .annotation(position: .top, alignment: .leading) {
                         // 在这里创建自定义的标记视图
                        dateMarkerView(for: selectedDate)
                    }
            }
        }
        // 4. 图表样式和坐标轴配置
        .chartYScale(domain: 0...100) // Y轴固定在0-100范围
        .chartYAxis {
            // 隐藏Y轴标签，但保留网格线，实现与原版一致的效果
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
            }
        }
        .chartXAxis {
            // 自定义X轴标签格式
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisTick()
                if value.as(Date.self) != nil {
                    AxisValueLabel(format: xAxisDateFormat(for: timeSpan))
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading) // 图例
        .chartForegroundStyleScale(domain: data.keys.sorted(), range: colors) // 颜色映射
        .chartOverlay { proxy in
            // 添加手势识别区域，用于更新选择的日期
            GeometryReader { _ in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(at: value.location, proxy: proxy)
                            }
                            .onEnded { _ in
                                selectedDate = nil // 拖动结束时隐藏标记
                            }
                    )
            }
        }
        .padding(.top, 40) // 为顶部的标记视图留出空间
    }

    // MARK: - Helper Functions

    /// 归一化数据，并为每个系列分配颜色
    private func normalizeData(_ originalData: [String: [DatabaseManager.PriceData]]) -> [NormalizedSeries] {
        let sortedSymbols = originalData.keys.sorted()
        return sortedSymbols.enumerated().compactMap { index, symbol -> NormalizedSeries? in
            guard let priceData = originalData[symbol], !priceData.isEmpty else { return nil }
            
            let prices = priceData.map(\.price)
            guard let minPrice = prices.min(), let maxPrice = prices.max() else { return nil }
            let priceRange = maxPrice - minPrice
            
            let normalizedPoints = priceData.map {
                let normalizedValue = (priceRange > 0) ? (($0.price - minPrice) / priceRange) * 100 : 50
                return NormalizedPoint(date: $0.date, originalPrice: $0.price, normalizedPrice: normalizedValue)
            }
            
            return NormalizedSeries(
                symbol: symbol,
                data: normalizedPoints,
                color: colors[index % colors.count]
            )
        }
    }
    
    /// 更新手势选择的位置
    private func updateSelection(at location: CGPoint, proxy: ChartProxy) {
        if let date: Date = proxy.value(atX: location.x) {
            selectedDate = date
        }
    }
    
    /// 创建自定义的日期标记视图
    @ViewBuilder
    private func dateMarkerView(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date, format: .dateTime.year().month().day())
                .font(.caption)
                .foregroundColor(.white)
            
            // 可以选择显示每个系列在这一天最近的价格
            // (此功能为增强，原版没有)
        }
        .padding(8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(4)
        .font(.system(size: 10))
        .transition(.opacity)
    }
    
    /// 根据时间跨度决定X轴日期格式
    private func xAxisDateFormat(for timespan: TimeInterval) -> Date.FormatStyle {
        if timespan > 365 * 24 * 3600 * 2 { // 大于两年显示年份
            return .dateTime.year()
        } else { // 否则显示月/日
            return .dateTime.month().day()
        }
    }
    
    /// 查找数据的整体日期范围
    private func findDateRange(from data: [String: [DatabaseManager.PriceData]]) -> (Date, Date) {
        var minDate = Date.distantFuture
        var maxDate = Date.distantPast
        
        for (_, priceData) in data {
            if let firstDate = priceData.first?.date {
                minDate = min(minDate, firstDate)
            }
            if let lastDate = priceData.last?.date {
                maxDate = max(maxDate, lastDate)
            }
        }
        return (minDate, maxDate)
    }
}

// MARK: - Helper Data Structures for Native Chart
struct NormalizedSeries {
    let symbol: String
    let data: [NormalizedPoint]
    let color: Color
}

struct NormalizedPoint: Identifiable {
    var id = UUID()
    let date: Date
    let originalPrice: Double
    let normalizedPrice: Double
}