import SwiftUI

struct BacktestView: View {
    let symbol: String
    @EnvironmentObject var dataService: DataService
    @Environment(\.presentationMode) var presentationMode
    
    // 计算属性：查找所属板块
    private var foundSectors: [String] {
        guard let allSectors = dataService.sectorsPanel?.sectors else { return [] }
        var results: [String] = []
        
        // 🚨 修改点 1：将传入的查询目标也清洗为纯净代码
        let target = symbol.cleanTicker.uppercased()
        
        // 递归查找函数
        func search(in sectors: [IndicesSector]) {
            for sector in sectors {
                // 🚨 修改点 2：将板块中存的 symbol 也清洗后对比，确保 "EWY黑热" == "EWY"
                if sector.symbols.contains(where: { $0.symbol.cleanTicker.uppercased() == target }) {
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
        // 🚨 修改点 3：清洗目标代码
        let target = symbol.cleanTicker.uppercased()
        
        // 临时字典：Key = 日期, Value = [策略组名]
        var tempDateMap: [String: [String]] = [:]
        
        // 遍历原始数据: [Category : [Date : [SymbolList]]]
        for (category, dateMap) in dataService.earningHistoryData {
            for (date, symbolList) in dateMap {
                // 🚨 修改点 4：清洗 JSON 里读出来的 symbol 列表进行比对
                if symbolList.contains(where: { $0.cleanTicker.uppercased() == target }) {
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
                        // 【新增】：提取是否包含黑名单
                        let isBlacklisted = item.categories.contains("_Tag_Blacklist")
                        // 【新增】：过滤掉黑名单 Key，剩下的才是真正策略
                        let displayCategories = item.categories.filter { $0 != "_Tag_Blacklist" }
                        
                        DisclosureGroup(
                            content: {
                                ForEach(displayCategories, id: \.self) { category in
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
                                    
                                    // MARK: - 【新增】 CallBack 界面显示的黑名单警告
                                    if isBlacklisted {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 14))
                                    }
                                    
                                    Spacer()
                                    
                                    // 计数显示
                                    Text("\(displayCategories.count) 组")
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
        // 🚨 修改点 5：让页面标题只显示纯净代码（如 "EWY 回溯" 而不是 "EWY黑热 回溯"）
        .navigationTitle("\(symbol.cleanTicker) 回溯")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // 辅助：格式化名称 (去掉下划线)
    private func formatName(_ name: String) -> String {
        return name.replacingOccurrences(of: "_", with: " ")
    }
}
