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
    }
}

// MARK: - ===================== 即时联想（Suggestion）核心 =====================

/// 命中字段类型（用于 UI 显示不同徽标）
enum SuggestionField: Int, Sendable {
    case symbol, name, tag
}

/// 联想结果项
struct SearchSuggestion: Identifiable, Sendable {
    let symbol: String
    let name: String
    let tags: [String]
    let isETF: Bool
    let score: Int
    let field: SuggestionField
    let matchedTag: String?      // 命中的那个标签（用于展示）
    let marketCapText: String?   // 已格式化好的市值字符串
    let rawMarketCap: Double
    
    var id: String { symbol }
}

/// 预处理过的索引条目（全部小写化 / 预切词，避免每次输入重复计算）
struct SearchIndexEntry: Sendable {
    let symbol: String
    let name: String
    let tags: [String]
    let isETF: Bool
    
    let lowerSymbol: String
    let lowerName: String
    let lowerTags: [String]
    let nameWords: [String]
}

/// 全局共享的搜索索引（后台构建、加锁访问）
final class SearchIndexStore: @unchecked Sendable {
    static let shared = SearchIndexStore()
    
    private let lock = NSLock()
    private var entries: [SearchIndexEntry] = []
    private var signature: String = ""
    private var building = false
    
    /// 索引构建完成后在主线程广播，便于 ViewModel 重算当前输入
    let didBuild = PassthroughSubject<Void, Never>()
    
    private init() {}
    
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return !entries.isEmpty
    }
    
    func snapshot() -> [SearchIndexEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
    
    /// 数据变化时构建（同一份数据只建一次）
    func buildIfNeeded(from data: DescriptionData?) {
        guard let data = data else { return }
        let sig = "\(data.stocks.count)_\(data.etfs.count)"
        
        lock.lock()
        if building || (sig == signature && !entries.isEmpty) {
            lock.unlock()
            return
        }
        building = true
        lock.unlock()
        
        let stocks = data.stocks
        let etfs = data.etfs
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var list: [SearchIndexEntry] = []
            list.reserveCapacity(stocks.count + etfs.count)
            for s in stocks {
                list.append(Self.makeEntry(symbol: s.symbol, name: s.name, tags: s.tag, isETF: false))
            }
            for e in etfs {
                list.append(Self.makeEntry(symbol: e.symbol, name: e.name, tags: e.tag, isETF: true))
            }
            
            self.lock.lock()
            self.entries = list
            self.signature = sig
            self.building = false
            self.lock.unlock()
            
            DispatchQueue.main.async { self.didBuild.send(()) }
        }
    }
    
    private static func makeEntry(symbol: String, name: String, tags: [String], isETF: Bool) -> SearchIndexEntry {
        let lowerName = name.lowercased()
        // 按非字母数字切词；中文字符 isLetter == true，会整体保留
        let words = lowerName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return SearchIndexEntry(
            symbol: symbol,
            name: name,
            tags: tags,
            isETF: isETF,
            lowerSymbol: symbol.lowercased(),
            lowerName: lowerName,
            lowerTags: tags.map { $0.lowercased() },
            nameWords: words
        )
    }
    
    // MARK: - 联想计算（纯函数，可在任意线程调用）
    
    static func containsCJK(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x4E00...0x9FFF,   // CJK 基本汉字
                 0x3400...0x4DBF,   // 扩展A
                 0xF900...0xFAFF:   // 兼容汉字
                return true
            default: continue
            }
        }
        return false
    }
    
    static func computeSuggestions(query rawQuery: String,
                                   entries: [SearchIndexEntry],
                                   marketCaps: [String: Double],
                                   limit: Int) -> [SearchSuggestion] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, !entries.isEmpty else { return [] }
        
        // 多词 AND 语义
        let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        
        var results: [SearchSuggestion] = []
        results.reserveCapacity(64)
        
        for entry in entries {
            var minScore = Int.max
            var sumScore = 0
            var field: SuggestionField = .symbol
            var matchedTag: String? = nil
            var ok = true
            
            for (idx, token) in tokens.enumerated() {
                let isCJK = containsCJK(token)
                guard let hit = scoreEntry(entry, token: token, isCJK: isCJK) else {
                    ok = false
                    break
                }
                if idx == 0 {
                    field = hit.field
                    matchedTag = hit.matchedTag
                }
                minScore = min(minScore, hit.score)
                sumScore += hit.score
            }
            
            guard ok, minScore != Int.max else { continue }
            
            let finalScore = minScore + (sumScore / tokens.count) / 10
            let cap = marketCaps[entry.symbol.uppercased()] ?? 0
            
            results.append(SearchSuggestion(
                symbol: entry.symbol,
                name: entry.name,
                tags: entry.tags,
                isETF: entry.isETF,
                score: finalScore,
                field: field,
                matchedTag: matchedTag,
                marketCapText: formatCap(cap),
                rawMarketCap: cap
            ))
        }
        
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.rawMarketCap != b.rawMarketCap { return a.rawMarketCap > b.rawMarketCap }
            return a.symbol < b.symbol
        }
        
        return Array(results.prefix(limit))
    }
    
    /// 单个 token 的打分
    private static func scoreEntry(_ e: SearchIndexEntry,
                                   token q: String,
                                   isCJK: Bool) -> (score: Int, field: SuggestionField, matchedTag: String?)? {
        var best = 0
        var field: SuggestionField = .symbol
        var matchedTag: String? = nil
        let qCount = q.count
        let allowContains = (qCount >= 2) || isCJK   // 单个英文字母禁止 contains，避免噪音
        
        // ---------- 1) Symbol（中文查询跳过） ----------
        if !isCJK {
            let sym = e.lowerSymbol
            if sym == q {
                best = 1000; field = .symbol
            } else if sym.hasPrefix(q) {
                // 越短越接近，保证 AAPL 排在 AAPLW 前
                let s = 900 - min(max(sym.count - qCount, 0), 30)
                if s > best { best = s; field = .symbol }
            } else if qCount >= 2, sym.contains(q) {
                if 600 > best { best = 600; field = .symbol }
            }
        }
        
        // ---------- 2) Name ----------
        let name = e.lowerName
        if name == q {
            if 880 > best { best = 880; field = .name }
        } else if name.hasPrefix(q) {
            if 760 > best { best = 760; field = .name }
        } else if e.nameWords.contains(where: { $0.hasPrefix(q) }) {
            if 700 > best { best = 700; field = .name }
        } else if allowContains, name.contains(q) {
            // 单个汉字命中面太广，降权
            let s = (isCJK && qCount == 1) ? 350 : 500
            if s > best { best = s; field = .name }
        }
        
        // ---------- 3) Tag ----------
        for (i, t) in e.lowerTags.enumerated() {
            var s = 0
            if t == q {
                s = 820
            } else if t.hasPrefix(q) {
                s = 680
            } else if allowContains, t.contains(q) {
                s = (isCJK && qCount == 1) ? 300 : 430
            }
            if s > best {
                best = s
                field = .tag
                matchedTag = i < e.tags.count ? e.tags[i] : nil
            }
        }
        
        return best > 0 ? (best, field, matchedTag) : nil
    }
    
    static func formatCap(_ v: Double) -> String? {
        guard v > 0 else { return nil }
        if v >= 1_000_000_000_000 { return String(format: "%.2fT", v / 1_000_000_000_000) }
        if v >= 1_000_000_000 { return String(format: "%.0fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.0fM", v / 1_000_000) }
        return String(format: "%.0f", v)
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
                .foregroundColor(.secondary)
            Spacer()
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
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
    @State private var navigateToHistory = false
    
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @State private var showSubscriptionSheet = false
    
    var body: some View {
        HStack(spacing: 12) {
            ToolButton(
                title: "对比",
                icon: "chart.line.uptrend.xyaxis",
                color: .blue,
                cardKey: "CompareTool"
            ) {
                PointsCoordinator.shared.requireLogin(authManager: authManager) {
                    FinanceAnalytics.shared.track(cardKey: "对比", cardName: "对比", authManager: authManager)
                    showCompare = true
                }
            }
            
            Button(action: {
                PointsCoordinator.shared.requireLogin(authManager: authManager) {
                    FinanceAnalytics.shared.track(cardKey: "搜索", cardName: "搜索", authManager: authManager)
                    showSearch = true
                }
            }) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .bold))
                    Text("搜索")
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
            
            ToolButton(title: "财报", icon: "calendar", color: .orange, cardKey: "EarningCalendar") {
                PointsCoordinator.shared.attempt(action: .openEarnings, itemKey: nil,
                    displayName: "财报发布日历", authManager: authManager) {
                    FinanceAnalytics.shared.track(cardKey: "财报", cardName: "财报", authManager: authManager)
                    navigateToEarnings = true
                }
            }

            ToolButton(title: "复盘", icon: "clock.arrow.circlepath", color: .purple, cardKey: "HistoryRecap") {
                PointsCoordinator.shared.attempt(action: .openHistory, itemKey: nil,
                    displayName: "复盘历史 (多组共振)", authManager: authManager) {
                    FinanceAnalytics.shared.track(cardKey: "复盘", cardName: "复盘", authManager: authManager)
                    navigateToHistory = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .background(Color(UIColor.systemGroupedBackground))
        .navigationDestination(isPresented: $showSearch) {
            SearchView(isSearchActive: true, dataService: dataService)
        }
        .navigationDestination(isPresented: $showCompare) {
            CompareView(initialSymbol: "")
        }
        .navigationDestination(isPresented: $navigateToEarnings) {
            EarningReleaseView()
        }
        .navigationDestination(isPresented: $navigateToHistory) {
            EarningHistoryView()
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
}

// 辅助组件：方形工具按钮
struct ToolButton: View {
    let title: String
    let icon: String
    let color: Color
    let cardKey: String
    let action: () -> Void
    
    @EnvironmentObject var dataService: DataService
    @State private var glow = false
    
    private var featuredLabel: String? { dataService.featuredCards[cardKey] }
    private var isFeatured: Bool { featuredLabel != nil }
    private var badgeText: String {
        if let label = featuredLabel, !label.isEmpty { return label }
        return "精选"
    }
    
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
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isFeatured
                        ? AnyShapeStyle(LinearGradient(colors: [.yellow, .orange, .pink],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.clear),
                        lineWidth: isFeatured ? 2 : 0
                    )
            )
            .cornerRadius(12)
            .shadow(
                color: isFeatured ? Color.orange.opacity(glow ? 0.55 : 0.2) : Color.black.opacity(0.05),
                radius: isFeatured ? (glow ? 8 : 3) : 2,
                x: 0, y: 1
            )
        }
        .overlay(alignment: .topTrailing) {
            if isFeatured {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill").font(.system(size: 7))
                    Text(badgeText).font(.system(size: 9, weight: .heavy))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                .offset(x: 3, y: -5)
                .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
            }
        }
        .onAppear {
            if isFeatured {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    glow = true
                }
            }
        }
    }
}

// MARK: - 搜索页面
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    @State private var searchText: String = ""
    @State private var showClearButton: Bool = false
    @State private var showSearchHistory: Bool = false
    @State private var groupedSearchResults: [GroupedSearchResults] = []
    @State private var isLoading: Bool = false
    @State private var hasSearched: Bool = false
    @State private var showChart: Bool = false
    @State private var selectedResult: SearchResult? = nil
    @State private var selectedSymbol: SelectedSymbol? = nil
    @State private var isFirstAppear = true
    
    // 【修改】改为 StateObject，避免 SwiftUI 重建 View 时反复创建 ViewModel
    @StateObject private var viewModel: SearchViewModel
    
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showChartView: Bool = false
    @State private var selectedSymbolForChart: SelectedSymbol? = nil
    @State private var selectedSymbolForDescription: SelectedSymbol? = nil
    @State private var clipboardContent: String = ""
    @State private var showClipboardBar: Bool = false
    
    // 【新增】联想显示开关
    @State private var showSuggestions: Bool = false
    
    @State private var collapsedGroups: [MatchCategory: Bool] = [:]
    let isSearchActive: Bool
    
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @State private var showSubscriptionSheet = false
    
    /// 【可调】输入内容恰好等于某个 symbol 时，回车直接开图（省一次搜索扣点）。
    /// 若想保持旧计费行为，把它改成 false。
    private let enableExactSymbolShortcut = true
    
    init(isSearchActive: Bool = false, dataService: DataService) {
        self.isSearchActive = isSearchActive
        _viewModel = StateObject(wrappedValue: SearchViewModel(dataService: dataService))
        _showSearchHistory = State(initialValue: isSearchActive)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            Color(UIColor.systemGroupedBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ===== 搜索区域 =====
                VStack(spacing: 10) {
                    searchBar
                    
                    if showClipboardBar {
                        Button(action: {
                            searchText = clipboardContent
                            withAnimation {
                                showClipboardBar = false
                                showSearchHistory = false
                                showSuggestions = true
                            }
                            viewModel.queryChanged(clipboardContent)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.caption)
                                Text("粘贴并搜索: \"\(clipboardContent)\"")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.bottom, 4)
                    }
                }
                .padding(.bottom, 8)
                .background(Color(UIColor.systemGroupedBackground))
                .zIndex(2)

                // ===== 内容区域 =====
                ZStack {
                    if isLoading {
                        VStack {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("正在搜索...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.systemGroupedBackground))
                    }
                    else if showSuggestions && !viewModel.suggestions.isEmpty {
                        suggestionList
                            .transition(.opacity)
                    }
                    else if showSearchHistory && searchText.isEmpty {
                        SearchHistoryView(viewModel: viewModel) { term in
                            searchText = term
                            startSearch()
                        }
                        .transition(.opacity)
                    }
                    else if !groupedSearchResults.isEmpty {
                        searchResultsList
                            .transition(.opacity)
                    }
                    else if !searchText.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.gray.opacity(0.5))
                            Text(hasSearched ? "未找到相关结果" : "继续输入以获取联想结果")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
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
        .sheet(item: $selectedSymbolForDescription) { selected in
            if let descriptions = getDescriptions(for: selected.result.symbol) {
                DescriptionView(descriptions: descriptions)
            } else {
                DescriptionView(descriptions: ("No description available.", ""))
            }
        }
        .navigationDestination(isPresented: $showChartView) {
            if let selected = selectedSymbolForChart {
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onAppear {
            // 冷启动时确保索引构建（数据已加载则立即建）
            viewModel.prepareIndex()
            if isSearchActive && isFirstAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                    isFirstAppear = false
                }
            }
        }
    }
    
    // MARK: - 搜索条
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 18))
                
                TextField("请输入股票代码/名称/标签", text: $searchText, onEditingChanged: { isEditing in
                    withAnimation {
                        if isEditing {
                            if searchText.isEmpty {
                                showSearchHistory = true
                                groupedSearchResults = []
                                showSuggestions = false
                            } else {
                                showSuggestions = true
                            }
                        }
                    }
                    if isEditing && searchText.isEmpty {
                        checkForClipboard()
                    }
                }, onCommit: {
                    startSearch()
                })
                .focused($isSearchFieldFocused)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 17))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .onChange(of: searchText) { _, newValue in
                    showClearButton = !newValue.isEmpty
                    // 【核心】每次输入变化都推给 ViewModel（内部 debounce）
                    viewModel.queryChanged(newValue)
                    
                    if newValue.isEmpty {
                        withAnimation {
                            showSearchHistory = true
                            showSuggestions = false
                            groupedSearchResults = []
                            hasSearched = false
                        }
                    } else {
                        withAnimation {
                            showClipboardBar = false
                            showSearchHistory = false
                            showSuggestions = true
                        }
                    }
                }

                if showClearButton {
                    Button(action: {
                        searchText = ""
                        viewModel.queryChanged("")
                        withAnimation {
                            showSearchHistory = true
                            showSuggestions = false
                            groupedSearchResults = []
                            hasSearched = false
                            isSearchFieldFocused = true
                        }
                        checkForClipboard()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .opacity(0.7)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            
            Button(action: {
                startSearch()
                isSearchFieldFocused = false
            }) {
                Text("搜索")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(12)
                    .shadow(color: Color.blue.opacity(0.3), radius: 3, x: 0, y: 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - 【新增】联想结果列表
    private var suggestionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, item in
                    SuggestionRow(
                        suggestion: item,
                        query: viewModel.activeHighlightToken,
                        onTap: { handleSuggestionTap(item) },
                        onFill: {
                            searchText = item.symbol
                            viewModel.queryChanged(item.symbol)
                            isSearchFieldFocused = true
                        }
                    )
                    
                    if index < viewModel.suggestions.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
                
                // 底部：查看全部结果（走完整搜索，会扣点）
                Divider()
                Button(action: {
                    isSearchFieldFocused = false
                    startSearch()
                }) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 14))
                        Text(fullSearchButtonTitle)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    .foregroundColor(.blue)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    private var fullSearchButtonTitle: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if PointsCoordinator.shared.isFree(action: .search, itemKey: trimmed, authManager: authManager) {
            return "查看全部匹配结果（含描述搜索）"
        }
        let cost = usageManager.cost(for: .search, itemKey: nil)
        return "查看全部匹配结果（消耗 \(cost) 点）"
    }
    
    // MARK: - 【新增】点击联想项 → 直接进详情
    private func handleSuggestionTap(_ item: SearchSuggestion) {
        isSearchFieldFocused = false
        withAnimation { showSuggestions = false }
        
        // 记录到搜索历史，便于下次直达
        viewModel.addSearchHistory(term: item.symbol)
        
        let data = viewModel.dataService.marketCapData[item.symbol.uppercased()]
        let result = SearchResult(
            symbol: item.symbol,
            name: item.name,
            tag: item.tags,
            marketCap: data?.marketCap,
            peRatio: data?.peRatio != nil ? String(format: "%.2f", data!.peRatio!) : "--",
            pb: data?.pb != nil ? String(format: "%.2f", data!.pb!) : "--",
            compare: viewModel.dataService.compareData[item.symbol.uppercased()]
        )
        
        PointsCoordinator.shared.attempt(action: .viewChart, itemKey: item.symbol,
            displayName: "查看 \(item.symbol) 图表", authManager: authManager) {
            FinanceAnalytics.shared.track(cardKey: "搜索联想", cardName: item.symbol, authManager: authManager)
            self.openResult(result)
        }
    }
    
    private func checkForClipboard() {
        if let content = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            clipboardContent = content
            withAnimation { showClipboardBar = true }
        }
    }
    
    // MARK: - 完整搜索结果列表
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
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleResultSelection(result: result)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func handleResultSelection(result: SearchResult) {
        PointsCoordinator.shared.attempt(action: .viewChart, itemKey: result.symbol,
            displayName: "查看 \(result.symbol) 图表", authManager: authManager) {
            self.openResult(result)
        }
    }

    // 真正的打开逻辑（不扣点）
    private func openResult(_ result: SearchResult) {
        ReviewManager.shared.recordInteraction()
        if let groupName = viewModel.dataService.getCategory(for: result.symbol) {
            Task {
                let data = await DatabaseManager.shared.fetchHistoricalData(
                    symbol: result.symbol,
                    tableName: groupName,
                    dateRange: .timeRange(.oneMonth)
                )
                await MainActor.run {
                    if data.isEmpty {
                        if getDescriptions(for: result.symbol) != nil {
                            selectedSymbolForDescription = SelectedSymbol(result: result, category: "Description")
                        }
                    } else {
                        selectedSymbolForChart = SelectedSymbol(result: result, category: groupName)
                        showChartView = true
                    }
                }
            }
        } else {
            if getDescriptions(for: result.symbol) != nil {
                selectedSymbolForDescription = SelectedSymbol(result: result, category: "Description")
            }
        }
    }

    private func getDescriptions(for symbol: String) -> (String, String)? {
        if let stock = viewModel.dataService.descriptionData?.stocks.first(where: {
            $0.symbol.uppercased() == symbol.uppercased()
        }) {
            return (stock.description1, stock.description2)
        }
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
        
        // 【新增】输入即为完整代码时，直接开图（避免"搜索 + 图表"重复扣点）
        if enableExactSymbolShortcut,
           let exact = viewModel.exactSymbolSuggestion(for: trimmed) {
            handleSuggestionTap(exact)
            return
        }

        if PointsCoordinator.shared.isFree(action: .search, itemKey: trimmed, authManager: authManager) {
            executeSearch(trimmed, shouldDeduct: false)
            return
        }

        let cost = usageManager.cost(for: .search, itemKey: nil)
        if !usageManager.hasEnough(cost) {
            PointsCoordinator.shared.authManagerRef = authManager
            PointsCoordinator.shared.presentInsufficient(cost: cost)
            return
        }

        PointsCoordinator.shared.presentConfirm(cost: cost, title: "搜索 \"\(trimmed)\"") {
            self.executeSearch(trimmed, shouldDeduct: true)
        }
    }

    private func executeSearch(_ trimmed: String, shouldDeduct: Bool) {
        isSearchFieldFocused = false
        isLoading = true
        showSearchHistory = false
        showSuggestions = false
        hasSearched = true

        viewModel.performSearch(query: trimmed) { groupedResults in
            DispatchQueue.main.async {
                if shouldDeduct && !groupedResults.isEmpty {
                    self.usageManager.commitDeduction(action: .search, itemKey: trimmed)
                }

                withAnimation {
                    self.groupedSearchResults = groupedResults
                    self.isLoading = false
                    for group in groupedResults {
                        if self.collapsedGroups[group.category] == nil {
                            self.collapsedGroups[group.category] = false
                        }
                    }
                }

                if let firstGroup = groupedResults.first,
                   let firstEntry = firstGroup.results.first,
                   trimmed.uppercased() == firstEntry.result.symbol.uppercased() {
                    self.openResult(firstEntry.result)
                    return
                }
            }
        }
    }
}

// MARK: - 【新增】联想结果行
struct SuggestionRow: View {
    let suggestion: SearchSuggestion
    let query: String
    let onTap: () -> Void
    let onFill: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            // 类型徽章
            Text(suggestion.isETF ? "ETF" : "股")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 20)
                .background(suggestion.isETF ? Color.teal : Color.blue.opacity(0.85))
                .cornerRadius(5)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    highlighted(suggestion.symbol, query: query)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    
                    highlighted(suggestion.name, query: query)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                if let tag = suggestion.matchedTag, !tag.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange.opacity(0.8))
                        highlighted(tag, query: query)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else if !suggestion.tags.isEmpty {
                    Text(suggestion.tags.prefix(3).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 6)
            
            if let cap = suggestion.marketCapText {
                Text(cap)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
            }
            
            Button(action: onFill) {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
    
    /// 命中片段高亮
    private func highlighted(_ source: String, query: String) -> Text {
        guard !query.isEmpty,
              let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(source)
        }
        let pre = String(source[source.startIndex..<range.lowerBound])
        let mid = String(source[range])
        let post = String(source[range.upperBound...])
        return Text(pre)
            + Text(mid).foregroundColor(.blue).fontWeight(.heavy)
            + Text(post)
    }
}

// MARK: - 全局函数
private func parseMarketCap(_ text: String?) -> Double {
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return 0 }
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
                        Text(result.symbol)
                            .foregroundColor(colorForEarningTrend(result.earningTrend))
                            .fontWeight(.bold)
                        Text(result.name)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.headline)
                    Text(result.tag.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
    
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp:    return .red
        case .negativeAndUp:    return .purple
        case .positiveAndDown:  return .cyan
        case .negativeAndDown:  return .green
        case .insufficientData: return .primary
        }
    }
    
    private func colorForCompareValue(_ value: String) -> Color {
        if value.contains("前") || value.contains("后") || value.contains("未") {
            return .orange
        } else {
            return .secondary
        }
    }
}

// MARK: - 搜索历史视图
struct SearchHistoryView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onSelect: (String) -> Void
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.searchHistory.isEmpty {
                    HStack {
                        Spacer()
                        Text("暂无搜索历史")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                        Spacer()
                    }
                } else {
                    HStack {
                        Text("最近搜索")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.searchHistory.enumerated()), id: \.element) { index, term in
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 14))
                                Text(term)
                                    .foregroundColor(.primary)
                                Spacer()
                                Button(action: {
                                    withAnimation {
                                        viewModel.removeSearchHistory(term: term)
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .foregroundColor(.gray.opacity(0.5))
                                        .font(.system(size: 12))
                                        .padding(8)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(term)
                            }
                            
                            if index < viewModel.searchHistory.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}

// MARK: - ViewModel
class SearchViewModel: ObservableObject {
    @Published var searchHistory: [String] = []
    @Published var errorMessage: String? = nil
    @Published var isChartLoading: Bool = false
    @Published var groupedSearchResults: [GroupedSearchResults] = []
    
    // 【新增】联想相关
    @Published var suggestions: [SearchSuggestion] = []
    /// 用于 UI 高亮的 token（取输入的第一个词）
    @Published var activeHighlightToken: String = ""
    
    var dataService: DataService
    private var cancellables = Set<AnyCancellable>()
    
    private let querySubject = PassthroughSubject<String, Never>()
    private var lastQuery: String = ""
    private var suggestionToken: Int = 0
    private var marketCapSnapshot: [String: Double] = [:]
    
    /// 联想最大条数
    private let suggestionLimit = 12
    
    init(dataService: DataService = DataService.shared) {
        self.dataService = dataService
        
        dataService.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
        
        // 数据到位 → 构建索引
        dataService.$descriptionData
            .receive(on: DispatchQueue.main)
            .sink { data in
                SearchIndexStore.shared.buildIfNeeded(from: data)
            }
            .store(in: &cancellables)
        
        // 市值快照（用于联想排序与展示，避免后台线程读 @Published）
        dataService.$marketCapData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dict in
                self?.marketCapSnapshot = dict.mapValues { $0.rawMarketCap }
                self?.recomputeSuggestions()
            }
            .store(in: &cancellables)
        
        // 索引构建完成 → 重算当前输入
        SearchIndexStore.shared.didBuild
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeSuggestions()
            }
            .store(in: &cancellables)
        
        // 输入防抖
        querySubject
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] q in
                self?.computeSuggestions(for: q)
            }
            .store(in: &cancellables)
        
        loadSearchHistory()
    }
    
    // MARK: - 【新增】联想入口
    
    func prepareIndex() {
        SearchIndexStore.shared.buildIfNeeded(from: dataService.descriptionData)
        if marketCapSnapshot.isEmpty {
            marketCapSnapshot = dataService.marketCapData.mapValues { $0.rawMarketCap }
        }
    }
    
    /// View 每次输入变化调用
    func queryChanged(_ text: String) {
        lastQuery = text
        let firstToken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        if activeHighlightToken != firstToken {
            activeHighlightToken = firstToken
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestions = []
        }
        querySubject.send(text)
    }
    
    private func recomputeSuggestions() {
        guard !lastQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        computeSuggestions(for: lastQuery)
    }
    
    private func computeSuggestions(for rawQuery: String) {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            self.suggestions = []
            return
        }
        
        let entries = SearchIndexStore.shared.snapshot()
        guard !entries.isEmpty else {
            // 索引还没建好，先尝试触发构建，didBuild 回来后会自动重算
            SearchIndexStore.shared.buildIfNeeded(from: dataService.descriptionData)
            return
        }
        
        let caps = marketCapSnapshot
        let limit = suggestionLimit
        suggestionToken &+= 1
        let token = suggestionToken
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SearchIndexStore.computeSuggestions(
                query: q, entries: entries, marketCaps: caps, limit: limit
            )
            DispatchQueue.main.async {
                guard let self = self, self.suggestionToken == token else { return }
                self.suggestions = result
            }
        }
    }
    
    /// 输入是否恰好等于某个 symbol（用于回车直达）
    func exactSymbolSuggestion(for query: String) -> SearchSuggestion? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let hit = suggestions.first(where: { $0.symbol.lowercased() == q }) {
            return hit
        }
        // 联想还没算完时，直接扫索引兜底
        let entries = SearchIndexStore.shared.snapshot()
        guard let e = entries.first(where: { $0.lowerSymbol == q }) else { return nil }
        let cap = marketCapSnapshot[e.symbol.uppercased()] ?? 0
        return SearchSuggestion(symbol: e.symbol, name: e.name, tags: e.tags, isETF: e.isETF,
                                score: 1000, field: .symbol, matchedTag: nil,
                                marketCapText: SearchIndexStore.formatCap(cap), rawMarketCap: cap)
    }
    
    // MARK: - 完整搜索（原逻辑保持不变）
    
    private func analyzeQueryConstraints(query: String) -> (skipDescription: Bool, forceExactMatch: Bool, allowFuzzy: Bool) {
        let length = query.count
        if length == 0 { return (false, false, true) }
        
        if query.range(of: "\\p{Han}", options: .regularExpression) != nil {
            if length >= 3 { return (false, false, true) }
            if length == 2 { return (true, false, false) }
            return (true, true, false)
        }
        
        if query.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            if length >= 3 { return (false, false, true) }
            if length == 2 { return (true, false, true) }
            return (true, true, false)
        }
        
        if length >= 4 { return (false, false, true) }
        if length == 3 { return (true, false, true) }
        return (true, true, false)
    }
    
    func performSearch(query: String, completion: @escaping ([GroupedSearchResults]) -> Void) {
        let constraints = analyzeQueryConstraints(query: query)
        let keywords = query.lowercased().split(separator: " ").map { String($0) }
        
        Task {
            guard let descriptionData = self.dataService.descriptionData else {
                await MainActor.run { completion([]) }
                return
            }
            
            var groupedResults: [(group: GroupedSearchResults, matchScore: Int, priority: Int)] = []
            var categories: [MatchCategory] = [.stockSymbol, .etfSymbol, .stockName, .etfName, .stockTag, .etfTag, .stockDescription, .etfDescription]
            
            if constraints.skipDescription {
                categories.removeAll { $0 == .stockDescription || $0 == .etfDescription }
            }
            
            for category in categories {
                var matches: [(result: SearchResult, score: Int)] = []
                
                switch category {
                case .stockSymbol, .stockName, .stockDescription, .stockTag:
                    matches = self.searchCategory(items: descriptionData.stocks,
                                                  keywords: keywords,
                                                  category: category,
                                                  forceExactMatch: constraints.forceExactMatch,
                                                  allowFuzzy: constraints.allowFuzzy)
                case .etfSymbol, .etfName, .etfDescription, .etfTag:
                    matches = self.searchCategory(items: descriptionData.etfs,
                                                  keywords: keywords,
                                                  category: category,
                                                  forceExactMatch: constraints.forceExactMatch,
                                                  allowFuzzy: constraints.allowFuzzy)
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
            
            await MainActor.run {
                if !keywords.isEmpty { self.addSearchHistory(term: query) }
                self.groupedSearchResults = sortedGroups
            }
            
            await self.fetchLatestVolumes(for: sortedGroups)
            await self.fetchEarningTrends(for: sortedGroups)
            
            await MainActor.run {
                completion(sortedGroups)
            }
        }
    }
    
    private func fetchEarningTrends(for groupedResults: [GroupedSearchResults]) async {
        await withTaskGroup(of: Void.self) { group in
            for groupedResult in groupedResults {
                for entry in groupedResult.results {
                    group.addTask {
                        let symbol = entry.result.symbol
                        let trend = await self.calculateTrend(for: symbol)
                        await MainActor.run {
                            entry.result.earningTrend = trend
                        }
                    }
                }
            }
        }
    }
    
    private func calculateTrend(for symbol: String) async -> EarningTrend {
        let sortedEarnings = await DatabaseManager.shared.fetchEarningData(forSymbol: symbol).sorted { $0.date > $1.date }
        
        if sortedEarnings.count >= 2 {
            let latestEarning = sortedEarnings[0]
            let previousEarning = sortedEarnings[1]
            
            if let tableName = self.dataService.getCategory(for: symbol) {
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

    func searchCategory<T: SearchDescribableItem>(items: [T],
                                                  keywords: [String],
                                                  category: MatchCategory,
                                                  forceExactMatch: Bool,
                                                  allowFuzzy: Bool)
    -> [(result: SearchResult, score: Int)] {
        var scoredResults: [(SearchResult, Int)] = []
        
        for item in items {
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
                    pb: pbStr,
                    compare: dataService.compareData[upperSymbol]
                )
                
                scoredResults.append((result, totalScore))
            }
        }
        
       return scoredResults.sorted { lhs, rhs in
           if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
           let lmc = parseMarketCap(lhs.0.marketCap)
           let rmc = parseMarketCap(rhs.0.marketCap)
           return lmc > rmc
       }
    }
    
    private func matchScoreForItem<T: SearchDescribableItem>(
        _ item: T,
        category: MatchCategory,
        keywords: [String],
        forceExactMatch: Bool,
        allowFuzzy: Bool) -> Int? {
        
        var totalScore = 0
        
        for keyword in keywords {
            let lowerKeyword = keyword.lowercased()
            let singleScore = scoreOfSingleMatch(item: item, keyword: lowerKeyword, category: category, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
            if singleScore <= 0 {
                return nil
            } else {
                totalScore += singleScore
            }
        }
        return totalScore
    }
    
    private func scoreOfSingleMatch<T: SearchDescribableItem>(
        item: T,
        keyword: String,
        category: MatchCategory,
        forceExactMatch: Bool,
        allowFuzzy: Bool) -> Int {
        
        switch category {
        case .stockSymbol, .etfSymbol:
            return matchSymbol(item.symbol.lowercased(), keyword: keyword, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
        case .stockName, .etfName:
            return matchName(item.name, keyword: keyword, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
        case .stockTag, .etfTag:
            return matchTags(item.tag, keyword: keyword, forceExactMatch: forceExactMatch, allowFuzzy: allowFuzzy)
        case .stockDescription, .etfDescription:
            return matchDescriptions(item.description1, item.description2, keyword: keyword)
        }
    }
    
    private func matchSymbol(_ symbol: String, keyword: String, forceExactMatch: Bool, allowFuzzy: Bool) -> Int {
        if symbol == keyword { return 3 }
        if forceExactMatch { return 0 }
        if symbol.contains(keyword) {
            return 2
        } else if allowFuzzy && isFuzzyMatch(text: symbol, keyword: keyword, maxDistance: 1) {
            return 1
        }
        return 0
    }
    
    private func matchName(_ name: String, keyword: String, forceExactMatch: Bool, allowFuzzy: Bool) -> Int {
        let lowercasedName = name.lowercased()
        if lowercasedName == keyword { return 4 }
        if forceExactMatch { return 0 }
        
        let nameComponents = lowercasedName.components(separatedBy: ",")
        let mainName = nameComponents.first ?? lowercasedName
        let nameWords = mainName.split(separator: " ").map { String($0) }
        
        if nameWords.contains(keyword) || mainName == keyword {
            return 3
        } else if mainName.contains(keyword) {
            return 2
        } else if lowercasedName.contains(keyword) {
            return 1
        } else if allowFuzzy && isFuzzyMatch(text: lowercasedName, keyword: keyword, maxDistance: 1) {
            return 1
        }
        return 0
    }
    
    private func matchTags(_ tags: [String], keyword: String, forceExactMatch: Bool, allowFuzzy: Bool) -> Int {
        var maxScore = 0
        for t in tags {
            let lowerTag = t.lowercased()
            var score = 0
            
            if lowerTag == keyword {
                score = 3
            } else if !forceExactMatch {
                if lowerTag.contains(keyword) {
                    score = 2
                } else if allowFuzzy && isFuzzyMatch(text: lowerTag, keyword: keyword, maxDistance: 1) {
                    score = 1
                }
            }
            maxScore = max(maxScore, score)
        }
        return maxScore
    }
    
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