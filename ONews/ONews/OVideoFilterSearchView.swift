// VideoFilterView、VideoSearchTabView
// 分类检索 + 搜索

import SwiftUI

// MARK: - 分类检索页
struct VideoFilterView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var selectedType: String? = nil
    @State private var selectedYear: Int? = nil
    @State private var selectedRegion: String? = nil
    // --- 新增：排序状态，默认按时间 ---
    @State private var selectedSort: VideoSortOption = .date
    
    // ⭐ 新增：预计算的筛选选项 + 就绪标志
    @State private var isReady = false
    @State private var allTypes: [String] = []
    @State private var allYears: [Int] = []
    @State private var allRegions: [String] = []
    
    private let typeOrder = ["纪录片", "动漫", "综艺", "科幻", "喜剧", "爱情", "恐怖", "惊悚", "古装", "剧情"]
    private let regionOrder = ["美国", "韩国", "中国", "欧洲", "日本", "亚洲", "香港澳门", "中国台湾", "印度", "中东", "北美洲/南美洲", "非洲"]
    
    // 过滤逻辑 + 排序逻辑（仍按需计算，仅在已就绪时使用）
    private var filteredItems: [OVideoItem] {
        let filtered = dataManager.allItems.filter { item in
            if let t = selectedType, !item.normalizedTypes.contains(t) { return false }
            if let y = selectedYear, item.releaseYear != y { return false }
            if let r = selectedRegion, item.normalizedRegion != r { return false }
            return true
        }
        // 应用排序
        return dataManager.sortItems(filtered, by: selectedSort)
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
        .task {
            await prepareOptions()
        }
    }
    
    // ⭐ 正式内容
    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterRow(title: isGlobalEnglishMode ? "Genre" : "类型",
                          options: ["All"] + allTypes,
                          selected: selectedType ?? "All") { v in
                    selectedType = (v == "All") ? nil : v
                }
                filterRow(title: isGlobalEnglishMode ? "Year" : "年份",
                          options: ["All"] + allYears.map { String($0) },
                          selected: selectedYear.map { String($0) } ?? "All") { v in
                    selectedYear = (v == "All") ? nil : Int(v)
                }
                filterRow(title: isGlobalEnglishMode ? "Region" : "地区",
                          options: ["All"] + allRegions,
                          selected: selectedRegion ?? "All") { v in
                    selectedRegion = (v == "All") ? nil : v
                }
                
                sortRow()
                
                Divider().padding(.horizontal, 16)
                
                HStack {
                    Text(isGlobalEnglishMode
                         ? "\(filteredItems.count) result(s)"
                         : "共 \(filteredItems.count) 个结果")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    
                    if selectedType != nil || selectedYear != nil || selectedRegion != nil || selectedSort != .date {
                        Button {
                            selectedType = nil
                            selectedYear = nil
                            selectedRegion = nil
                            selectedSort = .date
                        } label: {
                            Label(isGlobalEnglishMode ? "Reset" : "重置",
                                  systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                WaterfallGridView(items: filteredItems, dataManager: dataManager)
                    .padding(.top, 4)
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }
    
    // ⭐ 后台计算选项，算完才切换 isReady
    private func prepareOptions() async {
        if isReady { return }
        
        // 先让占位界面渲染出来（关键：把重计算让到下一帧之后）
        await Task.yield()
        
        let items = dataManager.allItems
        let tOrder = typeOrder
        let rOrder = regionOrder
        
        // 计算（量大时也只在这里发生一次，且占位界面已显示，用户不会觉得没点中）
        let typeSet = Set(items.flatMap { $0.normalizedTypes })
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
        withAnimation(.easeInOut(duration: 0.2)) {
            self.isReady = true
        }
    }
    
    private func filterRow(title: String, options: [String],
                           selected: String,
                           onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { opt in
                        let isSelected = opt == selected
                        Button {
                            onSelect(opt)
                        } label: {
                            Text(opt == "All" ? (isGlobalEnglishMode ? "All" : "全部") : opt)
                                .font(.system(size: 13,
                                              weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : .primary)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(
                                    Capsule().fill(isSelected
                                                   ? Color.accentColor
                                                   : Color.secondary.opacity(0.12))
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
    
    // --- 新增：单独的排序行视图 ---
    private func sortRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isGlobalEnglishMode ? "Sort" : "排序")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VideoSortOption.allCases, id: \.self) { opt in
                        let isSelected = opt == selectedSort
                        Button {
                            withAnimation {
                                selectedSort = opt
                            }
                        } label: {
                            Text(opt.displayName(isGlobalEnglishMode))
                                .font(.system(size: 13,
                                              weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : .primary)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(
                                    Capsule().fill(isSelected
                                                   ? Color.accentColor
                                                   : Color.secondary.opacity(0.12))
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
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