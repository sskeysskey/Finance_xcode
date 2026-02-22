import SwiftUI

struct EarningHistoryView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 1. 彻底过滤的黑名单（完全不显示）
    private let excludedGroups = ["season", "no_season", "_Tag_Blacklist"]
    
    // 2. 低优先级的名单（显示在最后面，例如 OverSell_W）
    private let lowPriorityGroups = [ "OverSell_W", "PE_W", "PE_Deep",
    "PE_Deeper", "PE_valid", "PE_invalid"]
    
    @State private var selectedGroup: String = ""
    @State private var expandedDates: Set<String> = []
    @State private var showSubscriptionSheet = false
    
    // 3. 核心逻辑：重新定义 groupNames 的排序规则
    private var groupNames: [String] {
        let allKeys = dataService.earningHistoryData.keys
        
        // 第一步：过滤掉彻底不需要的组
        let filtered = allKeys.filter { !excludedGroups.contains($0) }
        
        // 第二步：将剩余的组分成两部分
        // A 部分：普通组（不在低优先级名单里的）
        let normalGroups = filtered
            .filter { !lowPriorityGroups.contains($0) }
            .sorted() // 字母排序
        
        // B 部分：低优先级组
        let lowPrioGroups = filtered
            .filter { lowPriorityGroups.contains($0) }
            .sorted() // 字母排序
        
        // 第三步：合并，确保 normalGroups 在前，lowPrioGroups 在后
        return normalGroups + lowPrioGroups
    }
    
    // 获取当前选中组的数据 (按日期降序)
    private var currentGroupDates: [String] {
        guard !selectedGroup.isEmpty, 
              let datesMap = dataService.earningHistoryData[selectedGroup] else { return [] }
        return datesMap.keys.sorted(by: >)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部横向 Tab 分页
            if !groupNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        ForEach(groupNames, id: \.self) { group in
                            Button(action: {
                                withAnimation {
                                    selectedGroup = group
                                    expandedDates.removeAll() // 切换组时收起所有日期
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
            
            // 2. 内容区域
            if groupNames.isEmpty {
                // 如果过滤后没有数据，显示一个占位提示
                VStack {
                    Spacer()
                    Text("暂无复盘数据")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    // 1. 新增 ScrollViewReader
                    ScrollViewReader { proxy in 
                        LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) { // 👈 开启吸顶功能
                            ForEach(currentGroupDates, id: \.self) { dateStr in
                                if let symbols = dataService.earningHistoryData[selectedGroup]?[dateStr] {
                                    DateSectionView(
                                        dateStr: dateStr,
                                        symbols: symbols,
                                        isExpanded: expandedDates.contains(dateStr),
                                        onToggle: {
                                            withAnimation {
                                                if expandedDates.contains(dateStr) {
                                                    expandedDates.remove(dateStr)
                                                    // 2. 核心修复：折叠时自动定位回这个标题的顶部
                                                    // 稍微延迟一点点等动画开始，防止布局闪烁
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
                                    .id(dateStr) // 3. 给这个视图绑定唯一 ID，供 proxy 寻找锚点
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
            // 自动选中第一个（现在第一个必然是 normalGroups 里的第一个，除非 normal 为空）
            if !groupNames.isEmpty {
                if selectedGroup.isEmpty || !groupNames.contains(selectedGroup) {
                    selectedGroup = groupNames.first ?? ""
                }
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    // 简单的组名格式化，去掉下划线显示更友好
    private func formatGroupName(_ name: String) -> String {
        return name.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - 日期折叠组件
struct DateSectionView: View {
    let dateStr: String
    let symbols: [String]
    let isExpanded: Bool
    let onToggle: () -> Void
    
    var body: some View {
        // 使用 Section 来配合 LazyVStack 的 pinnedViews 达到吸顶效果
        Section {
            // 展开的内容（列表区域）
            if isExpanded {
                VStack(spacing: 0) {
                    // 去掉了 Divider()，因为现在头和内容是分离开的两个卡片，更美观
                    ForEach(symbols, id: \.self) { symbol in
                        HistorySymbolRow(symbol: symbol, dateStr: dateStr)
                        
                        if symbol != symbols.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12) // 给列表独立加圆角
                .padding(.horizontal)
                .padding(.top, 4) // 和吸顶的标题拉开一点距离，显得有层次
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            }
        } header: {
            // 头部点击区域（吸顶部分）
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
            .cornerRadius(12) // 给标题独立加圆角，这样吸顶悬浮时就像一个独立的浮岛药丸
            .padding(.horizontal)
            .padding(.bottom, 2) // 吸顶时底部稍微留一点间隙
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
    }
}

// MARK: - Symbol 行组件
struct HistorySymbolRow: View {
    let symbol: String
    let dateStr: String // 【新增】：接收日期，用于去查黑名单
    
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var navigateToChart = false
    @State private var showSubscriptionSheet = false
    
    // 获取 Tags
    private var tags: [(String, Double)] {
        let upperSymbol = symbol.uppercased()
        var rawTags: [String] = []
        
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            rawTags = stock.tag
        } else if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            rawTags = etf.tag
        }
        
        // 结合权重配置
        return rawTags.map { tag in
            // 查找权重，默认为 1.0
            let weight = dataService.tagsWeightConfig.first(where: { $0.value.contains(tag) })?.key ?? 1.0
            return (tag, weight)
        }
    }

    // 【新增】：计算属性判断是否黑名单
    private var isBlacklisted: Bool {
        dataService.isBlacklisted(symbol: symbol, date: dateStr)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 上半部分：Symbol 展示
            HStack {
                // 【修改点1】：将原来的 Button 改为 Text，仅保留样式
                Text(symbol)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)

                // MARK: - 【新增】黑名单 UI 指示器
                if isBlacklisted {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.shield.fill") // 盾牌感叹号图标
                        Text("Tag黑名单")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.8)) // 醒目的红色背景
                    .cornerRadius(6)
                }

                Spacer()
                
                // 这里可以加一些额外信息，比如 PE 或 价格，如果需要的话
                // 复用 DataService 中的数据
                if let capItem = dataService.marketCapData[symbol.uppercased()], let pe = capItem.peRatio {
                    Text("PE: \(String(format: "%.1f", pe))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // 下半部分：Tags
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
        // 【修改点2】：设置内容形状为矩形，确保点击空白处也有效
        .contentShape(Rectangle()) 
        // 【修改点3】：将点击逻辑移到整个 VStack 上
        .onTapGesture {
            if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                navigateToChart = true
            } else {
                showSubscriptionSheet = true
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            // 跳转到 ChartView
            ChartView(symbol: symbol, groupName: dataService.getCategory(for: symbol) ?? "Stocks")
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
}

// MARK: - 简单的流式布局显示 Tags
struct FlowLayoutTags: View {
    let tags: [(String, Double)]
    
    var body: some View {
        // 由于 SwiftUI 原生 FlowLayout 需要 iOS 16+ 的 Layout 协议比较复杂，
        // 这里使用一个简单的 ScrollView horizontal 或者 换行 Text 来模拟
        // 为了简单且美观，我们使用这种方式：
        
        var text = Text("")
        for (i, (tag, weight)) in tags.enumerated() {
            var tagText = Text(tag)
                .font(.system(size: 13))
            
            // 根据权重变色
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