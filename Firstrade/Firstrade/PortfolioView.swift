import SwiftUI
import Foundation
import SQLite3
import Combine

struct MainTabView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var vm = BalanceViewModel()

    var body: some View {
        TabView {
            PortfolioView(username: session.username, vm: vm)
                .tabItem {
                    Image(systemName: "briefcase.fill")
                    Text("Positions")
                }

            WatchlistView() // Use the newly created WatchlistView
                .tabItem {
                    Image(systemName: "star") // SwiftUI will use "star.fill" when selected
                    Text("Watchlist")
                }

            MarketsView()
                .tabItem {
                    Image(systemName: "safari.fill") // Using safari.fill as a compass-like icon
                    Text("Markets")
                }

            AssetsView() // <<< 新しい「资产」ページをここに追加
                .tabItem {
                    // Image(systemName: "rectangle.stack") // 元のアイコン
                    Image(systemName: "chart.pie.fill") // デザイン画像のアイコンに近いものに変更 (任意)
                    Text("Assets")
                }

            MyView()
                .tabItem {
                    Image(systemName: "person")
                    Text("Account")
                }
        }
        .accentColor(Color(red: 70/255, green: 130/255, blue: 220/255))
//        .environmentObject(session)
    }
}

struct BalanceRecord {
    let date: String
    let value: Double
}

class BalanceViewModel: ObservableObject {
    @Published var totalBalance: Double = 0
    @Published var cashBuyingPower: Double = 0
    @Published var dailyChange: Double = 0
    @Published var dailyChangePercent: Double = 0

    func fetchBalances() {
        // 从 Bundle 中找到数据库文件
        guard let dbURL = Bundle.main.url(forResource: "Firstrade", withExtension: "db") else {
            print("❌ Can't find Firstrade.db")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            print("❌ Can't open DATABASE")
            return
        }
        defer { sqlite3_close(db) }

        // 查询最新两天的记录
        let sql = "SELECT date, value FROM Balance ORDER BY date DESC LIMIT 2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ sqlite3_prepare_v2 错误")
            return
        }
        defer { sqlite3_finalize(stmt) }

        var records = [BalanceRecord]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                let date = String(cString: cString)
                let value = sqlite3_column_double(stmt, 1)
                records.append(.init(date: date, value: value))
            }
        }

        // 至少要有两条数据
        guard records.count >= 2 else {
            print("⚠️ Balance DATA not in 2 days")
            return
        }

        let latest = records[0]
        let previous = records[1]

        // 计算
        let diff = latest.value - previous.value
        let pct = previous.value != 0 ? (diff / previous.value) * 100 : 0

        // 回到主线程更新 UI
        DispatchQueue.main.async {
            self.totalBalance = latest.value
            self.cashBuyingPower = latest.value
            self.dailyChange = diff
            self.dailyChangePercent = pct
        }
    }
}

struct PortfolioView: View {
    let username: String
    @ObservedObject var vm: BalanceViewModel
    @State private var selectedSegment = 0
    private let segments = ["POSITION"]    // 这里只放一个

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 摘要卡片
                SummaryCard(vm: vm)
                    .onAppear { vm.fetchBalances() }

                // 分段控件
                Picker("", selection: $selectedSegment) {
                    ForEach(0..<segments.count, id: \.self) { idx in
                        Text(segments[idx]).tag(idx)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)

                // 空仓位提示
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.gray.opacity(0.7))
                    Text("No current positions")
                        .foregroundColor(.gray)
                    Button(action: {
                        // search operation
                    }) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Search for a symbol")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.gray, lineWidth: 1)
                        )
                    }
                }
                Spacer()
            }
            .background(Color(red: 25/255, green: 30/255, blue: 39/255).ignoresSafeArea())
            .navigationBarTitle(username, displayMode: .inline)
            .toolbar {
                // 左侧公文包
                ToolbarItem(placement: .navigationBarLeading) {
//                    Image(systemName: "briefcase")
//                        .foregroundColor(.white)
                }
                // 右侧菜单 / 通知 / 搜索
                ToolbarItemGroup(placement: .navigationBarTrailing) {
//                    Button(action: {}) {
//                        Image(systemName: "line.horizontal.3")
//                    }
//                    Button(action: {}) {
//                        Image(systemName: "bell")
//                    }
                    Button(action: {}) {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }
}

struct SummaryCard: View {
    @ObservedObject var vm: BalanceViewModel

    // 只保留整数金额，百分比保留两位小数
    private func fmt(_ v: Double) -> String {
        String(format: "$%.2f", v) // 将 %.0f 修改为 %.2f，表示显示两位小数
    }
    private func fmtChange(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : "−"
        return String(format: "\(sign)$%.0f", abs(v))
    }
    private func fmtPct(_ p: Double) -> String {
        String(format: "(%.2f%%)", p)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {  // ← alignment: .top
            // 左侧：账户总值 + 现金购买力
            VStack(alignment: .leading, spacing: 6) {
                Text("Total Account Value")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(fmt(vm.totalBalance))
                    .font(.title2)
                    .foregroundColor(.white)

                Text("Cash BP")
                    .font(.caption2)
                    .foregroundColor(.gray)
                Text(fmt(vm.cashBuyingPower))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧：今日变动
            VStack(alignment: .leading, spacing: 6) {
                Text("Today's Change")
                    .font(.caption)
                    .foregroundColor(.gray)

                HStack(spacing: 4) {
                    Text(fmtChange(vm.dailyChange))
                        .font(.title3)  // ← 调小为 .title2
                    Text(fmtPct(vm.dailyChangePercent))
                        .font(.caption)  // 比数字更小的字体
                }
                .foregroundColor(vm.dailyChange >= 0 ? .green : .red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(red: 40 / 255, green: 45 / 255, blue: 55 / 255))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}
