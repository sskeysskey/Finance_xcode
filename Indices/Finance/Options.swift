import SwiftUI
import Charts
import Foundation

// MARK: - 【重构】期权价格历史图表组件
struct OptionsHistoryChartView: View {
    let symbol: String
    
    // 状态管理
    @State private var historyData: [DatabaseManager.OptionHistoryItem] = []
    @State private var selectedTimeRange: TimeRangeOption = .threeMonths
    @State private var isLoading = false
    
    // 定义时间范围枚举
    enum TimeRangeOption: String, CaseIterable, Identifiable {
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case twoYears = "2Y"
        case fiveYears = "5Y"
        case tenYears = "10Y"
        
        var id: String { self.rawValue }
        
        var monthsBack: Int {
            switch self {
            case .threeMonths: return 3
            case .sixMonths: return 6
            case .oneYear: return 12
            case .twoYears: return 24
            case .fiveYears: return 60
            case .tenYears: return 120
            }
        }
    }
    
    // 过滤后的数据
    var filteredData: [DatabaseManager.OptionHistoryItem] {
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .month, value: -selectedTimeRange.monthsBack, to: Date()) else {
            return historyData
        }
        return historyData.filter { $0.date >= startDate }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // 1. 图表主体区域
            mainChartArea
            
            // 2. 时间切换条
            timeRangeSelector
        }
        .task {
            await loadData()
        }
    }
    
    // 拆分出图表主体
    @ViewBuilder
    private var mainChartArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            
            if isLoading {
                ProgressView()
            } else if historyData.isEmpty {
                Text("暂无历史价格数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if filteredData.isEmpty {
                Text("该时间段内无数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                chartContent
            }
        }
        .frame(height: 220)
        .padding(.horizontal)
    }
    
    // 拆分出具体的 Chart 代码
    private var chartContent: some View {
        Chart {
            ForEach(filteredData) { item in
                BarMark(
                    x: .value("Date", item.date),
                    y: .value("Price", item.price)
                )
                // 【注意】移除了 .width 修饰符以解决 "has no member width" 报错。
                // Charts 会自动根据数据密度调整柱子宽度。
                .foregroundStyle(barGradient(for: item.price))
            }
            
            // 0轴基准线
            RuleMark(y: .value("Zero", 0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.gray.opacity(0.5))
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.month().year(.twoDigits))
                            .font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
    }
    
    // 辅助函数：生成渐变色
    private func barGradient(for price: Double) -> LinearGradient {
        let isPositive = price >= 0
        let colors: [Color] = isPositive
            ? [.red.opacity(0.8), .red.opacity(0.4)]
            : [.green.opacity(0.8), .green.opacity(0.4)]
        
        return LinearGradient(
            colors: colors,
            startPoint: isPositive ? .bottom : .top,
            endPoint: isPositive ? .top : .bottom
        )
    }
    
    // 拆分出时间选择器
    private var timeRangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(TimeRangeOption.allCases) { option in
                Button(action: {
                    withAnimation(.easeInOut) {
                        selectedTimeRange = option
                    }
                }) {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedTimeRange == option
                            ? Color.blue.opacity(0.15)
                            : Color.clear
                        )
                        .foregroundColor(
                            selectedTimeRange == option
                            ? .blue
                            : .secondary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(4)
        .background(Color(UIColor.tertiarySystemFill))
        .cornerRadius(10)
        .padding(.horizontal)
    }
    
    private func loadData() async {
        isLoading = true
        let rawData = await DatabaseManager.shared.fetchOptionsHistory(forSymbol: symbol)
        await MainActor.run {
            self.historyData = rawData
            self.isLoading = false
        }
    }
}

// MARK: - 【重构】界面 A：期权 Symbol 列表
struct OptionsListView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    
    var sortedSymbols: [String] {
        let allSymbols = dataService.optionsData.keys
        let noCapSymbols = allSymbols.filter { symbol in
            guard let item = dataService.marketCapData[symbol.uppercased()] else { return true }
            return item.rawMarketCap <= 0
        }.sorted()
        
        let hasCapSymbols = allSymbols.filter { symbol in
            guard let item = dataService.marketCapData[symbol.uppercased()] else { return false }
            return item.rawMarketCap > 0
        }.sorted { s1, s2 in
            let cap1 = dataService.marketCapData[s1.uppercased()]?.rawMarketCap ?? 0
            let cap2 = dataService.marketCapData[s2.uppercased()]?.rawMarketCap ?? 0
            return cap1 > cap2
        }
        return noCapSymbols + hasCapSymbols
    }
    
    var body: some View {
        List {
            if sortedSymbols.isEmpty {
                Text("暂无期权异动数据")
                    .foregroundColor(.secondary)
            } else {
                ForEach(sortedSymbols, id: \.self) { symbol in
                    OptionListRow(symbol: symbol) {
                        handleSelection(symbol)
                    }
                }
            }
        }
        .navigationTitle("期权异动")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToDetail) {
            if let sym = selectedSymbol {
                OptionsDetailView(symbol: sym)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func handleSelection(_ symbol: String) {
        if usageManager.canProceed(authManager: authManager, action: .viewOptionsDetail) {
            self.selectedSymbol = symbol
            self.navigateToDetail = true
        } else {
            self.showSubscriptionSheet = true
        }
    }
}

// 拆分出的列表行视图
struct OptionListRow: View {
    let symbol: String
    let action: () -> Void
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        Button(action: action) {
            let info = getInfo(for: symbol)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(symbol)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        if !info.name.isEmpty {
                            Text(info.name)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    
                    if !info.tags.isEmpty {
                        Text(info.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)
        }
    }
    
    private func getInfo(for symbol: String) -> (name: String, tags: [String]) {
        let upperSymbol = symbol.uppercased()
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (stock.name, stock.tag)
        }
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (etf.name, etf.tag)
        }
        return ("", [])
    }
}

// MARK: - 【重构】界面 B：期权详情表格
struct OptionsDetailView: View {
    let symbol: String
    @EnvironmentObject var dataService: DataService
    
    @State private var selectedTypeIndex = 0
    @State private var navigateToChart = false
    @State private var summaryCall: String = ""
    @State private var summaryPut: String = ""
    
    var filteredData: [OptionItem] {
        guard let items = dataService.optionsData[symbol] else { return [] }
        let filtered = items.filter { item in
            let itemType = item.type.uppercased()
            if selectedTypeIndex == 0 {
                return itemType.contains("CALL") || itemType == "C"
            } else {
                return itemType.contains("PUT") || itemType == "P"
            }
        }
        return filtered.sorted { item1, item2 in
            let val1 = Double(item1.change) ?? 0
            let val2 = Double(item2.change) ?? 0
            return abs(val1) > abs(val2)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 图表组件
            OptionsHistoryChartView(symbol: symbol)
                .padding(.top, 10)
                .padding(.bottom, 4)
            
            // 顶部切换开关 (Picker)
            typePickerView
            
            // 表格头
            tableHeaderView
            
            Divider()
            
            // 数据列表
            dataListView
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { navigateToChart = true }) {
                    Text("切换到股价模式")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue)
                        .cornerRadius(14)
                        .shadow(color: Color.blue.opacity(0.3), radius: 2, x: 0, y: 1)
                }
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            let groupName = dataService.getCategory(for: symbol) ?? "US"
            ChartView(symbol: symbol, groupName: groupName)
        }
        .task {
            // 获取汇总数据
            if let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) {
                await MainActor.run {
                    if let c = summary.call { self.summaryCall = c }
                    if let p = summary.put { self.summaryPut = p }
                }
            }
        }
    }
    
    // 拆分出 Picker
    private var typePickerView: some View {
        Picker("Type", selection: $selectedTypeIndex) {
            Text(summaryCall.isEmpty ? "Calls" : "Calls \(summaryCall)").tag(0)
            Text(summaryPut.isEmpty ? "Puts" : "Puts \(summaryPut)").tag(1)
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding()
        .background(Color(UIColor.systemBackground))
    }
    
    // 拆分出表头
    private var tableHeaderView: some View {
        HStack(spacing: 4) {
            Text("Expiry").frame(maxWidth: .infinity, alignment: .leading)
            Text("Strike").frame(width: 55, alignment: .trailing)
            Text("Dist").frame(width: 55, alignment: .trailing)
            Text("Open Int").frame(width: 65, alignment: .trailing)
            Text("1-Day").frame(width: 60, alignment: .trailing)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemBackground))
    }
    
    // 拆分出列表部分
    private var dataListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("TopAnchor")
                    
                    if filteredData.isEmpty {
                        Text("暂无数据")
                            .foregroundColor(.secondary)
                            .padding(.top, 20)
                    } else {
                        ForEach(filteredData) { item in
                            OptionRowView(item: item)
                            Divider().padding(.leading)
                        }
                    }
                }
            }
            .onChange(of: selectedTypeIndex) { _, _ in
                proxy.scrollTo("TopAnchor", anchor: .top)
            }
        }
    }
}

// 拆分出单行数据视图
struct OptionRowView: View {
    let item: OptionItem
    
    var body: some View {
        HStack(spacing: 4) {
            OptionCellView(text: item.expiryDate, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            OptionCellView(text: item.strike, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
            OptionCellView(text: item.distance, alignment: .trailing)
                .frame(width: 55, alignment: .trailing)
                .font(.system(size: 12))
            OptionCellView(text: item.openInterest, alignment: .trailing)
                .frame(width: 65, alignment: .trailing)
            OptionCellView(text: item.change, alignment: .trailing)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal)
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - 辅助视图
struct OptionCellView: View {
    let text: String
    var alignment: Alignment = .leading
    
    var isNew: Bool {
        text.lowercased().contains("new")
    }
    
    var displayString: String {
        if isNew {
            return text.replacingOccurrences(of: "new", with: "", options: .caseInsensitive)
                       .trimmingCharacters(in: .whitespaces)
        }
        return text
    }
    
    var body: some View {
        Text(displayString)
            .font(.system(size: 14, weight: isNew ? .bold : .regular))
            .foregroundColor(isNew ? .orange : .primary)
            .multilineTextAlignment(textAlignment)
    }
    
    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        default: return .leading
        }
    }
}
