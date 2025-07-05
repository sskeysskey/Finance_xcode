import Foundation
import SQLite3

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    
    // 新增：用于承载从 MNSPP 表查询出的数据的结构体
    struct MarketCapInfo {
        let symbol: String
        let marketCap: Double
        let peRatio: Double?
        let pb: Double?
    }
    
    private init() {
        print("=== DatabaseManager Debug ===")
        // 首先尝试获取 bundle 中的数据库路径
        if let dbPath = Bundle.main.path(forResource: "Finance", ofType: "db") {
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                print("Successfully opened database")
            } else {
                print("Could not open database")
            }
        } else {
            print("Database file not found")
        }
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    struct PriceData: Identifiable {
        let id: Int
        let date: Date
        let price: Double
        let volume: Int64?  // 修改为可选类型
    }
    
    // 新增方法：从指定表（如 MNSPP）中获取所有市值相关数据
    func fetchAllMarketCapData(from tableName: String) -> [MarketCapInfo] {
        var results: [MarketCapInfo] = []
        // 注意：您的表名是 "MNSPP "，末尾有一个空格，这里需要精确匹配。如果实际表名没有空格，请移除它。
        let query = "SELECT symbol, marketcap, pe_ratio, pb FROM \"\(tableName)\""
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let symbol = String(cString: sqlite3_column_text(statement, 0))
                let marketCap = sqlite3_column_double(statement, 1)
                
                // pe_ratio 和 pb 可能为 NULL，需要检查
                let peRatio: Double?
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    peRatio = sqlite3_column_double(statement, 2)
                } else {
                    peRatio = nil
                }
                
                let pb: Double?
                if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                    pb = sqlite3_column_double(statement, 3)
                } else {
                    pb = nil
                }
                
                results.append(MarketCapInfo(symbol: symbol, marketCap: marketCap, peRatio: peRatio, pb: pb))
            }
        } else {
            print("Failed to prepare statement for market cap data: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        sqlite3_finalize(statement)
        return results
    }
    
    // 新增的方法：获取特定 ETF 的最新 volume
    func fetchLatestVolume(forSymbol symbol: String, tableName: String) -> Int64? {
        let query = "SELECT volume FROM \(tableName) WHERE name = ? ORDER BY date DESC LIMIT 1"
        var statement: OpaquePointer?
        var latestVolume: Int64? = nil

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (symbol as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                latestVolume = sqlite3_column_int64(statement, 0)
            }
        } else {
            print("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
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
        var result: [PriceData] = []
        let dateFormat = "yyyy-MM-dd"
        
        // 确定日期范围
        let (startDate, endDate): (Date, Date) = {
            switch dateRange {
            case .timeRange(let timeRange):
                return (timeRange.startDate, Date())
            case .customRange(let start, let end):
                return (start, end)
            }
        }()
        
        // 检查表结构
        let hasVolumeColumn = checkIfTableHasVolume(tableName: tableName)
        
        // 构建查询语句
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
            
            // 绑定参数
            sqlite3_bind_text(statement, 1, (symbol as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (formatter.string(from: startDate) as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (formatter.string(from: endDate) as NSString).utf8String, -1, nil)
            
            // 处理结果
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
        return result
    }
    
    // 添加辅助方法来检查表是否包含 volume 列
    private func checkIfTableHasVolume(tableName: String) -> Bool {
        var hasVolume = false
        var statement: OpaquePointer?
        
        // 查询表结构
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
