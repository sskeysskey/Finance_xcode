// VideoFilterView、VideoSearchTabView
// 分类检索 + 搜索

import SwiftUI

// MARK: - 筛选选项模型 & 字段枚举（文件私有）
private struct FilterOption: Identifiable {
    let value: String   // 内部值："All" / 大类key / 年份 / 地区 / 排序rawValue
    let label: String   // 显示文字
    var id: String { value }
}

private enum FilterField: Int, Identifiable {
    case category, type, year, region, sort
    var id: Int { rawValue }
}

// MARK: - 分类检索页（底部操作条 + 弹出式选择）
struct VideoFilterView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    // 筛选状态
    @State private var selectedCategory: String? = nil   // 大类: Movie/Drama/Show/Anime
    @State private var selectedType: String? = nil        // 子类(原"类型")
    @State private var selectedYear: Int? = nil
    @State private var selectedRegion: String? = nil
    // --- 新增：排序状态，默认按时间 ---
    @State private var selectedSort: VideoSortOption = .update
    
    // ⭐ 新增：预计算的筛选选项 + 就绪标志
    @State private var isReady = false
    @State private var allTypes: [String] = []
    @State private var allYears: [Int] = []
    @State private var allRegions: [String] = []
    
    // 当前弹出的面板
    @State private var activeSheet: FilterField? = nil
    // 虚拟大类 key（不与任何 JSON 顶层 key 冲突）
    private let documentaryCategoryKey = "Documentary"
    private let typeOrder = ["科幻", "喜剧", "情色", "爱情", "恐怖", "惊悚", "动作", "冒险", "战争", "体育片", "传记", "历史", "女性", "家庭", "灾难", "古装", "文艺", "校园", "百合", "美食", "西部"]
    private let regionOrder = ["美国", "韩国", "欧洲", "日本", "亚洲", "中国", "香港澳门", "中国台湾", "印度", "中东", "北美洲/南美洲", "非洲"]
    
    // 大类原始 key 列表（顺序与后端一致）
    private var allCategories: [String] {
        dataManager.categories.map { $0.name } + [documentaryCategoryKey]
    }
    
    // 大类中文名
    private func categoryDisplayName(_ key: String) -> String {
        if isGlobalEnglishMode { return key }
        switch key {
        case "Movie": return "电影"
        case "Drama": return "电视剧"
        case "Show":  return "综艺"
        case "Anime": return "动漫"
        case "Documentary": return "纪录片"   // ← 新增
        default:      return key
        }
    }
    
    // 选了大类 → 只在该大类内取；否则取全部
    private var baseItems: [OVideoItem] {
        if let cat = selectedCategory {
            if cat == documentaryCategoryKey {
                // 跨全部分组，取类型含"纪录片"的条目
                return dataManager.allItems.filter { $0.normalizedTypes.contains("纪录片") }
            }
            return dataManager.categories.first { $0.name == cat }?.items ?? []
        }
        return dataManager.allItems
    }

    // 过滤逻辑 + 排序逻辑（仍按需计算，仅在已就绪时使用）
    private var filteredItems: [OVideoItem] {
        let filtered = baseItems.filter { item in   // ← 改这里
            if let t = selectedType, !item.normalizedTypes.contains(t) { return false }
            if let y = selectedYear, item.releaseYear != y { return false }
            if let r = selectedRegion, item.normalizedRegion != r { return false }
            return true
        }
        return dataManager.sortItems(filtered, by: selectedSort)
    }
    
    private var hasActiveFilter: Bool {
        selectedCategory != nil || selectedType != nil || selectedYear != nil
            || selectedRegion != nil || selectedSort != .update
    }
    
    var body: some View {
        Group {
            if !isReady {
                // ⭐ 秒出的占位界面
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.1)
                    Text(isGlobalEnglishMode ? "Loading filters..." : "正在加载分类资源…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentView
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(isGlobalEnglishMode ? "Filter" : "分类检索")
        .navigationBarTitleDisplayMode(.inline)
        // MARK: 👉 重置按钮放到导航栏右侧（分类检索旁边）
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if hasActiveFilter {
                    Button {
                        withAnimation {
                            selectedCategory = nil
                            selectedType = nil
                            selectedYear = nil
                            selectedRegion = nil
                            selectedSort = .update
                        }
                    } label: {
                        Label(isGlobalEnglishMode ? "Reset" : "重置",
                              systemImage: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
        }
        .task { await prepareOptions() }
        // 弹出式选择面板
        .sheet(item: $activeSheet) { field in
            let cfg = optionConfig(for: field)
            FilterSheetView(
                title: cfg.title,
                options: cfg.options,
                selected: cfg.selected
            ) { value in
                apply(field, value: value)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
    
    // MARK: - 主内容：上方结果 + 底部操作条
    private var contentView: some View {
        VStack(spacing: 0) {
            // 👉 这里删除了原来的顶部重置按钮区域
            ScrollView {
                WaterfallGridView(items: filteredItems, dataManager: dataManager)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
        }
        // 底部固定操作条
        .safeAreaInset(edge: .bottom) {
            bottomFilterBar
        }
    }
    
    // MARK: - 底部操作条
    private var bottomFilterBar: some View {
        HStack(spacing: 6) {
            filterBarItem(field: .category,
                          label: selectedCategory.map(categoryDisplayName) ?? (isGlobalEnglishMode ? "Category" : "大类"),
                          isActive: selectedCategory != nil)
            filterBarItem(field: .type,
                          label: selectedType ?? (isGlobalEnglishMode ? "Genre" : "子类"),
                          isActive: selectedType != nil)
            filterBarItem(field: .year,
                          label: selectedYear.map(String.init) ?? (isGlobalEnglishMode ? "Year" : "年份"),
                          isActive: selectedYear != nil)
            filterBarItem(field: .region,
                          label: selectedRegion ?? (isGlobalEnglishMode ? "Region" : "地区"),
                          isActive: selectedRegion != nil)
            filterBarItem(field: .sort,
                          label: selectedSort.shortName(isGlobalEnglishMode),
                          isActive: selectedSort != .update)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.primary.opacity(0.0),
                                        Color.primary.opacity(0.15),
                                        Color.primary.opacity(0.0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }
    
    private func filterBarItem(field: FilterField, label: String, isActive: Bool) -> some View {
        Button {
            activeSheet = field
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 每个字段对应的选项配置
    private func optionConfig(for field: FilterField)
        -> (title: String, options: [FilterOption], selected: String) {
        let allLabel = isGlobalEnglishMode ? "All" : "全部"
        switch field {
        case .category:
            var opts = [FilterOption(value: "All", label: allLabel)]
            opts += allCategories.map { FilterOption(value: $0, label: categoryDisplayName($0)) }
            return (isGlobalEnglishMode ? "Category" : "大类", opts, selectedCategory ?? "All")
        case .type:
            var opts = [FilterOption(value: "All", label: allLabel)]
            opts += allTypes.map { FilterOption(value: $0, label: $0) }
            return (isGlobalEnglishMode ? "Genre" : "子类", opts, selectedType ?? "All")
        case .year:
            var opts = [FilterOption(value: "All", label: allLabel)]
            opts += allYears.map { FilterOption(value: String($0), label: String($0)) }
            return (isGlobalEnglishMode ? "Year" : "年份", opts, selectedYear.map(String.init) ?? "All")
        case .region:
            var opts = [FilterOption(value: "All", label: allLabel)]
            opts += allRegions.map { FilterOption(value: $0, label: $0) }
            return (isGlobalEnglishMode ? "Region" : "地区", opts, selectedRegion ?? "All")
        case .sort:
            let opts = VideoSortOption.allCases.map {
                FilterOption(value: $0.rawValue, label: $0.displayName(isGlobalEnglishMode))
            }
            return (isGlobalEnglishMode ? "Sort" : "排序", opts, selectedSort.rawValue)
        }
    }
    
    private func apply(_ field: FilterField, value: String) {
        withAnimation {
            switch field {
            case .category: selectedCategory = (value == "All") ? nil : value
            case .type:     selectedType = (value == "All") ? nil : value
            case .year:     selectedYear = (value == "All") ? nil : Int(value)
            case .region:   selectedRegion = (value == "All") ? nil : value
            case .sort:     selectedSort = VideoSortOption(rawValue: value) ?? .update
            }
        }
    }
    
    // MARK: - 后台计算选项
    private func prepareOptions() async {
        if isReady { return }
        await Task.yield()
        
        let items = dataManager.allItems
        let tOrder = typeOrder
        let rOrder = regionOrder
        
        // 计算（量大时也只在这里发生一次，且占位界面已显示，用户不会觉得没点中）
        let typeSet = Set(items.flatMap { $0.normalizedTypes }).subtracting(["纪录片"])
        let sortedTypes = typeSet.sorted { a, b in
            let ia = tOrder.firstIndex(of: a) ?? Int.max
            let ib = tOrder.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }
        
        let yearSet = Set(items.compactMap { $0.releaseYear })
        let sortedYears = yearSet.sorted(by: >)
        
        let regionSet = Set(items.map { $0.normalizedRegion }).filter { $0 != "其它" }
        let sortedRegions = regionSet.sorted { a, b in
            let ia = rOrder.firstIndex(of: a) ?? Int.max
            let ib = rOrder.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }
        
        self.allTypes = sortedTypes
        self.allYears = sortedYears
        self.allRegions = sortedRegions
        withAnimation(.easeInOut(duration: 0.2)) { self.isReady = true }
    }
}

// MARK: - 弹出选择面板（纵向滚动）
private struct FilterSheetView: View {
    let title: String
    let options: [FilterOption]
    let selected: String
    let onSelect: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 10)]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            
            Divider()
            
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(options) { opt in
                        let isSel = opt.value == selected
                        Button {
                            onSelect(opt.value)
                            dismiss()
                        } label: {
                            Text(opt.label)
                                .font(.system(size: 14, weight: isSel ? .bold : .medium))
                                .foregroundColor(isSel ? .white : .primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    Capsule().fill(isSel ? Color.accentColor
                                                         : Color.secondary.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .presentationBackground(.regularMaterial)
    }
}

// MARK: - 搜索 Tab
struct VideoSearchTabView: View {
    @ObservedObject var dataManager: OVideoDataManager
    let initialKeyword: String?          // 新增：外部传入的初始关键词
    let autoFocus: Bool                  // 新增：是否自动聚焦键盘
    @StateObject private var historyManager = SearchHistoryManager()
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var keyword: String = ""
    @FocusState private var focused: Bool
    
    // ⭐ 改为 State
    @State private var results: [OVideoItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isFirstAppear = true
    
    // 新增：init 方便默认调用
    init(dataManager: OVideoDataManager, initialKeyword: String? = nil, autoFocus: Bool = true) {
        self.dataManager = dataManager
        self.initialKeyword = initialKeyword
        self.autoFocus = autoFocus
    }

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(isGlobalEnglishMode
                          ? "Search name / director / cast..."
                          : "搜索视频名称 / 导演 / 演员",
                          text: $keyword)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { commitSearch() }
                
                if !keyword.isEmpty {
                    // ⭐ 修改：点击清除按钮时，不仅清空内容，还强制重新聚焦（focused = true）
                    Button {
                        keyword = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            
            // 内容区
            if trimmedKeyword.isEmpty {
                if historyManager.histories.isEmpty {
                    hintView(icon: "magnifyingglass",
                             text: isGlobalEnglishMode ? "Type to search" : "输入关键词开始搜索")
                } else {
                    historyView
                }
            } else if isSearching && results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                hintView(icon: "tray",
                         text: isGlobalEnglishMode ? "No results" : "暂无搜索结果")
            } else {
                // ⭐ 修改：使用 scrollDismissesKeyboard 使得用户在滑动结果列表时，键盘自动收起
                ScrollView {
                    WaterfallGridView(items: results, dataManager: dataManager)
                        .padding(.top, 10)
                        .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.immediately) // iOS 16+ 滚动时立即收起键盘
                .background(Color(UIColor.systemGroupedBackground))
                .simultaneousGesture(
                    TapGesture().onEnded {
                        // 用户在结果区域里点了某一项 → 记录当前关键词并收起键盘
                        historyManager.add(trimmedKeyword)
                        focused = false // ⭐ 修改：点击结果项时，主动收起键盘
                    }
                )
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Search" : "搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if isFirstAppear {
                if autoFocus {
                    focused = true
                }
                isFirstAppear = false
            }
            // 新增：处理外部传入的初始关键词
            if let initial = initialKeyword, !initial.isEmpty, keyword.isEmpty {
                keyword = initial
                scheduleSearch(initial)
                historyManager.add(initial)
            }
        }
        // ⭐ 关键：监听 keyword，防抖 + 取消旧任务
        .onChange(of: keyword) { newValue in
            scheduleSearch(newValue)
        }
    }
    
    // ⭐ 防抖调度
    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let kw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            // 防抖 300ms
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            
            let res = await dataManager.searchAsync(keyword: kw)
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.results = res
                self.isSearching = false
            }
        }
    }
    
    private func commitSearch() {
        historyManager.add(trimmedKeyword)
        focused = false
    }
    
    // MARK: - 历史视图
    private var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isGlobalEnglishMode ? "Recent Searches" : "搜索历史")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        withAnimation { historyManager.clearAll() }
                    } label: {
                        Label(isGlobalEnglishMode ? "Clear" : "清空",
                              systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                FlowLayout(spacing: 8) {
                    ForEach(historyManager.histories, id: \.self) { kw in
                        historyChip(kw)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    private func historyChip(_ kw: String) -> some View {
        HStack(spacing: 4) {
            // 关键词主体（点击 = 重新搜索 + 置顶）
            Text(kw)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundColor(.primary)
                .padding(.leading, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture {
                    keyword = kw
                    historyManager.add(kw)   // 置顶
                    focused = false
                }
            
            // 单独的 ✕（点击 = 删除这一条）
            Button {
                withAnimation { historyManager.remove(kw) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
    
    private func hintView(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.5))
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 自适应换行布局（用于历史 chip）
// 需要 iOS 16+
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth,
                      height: totalHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}