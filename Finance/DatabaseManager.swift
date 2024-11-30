import Foundation
import SQLite3

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    
    private init() {
        print("=== DatabaseManager Debug ===")
        // 首先尝试获取 bundle 中的数据库路径
        if let dbPath = Bundle.main.path(forResource: "Finance", ofType: "db") {
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                print("Successfully opened database")
            } else {
                print("Could not open database")
            }
        }
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    struct PriceData: Identifiable {
        let id: Int
        let date: Date
        let price: Double
        let volume: Int64
    }
    
    func fetchHistoricalData(symbol: String, tableName: String, timeRange: TimeRange) -> [PriceData] {
        var result: [PriceData] = []
        let dateFormat = "yyyy-MM-dd"
        let endDate = Date()
        let startDate = timeRange.startDate
        
        let query = """
            SELECT id, date, price, volume 
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
                let volume = sqlite3_column_int64(statement, 3)
                
                if let date = formatter.date(from: dateString) {
                    result.append(PriceData(id: id, date: date, price: price, volume: volume))
                }
            }
        }
        
        sqlite3_finalize(statement)
        return result
    }
}
