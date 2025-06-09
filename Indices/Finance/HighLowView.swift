import SwiftUI

/// 通用的 High/Low 列表视图，其设计参考了 EarningReleaseView
struct HighLowListView: View {
    let title: String
    let groups: [HighLowGroup]
    
    @EnvironmentObject var dataService: DataService
    @State private var expandedSections: [String: Bool] = [:]

    var body: some View {
        List {
            ForEach(groups) { group in
                // 确保分组内有项目才显示
                if !group.items.isEmpty {
                    Section(header: sectionHeader(for: group)) {
                        // 根据展开/折叠状态决定是否显示内容
                        if expandedSections[group.id, default: true] {
                            ForEach(group.items) { item in
                                rowView(for: item)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(title)
        .onAppear(perform: initializeExpandedStates)
    }

    /// 分组的头部视图，包含标题和折叠/展开按钮
    @ViewBuilder
    private func sectionHeader(for group: HighLowGroup) -> some View {
        HStack {
            Text(group.timeInterval)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            Image(systemName: (expandedSections[group.id, default: true]) ? "chevron.down" : "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                expandedSections[group.id, default: true].toggle()
            }
        }
    }

    /// 列表中的单行视图，展示 symbol 和其关联的 tags
    private func rowView(for item: HighLowItem) -> some View {
        // 获取 symbol 所属的分类，用于导航到 ChartView
        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
        
        return NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.symbol)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.blue) // 使用蓝色以示可点击
                
                if let tags = getTags(for: item.symbol), !tags.isEmpty {
                    Text(tags.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 初始化每个分组的展开/折叠状态
    private func initializeExpandedStates() {
        for group in groups {
            // 只有当该分组的状态未被设置时才进行初始化
            if expandedSections[group.id] == nil {
                // 如果分组内的项目超过5个，则默认折叠 (false)，否则展开 (true)
                expandedSections[group.id] = (group.items.count <= 5)
            }
        }
    }

    /// 根据 symbol 获取其在 description.json 中定义的 tags
    private func getTags(for symbol: String) -> [String]? {
        let upperSymbol = symbol.uppercased()
        
        if let stockTags = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol })?.tag {
            return stockTags
        }
        
        if let etfTags = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol })?.tag {
            return etfTags
        }
        
        return nil
    }
}
