import Foundation
import Combine
import SwiftUI

// MARK: - 协议与模型
protocol SearchDescribableItem {
    var symbol: String { get }
    var name: String { get }
    var tag: [String] { get }
    var description1: String { get }
    var description2: String { get }
}

struct SelectedSymbol: Identifiable {
    let id = UUID()
    let result: SearchResult
    let category: String
}

struct GroupedSearchResults: Identifiable {
    var id = UUID()
    var category: MatchCategory
    var results: [(result: SearchResult, score: Int)]
    let highestScore: Int
}

enum MatchCategory: String, CaseIterable, Identifiable {
    case stockSymbol = "Stock Symbol"
    case etfSymbol = "ETF Symbol"
    case stockName = "Stock Name"
    case etfName = "ETF Name"
    case stockTag = "Stock Tag"
    case etfTag = "ETF Tag"
    case stockDescription = "Stock Description"
    case etfDescription = "ETF Description"
    
    var id: String { self.rawValue }
    
    var priority: Int {
        switch self {
        case .stockSymbol, .etfSymbol:
            return 1000
        case .stockTag, .etfTag:
            return 800
        case .stockName, .etfName:
            return 500
        case .stockDescription, .etfDescription:
            return 300
        }
    }
}

// MARK: - 搜索结果包装
class SearchResult: Identifiable, ObservableObject {
    let id = UUID()
    @Published var symbol: String
    @Published var name: String
    @Published var tag: [String]
    @Published var marketCap: String?
    @Published var peRatio: String?
    @Published var pb: String?
    @Published var compare: String?
    @Published var volume: String?
    // 【新增】: 添加 earningTrend 属性，用于驱动颜色变化
    @Published var earningTrend: EarningTrend = .insufficientData
    
    init(symbol: String, name: String, tag: [String],
         marketCap: String? = nil, peRatio: String? = nil, pb: String? = nil,
         compare: String? = nil, volume: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.tag = tag
        self.marketCap = marketCap
        self.peRatio = peRatio
        self.pb = pb
        self.compare = compare
        self.volume = volume
        // earningTrend 会在之后异步更新
    }
}

// MARK: - 分组 header
struct GroupHeaderView: View {
    let category: MatchCategory
    @Binding var isCollapsed: Bool
    
    var body: some View {
        HStack {
            Text(category.rawValue)
                .font(.headline)
                // 【修改】: 从 .gray 改为 .secondary，更符合系统原生风格
                .foregroundColor(.secondary)
            Spacer()
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                // 【修改】: 同上
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                isCollapsed.toggle()
            }
        }
    }
}

// MARK: - 主搜索按钮页面
struct SearchContentView: View {
    @State private var showSearch = false
    @State private var showCompare = false
    @State private var navigateToEarnings = false
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @State private var showSubscriptionSheet = false
    
    var body: some View {
        // 移除 NavigationStack，因为外层已经有了
        HStack(spacing: 15) {
            // 1. 比较按钮
            ToolButton(
                title: "对比",
                icon: "chart.line.uptrend.xyaxis",
                color: .blue
            ) {
                showCompare = true
            }
            
            // 2. 搜索按钮 (占据中间主要位置)
            Button(action: { showSearch = true }) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .bold))
                    Text("搜索股票/ETF")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)]), startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(16)
                .shadow(color: Color.blue.opacity(0.3), radius: 5, x: 0, y: 3)
            }
            
            // 3. 财报按钮
            ToolButton(
                title: "财报",
                icon: "calendar",
                color: .orange
            ) {
                if usageManager.canProceed(authManager: authManager, action: .openEarnings) {
                    navigateToEarnings = true
                } else {
                    showSubscriptionSheet = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGroupedBackground)) // 与整体背景融合
        
        // 导航目标
        .navigationDestination(isPresented: $showSearch) {
            SearchView(isSearchActive: true, dataService: dataService)
        }
        .navigationDestination(isPresented: $showCompare) {
            CompareView(initialSymbol: "")
        }
        .navigationDestination(isPresented: $navigateToEarnings) {
            EarningReleaseView()
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
}

// 辅助组件：方形工具按钮
struct ToolButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
                    .fontWeight(.bold)
            }
            .foregroundColor(color)
            .frame(width: 60, height: 56)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
    }
}

// MARK: - 搜索页面
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var showClearButton: Bool = false
    @State private var showSearchHistory: Bool = false
    @State private var groupedSearchResults: [GroupedSearchResults] = []
    @State private var isLoading: Bool = false
    @State private var selectedCategory: String? = nil
    @State private var showChart: Bool = false
    @State private var selectedResult: SearchResult? = nil
    @State private var selectedSymbol: SelectedSymbol? = nil
    @State private var isFirstAppear = true
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showChartView: Bool = false
    @State private var selectedSymbolForChart: SelectedSymbol? = nil
    @State private var selectedSymbolForDescription: SelectedSymbol? = nil
    @State private var clipboardContent: String = ""
    @State private var showClipboardBar: Bool = false
    
    @State private var collapsedGroups: [MatchCategory: Bool] = [:]
    let isSearchActive: Bool
    
    // 【新增】权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    // 【修改】移除 showLoginSheet
    @State private var showSubscriptionSheet = false
    
    init(isSearchActive: Bool = false, dataService: DataService) {
        self.isSearchActive = isSearchActive
        self.viewModel = SearchViewModel(dataService: dataService)
        _showSearchHistory = State(initialValue: isSearchActive)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.vertical, 4)
            
            // 剪贴板小条
            if showClipboardBar {
                HStack {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.gray)
                    Text(clipboardContent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray5))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.bottom, 12) // <<< 修改点：在这里增加一个底部的间距
                .onTapGesture {
                    // 粘贴并隐藏小条
                    searchText = clipboardContent
                    withAnimation {
                        showClipboardBar = false
                        showSearchHistory = false
                    }
                    // 你可以根据需要自动触发搜索：
                     startSearch()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                if showSearchHistory {
                    SearchHistoryView(viewModel: viewModel) { term in
                        searchText = term
                        startSearch()
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
                
                if isLoading {
                    ProgressView("正在搜索...")
                        .padding()
                }
                
                if !showSearchHistory && !groupedSearchResults.isEmpty {
                    searchResultsList
                        .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: Binding<Bool>(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Alert(
                    title: Text("错误"),
                    message: Text(viewModel.errorMessage ?? ""),
                    dismissButton: .default(Text("确定"))
                )
            }
            .sheet(item: $selectedSymbol) { selected in
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
            // 【修改】移除了 LoginView 的 sheet
            .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        }
        .onAppear {
            if isSearchActive && isFirstAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                    isFirstAppear = false
                }
            }
        }
    }
    
    private var searchBar: some View {
        HStack {
            ZStack(alignment: .trailing) {
                TextField(
                    "请输入要搜索的关键字",
                    text: $searchText,
                    onEditingChanged: { isEditing in
                        withAnimation {
                            // 控制搜索历史的展示
                            showSearchHistory = isEditing && searchText.isEmpty
                            if isEditing && searchText.isEmpty {
                                groupedSearchResults = []
                            }
                        }
                        // 当开始编辑且文本为空时，读取剪贴板并展示小条
                        if isEditing && searchText.isEmpty {
                            if let content = UIPasteboard.general.string?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                               !content.isEmpty {
                                clipboardContent = content
                                withAnimation {
                                    showClipboardBar = true
                                }
                            }
                        }
                    },
                    onCommit: {
                        startSearch()
                    }
                )
                .focused($isSearchFieldFocused)
                .padding(10)
                .padding(.trailing, showClearButton ? 30 : 10)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .onChange(of: searchText) { _, newValue in
                    showClearButton = !newValue.isEmpty
                    if newValue.isEmpty {
                        withAnimation {
                            showSearchHistory = true
                            groupedSearchResults = []
                        }
                    } else {
                        // 输入时隐藏剪贴板小条
                        withAnimation { showClipboardBar = false }
                    }
                }

                if showClearButton {
                    Button(action: {
                        searchText = ""
                        withAnimation {
                            showSearchHistory = true
                            groupedSearchResults = []
                            isSearchFieldFocused = true
                        }
                        // 点击清除时读取剪贴板
                        if let content = UIPasteboard.general.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !content.isEmpty {
                            clipboardContent = content
                            withAnimation {
                                showClipboardBar = true
                            }
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .opacity(0.6)
                    }
                    .padding(.trailing, 15)
                    .transition(.opacity)
                }
            }

            Button(action: {
                startSearch()
                isSearchFieldFocused = false
            }) {
                Text("搜索")
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
    }
    
    private var searchResultsList: some View {
        List {
            ForEach(groupedSearchResults) { groupedResult in
                if !groupedResult.results.isEmpty {
                    Section(header: GroupHeaderView(
                        category: groupedResult.category,
                        isCollapsed: Binding(
                            get: { collapsedGroups[groupedResult.category] ?? false },
                            set: { collapsedGroups[groupedResult.category] = $0 }
                        )
                    )) {
                        if !(collapsedGroups[groupedResult.category] ?? false) {
//                            ForEach(groupedResult.results.sorted { $0.score > $1.score }, id: \.result.id) { result, score in
                            // 修改点：在渲染时，先按 score 降序，其次按 marketCap 数值降序
                               ForEach(
                                   groupedResult.results.sorted(by: { lhs, rhs in
                                       if lhs.score != rhs.score {
                                           return lhs.score > rhs.score
                                       }
                                       let lmc = parseMarketCap(lhs.result.marketCap)
                                       let rmc = parseMarketCap(rhs.result.marketCap)
                                       return lmc > rmc
                                   }),
                                   id: \.result.id
                               ) { result, score in
                                SearchResultRow(result: result, score: score)
                                    .contentShape(Rectangle())  // 添加这一行
                                    .onTapGesture {           // 改用 onTapGesture
                                        handleResultSelection(result: result)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .sheet(item: $selectedSymbolForDescription) { selected in
            if let descriptions = getDescriptions(for: selected.result.symbol) {
                DescriptionView(descriptions: descriptions, isDarkMode: true)
            } else {
                DescriptionView(descriptions: ("No description available.", ""), isDarkMode: true)
            }
        }
        .navigationDestination(isPresented: $showChartView) {
            if let selected = selectedSymbolForChart {
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
        }
    }

    // 【核心修改】处理结果选择，加入权限判断
    private func handleResultSelection(result: SearchResult) {
        // 1. 检查权限 (点击结果查看图表)
        // 修复：添加 action: .viewChart 参数
        guard usageManager.canProceed(authManager: authManager, action: .viewChart) else {
            showSubscriptionSheet = true
            return
        }
        
        // 2. 正常逻辑
        if let groupName = viewModel.dataService.getCategory(for: result.symbol) {
            // 【修改点】：使用 Task 替代 DispatchQueue.global().async
            // 因为 fetchHistoricalData 现在是 async 函数
            Task {
                let data = await DatabaseManager.shared.fetchHistoricalData(
                    symbol: result.symbol,
                    tableName: groupName,
                    dateRange: .timeRange(.oneMonth)
                )
                
                // UI 更新必须在主线程 (Task 在 View 中通常默认在 MainActor，但显式调用更安全)
                await MainActor.run {
                    if data.isEmpty {
                        // 如果没有价格数据，但有description数据
                        if getDescriptions(for: result.symbol) != nil {
                            selectedSymbolForDescription = SelectedSymbol(result: result, category: "Description")
                        }
                    } else {
                        // 有价格数据，通过导航打开ChartView
                        selectedSymbolForChart = SelectedSymbol(result: result, category: groupName)
                        showChartView = true
                    }
                }
            }
        } else {
            // 如果在分类中找不到，但可能有description
            if getDescriptions(for: result.symbol) != nil {
                selectedSymbolForDescription = SelectedSymbol(result: result, category: "Description")
            }
        }
    }

    // 添加获取描述的辅助方法
    private func getDescriptions(for symbol: String) -> (String, String)? {
        // 检查是否为股票
        if let stock = viewModel.dataService.descriptionData?.stocks.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (stock.description1, stock.description2)
        }
        // 检查是否为ETF
        if let etf = viewModel.dataService.descriptionData?.etfs.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (etf.description1, etf.description2)
        }
        return nil
    }
    
    func startSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        // 【核心逻辑】
        // 1. 先检查是否有足够的点数进行搜索 (performDeduction: false，先不扣)
        if !usageManager.canProceed(authManager: authManager, action: .search, performDeduction: false) {
            showSubscriptionSheet = true
            return
        }
        
        isSearchFieldFocused = false
        isLoading = true
        showSearchHistory = false

        viewModel.performSearch(query: trimmed) { groupedResults in
            DispatchQueue.main.async {
                // 2. 搜索完成，如果有结果，则扣点
                if !groupedResults.isEmpty {
                    self.usageManager.deduct(action: .search)
                }
                
                withAnimation {
                    // 1. 先赋值
                    self.groupedSearchResults = groupedResults
                    self.isLoading = false
                    
                    // 2. 初始化折叠状态
                    for group in groupedResults {
                        if self.collapsedGroups[group.category] == nil {
                            self.collapsedGroups[group.category] = false
                        }
                    }
                }
                
                // 3. 自动判断首个结果
                if
                    let firstGroup = groupedResults.first,
                    // 记得 results 本来就是按 score 排好序的
                    let firstEntry = firstGroup.results.first,
                    trimmed.uppercased() == firstEntry.result.symbol.uppercased()
                {
                    // 4. 直接打开 chart 或 description
                    self.handleResultSelection(result: firstEntry.result)
                    return
                }
                
                // 如果不一致，就正常停留在列表
            }
        }
    }
}

// MARK: - 全局函数 (移出 SearchView 防止作用域错误)
// 解析市值字符串，返回可比较的数值（单位统一为美元）
private func parseMarketCap(_ text: String?) -> Double {
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return 0 }
    // 常见格式示例： "1.23T", "456.7B", "89.0M" 或纯数字字符串
    let upper = t.uppercased()
    let multipliers: [Character: Double] = [
        "T": 1_000_000_000_000,
        "B": 1_000_000_000,
        "M": 1_000_000,
        "K": 1_000
    ]
    if let last = upper.last, let mul = multipliers[last] {
        let numberPart = String(upper.dropLast())
        if let v = Double(numberPart.replacingOccurrences(of: ",", with: "")) {
            return v * mul
        }
    }
    // 无单位，尝试直接解析
    let plain = upper.replacingOccurrences(of: ",", with: "")
    return Double(plain) ?? 0
}

// MARK: - 搜索结果行
struct SearchResultRow: View {
    @ObservedObject var result: SearchResult
    let score: Int
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        // 【修改】: 应用动态颜色
                        Text(result.symbol)
                            .foregroundColor(colorForEarningTrend(result.earningTrend))
                            .fontWeight(.bold) // 稍微加粗一点，让颜色更明显
                        Text(result.name)
                            .foregroundColor(.primary) // 确保名字也是自适应颜色
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.headline)
                    Text(result.tag.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundColor(.secondary) // 使用 secondary 替代 gray
                }
                Spacer()
            }
            HStack {
                if let marketCap = result.marketCap {
                    Text(marketCap)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let peRatio = result.peRatio, peRatio != "--" {
                    Text(peRatio)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let pb = result.pb, pb != "--" {
                    Text(pb)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let compare = result.compare {
                    Text(compare)
                        .font(.subheadline)
                        // 【修改】: 应用动态颜色
                        .foregroundColor(colorForCompareValue(compare))
                }
                if let volume = result.volume {
                    Text(volume)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    // 【修改】: 修复了 Light Mode 下看不到文字的问题，并优化了对比度
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp:
            return .red // 红色 (通常在浅色/深色都可见)
        case .negativeAndUp:
            return .purple // 紫色
        case .positiveAndDown:
            return .cyan // 蓝色
        case .negativeAndDown:
            // 原来的 .green 在白背景下有时对比度不够，使用系统 green 通常可以，但在浅色模式下 .green 稍显刺眼，这里保持 .green 即可，或者用 .mint
            return .green 
        case .insufficientData:
            // 【核心修复】: 以前是 .white，导致浅色模式不可见。
            // 改为 .primary，它会自动变色（浅色模式黑字，深色模式白字）。
            return .primary 
        }
    }
    
    // 【新增】: 根据 compare_all 内容返回颜色的辅助函数
    private func colorForCompareValue(_ value: String) -> Color {
        if value.contains("前") || value.contains("后") || value.contains("未") {
            return .orange
        } else {
            return .secondary // 默认颜色使用 .secondary 灰色
        }
    }
}

// MARK: - 搜索历史视图
struct SearchHistoryView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onSelect: (String) -> Void
    
    var body: some View {
        VStack {
            if viewModel.searchHistory.isEmpty {
                Text("暂无搜索历史")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.searchHistory, id: \.self) { term in
                            HStack {
                                Text(term)
                                Spacer()
                                Button(action: {
                                    viewModel.removeSearchHistory(term: term)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(term)
                            }
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(8)
                .shadow(radius: 5)
                .padding([.horizontal, .bottom])
            }
        }
    }
}

// MARK: - ViewModel
class SearchViewModel: ObservableObject {
    @Published var searchHistory: [String] = []
    @Published var errorMessage: String? = nil
    @Published var isChartLoading: Bool = false
    @Published var groupedSearchResults: [GroupedSearchResults] = []
    
    var dataService: DataService
    private var cancellables = Set<AnyCancellable>()
    
    // 使用 DataService.shared 作为默认值
    init(dataService: DataService = DataService.shared) {
        self.dataService = dataService
        dataService.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
        loadSearchHistory()
    }
    
    // 【修改】: 增加 allowFuzzy 返回值
    // 返回值: (是否跳过描述搜索, 是否强制精准全等匹配, 是否允许模糊/容错搜索)
    private func analyzeQueryConstraints(query: String) -> (skipDescription: Bool, forceExactMatch: Bool, allowFuzzy: Bool) {
        let length = query.count
        if length == 0 { return (false, false, true) }
        
        // 1. 判断是否包含中文 (只要包含一个汉字即视为中文处理逻辑)
        if query.range(of: "\\p{Han}", options: .regularExpression) != nil {
            if length >= 3 { return (false, false, true) }      // >=3: 一切如常 (允许模糊)
            
            // 【核心修改点】: 2个中文字 -> 跳过描述, 非强制全等(允许包含), 但禁止模糊搜索
            if length == 2 { return (true, false, false) }
            
            return (true, true, false)                          // 1: 不搜描述 + 精准匹配 + 禁止模糊
        }
        
        // 2. 判断是否为纯数字
        if query.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            if length >= 3 { return (false, false, true) }      // >=3: 一切如常
            if length == 2 { return (true, false, true) }       // 2: 不搜描述
            return (true, true, false)                          // 1: 不搜描述 + 精准匹配
        }
        
        // 3. 默认为英文/其他
        if length >= 4 { return (false, false, true) }          // >=4: 一切如常
        if length == 3 { return (true, false, true) }           // 3: 不搜描述
        return (true, true, false)                              // 1或2: 不搜描述 + 精准匹配
    }
    
    func performSearch(query: String, completion: @escaping ([GroupedSearchResults]) -> Void) {
        // 获取约束条件，现在包含 allowFuzzy
        let constraints = analyzeQueryConstraints(query: query)
        
        let keywords = query.lowercased().split(separator: " ").map { String($0) }
        
        // 使用 Task
        Task {
            guard let descriptionData = self.dataService.descriptionData else {
                await MainActor.run { completion([]) }
                return
            }
            
            // 搜索逻辑 (CPU 密集，非 Async)
            var groupedResults: [(group: GroupedSearchResults, matchScore: Int, priority: Int)] = []
            
            // 初始分类列表
            var categories: [MatchCategory] = [.stockSymbol, .etfSymbol, .stockName, .etfName, .stockTag, .etfTag, .stockDescription, .etfDescription]
            
            // 如果约束条件要求跳过描述，直接从列表中移除
            if constraints.skipDescription {
                categories.removeAll { $0 == .stockDescription || $0 == .etfDescription }
            }
            
            for category in categories {
                // 【修改】: 传递 forceExactMatch 和 allowFuzzy 参数
                var matches: [(result: SearchResult, score: Int)] = []
                
                switch category {
                case .stockSymbol, .stockName, .stockDescription, .stockTag:
                    matches = self.searchCategory(items: descriptionData.stocks,
                                                  keywords: keywords,
                                                  category: category,
                                                  forceExactMatch: constraints.forceExactMatch,
                                                  allowFuzzy: constraints.allowFuzzy) // 传递 allowFuzzy
                    
                case .etfSymbol, .etfName, .etfDescription, .etfTag:
                    matches = self.searchCategory(items: descriptionData.etfs,
                                                  keywords: keywords,
                                                  category: category,
                                                  forceExactMatch: constraints.forceExactMatch,
                                                  allowFuzzy: constraints.allowFuzzy) // 传递 allowFuzzy
                }
                
                if !matches.isEmpty {
                    let highestScore = matches.max(by: { $0.score < $1.score })?.score ?? 0
                    let group = GroupedSearchResults(category: category, results: matches, highestScore: highestScore)
                    groupedResults.append((group, highestScore, category.priority))
                }
            }
            
            let sortedGroups = groupedResults.sorted {
                if $0.matchScore != $1.matchScore { return $0.matchScore > $1.matchScore }
                return $0.priority > $1.priority
            }.map { $0.group }
            
            // 缓存结果
            await MainActor.run {
                if !keywords.isEmpty { self.addSearchHistory(term: query) }
                self.groupedSearchResults = sortedGroups
            }
            
            // 异步获取 Volume
            await self.fetchLatestVolumes(for: sortedGroups)
            
            // 异步获取财报趋势
            await self.fetchEarningTrends(for: sortedGroups)
            
            await MainActor.run {
                completion(sortedGroups)
            }
        }
    }
    
    // MARK: - 修复后的 fetchEarningTrends
    private func fetchEarningTrends(for groupedResults: [GroupedSearchResults]) async {
        await withTaskGroup(of: Void.self) { group in
            for groupedResult in groupedResults {
                for entry in groupedResult.results {
                    group.addTask {
                        let symbol = entry.result.symbol
                        
                        // 修复：不再使用 var trend 并在 async let 块中修改
                        // 而是调用辅助函数直接返回计算结果赋值给 let
                        let trend = await self.calculateTrend(for: symbol)
                        
                        await MainActor.run {
                            entry.result.earningTrend = trend
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 新增辅助函数：封装计算逻辑，避免变量捕获问题
    private func calculateTrend(for symbol: String) async -> EarningTrend {
        let sortedEarnings = await DatabaseManager.shared.fetchEarningData(forSymbol: symbol).sorted { $0.date > $1.date }
        
        if sortedEarnings.count >= 2 {
            let latestEarning = sortedEarnings[0]
            let previousEarning = sortedEarnings[1]
            
            if let tableName = self.dataService.getCategory(for: symbol) {
                // 在这里使用 async let 是安全的，因为我们没有修改外部的 var
                async let latestCloseTask = DatabaseManager.shared.fetchClosingPrice(forSymbol: symbol, onDate: latestEarning.date, tableName: tableName)
                async let previousCloseTask = DatabaseManager.shared.fetchClosingPrice(forSymbol: symbol, onDate: previousEarning.date, tableName: tableName)
                
                let (latest, previous) = await (latestCloseTask, previousCloseTask)
                
                if let l = latest, let p = previous {
                    if latestEarning.price > 0 {
                        return (l > p) ? .positiveAndUp : .positiveAndDown
                    } else {
                        return (l > p) ? .negativeAndUp : .negativeAndDown
                    }
                }
            }
        }
        return .insufficientData
    }
    
    private func fetchLatestVolumes(for groupedResults: [GroupedSearchResults]) async {
        let etfCategories: Set<MatchCategory> = [.etfSymbol, .etfName, .etfDescription, .etfTag]
        
        await withTaskGroup(of: Void.self) { group in
            for groupedResult in groupedResults {
                if etfCategories.contains(groupedResult.category) {
                    for entry in groupedResult.results {
                        group.addTask {
                            let symbol = entry.result.symbol
                            if let latestVolume = await DatabaseManager.shared.fetchLatestVolume(forSymbol: symbol, tableName: "ETFs") {
                                await MainActor.run {
                                    entry.result.volume = self.formatVolume(latestVolume)
                                }
                            } else {
                                await MainActor.run {
                                    entry.result.volume = "--K"
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func formatVolume(_ volume: Int64) -> String {
        let kVolume = Double(volume) / 1000.0
        return String(format: "%.0fK", kVolume)
    }

    // 增加 forceExactMatch 参数，  增加 allowFuzzy 参数
    func searchCategory<T: SearchDescribableItem>(items: [T],
                                                  keywords: [String],
                                                  category: MatchCategory,
                                                  forceExactMatch: Bool,
                                                  allowFuzzy: Bool) // 新增参数
    -> [(result: SearchResult, score: Int)] {
        var scoredResults: [(SearchResult, Int)] = []
        
        for item in items {
            // 传递 allowFuzzy
            if let totalScore = matchScoreForItem(item, category: category, keywords: keywords, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy) {
                let upperSymbol = item.symbol.uppercased()
                let data = dataService.marketCapData[upperSymbol]
                let marketCap = data?.marketCap
                let peRatioStr = data?.peRatio != nil ? String(format: "%.2f", data!.peRatio!) : "--"
                let pbStr = data?.pb != nil ? String(format: "%.2f", data!.pb!) : "--"
                
                let result = SearchResult(
                    symbol: item.symbol,
                    name: item.name,
                    tag: item.tag,
                    marketCap: marketCap,
                    peRatio: peRatioStr,
                    pb: pbStr,  // 添加 PB 数据
                    compare: dataService.compareData[upperSymbol]
                )
                
                scoredResults.append((result, totalScore))
            }
        }
        
//        return scoredResults.sorted { $0.1 > $1.1 }
        // 修改点：组内排序先按分数降序，再按 marketCap 数值降序
       return scoredResults.sorted { lhs, rhs in
           if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
           let lmc = parseMarketCap(lhs.0.marketCap)
           let rmc = parseMarketCap(rhs.0.marketCap)
           return lmc > rmc
       }
    }
    
    // 【修改】: 增加 forceExactMatch 参数，增加 allowFuzzy 参数
    private func matchScoreForItem<T: SearchDescribableItem>(
        _ item: T,
        category: MatchCategory,
        keywords: [String],
        forceExactMatch: Bool,
        allowFuzzy: Bool) -> Int? { // 新增参数
        
        var totalScore = 0
        
        for keyword in keywords {
            let lowerKeyword = keyword.lowercased()
            // 传递 allowFuzzy
            let singleScore = scoreOfSingleMatch(item: item, keyword: lowerKeyword, category: category, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
            if singleScore <= 0 {
                return nil
            } else {
                totalScore += singleScore
            }
        }
        return totalScore
    }
    
    // 【修改】: 增加 forceExactMatch 参数，增加 allowFuzzy 参数
    private func scoreOfSingleMatch<T: SearchDescribableItem>(
        item: T,
        keyword: String,
        category: MatchCategory,
        forceExactMatch: Bool,
        allowFuzzy: Bool) -> Int { // 新增参数
        
        switch category {
        case .stockSymbol, .etfSymbol:
            return matchSymbol(item.symbol.lowercased(), keyword: keyword, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
        case .stockName, .etfName:
            return matchName(item.name, keyword: keyword, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
        case .stockTag, .etfTag:
            return matchTags(item.tag, keyword: keyword, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
        case .stockDescription, .etfDescription:
            // Description 已经被上层逻辑过滤掉了，但为了安全起见，这里也可以处理
            return matchDescriptions(item.description1, item.description2, keyword: keyword)
        }
    }
    
    // 【修改】: 实现 forceExactMatch 逻辑，增加 allowFuzzy 逻辑
    private func matchSymbol(_ symbol: String, keyword: String, forceExactMatch: Bool, allowFuzzy: Bool) -> Int {
        if symbol == keyword {
            return 3
        }
        
        // 如果强制精准匹配，且不相等，直接返回 0
        if forceExactMatch { return 0 }
        
        if symbol.contains(keyword) {
            return 2
        } else if allowFuzzy && isFuzzyMatch(text: symbol, keyword: keyword, maxDistance: 1) { // 检查 allowFuzzy
            return 1
        }
        return 0
    }
    
    // 【修改】: 实现 forceExactMatch 逻辑，增加 allowFuzzy 逻辑
    private func matchName(_ name: String, keyword: String, forceExactMatch: Bool, allowFuzzy: Bool) -> Int {
        let lowercasedName = name.lowercased()
        
        // 1. 全等匹配 (最高优先级，无论是否强制精准)
        if lowercasedName == keyword {
            return 4
        }
        
        // 如果强制精准匹配，且没有全等，直接返回 0
        if forceExactMatch { return 0 }
        
        // 以下是模糊/部分匹配逻辑
        let nameComponents = lowercasedName.components(separatedBy: ",")
        let mainName = nameComponents.first ?? lowercasedName
        let nameWords = mainName.split(separator: " ").map { String($0) }
        
        if nameWords.contains(keyword) || mainName == keyword {
            return 3
        } else if mainName.contains(keyword) {
            return 2
        } else if lowercasedName.contains(keyword) {
            return 1
        } else if allowFuzzy && isFuzzyMatch(text: lowercasedName, keyword: keyword, maxDistance: 1) { // 检查 allowFuzzy
            return 1
        }
        return 0
    }
    
    // 【修改】: 实现 forceExactMatch 逻辑，增加 allowFuzzy 逻辑
    private func matchTags(_ tags: [String], keyword: String, forceExactMatch: Bool, allowFuzzy: Bool) -> Int {
        var maxScore = 0
        for t in tags {
            let lowerTag = t.lowercased()
            var score = 0
            
            if lowerTag == keyword {
                score = 3
            } else if !forceExactMatch {
                // 只有非强制精准匹配时，才进行部分匹配和模糊匹配
                if lowerTag.contains(keyword) {
                    score = 2
                } else if allowFuzzy && isFuzzyMatch(text: lowerTag, keyword: keyword, maxDistance: 1) { // 检查 allowFuzzy
                    score = 1
                }
            }
            
            maxScore = max(maxScore, score)
        }
        return maxScore
    }
    
    // Description 不需要 forceExactMatch，因为如果启用了 forceExactMatch，
    // 在 performSearch 层级就已经把 .stockDescription/.etfDescription 移除了。
    private func matchDescriptions(_ desc1: String, _ desc2: String, keyword: String) -> Int {
        let d1 = desc1.lowercased()
        let d2 = desc2.lowercased()
        let words = d1.split(separator: " ") + d2.split(separator: " ")
        
        if words.contains(where: { String($0) == keyword }) {
            return 2
        } else if d1.contains(keyword) || d2.contains(keyword) {
            return 1
        }
        return 0
    }
    
    private func isFuzzyMatch(text: String, keyword: String, maxDistance: Int) -> Bool {
        if keyword.count <= 1 {
            return text.contains(keyword)
        }
        let words = text.split(separator: " ").map { String($0) }
        return words.contains { levenshteinDistance($0, keyword) <= maxDistance }
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let n = a.count
        let m = b.count
        
        if n == 0 { return m }
        if m == 0 { return n }
        
        var matrix = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { matrix[i][0] = i }
        for j in 0...m { matrix[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1,
                        matrix[i][j - 1] + 1,
                        matrix[i - 1][j - 1] + 1
                    )
                }
            }
        }
        return matrix[n][m]
    }
    
    // MARK: - 搜索历史
    func loadSearchHistory() {
        if let history = UserDefaults.standard.array(forKey: "stockSearchHistory") as? [String] {
            self.searchHistory = history
        }
    }
    
    func addSearchHistory(term: String) {
        let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
        guard !trimmedTerm.isEmpty else { return }
        
        if let index = self.searchHistory.firstIndex(where: { $0.lowercased() == trimmedTerm.lowercased() }) {
            self.searchHistory.remove(at: index)
        }
        self.searchHistory.insert(trimmedTerm, at: 0)
        
        // 增加搜索历史记录保存条目的数量
        if self.searchHistory.count > 20 {
            self.searchHistory = Array(self.searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: "stockSearchHistory")
    }
    
    func removeSearchHistory(term: String) {
        if let index = searchHistory.firstIndex(where: { $0.lowercased() == term.lowercased() }) {
            searchHistory.remove(at: index)
            UserDefaults.standard.set(searchHistory, forKey: "stockSearchHistory")
        }
    }
}
