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
    
    // --- 定义自定义排序规则 ---
    private let typeOrder = ["综艺", "动漫", "剧情", "动作", "科幻", "喜剧", "爱情", "恐怖", "犯罪", "惊悚", "悬疑", "西部", "古装", "纪录"]
    private let regionOrder = ["美国", "韩国", "中国", "日本", "中国香港", "中国台湾", "欧洲", "亚洲", "中东", "北美洲/南美洲"]
    
    // --- 使用自定义排序逻辑 ---
    private var allTypes: [String] {
        let set = Set(dataManager.allItems.flatMap { $0.normalizedTypes })
        return set.sorted { (a, b) -> Bool in
            let indexA = typeOrder.firstIndex(of: a) ?? Int.max
            let indexB = typeOrder.firstIndex(of: b) ?? Int.max
            if indexA != indexB { return indexA < indexB }
            return a < b // 如果都在自定义列表中，按顺序；如果都不在，按字母排序
        }
    }
    
    private var allYears: [Int] {
        let set = Set(dataManager.allItems.compactMap { $0.releaseYear })
        return set.sorted(by: >)
    }
    
    private var allRegions: [String] {
        // 使用 normalizedRegion 进行去重和排序
        let set = Set(dataManager.allItems.map { $0.normalizedRegion }).filter { $0 != "其它" }
        return set.sorted { (a, b) -> Bool in
            let indexA = regionOrder.firstIndex(of: a) ?? Int.max
            let indexB = regionOrder.firstIndex(of: b) ?? Int.max
            if indexA != indexB { return indexA < indexB }
            return a < b
        }
    }
    
    // --- 修改：过滤逻辑 + 排序逻辑 ---
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
        VStack(spacing: 0) {
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
                    
                    // --- 新增：排序选择行 ---
                    sortRow()
                    
                    Divider().padding(.horizontal, 16)
                    
                    HStack {
                        Text(isGlobalEnglishMode
                             ? "\(filteredItems.count) result(s)"
                             : "共 \(filteredItems.count) 个结果")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        
                        // 修改：如果任意条件被修改过，显示重置按钮
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
                    
                    WaterfallGridView(items: filteredItems)
                        .padding(.top, 4)
                }
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(isGlobalEnglishMode ? "Filter" : "分类检索")
        .navigationBarTitleDisplayMode(.inline)
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
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var keyword: String = ""
    @FocusState private var focused: Bool
    
    private var results: [OVideoItem] { dataManager.search(keyword: keyword) }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(isGlobalEnglishMode
                          ? "Search name / director / cast..."
                          : "搜索视频名称 / 导演 / 演员",
                          text: $keyword)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
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
            
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintView(icon: "magnifyingglass",
                         text: isGlobalEnglishMode ? "Type to search" : "输入关键词开始搜索")
            } else if results.isEmpty {
                hintView(icon: "tray",
                         text: isGlobalEnglishMode ? "No results" : "暂无搜索结果")
            } else {
                ScrollView {
                    WaterfallGridView(items: results)
                        .padding(.top, 10)
                        .padding(.bottom, 20)
                }
                .background(Color(UIColor.systemGroupedBackground))
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Search" : "搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
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