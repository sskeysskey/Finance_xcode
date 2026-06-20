// VideoFilterView（服务端筛选分页）、VideoSearchTabView（服务端搜索）

import SwiftUI

private struct FilterOption: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}
private enum FilterField: Int, Identifiable {
    case category, type, year, region, sort
    var id: Int { rawValue }
}

// MARK: - 分类检索页
struct VideoFilterView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var selectedCategory: String? = nil
    @State private var selectedType: String? = nil
    @State private var selectedYear: Int? = nil
    @State private var selectedRegion: String? = nil
    @State private var selectedSort: VideoSortOption = .update

    @State private var isReady = false
    @State private var allTypes: [String] = []
    @State private var allYears: [Int] = []
    @State private var allRegions: [String] = []

    // 结果分页
    @State private var results: [OVideoItem] = []
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var page = 0
    // ⭐ 修复点：记录已加载的筛选条件签名，避免视图重新出现时被重复 reload 清空数据
    @State private var loadedSignature: String? = nil
    private let scrollTopID = "filter_scroll_top"

    @State private var activeSheet: FilterField? = nil
    private let documentaryCategoryKey = "Documentary"
    private let typeOrder = ["科幻","喜剧","爱情","恐怖","惊悚","动作","悬疑","犯罪","冒险","战争","情色","体育","传记","历史","女性","家庭","灾难","古装","文艺","校园","百合","美食","西部"]
    private let regionOrder = ["美国","韩国","欧洲","日本","亚洲","中国","香港澳门","中国台湾","印度","中东","北美洲/南美洲","非洲"]

    private var userId: String? { authManager.userIdentifier }

    private var allCategories: [String] {
        dataManager.categoryNames + [documentaryCategoryKey]
    }

    private func categoryDisplayName(_ key: String) -> String {
        if isGlobalEnglishMode { return key }
        switch key {
        case "Movie": return "电影"
        case "Drama": return "电视剧"
        case "Show":  return "综艺"
        case "Anime": return "动漫"
        case "Documentary": return "纪录片"
        default:      return key
        }
    }

    private var hasActiveFilter: Bool {
        selectedCategory != nil || selectedType != nil || selectedYear != nil
            || selectedRegion != nil || selectedSort != .update
    }

    private var filterSignature: String {
        "\(selectedCategory ?? "")|\(selectedType ?? "")|\(selectedYear.map(String.init) ?? "")|\(selectedRegion ?? "")|\(selectedSort.rawValue)"
    }

    var body: some View {
        Group {
            if !isReady {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.1)
                    Text(isGlobalEnglishMode ? "Loading filters..." : "正在加载分类资源…")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentView
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(isGlobalEnglishMode ? "Filter" : "分类检索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if hasActiveFilter {
                    Button {
                        withAnimation {
                            selectedCategory = nil; selectedType = nil
                            selectedYear = nil; selectedRegion = nil
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
        // ⭐ 修复点：isReady 或筛选条件变化都纳入 id；内部再用 loadedSignature 守卫，
        //    确保从详情页返回（视图重新出现）时不会重复 reload 清空已加载的数据。
        .task(id: "\(isReady)|\(filterSignature)") {
            guard isReady else { return }
            guard loadedSignature != filterSignature else { return }
            await reload()
        }
        .sheet(item: $activeSheet) { field in
            let cfg = optionConfig(for: field)
            FilterSheetView(title: cfg.title, options: cfg.options, selected: cfg.selected) { value in
                apply(field, value: value)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var contentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id(scrollTopID)

                if results.isEmpty && isLoading {
                    ProgressView().padding(.top, 80)
                } else {
                    WaterfallGridView(items: results, dataManager: dataManager, onReachEnd: {
                        Task { await loadMore() }
                    })
                    .padding(.top, 4)
                    if isLoading && !results.isEmpty {
                        ProgressView().padding(.vertical, 16)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .onChange(of: filterSignature) { _ in
                proxy.scrollTo(scrollTopID, anchor: .top)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomFilterBar }
    }

    // 重新加载第一页
    private func reload() async {
        loadedSignature = filterSignature      // ⭐ 标记当前签名已加载
        page = 0; hasMore = true; isLoading = true
        let r = await dataManager.fetchFilter(category: selectedCategory, type: selectedType,
                                              year: selectedYear, region: selectedRegion,
                                              sort: selectedSort, page: 0, userId: userId)
        results = r.items; hasMore = r.hasMore; page = 1; isLoading = false
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let r = await dataManager.fetchFilter(category: selectedCategory, type: selectedType,
                                              year: selectedYear, region: selectedRegion,
                                              sort: selectedSort, page: page, userId: userId)
        let existing = Set(results.map { $0.url })
        results.append(contentsOf: r.items.filter { !existing.contains($0.url) })
        hasMore = r.hasMore; page += 1; isLoading = false
    }

    // MARK: - ⭐ 改进后的底部筛选条
    private var bottomFilterBar: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
        .background(
            Rectangle().fill(Color(UIColor.systemBackground))
                .overlay(alignment: .top) {
                    Color.primary.opacity(0.15).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func filterBarItem(field: FilterField, label: String, isActive: Bool) -> some View {
        Button { activeSheet = field } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            // ⭐ 未激活也用 accent 色调，不再是灰色，整体更显眼
            .foregroundColor(isActive ? .white : .accentColor)
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isActive
                        ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                Color.accentColor.opacity(0.75)],
                                                       startPoint: .topLeading,
                                                       endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.accentColor.opacity(0.12))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(isActive ? 0 : 0.35), lineWidth: 1)
            )
            .shadow(color: isActive ? Color.accentColor.opacity(0.35) : .clear,
                    radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

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

    private func prepareOptions() async {
        if isReady { return }
        if let opts = await dataManager.fetchFilterOptions(userId: userId) {
            let tOrder = typeOrder, rOrder = regionOrder
            self.allTypes = opts.types.sorted { a, b in
                let ia = tOrder.firstIndex(of: a) ?? Int.max
                let ib = tOrder.firstIndex(of: b) ?? Int.max
                if ia != ib { return ia < ib }
                return a < b
            }
            self.allYears = opts.years.sorted(by: >)
            self.allRegions = opts.regions.sorted { a, b in
                let ia = rOrder.firstIndex(of: a) ?? Int.max
                let ib = rOrder.firstIndex(of: b) ?? Int.max
                if ia != ib { return ia < ib }
                return a < b
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) { self.isReady = true }
    }
}

// MARK: - 弹出选择面板（不变）
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
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(options) { opt in
                        let isSel = opt.value == selected
                        Button { onSelect(opt.value); dismiss() } label: {
                            Text(opt.label)
                                .font(.system(size: 14, weight: isSel ? .bold : .medium))
                                .foregroundColor(isSel ? .white : .primary)
                                .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Capsule().fill(isSel ? Color.accentColor : Color.secondary.opacity(0.12)))
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

// MARK: - 搜索 Tab（服务端搜索）⭐ 新增：无/少结果时的寻片提示
struct VideoSearchTabView: View {
    @ObservedObject var dataManager: OVideoDataManager
    let initialKeyword: String?
    let autoFocus: Bool
    @StateObject private var historyManager = SearchHistoryManager()
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @State private var keyword: String = ""
    @FocusState private var focused: Bool
    @State private var results: [OVideoItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isFirstAppear = true

    // ⭐ 新增：寻片相关
    @State private var showWishSheet = false

    private var userId: String? { authManager.userIdentifier }
    private var userType: String {
        guard let uid = userId, !uid.isEmpty else { return "device" }
        return (uid.hasPrefix("dev_") || uid == "guest_user") ? "device" : "apple"
    }

    init(dataManager: OVideoDataManager, initialKeyword: String? = nil, autoFocus: Bool = true) {
        self.dataManager = dataManager
        self.initialKeyword = initialKeyword
        self.autoFocus = autoFocus
    }

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            // ⭐ 整体柔和渐变背景
            LinearGradient(
                colors: [Color(UIColor.systemGroupedBackground),
                         Color.accentColor.opacity(0.06)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                contentArea
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Search" : "搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if isFirstAppear {
                if autoFocus { focused = true }
                isFirstAppear = false
            }
            if let initial = initialKeyword, !initial.isEmpty, keyword.isEmpty {
                keyword = initial
                scheduleSearch(initial)
                historyManager.add(initial)
            }
        }
        .onChange(of: keyword) { newValue in scheduleSearch(newValue) }
        // ⭐ 寻片提交弹窗
        .sheet(isPresented: $showWishSheet) {
            WishSubmitSheet(initialContent: trimmedKeyword,
                            keyword: trimmedKeyword,
                            userId: userId,
                            userType: userType,
                            isPresented: $showWishSheet)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - ⭐ 精致搜索框
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(focused ? .accentColor : .secondary)

            TextField(isGlobalEnglishMode ? "Search name / director / cast..." : "搜索视频名称 / 导演 / 演员",
                      text: $keyword)
                .font(.system(size: 16))
                .focused($focused).submitLabel(.search).autocorrectionDisabled()
                .onSubmit { commitSearch() }

            if !keyword.isEmpty {
                Button { keyword = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    focused
                    ? LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
                                     startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.secondary.opacity(0.15), Color.secondary.opacity(0.15)],
                                     startPoint: .leading, endPoint: .trailing),
                    lineWidth: focused ? 1.6 : 1
                )
        )
        .shadow(color: focused ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.05),
                radius: focused ? 10 : 4, x: 0, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.22), value: focused)
        .animation(.easeInOut(duration: 0.18), value: keyword.isEmpty)
    }

    // MARK: - 内容区
    @ViewBuilder
    private var contentArea: some View {
        if trimmedKeyword.isEmpty {
            if historyManager.histories.isEmpty {
                hintView(icon: "magnifyingglass",
                         text: isGlobalEnglishMode ? "Type to search" : "输入关键词开始搜索")
            } else {
                historyView
            }
        } else if isSearching && results.isEmpty {
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.2)
                Text(isGlobalEnglishMode ? "Searching..." : "正在搜索…")
                    .font(.system(size: 14)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            // ⭐ 结果为空：整屏醒目寻片提示
            emptyWishView
        } else {
            ScrollView {
                // ⭐ 结果数量提示条 + 常驻寻片求助
                HStack {
                    Text(isGlobalEnglishMode
                         ? "\(results.count) results"
                         : "找到 \(results.count) 个结果")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button { focused = false; showWishSheet = true } label: {
                        shortWishPromptText
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)

                WaterfallGridView(items: results, dataManager: dataManager)
                    .padding(.top, 8)

                Color.clear.frame(height: 20)
            }
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(TapGesture().onEnded {
                historyManager.add(trimmedKeyword); focused = false
            })
        }
    }

    // MARK: - ⭐ 寻片提示文案（“这里”放大可点）
    private var wishPromptText: Text {
        if isGlobalEnglishMode {
            return Text("Didn't find it? Tap ")
                    .font(.system(size: 15)).foregroundColor(.secondary)
                + Text("HERE")
                    .font(.system(size: 19, weight: .heavy)).foregroundColor(.orange) // 改为橙色
                + Text(" to submit — we'll do our best to find it")
                    .font(.system(size: 15)).foregroundColor(.secondary)
        } else {
            return Text("没有找到你想要的内容？点击")
                    .font(.system(size: 15)).foregroundColor(.secondary)
                + Text("这里")
                    .font(.system(size: 21, weight: .heavy)).foregroundColor(.orange) // 改为橙色
                + Text("提交，我们会全力为你寻找")
                    .font(.system(size: 15)).foregroundColor(.secondary)
        }
    }

    // MARK: - ⭐ 简短寻片提示（常驻于结果计数右侧）
    private var shortWishPromptText: Text {
        if isGlobalEnglishMode {
            return Text("Not found? Tap ")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                + Text("HERE")
                    .font(.system(size: 15, weight: .heavy)).foregroundColor(.orange)
                + Text(" for help")
                    .font(.system(size: 13)).foregroundColor(.secondary)
        } else {
            return Text("没找到你想要的内容？点击")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                + Text("这里")
                    .font(.system(size: 15, weight: .heavy)).foregroundColor(.orange)
                + Text("求助")
                    .font(.system(size: 13)).foregroundColor(.secondary)
        }
    }

    // 整屏（空结果）
    private var emptyWishView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18),
                                                  Color.accentColor.opacity(0.04)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.accentColor.opacity(0.75))
            }
            Text(isGlobalEnglishMode ? "No results" : "暂无搜索结果")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            Button { focused = false; showWishSheet = true } label: {
                wishPromptText
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let kw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { results = []; isSearching = false; return }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let res = await dataManager.search(keyword: kw, userId: userId)
            if Task.isCancelled { return }
            await MainActor.run { self.results = res; self.isSearching = false }
        }
    }

    private func commitSearch() { historyManager.add(trimmedKeyword); focused = false }

    // MARK: - ⭐ 搜索历史
    private var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text(isGlobalEnglishMode ? "Recent Searches" : "搜索历史")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    Button { withAnimation { historyManager.clearAll() } } label: {
                        Label(isGlobalEnglishMode ? "Clear" : "清空", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 18)

                FlowLayout(spacing: 10) {
                    ForEach(historyManager.histories, id: \.self) { kw in historyChip(kw) }
                }
                .padding(.horizontal, 18).padding(.bottom, 20)
            }
        }
    }

    private func historyChip(_ kw: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.accentColor.opacity(0.8))
                .padding(.leading, 12)
            Text(kw).font(.system(size: 13, weight: .medium))
                .lineLimit(1).foregroundColor(.primary)
                .padding(.vertical, 8).contentShape(Rectangle())
                .onTapGesture { keyword = kw; historyManager.add(kw); focused = false }
            Button { withAnimation { historyManager.remove(kw) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary).padding(7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.trailing, 3)
        }
        .background(
            Capsule().fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            Capsule().stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
    }

    // MARK: - ⭐ 空状态提示
    private func hintView(icon: String, text: String) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18),
                                                  Color.accentColor.opacity(0.04)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.accentColor.opacity(0.75))
            }
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ⭐ 寻片提交弹窗
private struct WishSubmitSheet: View {
    let initialContent: String
    let keyword: String
    let userId: String?
    let userType: String
    @Binding var isPresented: Bool

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var content: String = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMsg: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Text(isGlobalEnglishMode ? "Request a title" : "告诉我们你想看什么")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            Divider()

            if submitted {
                successView
            } else {
                inputView
            }
        }
        .presentationBackground(.regularMaterial)
        .onAppear { content = initialContent }
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isGlobalEnglishMode
                 ? "Enter the title / show name. We'll do our best to find it for you."
                 : "输入你想看的剧集 / 电影名称，我们会全力为你寻找。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            TextField(isGlobalEnglishMode ? "e.g. The Movie Name" : "例如：想看的剧集名称",
                      text: $content)
                .font(.system(size: 16))
                .focused($focused)
                .submitLabel(.done)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )

            if let err = errorMsg {
                Text(err).font(.system(size: 13)).foregroundColor(.red)
            }

            Button { Task { await submit() } } label: {
                HStack {
                    if isSubmitting { ProgressView().tint(.white) }
                    Text(isGlobalEnglishMode ? "Submit" : "提交")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(content.trimmingCharacters(in: .whitespaces).isEmpty
                              ? AnyShapeStyle(Color.secondary.opacity(0.4))
                              : AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                      Color.accentColor.opacity(0.8)],
                                                             startPoint: .leading, endPoint: .trailing)))
                )
            }
            .disabled(isSubmitting || content.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var successView: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundColor(.green)
            Text(isGlobalEnglishMode ? "Submitted!" : "提交成功！")
                .font(.system(size: 18, weight: .bold))
            Text(isGlobalEnglishMode
                 ? "Thanks! We'll do our best to find it for you."
                 : "感谢反馈，我们会尽快为你寻找。")
                .font(.system(size: 14)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { isPresented = false }
        }
    }

    private func submit() async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focused = false
        isSubmitting = true
        errorMsg = nil
        do {
            try await OVideoAPI.submitWish(content: text, keyword: keyword,
                                           userId: userId, userType: userType)
            withAnimation { submitted = true }
        } catch {
            errorMsg = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - 自适应换行布局（不变）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}