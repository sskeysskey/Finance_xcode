import SwiftUI

struct BacktestView: View {
    let symbol: String
    @EnvironmentObject var dataService: DataService
    @Environment(\.presentationMode) var presentationMode
    
    // MARK: - 数据聚合：[(日期, [策略组名])]，按日期降序
    private var foundHistory: [(date: String, categories: [String])] {
        let target = symbol.cleanTicker.uppercased()
        
        var tempDateMap: [String: [String]] = [:]
        
        for (category, dateMap) in dataService.earningHistoryData {
            for (date, symbolList) in dateMap {
                if symbolList.contains(where: { $0.cleanTicker.uppercased() == target }) {
                    if tempDateMap[date] == nil {
                        tempDateMap[date] = []
                    }
                    tempDateMap[date]?.append(category)
                }
            }
        }
        
        var results = tempDateMap.map { (date, categories) in
            return (date: date, categories: categories.sorted())
        }.sorted { $0.date > $1.date }
        
        // 【新增】如果该 symbol 命中 52周新低板块，则给"最新日期"追加 52week_low 标记
        if !results.isEmpty, dataService.weekLow52Symbols.contains(target) {
            results[0].categories.append("52week_low")
        }
        
        return results
    }
    
    var body: some View {
        List {
            // MARK: - 历史记录区域
            Section {
                if foundHistory.isEmpty {
                    Text("未找到历史复盘记录")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(foundHistory, id: \.date) { item in
                        // 提取是否包含黑名单
                        let isBlacklisted = item.categories.contains("_Tag_Blacklist")
                        // 过滤掉黑名单 Key，剩下的才是真正策略
                        let displayCategories = item.categories.filter { $0 != "_Tag_Blacklist" }
                        
                        DisclosureGroup(
                            content: {
                                ForEach(displayCategories, id: \.self) { category in
                                    HStack {
                                        Image(systemName: "tag.fill")
                                            .foregroundColor(.blue)
                                            .font(.system(size: 12))
                                        
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
                                    Text(item.date)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    if isBlacklisted {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 14))
                                    }
                                    
                                    Spacer()
                                    
                                    Text("\(displayCategories.count) 组")
                                        .font(.caption)
                                        .padding(4)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("复盘历史记录 (按日期)")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.green)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("\(symbol.cleanTicker) 回溯")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // 辅助：格式化名称 (去掉下划线)
    private func formatName(_ name: String) -> String {
        return name.replacingOccurrences(of: "_", with: " ")
    }
}