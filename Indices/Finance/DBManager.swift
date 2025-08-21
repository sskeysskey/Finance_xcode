import Foundation
import SQLite3

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.finance.db.queue") // 新增：串行队列
    
    // MARK: - 表分组定义
    // 定义使用 (name, date) 作为复合主键的表集合
    private let tablesWithCompositeKey: Set<String> = [
        "Earning", "Energy", "Indices", "Crypto", "Currencies", "Bonds",
        "Basic_Materials", "Communication_Services", "Consumer_Cyclical",
        "Consumer_Defensive", "Financial_Services", "Utilities", "Real_Estate",
        "Industrials", "Healthcare", "Technology", "Economics", "ETFs",
        "Commodities"
    ]

    // 定义使用 (symbol) 作为主键的表集合
    private let tablesWithSymbolKey: Set<String> = ["MNSPP"]
    
    struct MarketCapInfo {
        let symbol: String
        let marketCap: Double
        let peRatio: Double?
        let pb: Double?
    }
    
    private init() {
        print("=== DatabaseManager Initializing ===")
        openDatabase()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    func reconnectToLatestDatabase() {
        print("=== DatabaseManager Reconnecting ===")
        if db != nil {
            sqlite3_close(db)
            db = nil
            print("已关闭旧的数据库连接。")
        }
        openDatabase()
    }

    private func openDatabase() {
        let dbName = "Finance.db"
        let dbUrl = FileManagerHelper.documentsDirectory.appendingPathComponent(dbName)

        guard FileManager.default.fileExists(atPath: dbUrl.path) else {
            print("错误：数据库文件 \(dbName) 在 Documents 目录中未找到。")
            self.db = nil
            return
        }

        if sqlite3_open(dbUrl.path, &db) == SQLITE_OK {
            print("成功从 Documents 目录打开数据库: \(dbName)")
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("无法从 Documents 目录打开数据库: \(dbName)。错误: \(errorMessage)")
            self.db = nil
        }
    }

    func applySyncChanges(_ changes: [Change]) async -> Bool {
        guard db != nil else {
            print("数据库连接无效，无法应用变更。")
            return false
        }
        
        return await Task.detached {
            guard sqlite3_exec(self.db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                print("开启事务失败: \(String(cString: sqlite3_errmsg(self.db)))")
                return false
            }
            
            for change in changes {
                var success = false
                switch change.op {
                case "I", "U":
                    success = self.applyReplace(for: change)
                case "D":
                    success = self.applyDelete(for: change)
                default:
                    print("未知的操作类型: \(change.op)")
                    success = true
                }
                
                if !success {
                    print("应用变更失败，正在回滚...")
                    sqlite3_exec(self.db, "ROLLBACK TRANSACTION", nil, nil, nil)
                    return false
                }
            }
            
            guard sqlite3_exec(self.db, "COMMIT TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                print("提交事务失败: \(String(cString: sqlite3_errmsg(self.db)))")
                sqlite3_exec(self.db, "ROLLBACK TRANSACTION", nil, nil, nil)
                return false
            }
            
            print("成功应用 \(changes.count) 条变更。")
            return true
        }.value
    }

    // ==================== 【最终版修复代码】 ====================
    private func applyDelete(for change: Change) -> Bool {
        var sql: String
        var statement: OpaquePointer?
        
        // 使用 Set 来判断表的类型，实现动态处理
        if tablesWithCompositeKey.contains(change.table) {
            // 处理所有使用 (name, date) 作为主键的表
            guard case let .string(name) = change.key["name"],
                  case let .string(date) = change.key["date"] else {
                print("\(change.table) 删除失败：无法从 key 解析 name 和 date。Key: \(change.key)")
                return false
            }
            
            sql = "DELETE FROM \"\(change.table)\" WHERE name = ? AND date = ?;"
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                print("为 \(change.table) DELETE 准备语句失败: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (date as NSString).utf8String, -1, nil)

        } else if tablesWithSymbolKey.contains(change.table) {
            // 处理所有使用 (symbol) 作为主键的表
            guard case let .string(symbol) = change.key["symbol"] else {
                print("\(change.table) 删除失败：无法从 key 解析 symbol。Key: \(change.key)")
                return false
            }
            
            sql = "DELETE FROM \"\(change.table)\" WHERE symbol = ?;"
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                print("为 \(change.table) DELETE 准备语句失败: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            sqlite3_bind_text(statement, 1, (symbol as NSString).utf8String, -1, nil)
            
        } else {
            // 如果有未知的表类型，打印错误
            print("未知的表类型 \(change.table)，无法执行删除。请检查 DBManager.swift 中的分组定义。")
            return false
        }
        
        let result = sqlite3_step(statement)
        sqlite3_finalize(statement)
        
        guard result == SQLITE_DONE else {
            print("执行 DELETE 失败 (table: \(change.table), key: \(change.key)): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        return true
    }
    // ==========================================================

    private func applyReplace(for change: Change) -> Bool {
        guard let data = change.data, !data.isEmpty else { return false }
        
        let sortedKeys = data.keys.sorted()
        
        let columns = sortedKeys.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: data.count).joined(separator: ", ")
        let sql = "REPLACE INTO \"\(change.table)\" (\(columns)) VALUES (\(placeholders));"
        
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("为 REPLACE 操作准备语句失败: \(String(cString: sqlite3_errmsg(db)))")
            print("导致准备失败的变更是: \(change)")
            return false
        }
        
        var index: Int32 = 1
        for key in sortedKeys {
            let value = data[key]!
            
            switch value {
            case .int(let intValue):
                sqlite3_bind_int64(statement, index, Int64(intValue))
            case .double(let doubleValue):
                if doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                    sqlite3_bind_int64(statement, index, Int64(doubleValue))
                } else {
                    sqlite3_bind_double(statement, index, doubleValue)
                }
            case .string(let stringValue):
                sqlite3_bind_text(statement, index, (stringValue as NSString).utf8String, -1, nil)
            case .null:
                sqlite3_bind_null(statement, index)
            }
            index += 1
        }
        
        let result = sqlite3_step(statement)
        sqlite3_finalize(statement)
        
        guard result == SQLITE_DONE else {
            print("执行 REPLACE 失败 (table: \(change.table), key: \(change.key)): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        
        return true
    }
    
    struct PriceData: Identifiable {
        let id: Int
        let date: Date
        let price: Double
        let volume: Int64?
    }
    
    func fetchAllMarketCapData(from tableName: String) -> [MarketCapInfo] {
            var results: [MarketCapInfo] = []
            
            // 在串行队列中同步执行数据库操作
            dbQueue.sync {
                guard db != nil else { return }
                let query = "SELECT symbol, marketcap, pe_ratio, pb FROM \"\(tableName)\""
                var statement: OpaquePointer?
                
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        let symbol = String(cString: sqlite3_column_text(statement, 0))
                        let marketCap = sqlite3_column_double(statement, 1)
                        let peRatio: Double? = sqlite3_column_type(statement, 2) != SQLITE_NULL ? sqlite3_column_double(statement, 2) : nil
                        let pb: Double? = sqlite3_column_type(statement, 3) != SQLITE_NULL ? sqlite3_column_double(statement, 3) : nil
                        results.append(MarketCapInfo(symbol: symbol, marketCap: marketCap, peRatio: peRatio, pb: pb))
                    }
                } else {
                    print("Failed to prepare statement for market cap data: \(String(cString: sqlite3_errmsg(db)))")
                }
                sqlite3_finalize(statement)
            }
            
            return results
        }
    
    func fetchLatestVolume(forSymbol symbol: String, tableName: String) -> Int64? {
            var latestVolume: Int64? = nil
            
            dbQueue.sync {
                guard db != nil else { return }
                let query = "SELECT volume FROM \(tableName) WHERE name = ? ORDER BY date DESC LIMIT 1"
                var statement: OpaquePointer?

                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (symbol as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        latestVolume = sqlite3_column_int64(statement, 0)
                    }
                } else {
                    print("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
                }
                sqlite3_finalize(statement)
            }
            
            return latestVolume
        }
    
    enum DateRangeInput {
        case timeRange(TimeRange)
        case customRange(start: Date, end: Date)
    }

    func fetchHistoricalData(
        symbol: String,
        tableName: String,
        dateRange: DateRangeInput
    ) -> [PriceData] {
        guard db != nil else { return [] }
        var result: [PriceData] = []
        let dateFormat = "yyyy-MM-dd"
        
        let (startDate, endDate): (Date, Date) = {
            switch dateRange {
            case .timeRange(let timeRange):
                return (timeRange.startDate, Date())
            case .customRange(let start, let end):
                return (start, end)
            }
        }()
        
        let hasVolumeColumn = checkIfTableHasVolume(tableName: tableName)
        
        let query = """
            SELECT id, date, price\(hasVolumeColumn ? ", volume" : "")
            FROM \(tableName)
            WHERE name = ? AND date BETWEEN ? AND ?
            ORDER BY date ASC
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            let formatter = DateFormatter()
            formatter.dateFormat = dateFormat
            
            sqlite3_bind_text(statement, 1, (symbol as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (formatter.string(from: startDate) as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (formatter.string(from: endDate) as NSString).utf8String, -1, nil)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let dateString = String(cString: sqlite3_column_text(statement, 1))
                let price = sqlite3_column_double(statement, 2)
                
                if let date = formatter.date(from: dateString) {
                    let volume = hasVolumeColumn ? sqlite3_column_int64(statement, 3) : nil
                    result.append(PriceData(id: id, date: date, price: price, volume: volume))
                }
            }
        }
        
        sqlite3_finalize(statement)
        return result
    }
    
    struct EarningData {
        let date: Date
        let price: Double
    }

    func fetchEarningData(forSymbol symbol: String) -> [EarningData] {
            var result: [EarningData] = []
            
            // 在串行队列中同步执行数据库操作
            dbQueue.sync {
                guard db != nil else { return }
                let dateFormat = "yyyy-MM-dd"
                let formatter = DateFormatter()
                formatter.dateFormat = dateFormat
                
                let query = "SELECT date, price FROM Earning WHERE name = ?"
                var statement: OpaquePointer?
                
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (symbol as NSString).utf8String, -1, nil)
                    
                    while sqlite3_step(statement) == SQLITE_ROW {
                        if let dateString = sqlite3_column_text(statement, 0) {
                            let dateStr = String(cString: dateString)
                            let price = sqlite3_column_double(statement, 1)
                            
                            if let date = formatter.date(from: dateStr) {
                                result.append(EarningData(date: date, price: price))
                            }
                        }
                    }
                } else {
                    print("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
                }
                
                sqlite3_finalize(statement)
            }
            
            return result
        }
    
    private func checkIfTableHasVolume(tableName: String) -> Bool {
        guard db != nil else { return false }
        var hasVolume = false
        var statement: OpaquePointer?
        
        let query = "PRAGMA table_info(\(tableName))"
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) {
                    let columnName = String(cString: name)
                    if columnName.lowercased() == "volume" {
                        hasVolume = true
                        break
                    }
                }
            }
        }
        
        sqlite3_finalize(statement)
        return hasVolume
    }
}
