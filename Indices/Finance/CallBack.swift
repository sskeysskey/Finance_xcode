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
    
    // 计算属性：查找 Earning History
    // 返回格式：[(CategoryName, [DateStrings])]
    private var foundHistory: [(category: String, dates: [String])] {
        let target = symbol.uppercased()
        var results: [(String, [String])] = []
        
        // 遍历 DataService 中已加载的 earningHistoryData
        // 结构: [Category : [Date : [SymbolList]]]
        for (category, dateMap) in dataService.earningHistoryData {
            var matchedDates: [String] = []
            
            for (date, symbolList) in dateMap {
                // 检查 symbol 是否在列表里 (忽略大小写)
                if symbolList.contains(where: { $0.uppercased() == target }) {
                    matchedDates.append(date)
                }
            }
            
            if !matchedDates.isEmpty {
                // 日期降序排列 (最新的在上面)
                results.append((category, matchedDates.sorted(by: >)))
            }
        }
        
        // 按分类名称排序
        return results.sorted { $0.0 < $1.0 }
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
            
            // MARK: - 2. 历史记录区域
            Section {
                if foundHistory.isEmpty {
                    Text("未找到历史复盘记录")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(foundHistory, id: \.category) { item in
                        DisclosureGroup(
                            content: {
                                ForEach(item.dates, id: \.self) { date in
                                    HStack {
                                        Image(systemName: "calendar")
                                            .foregroundColor(.gray)
                                            .font(.system(size: 12))
                                        Text(date)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    .padding(.leading, 10)
                                    .padding(.vertical, 2)
                                }
                            },
                            label: {
                                HStack {
                                    Text(formatName(item.category))
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("\(item.dates.count) 次")
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
                    Text("复盘历史记录")
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