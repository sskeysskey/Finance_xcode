import SwiftUI
import Combine

struct EarningReleaseView: View {
  @EnvironmentObject var dataService: DataService

  // ==================== 修改开始 ====================
  // 1. 定义新的嵌套数据结构
  
  // 时段分组 (BMO, AMC, etc.)
  struct TimingGroup: Identifiable {
    let id: String // 唯一标识，例如 "07-21-BMO"
    let timing: String // "BMO", "AMC", "TNS"
    let items: [EarningRelease]
    
    // 用于显示的名称
    var displayName: String {
        switch timing {
        case "BMO": return "盘前"
        case "AMC": return "盘后"
        case "TNS": return "待定"
        default: return timing
        }
    }
  }

  // 日期分组，包含多个时段分组
  struct DateGroup: Identifiable {
    let id: String // 日期，例如 "07-21"
    let date: String
    let timingGroups: [TimingGroup]
  }

  // 状态变量，使用 TimingGroup 的 id 作为 key
  @State private var expandedSections: [String: Bool] = [:]
  @State private var showSearchView = false

  // 2. 重构 groupedReleases 以支持两级分组
  private var groupedReleases: [DateGroup] {
    // 按日期分组
    let groupedByDate = Dictionary(grouping: dataService.earningReleases, by: { $0.date })
    
    var dateGroups: [DateGroup] = []

    // 遍历每个日期
    for (date, releasesOnDate) in groupedByDate {
      // 在日期内，再按时段 (timing) 分组
      let groupedByTiming = Dictionary(grouping: releasesOnDate, by: { $0.timing })
      
      var timingGroups: [TimingGroup] = []
      
      // 遍历每个时段
      for (timing, items) in groupedByTiming {
        // 创建 TimingGroup，使用 "date-timing" 作为唯一 ID
        let timingGroup = TimingGroup(id: "\(date)-\(timing)", timing: timing, items: items)
        timingGroups.append(timingGroup)
      }
      
      // 按 BMO -> AMC -> TNS 的顺序对时段进行排序
      let timingOrder: [String: Int] = ["BMO": 0, "AMC": 1, "TNS": 2]
      timingGroups.sort {
          (timingOrder[$0.timing] ?? 99) < (timingOrder[$1.timing] ?? 99)
      }
      
      // 创建 DateGroup
      let dateGroup = DateGroup(id: date, date: date, timingGroups: timingGroups)
      dateGroups.append(dateGroup)
    }

    // 按日期升序排序
    dateGroups.sort { $0.date < $1.date }
    return dateGroups
  }
  // ==================== 修改结束 ====================

  var body: some View {
    List {
      // 遍历日期分组
      ForEach(groupedReleases) { dateGroup in
        // Section Header 显示日期
        Section(header: Text(dateGroup.date).font(.headline).foregroundColor(.primary).padding(.vertical, 5)) {
          // 遍历该日期下的时段分组
          ForEach(dateGroup.timingGroups) { timingGroup in
            // 时段分组的 Header，可点击折叠
            timingGroupHeader(for: timingGroup)
            
            // 如果该时段分组是展开的，则显示其下的 Symbol
            if expandedSections[timingGroup.id] ?? true {
              ForEach(timingGroup.items) { item in
                sectionRow(for: item)
              }
            }
          }
        }
      }
    }
    .navigationTitle("财报发布")
    .onAppear {
      dataService.loadData()
      initializeExpandedStates()
    }
    .onReceive(dataService.$earningReleases) { _ in
      initializeExpandedStates()
    }
    .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: {
                showSearchView = true
            }) {
                Image(systemName: "magnifyingglass")
            }
        }
    }
    .navigationDestination(isPresented: $showSearchView) {
        SearchView(isSearchActive: true, dataService: dataService)
    }
  }

    // ==================== 修改开始 ====================
    // 3. 创建新的 timingGroupHeader 视图
    @ViewBuilder
    private func timingGroupHeader(for group: TimingGroup) -> some View {
        HStack {
            // 显示时段名称和 Symbol 数量
            Text("\(group.displayName)  \(group.items.count)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            // 折叠/展开的箭头图标
            Image(systemName: (expandedSections[group.id] ?? true)
                  ? "chevron.down"
                  : "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.leading) // 增加缩进，以表示层级关系
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            // 切换折叠/展开状态
            let isExpanded = expandedSections[group.id] ?? true
            withAnimation {
                expandedSections[group.id] = !isExpanded
            }
        }
    }

    // 4. 修改 sectionRow，移除对颜色的引用
    private func sectionRow(for item: EarningRelease) -> some View {
        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
        return NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.symbol)
                    .font(.system(.body, design: .monospaced))
                    // .foregroundColor(item.color) // 移除颜色设置
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
            .padding(.leading) // 增加缩进，与时段 Header 对齐
        }
    }

    // 5. 更新 initializeExpandedStates 以适应新结构
    private func initializeExpandedStates() {
        for dateGroup in groupedReleases {
            for timingGroup in dateGroup.timingGroups {
                // 只有还没设置过的时段分组，才根据条目数设初始值
                if expandedSections[timingGroup.id] == nil {
                    // 超过 5 条折叠(false)，否则展开(true)
                    expandedSections[timingGroup.id] = (timingGroup.items.count <= 5)
                }
            }
        }
    }
    // ==================== 修改结束 ====================

    // MARK: - 获取 Tags
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
