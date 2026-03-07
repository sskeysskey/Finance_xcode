import SwiftUI

struct EarningHistoryView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager

    private let excludedGroups = ["season", "no_season", "_Tag_Blacklist"]
    private let lowPriorityGroups = ["PE_W", "OverSell_W", "PE_Deeper", "PE_Deep", "PE_valid", "PE_invalid"]

    private var groupNames: [String] {
        let allKeys = dataService.earningHistoryData.keys
        let filtered = allKeys.filter { !excludedGroups.contains($0) }
        
        // 1. 普通分组：保持字母排序
        let normalGroups = filtered
            .filter { !lowPriorityGroups.contains($0) }
            .sorted()
        
        // 2. 低优先级分组：按照 lowPriorityGroups 定义的顺序排序
        let lowPrioGroups = filtered
            .filter { lowPriorityGroups.contains($0) }
            .sorted { a, b in
                let indexA = lowPriorityGroups.firstIndex(of: a) ?? Int.max
                let indexB = lowPriorityGroups.firstIndex(of: b) ?? Int.max
                return indexA < indexB
            }

        return normalGroups + lowPrioGroups
    }

    var body: some View {
        Group {
            if groupNames.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无复盘数据")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(groupNames, id: \.self) { group in
                        NavigationLink(
                            destination: EarningHistoryDetailView(groupName: group)
                        ) {
                            HStack {
                                Text(formatGroupName(group))
                                    .font(.system(size: 16, weight: .medium))
                                Spacer()
                                // 可选：显示该分类下共有多少个日期
                                if let datesMap = dataService.earningHistoryData[group] {
                                    Text("\(datesMap.keys.count) 个日期")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("复盘历史")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatGroupName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - 分类详情页（时间分组）
struct EarningHistoryDetailView: View {
    let groupName: String

    @EnvironmentObject var dataService: DataService

    @State private var expandedDates: Set<String> = []

    private var currentGroupDates: [String] {
        guard let datesMap = dataService.earningHistoryData[groupName] else { return [] }
        return datesMap.keys.sorted(by: >)
    }

    private var latestDate: String? {
        currentGroupDates.first
    }

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(currentGroupDates, id: \.self) { dateStr in
                        if let symbols = dataService.earningHistoryData[groupName]?[dateStr] {
                            DateSectionView(
                                dateStr: dateStr,
                                symbols: symbols,
                                isExpanded: expandedDates.contains(dateStr),
                                isLatestDate: dateStr == latestDate,
                                onToggle: {
                                    withAnimation {
                                        if expandedDates.contains(dateStr) {
                                            expandedDates.remove(dateStr)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                withAnimation {
                                                    proxy.scrollTo("\(groupName)_\(dateStr)", anchor: .top) // ← 与 .id() 保持一致
                                                }
                                            }
                                        } else {
                                            expandedDates.insert(dateStr)
                                        }
                                    }
                                }
                            )
                            // groupName 已由页面级别保证唯一，id 只需包含 dateStr 即可，
                            // 但保留拼接格式与原逻辑保持一致
                            .id("\(groupName)_\(dateStr)")
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle(formatGroupName(groupName))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
    }

    private func formatGroupName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - 日期折叠组件
struct DateSectionView: View {
    let dateStr: String
    let symbols: [String]
    let isExpanded: Bool
    let isLatestDate: Bool   // 新增：是否是最新日期分组
    let onToggle: () -> Void
    
    @EnvironmentObject var dataService: DataService
    
    // 标记是否已触发过此分组的涨跌幅计算，避免重复请求
    @State private var isFetchInitiated = false
    
    var body: some View {
        Section {
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(symbols, id: \.self) { symbol in
                        HistorySymbolRow(
                            symbol: symbol,
                            dateStr: dateStr,
                            isLatestDate: isLatestDate,
                            isFetchInitiated: isFetchInitiated
                        )
                        
                        if symbol != symbols.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 4)
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            }
        } header: {
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .foregroundColor(isExpanded ? .blue : .gray)
                        .font(.system(size: 20))
                    
                    Text(dateStr)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text("\(symbols.count) 个")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(UIColor.systemGray5))
                        .cornerRadius(8)
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
            }
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom, 2)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        // 核心：展开时触发懒加载
        // 修改点：使用新的 onChange API，参数为 (oldValue, newValue)
        .onChange(of: isExpanded) { oldValue, newValue in
            // 只对旧日期分组处理，且只触发一次
            // 使用 newValue 判断当前是否处于展开状态
            guard newValue, !isLatestDate, !isFetchInitiated else { return }
            isFetchInitiated = true
            
            // 提取干净的 ticker，批量发起请求
            let cleanSymbols = symbols.map { $0.cleanTicker }
            let items = cleanSymbols.map { (symbol: $0, dateStr: dateStr) }
            dataService.fetchHistoryPriceChanges(for: items)
        }
    }
}

// MARK: - Symbol 行组件
struct HistorySymbolRow: View {
    let symbol: String
    let dateStr: String
    let isLatestDate: Bool        // 新增
    let isFetchInitiated: Bool    // 新增：由父组件传入，用于区分"未请求"和"请求中"
    
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var navigateToChart = false
    @State private var showSubscriptionSheet = false
    // 超时兜底：若请求发出后 5 秒仍无数据，显示 "—" 而非无限转圈
    @State private var showDash = false
    
    private var cleanSymbol: String {
        return symbol.cleanTicker
    }
    
    private var tags: [(String, Double)] {
        let upperSymbol = cleanSymbol.uppercased()
        var rawTags: [String] = []
        
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            rawTags = stock.tag
        } else if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            rawTags = etf.tag
        }
        
        return rawTags.map { tag in
            let weight = dataService.tagsWeightConfig.first(where: { $0.value.contains(tag) })?.key ?? 1.0
            return (tag, weight)
        }
    }
    
    // 从 DataService 缓存里读取该 symbol 在该日期的涨跌幅
    private var priceChange: Double? {
        let key = "\(cleanSymbol.uppercased())_\(dateStr)"
        return dataService.historyPriceChanges[key]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(symbol)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                Spacer()
                
                if isLatestDate {
                    // 最新日期分组：保持原来的 PE 显示逻辑
                    if let capItem = dataService.marketCapData[cleanSymbol.uppercased()], let pe = capItem.peRatio {
                        Text("PE: \(String(format: "%.1f", pe))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    // 旧日期分组：显示区间涨跌幅
                    priceChangeIndicator
                }
            }
            
            if !tags.isEmpty {
                FlowLayoutTags(tags: tags)
            } else {
                Text("No Tags")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .italic()
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                navigateToChart = true
            } else {
                showSubscriptionSheet = true
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            ChartView(symbol: cleanSymbol, groupName: dataService.getCategory(for: cleanSymbol) ?? "Stocks")
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        // 当 isFetchInitiated 变为 true 后，启动 5 秒超时计时器
        // task(id:) 会在 id 值变化时自动重启，旧 task 自动取消
        .task(id: isFetchInitiated) {
            guard isFetchInitiated, !isLatestDate else { return }
            // 等待最多 5 秒
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            // 超时后如果还没数据，显示破折号
            if priceChange == nil {
                showDash = true
            }
        }
    }
    
    // MARK: 涨跌幅指示器（抽成子视图避免 body 过于复杂）
    @ViewBuilder
    private var priceChangeIndicator: some View {
        if let change = priceChange {
            // 已有数据：显示带颜色的百分比
            let isPositive = change >= 0
            Text(String(format: "%+.1f%%", change * 100))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(isPositive ? .red : .green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((isPositive ? Color.red : Color.green).opacity(0.1))
                .cornerRadius(4)
        } else if showDash {
            // 超时或无数据：显示破折号
            Text("—")
                .font(.system(size: 14))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        } else if isFetchInitiated {
            // 请求已发出，等待结果：显示小转圈
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 22, height: 22)
        }
        // isFetchInitiated == false 时什么都不显示（尚未展开，不占位）
    }
}

// MARK: - 简单的流式布局显示 Tags
struct FlowLayoutTags: View {
    let tags: [(String, Double)]
    
    var body: some View {
        var text = Text("")
        for (i, (tag, weight)) in tags.enumerated() {
            var tagText = Text(tag)
                .font(.system(size: 13))
            
            if weight > 1.0 {
                tagText = tagText.foregroundColor(.orange).bold()
            } else {
                tagText = tagText.foregroundColor(.secondary)
            }
            
            text = text + tagText
            
            if i < tags.count - 1 {
                text = text + Text(",  ").foregroundColor(.gray.opacity(0.5))
            }
        }
        
        return text
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}