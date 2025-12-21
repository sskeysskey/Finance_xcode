import SwiftUI
import Combine

struct EarningReleaseView: View {
    @EnvironmentObject var dataService: DataService
    
    // 【新增】权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    // 【修改】移除 showLoginSheet
    @State private var showSubscriptionSheet = false
    
    // 【新增】导航控制
    @State private var selectedItem: EarningRelease?
    @State private var isNavigationActive = false

    struct TimingGroup: Identifiable {
        let id: String
        let timing: String
        let items: [EarningRelease]
        var displayName: String {
            switch timing {
            case "BMO": return "盘前"
            case "AMC": return "盘后"
            case "TNS": return "待定"
            default: return timing
            }
        }
    }

    struct DateGroup: Identifiable {
        let id: String
        let date: String
        let timingGroups: [TimingGroup]
    }

    @State private var expandedSections: [String: Bool] = [:]
    @State private var showSearchView = false
    
    // 【新增】用于控制自动滚动的状态，防止重复滚动
    @State private var hasScrolledToToday = false

    private var groupedReleases: [DateGroup] {
        // 1. 【新增】定义一个格式化器，生成 "yyyy-MM-dd" 格式的字符串
        // 这样既包含了年份用于正确排序，又可以作为分组的 Key
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        
        // 2. 【修改】使用 fullDate 生成带年份的 Key 进行分组
        // 原代码使用的是 $0.date (只有月-日)，导致排序时 "01-xx" 永远排在 "12-xx" 前面
        let groupedByDate = Dictionary(grouping: dataService.earningReleases, by: { release in
            keyFormatter.string(from: release.fullDate)
        })
        
        var dateGroups: [DateGroup] = []
        for (dateKey, releasesOnDate) in groupedByDate {
            let groupedByTiming = Dictionary(grouping: releasesOnDate, by: { $0.timing })
            var timingGroups: [TimingGroup] = []
            for (timing, items) in groupedByTiming {
                // ID 使用 dateKey 保证唯一性
                let timingGroup = TimingGroup(id: "\(dateKey)-\(timing)", timing: timing, items: items)
                timingGroups.append(timingGroup)
            }
            let timingOrder: [String: Int] = ["BMO": 0, "AMC": 1, "TNS": 2]
            timingGroups.sort { (timingOrder[$0.timing] ?? 99) < (timingOrder[$1.timing] ?? 99) }
            
            // 3. 【修改】这里传入 dateKey (例如 "2025-12-15")
            // 这样列表标题也会显示年份，避免用户混淆是哪一年的1月
            let dateGroup = DateGroup(id: dateKey, date: dateKey, timingGroups: timingGroups)
            dateGroups.append(dateGroup)
        }
        
        // 4. 【排序】因为 dateKey 是 "yyyy-MM-dd" 格式，字符串排序即可保证时间顺序
        // "2025-12-xx" 会正确地排在 "2026-01-xx" 前面
        dateGroups.sort { $0.date < $1.date }
        
        return dateGroups
    }

    var body: some View {
        // 【核心修改 1】引入 ScrollViewReader
        ScrollViewReader { proxy in
            List {
                ForEach(groupedReleases) { dateGroup in
                    Section(header: Text(dateGroup.date).font(.headline).foregroundColor(.primary).padding(.vertical, 5)) {
                        ForEach(dateGroup.timingGroups) { timingGroup in
                            timingGroupHeader(for: timingGroup)
                            // 这里使用了 expandedSections 的状态
                            if expandedSections[timingGroup.id] ?? true {
                                ForEach(timingGroup.items) { item in
                                    sectionRow(for: item)
                                }
                            }
                        }
                    }
                    // 【核心修改 2】给每个 Section 头部绑定 ID，方便定位
                    .id(dateGroup.id)
                }
            }
            .listStyle(.plain)
            .navigationTitle("财报发布")
            .onAppear {
                initializeExpandedStates()
                // 【核心修改 3】视图出现时执行滚动逻辑
                scrollToTargetDate(proxy: proxy)
            }
            // 【修复警告】适配 iOS 17 新语法
            // 旧写法: .onChange(of: value) { _ in ... }
            // 新写法: .onChange(of: value) { ... } (如果是0个参数)
            // 或者: .onChange(of: value) { oldValue, newValue in ... } (如果是2个参数)
            .onChange(of: dataService.earningReleases.count) { 
                // 这里不需要参数，直接执行逻辑
                initializeExpandedStates()
                scrollToTargetDate(proxy: proxy)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSearchView = true }) { Image(systemName: "magnifyingglass") }
                }
            }
            .navigationDestination(isPresented: $showSearchView) {
                SearchView(isSearchActive: true, dataService: dataService)
            }
            .navigationDestination(isPresented: $isNavigationActive) {
                if let item = selectedItem {
                    ChartView(symbol: item.symbol, groupName: dataService.getCategory(for: item.symbol) ?? "Stocks")
                }
            }
            .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        }
    }

    // 【核心修改 4】计算日期并滚动的逻辑函数
    private func scrollToTargetDate(proxy: ScrollViewProxy) {
        // 防止重复滚动，或者数据还没加载完就滚动
        guard !hasScrolledToToday, !groupedReleases.isEmpty else { return }
        
        // 1. 获取当前系统日期
        let today = Date()
        // 2. 计算前一天
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let targetDateString = formatter.string(from: yesterday)
        
        // 3. 寻找最合适的滚动目标
        // 我们需要找到列表中日期 >= 目标日期(昨天) 的第一个分组
        // 这样如果昨天没有财报，它会停在昨天之后最近的一天（比如今天或明天），保证用户看到的是最新的未过期数据
        // 如果你严格想要“昨天”那个组，如果没有就不跳，可以用 first(where: { $0.date == targetDateString })
        
        if let targetGroup = groupedReleases.first(where: { $0.date >= targetDateString }) {
            // 稍微延迟一点执行，确保 List 渲染完成，避免滚动失效
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    proxy.scrollTo(targetGroup.id, anchor: .top)
                }
                hasScrolledToToday = true
            }
        } else {
            // 如果所有数据都比昨天早（全是历史数据），则滚动到底部（可选）
             if let lastGroup = groupedReleases.last {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                     proxy.scrollTo(lastGroup.id, anchor: .top)
                     hasScrolledToToday = true
                 }
             }
        }
    }

    @ViewBuilder
    private func timingGroupHeader(for group: TimingGroup) -> some View {
        HStack {
            // 1. 字体加粗，增加视觉重量
            Text("\(group.displayName)  \(group.items.count)")
                .font(.subheadline.weight(.semibold)) // 使用 .semibold 加粗
                .foregroundColor(.secondary)
            
            Spacer()
            
            Image(systemName: (expandedSections[group.id] ?? true)
                  ? "chevron.down"
                  : "chevron.right")
                .foregroundColor(.secondary)
        }
        // 2. 增加内边距，让内容和背景之间有更多空间
        .padding(.horizontal) // 给左右也加上 padding
        .padding(.vertical, 8) // 增加垂直 padding
        .contentShape(Rectangle())
        .onTapGesture {
            let isExpanded = expandedSections[group.id] ?? true
            withAnimation {
                expandedSections[group.id] = !isExpanded
            }
        }
        // 3. 设置行内边距为0，这样背景色可以撑满整行
        .listRowInsets(EdgeInsets())
        // 4. 添加一个微妙的背景色，以和内容行区分
        //    Color(.systemGray5) 是一个很好的选择，它能自适应浅色/深色模式
        .background(Color(.systemGray5))
    }

    private func sectionRow(for item: EarningRelease) -> some View {
        // 【修改】使用 Button 替代 NavigationLink
        Button(action: {
            // 【修改】使用 .viewChart
            if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                selectedItem = item
                isNavigationActive = true
            } else {
                // 【核心修改】直接弹出订阅页
                showSubscriptionSheet = true
            }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.symbol)
                    .font(.system(.body, design: .monospaced))
                if let tags = getTags(for: item.symbol), !tags.isEmpty {
                    Text(tags.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            // 保持 Symbol 行的缩进
            .padding(.leading)
        }
    }

    // 【修改】这里是修改后的初始化状态方法
    private func initializeExpandedStates() {
        for dateGroup in groupedReleases {
            for timingGroup in dateGroup.timingGroups {
                // 如果该组的状态还未被记录，则将其初始化为 true (展开)
                if expandedSections[timingGroup.id] == nil {
                    // 【修改】不再判断数量，直接设置为 false，即默认全部折叠
                    expandedSections[timingGroup.id] = false
                }
            }
        }
    }

    private func getTags(for symbol: String) -> [String]? {
        if let stockTags = dataService.descriptionData?
            .stocks.first(where: { $0.symbol.uppercased() == symbol.uppercased() })?.tag {
            return stockTags
        }
        if let etfTags = dataService.descriptionData?
            .etfs.first(where: { $0.symbol.uppercased() == symbol.uppercased() })?.tag {
            return etfTags
        }
        return nil
    }
}