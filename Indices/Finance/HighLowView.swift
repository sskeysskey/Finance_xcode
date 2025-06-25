import SwiftUI

/// 通用的 High/Low 列表视图，其设计参考了 EarningReleaseView
struct HighLowListView: View {
    let title: String
    let groups: [HighLowGroup]
    
    @EnvironmentObject var dataService: DataService
    @State private var expandedSections: [String: Bool] = [:]
    
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false

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
        // 新增：在导航栏添加工具栏
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    // 点击按钮时，触发导航
                    showSearchView = true
                }) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        // 新增：定义导航的目标视图
        .navigationDestination(isPresented: $showSearchView) {
            // 传入 dataService 并设置 isSearchActive 为 true，让搜索框自动激活
            SearchView(isSearchActive: true, dataService: dataService)
        }
    }

    /// 分组的头部视图，包含标题和折叠/展开按钮
    @ViewBuilder
    private func sectionHeader(for group: HighLowGroup) -> some View {
        HStack {
            Text(group.timeInterval)
                .font(.headline)
                .foregroundColor(.primary)
            
            // ==================== 代码修改开始 ====================
            // 如果分组是折叠状态，则显示分组内的项目总数
            if !expandedSections[group.id, default: true] {
                Text("(\(group.items.count))")
                    .font(.headline) // 使用与标题相同的字体，使其大小一致
                    .foregroundColor(.secondary) // 使用次要颜色，以作区分
                    .padding(.leading, 4) // 与标题保持一点间距
            }
            // ==================== 代码修改结束 ====================
            
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

    /// 列表中的单行视图，展示 symbol、百分比值和其关联的 tags
    private func rowView(for item: HighLowItem) -> some View {
        // 获取 symbol 所属的分类，用于导航到 ChartView
        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
        
        return NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 4) {
                // 上半部分：Symbol 和 百分比值
                HStack {
                    Text(item.symbol)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.blue) // 使用蓝色以示可点击
                    
                    Spacer() // 将百分比推到右边
                    
                    // 从 dataService.compareData 查找并显示百分比
                    // 使用 .uppercased() 来确保匹配的健壮性
                    if let compareValue = dataService.compareData[item.symbol.uppercased()] {
                        Text(compareValue)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 下半部分：Tags
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
