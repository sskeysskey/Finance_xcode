import SwiftUI

struct EarningHistoryView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    private let excludedGroups = ["season", "no_season", "_Tag_Blacklist"]
    private let lowPriorityGroups = ["OverSell_W", "PE_W", "PE_Deep",
    "PE_Deeper", "PE_valid", "PE_invalid"]
    
    @State private var selectedGroup: String = ""
    @State private var expandedDates: Set<String> = []
    @State private var showSubscriptionSheet = false
    
    private var groupNames: [String] {
        let allKeys = dataService.earningHistoryData.keys
        let filtered = allKeys.filter { !excludedGroups.contains($0) }
        let normalGroups = filtered
            .filter { !lowPriorityGroups.contains($0) }
            .sorted()
        let lowPrioGroups = filtered
            .filter { lowPriorityGroups.contains($0) }
            .sorted()
        return normalGroups + lowPrioGroups
    }
    
    private var currentGroupDates: [String] {
        guard !selectedGroup.isEmpty,
              let datesMap = dataService.earningHistoryData[selectedGroup] else { return [] }
        return datesMap.keys.sorted(by: >)
    }
    
    // 当前分组里最新的那个日期（排序后第一个）
    private var latestDate: String? {
        currentGroupDates.first
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if !groupNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        ForEach(groupNames, id: \.self) { group in
                            Button(action: {
                                withAnimation {
                                    selectedGroup = group
                                    expandedDates.removeAll()
                                }
                            }) {
                                Text(formatGroupName(group))
                                    .font(.system(size: 15, weight: .medium))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(selectedGroup == group ? Color.blue : Color(.systemGray5))
                                    .foregroundColor(selectedGroup == group ? .white : .primary)
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .background(Color(UIColor.systemBackground))
                .overlay(Divider(), alignment: .bottom)
            }
            
            if groupNames.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无复盘数据")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                            ForEach(currentGroupDates, id: \.self) { dateStr in
                                if let symbols = dataService.earningHistoryData[selectedGroup]?[dateStr] {
                                    DateSectionView(
                                        dateStr: dateStr,
                                        symbols: symbols,
                                        isExpanded: expandedDates.contains(dateStr),
                                        // 只有最新日期才显示 PE，旧日期显示涨跌幅
                                        isLatestDate: dateStr == latestDate,
                                        onToggle: {
                                            withAnimation {
                                                if expandedDates.contains(dateStr) {
                                                    expandedDates.remove(dateStr)
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                        withAnimation {
                                                            proxy.scrollTo(dateStr, anchor: .top)
                                                        }
                                                    }
                                                } else {
                                                    expandedDates.insert(dateStr)
                                                }
                                            }
                                        }
                                    )
                                    .id(dateStr)
                                }
                            }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .navigationTitle("复盘历史")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            if !groupNames.isEmpty {
                if selectedGroup.isEmpty || !groupNames.contains(selectedGroup) {
                    selectedGroup = groupNames.first ?? ""
                }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func formatGroupName(_ name: String) -> String {
        return name.replacingOccurrences(of: "_", with: " ")
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