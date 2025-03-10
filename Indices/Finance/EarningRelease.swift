import SwiftUI

struct EarningReleaseView: View {
    @EnvironmentObject var dataService: DataService
    
    // 将数据按日期分组
    private var groupedReleases: [String: [EarningRelease]] {
        Dictionary(grouping: dataService.earningReleases) { $0.date }
            .sorted(by: { $0.key < $1.key })
            .reduce(into: [:]) { result, element in
                result[element.0] = element.1
            }
    }
    
    var body: some View {
        List {
            ForEach(Array(groupedReleases.keys.sorted()), id: \.self) { date in
                Section(header: Text(date)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .padding(.vertical, 5)) {
                    ForEach(groupedReleases[date] ?? []) { item in
                        let groupName = dataService.getCategory(for: item.symbol) ?? "Stocks"
                        
                        NavigationLink(destination: ChartView(symbol: item.symbol, groupName: groupName)) {
                            Text(item.symbol)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(item.color)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("财报发布")
        .onAppear {
            dataService.loadData()
        }
    }
}
