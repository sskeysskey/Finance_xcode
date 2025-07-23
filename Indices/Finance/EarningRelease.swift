import SwiftUI
import Combine

struct EarningReleaseView: View {
  @EnvironmentObject var dataService: DataService

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

  @State private var expandedSections: [String: Bool] = [:]
  @State private var showSearchView = false

  private var groupedReleases: [DateGroup] {
    let groupedByDate = Dictionary(grouping: dataService.earningReleases, by: { $0.date })
    
    var dateGroups: [DateGroup] = []

    for (date, releasesOnDate) in groupedByDate {
      let groupedByTiming = Dictionary(grouping: releasesOnDate, by: { $0.timing })
      
      var timingGroups: [TimingGroup] = []
      
      for (timing, items) in groupedByTiming {
        let timingGroup = TimingGroup(id: "\(date)-\(timing)", timing: timing, items: items)
        timingGroups.append(timingGroup)
      }
      
      let timingOrder: [String: Int] = ["BMO": 0, "AMC": 1, "TNS": 2]
      timingGroups.sort {
          (timingOrder[$0.timing] ?? 99) < (timingOrder[$1.timing] ?? 99)
      }
      
      let dateGroup = DateGroup(id: date, date: date, timingGroups: timingGroups)
      dateGroups.append(dateGroup)
    }

    dateGroups.sort { $0.date < $1.date }
    return dateGroups
  }

  var body: some View {
    // 使用 .insetGrouped 样式，可以让 Section 之间的区别更明显
    List {
      ForEach(groupedReleases) { dateGroup in
        // Section Header 显示日期
        Section(header: Text(dateGroup.date).font(.headline).foregroundColor(.primary).padding(.vertical, 5)) {
          ForEach(dateGroup.timingGroups) { timingGroup in
            // 时段分组的 Header
            timingGroupHeader(for: timingGroup)
            
            if expandedSections[timingGroup.id] ?? true {
              ForEach(timingGroup.items) { item in
                sectionRow(for: item)
              }
            }
          }
        }
      }
    }
    .listStyle(.plain) // 使用 plain 样式，让我们的自定义背景色可以撑满整行
    .navigationTitle("财报发布")
    .onAppear {
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
    // 3. 调整 timingGroupHeader 视图，使其在视觉上更突出
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
    // ==================== 修改结束 ====================

    private func sectionRow(for item: EarningRelease) -> some View {
        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
        return NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
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

    private func initializeExpandedStates() {
        for dateGroup in groupedReleases {
            for timingGroup in dateGroup.timingGroups {
                if expandedSections[timingGroup.id] == nil {
                    expandedSections[timingGroup.id] = (timingGroup.items.count <= 5)
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
