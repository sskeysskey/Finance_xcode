import Foundation
import SQLite3
import Combine

struct BalanceRecord {
    let date: String
    let value: Double
}

class AccountSummaryViewModel: ObservableObject {
    @Published var totalBalance: Double = 0
    @Published var cashBuyingPower: Double = 0
    @Published var dailyChange: Double = 0
    @Published var dailyChangePercent: Double = 0

    func fetchBalances() {
        // 从 Bundle 中找到数据库文件
        guard let dbURL = Bundle.main.url(forResource: "Firstrade", withExtension: "db") else {
            print("❌ 找不到 Firstrade.db")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            print("❌ 无法打开数据库")
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
            print("⚠️ Balance 表中数据不足 2 天")
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
