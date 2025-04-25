import SwiftUI
import Combine

struct EarningReleaseView: View {
  @EnvironmentObject var dataService: DataService

  struct DateGroup: Identifiable {
    let id: String; let date: String; let items: [EarningRelease]
  }

  @State private var expandedSections: [String: Bool] = [:]

  private var groupedReleases: [DateGroup] {
    let dict = Dictionary(grouping: dataService.earningReleases, by: { $0.date })
    var groups: [DateGroup] = []
    for (date, items) in dict {
      groups.append(.init(id: date, date: date, items: items))
    }
    groups.sort { $0.date < $1.date }
    return groups
  }

  var body: some View {
    List {
      ForEach(groupedReleases) { group in
        Section(header: sectionHeader(for: group)) {
          if expandedSections[group.date] ?? true {
            ForEach(group.items) { item in
              sectionRow(for: item)
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
    // 用 onReceive 监听 @Published 值的变化
    .onReceive(dataService.$earningReleases) { _ in
      initializeExpandedStates()
    }
  }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(for group: DateGroup) -> some View {
        HStack {
            Text(group.date)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            // 直接显示 chevron
            Image(systemName: (expandedSections[group.date] ?? true)
                  ? "chevron.down"
                  : "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
        // 让整个 HStack 区域都能点
        .contentShape(Rectangle())
        .onTapGesture {
            // 切换折叠/展开
            let isExpanded = expandedSections[group.date] ?? true
            withAnimation {
                expandedSections[group.date] = !isExpanded
            }
        }
    }

    // MARK: - Section Row

    private func sectionRow(for item: EarningRelease) -> some View {
        // 拿到分组名
        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
        return NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.symbol)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(item.color)
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
        }
    }

    // MARK: - 初始化每组的“默认展开状态”

    private func initializeExpandedStates() {
        for group in groupedReleases {
            // 只有还没设置过的组，才根据条目数设初始值
            if expandedSections[group.date] == nil {
                // 超过 5 条折叠(false)，否则展开(true)
                expandedSections[group.date] = (group.items.count <= 5)
            }
        }
    }

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
