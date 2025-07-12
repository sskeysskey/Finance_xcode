import Foundation
import SQLite3

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    
    struct MarketCapInfo {
        let symbol: String
        let marketCap: Double
        let peRatio: Double?
        let pb: Double?
    }
    
    private init() {
        print("=== DatabaseManager Initializing ===")
        // 初始化时，执行一次数据库打开操作
        openLatestDatabase()
    }
    
    // MARK: - 新增：重新连接到最新的数据库
    /// 当数据库文件更新后，调用此方法来关闭旧连接并打开新连接。
    func reconnectToLatestDatabase() {
        print("=== DatabaseManager Reconnecting ===")
        // 1. 先关闭现有的数据库连接（如果存在）
        if db != nil {
            sqlite3_close(db)
            db = nil // 将指针设为 nil
            print("已关闭旧的数据库连接。")
        }
        
        // 2. 重新执行打开最新数据库的逻辑
        openLatestDatabase()
    }

    // MARK: - 新增：将打开数据库的逻辑提取到私有方法
    /// 查找最新的数据库文件并打开连接。
    private func openLatestDatabase() {
        guard let dbUrl = FileManagerHelper.getLatestFileUrl(for: "Finance") else {
            print("错误：在 Documents 目录中未找到任何 Finance 数据库文件。")
            // 确保 db 为 nil
            self.db = nil
            return
        }

        // 尝试打开新的数据库文件
        if sqlite3_open(dbUrl.path, &db) == SQLITE_OK {
            print("成功从 Documents 目录打开数据库: \(dbUrl.lastPathComponent)")
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("无法从 Documents 目录打开数据库: \(dbUrl.lastPathComponent)。错误: \(errorMessage)")
            // 确保打开失败时 db 为 nil
            self.db = nil
        }
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    struct PriceData: Identifiable {
        let id: Int
        let date: Date
        let price: Double
        let volume: Int64?
    }
    
    func fetchAllMarketCapData(from tableName: String) -> [MarketCapInfo] {
        guard db != nil else {
            print("数据库连接无效，无法执行 fetchAllMarketCapData。")
            return []
        }
        
        var results: [MarketCapInfo] = []
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
        return results
    }
    
    // ... 其他 fetch 方法保持不变 ...
    // fetchLatestVolume, fetchHistoricalData, fetchEarningData, checkIfTableHasVolume
    // 这些方法都不需要修改，因为它们依赖于 db 连接，只要 db 连接是正确的，它们就能正常工作。
    
    // 新增的方法：获取特定 ETF 的最新 volume
    func fetchLatestVolume(forSymbol symbol: String, tableName: String) -> Int64? {
        guard db != nil else { return nil }
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
        guard db != nil else { return [] }
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
        guard db != nil else { return [] }
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
        guard db != nil else { return false }
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
