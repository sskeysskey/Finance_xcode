import SwiftUI

struct BacktestView: View {
    let symbol: String
    @EnvironmentObject var dataService: DataService
    @Environment(\.presentationMode) var presentationMode
    
    // 计算属性：查找所属板块
    private var foundSectors: [String] {
        guard let allSectors = dataService.sectorsPanel?.sectors else { return [] }
        var results: [String] = []
        let target = symbol.uppercased()
        
        // 递归查找函数
        func search(in sectors: [IndicesSector]) {
            for sector in sectors {
                // 1. 检查当前层级的 symbols
                if sector.symbols.contains(where: { $0.symbol.uppercased() == target }) {
                    // 如果找到了，添加板块名
                    // Python 脚本里处理了 "MOS": "美盛化肥" 这种备注，
                    // 但 Swift 模型里 IndicesSymbol 只有 symbol, name, value, tags。
                    // 这里我们直接显示板块名称
                    results.append(sector.name)
                }
                
                // 2. 递归检查子板块
                if let subSectors = sector.subSectors {
                    search(in: subSectors)
                }
            }
        }
        
        search(in: allSectors)
        return Array(Set(results)).sorted() // 去重并排序
    }
    
    // MARK: - 修改点 1: 重构数据聚合逻辑
    // 改为：[(日期, [策略组名])]，按日期降序排列
    private var foundHistory: [(date: String, categories: [String])] {
        let target = symbol.uppercased()
        // 临时字典：Key = 日期, Value = [策略组名]
        var tempDateMap: [String: [String]] = [:]
        
        // 遍历原始数据: [Category : [Date : [SymbolList]]]
        for (category, dateMap) in dataService.earningHistoryData {
            for (date, symbolList) in dateMap {
                // 检查 symbol 是否在当天的列表中
                if symbolList.contains(where: { $0.uppercased() == target }) {
                    // 如果存在，将该 category 加入到该日期的列表中
                    if tempDateMap[date] == nil {
                        tempDateMap[date] = []
                    }
                    tempDateMap[date]?.append(category)
                }
            }
        }
        
        // 转换为数组并排序
        // 1. Map 字典为元组数组
        // 2. 内部 categories 排序 (字母顺序)
        // 3. 外部 date 排序 (降序，最近的日期在最上面)
        let results = tempDateMap.map { (date, categories) in
            return (date: date, categories: categories.sorted())
        }.sorted { $0.date > $1.date }
        
        return results
    }
    
    var body: some View {
        List {
            // MARK: - 1. 所属板块区域
            Section {
                if foundSectors.isEmpty {
                    Text("未找到所属板块信息")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(foundSectors, id: \.self) { sectorName in
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            Text(formatName(sectorName))
                                .font(.headline)
                        }
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "square.grid.2x2.fill")
                    Text("所属板块 / 分组")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.green) // 对应 Python 中的 success_green
            }
            
            // MARK: - 2. 历史记录区域 (修改点 2: UI渲染逻辑)
            Section {
                if foundHistory.isEmpty {
                    Text("未找到历史复盘记录")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    // 这里 item.date 是日期，item.categories 是当天的策略列表
                    ForEach(foundHistory, id: \.date) { item in
                        DisclosureGroup(
                            content: {
                                ForEach(item.categories, id: \.self) { category in
                                    HStack {
                                        // 换个图标表示“策略/组别”
                                        Image(systemName: "tag.fill")
                                            .foregroundColor(.blue) // 使用蓝色区分
                                            .font(.system(size: 12))
                                        
                                        // 显示策略名 (处理掉下划线)
                                        Text(formatName(category))
                                            .font(.system(.body, design: .rounded))
                                        
                                        Spacer()
                                    }
                                    .padding(.leading, 10)
                                    .padding(.vertical, 2)
                                }
                            },
                            label: {
                                HStack {
                                    // 标题显示日期
                                    Text(item.date)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    // 计数显示：当天命中了几个策略
                                    Text("\(item.categories.count) 组")
                                        .font(.caption)
                                        .padding(4)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                        )
                        // 默认展开
                        // .accentColor(.green) 
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("复盘历史记录 (按日期)")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.green) // 对应 Python 中的 success_green
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("\(symbol) 回溯")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // 辅助：格式化名称 (去掉下划线)
    private func formatName(_ name: String) -> String {
        return name.replacingOccurrences(of: "_", with: " ")
    }
}
