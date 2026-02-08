import SwiftUI

struct EarningHistoryView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 【修改点1】：将初始值直接设为 "PE_Volume_up"，这样打开页面时默认就是它
    @State private var selectedGroup: String = "PE_Volume_up"
    @State private var expandedDates: Set<String> = []
    @State private var showSubscriptionSheet = false
    
    // 获取所有组名并排序
    private var groupNames: [String] {
        dataService.earningHistoryData.keys.sorted()
    }
    
    // 获取当前选中组的数据 (按日期降序)
    private var currentGroupDates: [String] {
        guard let datesMap = dataService.earningHistoryData[selectedGroup] else { return [] }
        // 日期降序排列 (最新的在上面)
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
                EmptyView() // 或者显示 LoadingView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
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
                                            } else {
                                                expandedDates.insert(dateStr)
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("复盘历史")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            // 【修改点2】：安全检查
            // 虽然默认是 PE_Volume_up，但如果数据里没有这个Key（且数据不为空），则回退到第一个组
            // 这样即使 Python 端数据生成有问题，App 也不会显示空白
            if !groupNames.isEmpty && !groupNames.contains(selectedGroup) {
                if let first = groupNames.first {
                    selectedGroup = first
                }
            } else if selectedGroup.isEmpty, let first = groupNames.first {
                // 防止极端情况 selectedGroup 变为空字符串
                selectedGroup = first
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
        VStack(spacing: 0) {
            // 头部点击区域
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
            
            // 展开的内容
            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(symbols, id: \.self) { symbol in
                        // 【修改这里】：传入 dateStr
                        HistorySymbolRow(symbol: symbol, dateStr: dateStr)
                        
                        if symbol != symbols.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
            }
        }
        .cornerRadius(12)
        .padding(.horizontal)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
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