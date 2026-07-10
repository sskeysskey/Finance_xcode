import SwiftUI

struct EarningHistoryView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager

    private let excludedGroups = ["season", "no_season", "_Tag_Blacklist"]

    // MARK: - 计算多组共振（次数统计）数据
    private var frequencyData: [(count: Int, symbols: [String])] {
        // 记录每个 symbol 出现的分组集合
        var symbolGroups: [String: Set<String>] = [:]
        // 【新增】记录名字里含 "抄底" 的 symbol（与 Python 的 symbols_with_chaodi 对应）
        var symbolsWithChaodi: Set<String> = []
        
        // 1. 遍历所有分组
        for (group, dateMap) in dataService.earningHistoryData {
            if excludedGroups.contains(group) { continue }
            if dateMap.isEmpty { continue }
            
            // 2. 获取该分组的最新日期
            let sortedDates = dateMap.keys.sorted(by: >)
            guard let latestDate = sortedDates.first,
                  let symbols = dateMap[latestDate] else { continue }
            
            // 【新增】检测 "抄底" 标记
            for s in symbols {
                if s.contains("抄底") {
                    symbolsWithChaodi.insert(s.cleanTicker.uppercased())
                }
            }
            
            // 3. 清洗 Symbol 并去重
            let cleanSymbols = Set(symbols.map { $0.cleanTicker.uppercased() })
            
            // 4. 记录该 Symbol 所在的分组
            for sym in cleanSymbols {
                symbolGroups[sym, default: []].insert(group)
            }
        }
        
        // 【对齐 Python】先为命中 52week_low 的 symbol 追加虚拟分组（在剔除逻辑之前）
        for sym in Array(symbolGroups.keys) {
            if dataService.weekLow52Symbols.contains(sym) {
                symbolGroups[sym]?.insert("52week_low")
            }
        }
        
        // 定义需要特殊处理的源头分组和衍生分组
        let supportLevelGroups: Set<String> = ["SupportLevel_Close", "SupportLevel_Over"]
        let sourceGroups: Set<String> = [
            "Short", "Short_W", "Strategy12", "Strategy34", "OverSell_W",
            "PE_Deep", "PE_Deeper", "PE_W", "PE_valid", "PE_invalid",
            "PE_Volume", "PE_Volume_up", "PE_Hot", "PE_Volume_high"
        ]
        
        // PE_Hot 的源头分组
        let peHotSources: Set<String> = [
            "PE_Deep", "PE_Deeper", "PE_W", "OverSell_W",
            "PE_valid", "PE_invalid", "season"
        ]
        
        // 【新增】抄底的源头分组（对应 Python 的 pe_chaodi_sources）
        let peChaodiSources: Set<String> = ["PE_Null"]
        
        // 5. 按次数分组，并过滤掉无意义的 2 次共振
        var countToSymbols: [Int: [String]] = [:]
        for (sym, groups) in symbolGroups {
            var effectiveGroups = groups
            
            // 如果包含 PE_Hot，剔除其源头分组
            if effectiveGroups.contains("PE_Hot") {
                effectiveGroups.subtract(peHotSources)
            }
            
            // 【新增】如果是抄底标的，剔除 PE_Null
            if symbolsWithChaodi.contains(sym) {
                effectiveGroups.subtract(peChaodiSources)
            }
            
            let count = effectiveGroups.count
            
            if count >= 2 {
                if count == 2 {
                    let hasSupport = !effectiveGroups.isDisjoint(with: supportLevelGroups)
                    let hasSource = !effectiveGroups.isDisjoint(with: sourceGroups)
                    if hasSupport && hasSource {
                        continue
                    }
                }
                countToSymbols[count, default: []].append(sym)
            }
        }
        
        // 6. 转换为数组，按次数降序，内部 Symbol 字母排序
        return countToSymbols.keys.sorted(by: >).map { count in
            (count: count, symbols: countToSymbols[count]!.sorted())
        }
    }

    var body: some View {
        Group {
            let freqData = frequencyData
            if freqData.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无复盘数据")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(freqData, id: \.count) { item in
                        FrequencyGroupView(count: item.count, symbols: item.symbols)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("复盘历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 共振分组：默认展开、可折叠
struct FrequencyGroupView: View {
    let count: Int
    let symbols: [String]
    
    @State private var isExpanded = true  // 默认展开
    
    var body: some View {
        Section {
            if isExpanded {
                ForEach(symbols, id: \.self) { symbol in
                    HistorySymbolRow(
                        symbol: symbol,
                        dateStr: "最新",
                        isLatestDate: true,
                        isFetchInitiated: false
                    )
                }
            }
        } header: {
            Button(action: {
                withAnimation {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.orange)
                        .font(.system(size: 14, weight: .bold))
                    
                    Text("共振 \(count) 个分组")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    Text("\(symbols.count) 只")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Symbol 行组件
struct HistorySymbolRow: View {
    let symbol: String
    let dateStr: String
    let isLatestDate: Bool
    let isFetchInitiated: Bool
    
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var navigateToChart = false
    @State private var showSubscriptionSheet = false
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
                    if let capItem = dataService.marketCapData[cleanSymbol.uppercased()], let pe = capItem.peRatio {
                        Text("PE: \(String(format: "%.1f", pe))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
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
            PointsCoordinator.shared.attempt(action: .viewChart, itemKey: cleanSymbol,
                displayName: "查看 \(symbol) 图表", authManager: authManager) {
                navigateToChart = true
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            ChartView(symbol: cleanSymbol, groupName: dataService.getCategory(for: cleanSymbol) ?? "Stocks")
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .task(id: isFetchInitiated) {
            guard isFetchInitiated, !isLatestDate else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if priceChange == nil {
                showDash = true
            }
        }
    }
    
    @ViewBuilder
    private var priceChangeIndicator: some View {
        if let change = priceChange {
            let isPositive = change >= 0
            Text(String(format: "%+.1f%%", change * 100))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(isPositive ? .red : .green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((isPositive ? Color.red : Color.green).opacity(0.1))
                .cornerRadius(4)
        } else if showDash {
            Text("—")
                .font(.system(size: 14))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        } else if isFetchInitiated {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 22, height: 22)
        }
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