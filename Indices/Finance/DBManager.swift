import Foundation
import SQLite3

class DatabaseManager {
    static let shared = DatabaseManager()
    
    // 服务器地址，请确保与 UpdateManager 中一致
    internal let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    
    // 本地数据库指针
    private var db: OpaquePointer?
    // 线程锁，确保多线程访问数据库安全
    private let dbLock = NSLock()
    
    private init() {
        // 初始化时尝试连接一次
        reconnectToLatestDatabase()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // MARK: - 数据库连接管理
    
    /// 尝试连接本地数据库
    /// 修复说明：使用了 MainActor.assumeIsolated 配合 DispatchQueue.main.sync
    /// 解决了 "Call to main actor-isolated instance method in a synchronous nonisolated context" 报错
    func reconnectToLatestDatabase() {
        dbLock.lock()
        defer { dbLock.unlock() }
        
        // 1. 先关闭旧连接
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        
        // 2. 安全地从 UpdateManager 获取路径
        // 我们定义一个闭包，专门用于在主线程上下文中执行
        let getMainActorPath = {
            // assumeIsolated 告诉编译器：此处代码已确信在主线程运行，允许调用 MainActor 方法
            return MainActor.assumeIsolated { () -> String? in
                if UpdateManager.shared.isLocalDatabaseValid() {
                    return UpdateManager.shared.getLocalDatabasePath()
                }
                return nil
            }
        }
        
        var dbPath: String?
        
        if Thread.isMainThread {
            // 如果已经在主线程，直接调用 assumeIsolated
            dbPath = getMainActorPath()
        } else {
            // 如果在后台线程，同步调度到主线程，然后调用 assumeIsolated
            dbPath = DispatchQueue.main.sync {
                return getMainActorPath()
            }
        }
        
        // 3. 根据获取到的路径执行连接
        if let validPath = dbPath {
            // sqlite3_open 接受 C 字符串，路径必须有效
            if sqlite3_open(validPath, &db) == SQLITE_OK {
                print("DBManager: ✅ 已切换至【离线模式】，加载本地数据库成功。")
            } else {
                print("DBManager: ❌ 本地数据库打开失败，回退至在线模式。")
                db = nil
            }
        } else {
            print("DBManager: 🌐 本地数据不存在或已过期，使用【在线模式】。")
        }
    }
    
    /// 判断当前是否处于离线模式
    private var isOfflineMode: Bool {
        return db != nil
    }
    
    // MARK: - Models
    
    struct OptionsSummary: Codable {
        let call: String?
        let put: String?
        // 【新增】匹配服务器返回的 Price 和 Change
        let price: Double?
        let change: Double?
        // 【新增】IV 字段
        let iv: String?
        // 【本次新增】日期字段，用于前端校验
        let date: String?
        
        // 【新增】次新 IV
        let prev_iv: String? 
        // 【本次新增】次新数据的 Price 和 Change
        let prev_price: Double?
        let prev_change: Double?
    }

    struct MarketCapInfo: Codable {
        let symbol: String
        let marketCap: Double
        let peRatio: Double?
        let pb: Double?
    }
    
    struct PriceData: Identifiable, Codable {
        let id: Int
        let date: Date
        let price: Double
        let volume: Int64?
        
        // 自定义解码以处理日期字符串
        enum CodingKeys: String, CodingKey {
            case id, date, price, volume
        }
        
        init(id: Int, date: Date, price: Double, volume: Int64?) {
            self.id = id
            self.date = date
            self.price = price
            self.volume = volume
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            price = try container.decode(Double.self, forKey: .price)
            volume = try container.decodeIfPresent(Int64.self, forKey: .volume)
            
            let dateString = try container.decode(String.self, forKey: .date)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: dateString) {
                self.date = date
            } else {
                self.date = Date.distantPast // Fallback
            }
        }
    }

    // MARK: - Models (追加新的模型)
    struct OptionHistoryItem: Codable, Identifiable {
        let id = UUID() //以此符合 Identifiable
        let date: Date
        let price: Double
        // 【新增】存储处理后的 IV 数值
        let iv: Double 
        
        enum CodingKeys: String, CodingKey {
            case date, price, iv
        }
        
        // 手动初始化器（用于本地数据库读取）
        init(date: Date, price: Double, ivString: String?) {
            self.date = date
            self.price = price
            if let ivStr = ivString {
                let cleanIv = ivStr.replacingOccurrences(of: "%", with: "")
                let val = Double(cleanIv) ?? 0.0
                self.iv = val * 100
            } else {
                self.iv = 0.0
            }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            price = try container.decode(Double.self, forKey: .price)
            
            // 【新增】解析 IV 字符串并进行数学转换
            // 逻辑：Server 返回 "50.2%", 去掉 "%" -> 50.2, * 100 -> 5020.0
            if let ivString = try? container.decode(String.self, forKey: .iv) {
                let cleanIv = ivString.replacingOccurrences(of: "%", with: "")
                let val = Double(cleanIv) ?? 0.0
                self.iv = val * 100 
            } else {
                self.iv = 0.0
            }
            
            let dateString = try container.decode(String.self, forKey: .date)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            // 容错处理
            if let date = formatter.date(from: dateString) {
                self.date = date
            } else {
                self.date = Date.distantPast
            }
        }
    }
    
    struct EarningData: Codable {
        let date: Date
        let price: Double
        
        enum CodingKeys: String, CodingKey {
            case date, price
        }
        
        // 【修正】这里不需要 iv 参数，因为 EarningData 只有 date 和 price
        init(date: Date, price: Double) {
            self.date = date
            self.price = price
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            price = try container.decode(Double.self, forKey: .price)
            let dateString = try container.decode(String.self, forKey: .date)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: dateString) {
                self.date = date
            } else {
                self.date = Date.distantPast
            }
        }
    }
    
    enum DateRangeInput {
        case timeRange(TimeRange)
        case customRange(start: Date, end: Date)
    }
    
    // MARK: - API Requests (混合模式)

    // 1. 获取所有市值数据
    func fetchAllMarketCapData(from tableName: String) async -> [MarketCapInfo] {
        if isOfflineMode {
            return await fetchAllMarketCapDataLocal()
        }
        
        guard let url = URL(string: "\(serverBaseURL)/query/market_cap") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([MarketCapInfo].self, from: data)
        } catch {
            print("Network error fetching market cap: \(error)")
            return []
        }
    }
    
    // 【本地实现】
    private func fetchAllMarketCapDataLocal() async -> [MarketCapInfo] {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            var result: [MarketCapInfo] = []
            let query = "SELECT symbol, marketcap, pe_ratio, pb FROM \"MNSPP\""
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let symbol = String(cString: sqlite3_column_text(stmt, 0))
                    let marketCap = sqlite3_column_double(stmt, 1)
                    let peRatio = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
                    let pb = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
                    
                    result.append(MarketCapInfo(symbol: symbol, marketCap: marketCap, peRatio: peRatio, pb: pb))
                }
            }
            sqlite3_finalize(stmt)
            continuation.resume(returning: result)
        }
    }
    
    // 2. 获取最新成交量
    func fetchLatestVolume(forSymbol symbol: String, tableName: String) async -> Int64? {
        if isOfflineMode {
            return await fetchLatestVolumeLocal(forSymbol: symbol, tableName: tableName)
        }
        
        guard var components = URLComponents(string: "\(serverBaseURL)/query/latest_volume") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "table", value: tableName)
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode([String: Int64?].self, from: data)
            return response["volume"] ?? nil
        } catch { return nil }
    }
    
    // 【本地实现】
    private func fetchLatestVolumeLocal(forSymbol symbol: String, tableName: String) async -> Int64? {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            // 假设表结构有 volume 字段。如果部分表没有，SQLite 会报错，这里简单处理返回 nil
            let query = "SELECT volume FROM \"\(tableName)\" WHERE name = ? ORDER BY date DESC LIMIT 1"
            var stmt: OpaquePointer?
            var volume: Int64? = nil
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (symbol as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                        volume = sqlite3_column_int64(stmt, 0)
                    }
                }
            }
            sqlite3_finalize(stmt)
            continuation.resume(returning: volume)
        }
    }
    
    // 3. 获取历史数据
    func fetchHistoricalData(symbol: String, tableName: String, dateRange: DateRangeInput) async -> [PriceData] {
        if isOfflineMode {
            return await fetchHistoricalDataLocal(symbol: symbol, tableName: tableName, dateRange: dateRange)
        }
        
        guard var components = URLComponents(string: "\(serverBaseURL)/query/historical") else { return [] }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        let (startDate, endDate): (Date, Date) = {
            switch dateRange {
            case .timeRange(let timeRange):
                return (timeRange.startDate, Date())
            case .customRange(let start, let end):
                return (start, end)
            }
        }()
        
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "table", value: tableName),
            URLQueryItem(name: "start", value: formatter.string(from: startDate)),
            URLQueryItem(name: "end", value: formatter.string(from: endDate))
        ]
        
        guard let url = components.url else { return [] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([PriceData].self, from: data)
        } catch { return [] }
    }
    
    // 【本地实现】
    private func fetchHistoricalDataLocal(symbol: String, tableName: String, dateRange: DateRangeInput) async -> [PriceData] {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            var result: [PriceData] = []
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let (startDate, endDate): (Date, Date) = {
                switch dateRange {
                case .timeRange(let timeRange): return (timeRange.startDate, Date())
                case .customRange(let start, let end): return (start, end)
                }
            }()
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)
            
            // 尝试查询 volume，如果表没有 volume 列，这个查询会失败
            // 为了稳健性，可以先查 PRAGMA table_info，但为了性能和代码简洁，
            // 我们假设大部分表都有 volume，或者接受查询失败返回空数组（虽然不太好）
            // 更好的方式是：如果查询失败，尝试不带 volume 的查询。
            
            var query = "SELECT id, date, price, volume FROM \"\(tableName)\" WHERE name = ? AND date BETWEEN ? AND ? ORDER BY date ASC"
            var stmt: OpaquePointer?
            
            // 第一次尝试：带 Volume
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) != SQLITE_OK {
                // 如果失败（可能是没有 volume 列），尝试不带 Volume
                sqlite3_finalize(stmt)
                query = "SELECT id, date, price FROM \"\(tableName)\" WHERE name = ? AND date BETWEEN ? AND ? ORDER BY date ASC"
                sqlite3_prepare_v2(db, query, -1, &stmt, nil)
            }
            
            if stmt != nil {
                sqlite3_bind_text(stmt, 1, (symbol as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (startStr as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (endStr as NSString).utf8String, -1, nil)
                
                let colCount = sqlite3_column_count(stmt)
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = Int(sqlite3_column_int(stmt, 0))
                    let dateStr = String(cString: sqlite3_column_text(stmt, 1))
                    let price = sqlite3_column_double(stmt, 2)
                    var volume: Int64? = nil
                    
                    // 如果有第4列 (index 3)，则是 volume
                    if colCount > 3 && sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                        volume = sqlite3_column_int64(stmt, 3)
                    }
                    
                    if let date = formatter.date(from: dateStr) {
                        result.append(PriceData(id: id, date: date, price: price, volume: volume))
                    }
                }
            }
            sqlite3_finalize(stmt)
            continuation.resume(returning: result)
        }
    }
    
    // 4. 获取财报数据
    func fetchEarningData(forSymbol symbol: String) async -> [EarningData] {
        if isOfflineMode {
            return await fetchEarningDataLocal(forSymbol: symbol)
        }
        
        guard var components = URLComponents(string: "\(serverBaseURL)/query/earning") else { return [] }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([EarningData].self, from: data)
        } catch { return [] }
    }
    
    // 【本地实现】
    private func fetchEarningDataLocal(forSymbol symbol: String) async -> [EarningData] {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            var result: [EarningData] = []
            let query = "SELECT date, price FROM Earning WHERE name = ?"
            var stmt: OpaquePointer?
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (symbol as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let dateStr = String(cString: sqlite3_column_text(stmt, 0))
                    let price = sqlite3_column_double(stmt, 1)
                    if let date = formatter.date(from: dateStr) {
                        result.append(EarningData(date: date, price: price))
                    }
                }
            }
            sqlite3_finalize(stmt)
            continuation.resume(returning: result)
        }
    }
    
    // 5. 获取收盘价
    func fetchClosingPrice(forSymbol symbol: String, onDate date: Date, tableName: String) async -> Double? {
        if isOfflineMode {
            return await fetchClosingPriceLocal(forSymbol: symbol, onDate: date, tableName: tableName)
        }
        
        guard var components = URLComponents(string: "\(serverBaseURL)/query/closing_price") else { return nil }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "date", value: formatter.string(from: date)),
            URLQueryItem(name: "table", value: tableName)
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode([String: Double?].self, from: data)
            return response["price"] ?? nil
        } catch { return nil }
    }
    
    // 【本地实现】
    private func fetchClosingPriceLocal(forSymbol symbol: String, onDate date: Date, tableName: String) async -> Double? {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: date)
            let query = "SELECT price FROM \"\(tableName)\" WHERE name = ? AND date = ? LIMIT 1"
            var stmt: OpaquePointer?
            var price: Double? = nil
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (symbol as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (dateStr as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    price = sqlite3_column_double(stmt, 0)
                }
            }
            sqlite3_finalize(stmt)
            continuation.resume(returning: price)
        }
    }
    
    // 6. 获取期权汇总数据 (Single)
    func fetchOptionsSummary(forSymbol symbol: String) async -> OptionsSummary? {
        if isOfflineMode {
            return await fetchOptionsSummaryLocal(forSymbol: symbol)
        }
        
        guard var components = URLComponents(string: "\(serverBaseURL)/query/options_summary") else { return nil }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(OptionsSummary.self, from: data)
        } catch { return nil }
    }
    
    // 【本地实现】
    private func fetchOptionsSummaryLocal(forSymbol symbol: String) async -> OptionsSummary? {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            // 获取最近的两条记录
            let query = "SELECT call, put, price, change, iv, date FROM \"Options\" WHERE name = ? ORDER BY date DESC LIMIT 2"
            var stmt: OpaquePointer?
            var rows: [OptionsSummary] = []
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (symbol as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let call = String(cString: sqlite3_column_text(stmt, 0))
                    let put = String(cString: sqlite3_column_text(stmt, 1))
                    let price = sqlite3_column_double(stmt, 2)
                    let change = sqlite3_column_double(stmt, 3)
                    let iv = String(cString: sqlite3_column_text(stmt, 4))
                    let date = String(cString: sqlite3_column_text(stmt, 5))
                    
                    // 临时存入，prev 字段暂时为 nil
                    rows.append(OptionsSummary(call: call, put: put, price: price, change: change, iv: iv, date: date, prev_iv: nil, prev_price: nil, prev_change: nil))
                }
            }
            sqlite3_finalize(stmt)
            
            if let latest = rows.first {
                let prev = rows.count > 1 ? rows[1] : nil
                // 合并数据
                let finalSummary = OptionsSummary(
                    call: latest.call, put: latest.put, price: latest.price, change: latest.change, iv: latest.iv, date: latest.date,
                    prev_iv: prev?.iv, prev_price: prev?.price, prev_change: prev?.change
                )
                continuation.resume(returning: finalSummary)
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // 7. 批量获取期权汇总数据
    func fetchOptionsSummaries(forSymbols symbols: [String]) async -> [String: OptionsSummary] {
        if isOfflineMode {
            return await fetchOptionsSummariesLocal(forSymbols: symbols)
        }
        
        guard !symbols.isEmpty else { return [:] }
        guard var components = URLComponents(string: "\(serverBaseURL)/query/options_summary") else { return [:] }
        components.queryItems = [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
        guard let url = components.url else { return [:] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([String: OptionsSummary].self, from: data)
        } catch { return [:] }
    }
    
    // 【本地实现】批量获取
    private func fetchOptionsSummariesLocal(forSymbols symbols: [String]) async -> [String: OptionsSummary] {
        // 由于 SQLite 没有简单的 IN (?) 绑定数组的方法，且 symbols 数量通常不多 (50个以内)，
        // 我们循环调用 fetchOptionsSummaryLocal 即可。本地 DB 速度很快。
        var results: [String: OptionsSummary] = [:]
        for symbol in symbols {
            if let summary = await fetchOptionsSummaryLocal(forSymbol: symbol) {
                results[symbol] = summary
            }
        }
        return results
    }
    
    // 8. 获取期权历史价格数据
    func fetchOptionsHistory(forSymbol symbol: String) async -> [OptionHistoryItem] {
        if isOfflineMode {
            return await fetchOptionsHistoryLocal(forSymbol: symbol)
        }
        
        guard var components = URLComponents(string: "\(serverBaseURL)/query/options_price_history") else { return [] }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([OptionHistoryItem].self, from: data)
        } catch { return [] }
    }
    
    // 【本地实现】
    private func fetchOptionsHistoryLocal(forSymbol symbol: String) async -> [OptionHistoryItem] {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            var result: [OptionHistoryItem] = []
            let query = "SELECT date, price, iv FROM \"Options\" WHERE name = ? ORDER BY date DESC"
            var stmt: OpaquePointer?
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (symbol as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let dateStr = String(cString: sqlite3_column_text(stmt, 0))
                    let price = sqlite3_column_double(stmt, 1)
                    let ivStr = String(cString: sqlite3_column_text(stmt, 2))
                    
                    if let date = formatter.date(from: dateStr) {
                        // 使用自定义初始化器处理 IV 字符串解析
                        result.append(OptionHistoryItem(date: date, price: price, ivString: ivStr))
                    }
                }
            }
            sqlite3_finalize(stmt)
            continuation.resume(returning: result)
        }
    }
    
    // 9. 获取期权榜单 (Options Rank)
    // 这是一个复杂的查询，包含自连接和跨表查询
    func fetchOptionsRankData(limit: Double) async -> (rankUp: [OptionRankItem], rankDown: [OptionRankItem])? {
        // 注意：DataService 调用时会处理 JSON 解码，这里我们需要返回与 JSON 结构对应的对象，
        // 或者直接返回 DataService 需要的 ([Item], [Item]) 元组。
        // 为了保持接口一致，我们让 DBManager 直接返回元组。
        
        if isOfflineMode {
            return await fetchOptionsRankDataLocal(limit: limit)
        }
        
        // 在线模式：URL 请求返回的是 OptionRankResponse JSON
        // 由于 DataService 里的 fetchOptionsRankData 是自己发请求的，
        // 这里我们实际上是在为 DataService 提供底层支持。
        // 如果 DataService 直接调用了 DBManager，那么我们需要在这里发请求。
        // 假设 DataService 已经改成了调用 DBManager.shared.fetchOptionsRankData...
        
        let urlString = "\(serverBaseURL)/query/options_rank?limit=\(String(format: "%.0f", limit))"
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try JSONDecoder().decode(OptionRankResponse.self, from: data)
            return (result.rank_up, result.rank_down)
        } catch {
            print("Network error fetching options rank: \(error)")
            return nil
        }
    }
    
    // 【本地实现】期权榜单
    private func fetchOptionsRankDataLocal(limit: Double) async -> (rankUp: [OptionRankItem], rankDown: [OptionRankItem])? {
        return await withCheckedContinuation { continuation in
            dbLock.lock()
            defer { dbLock.unlock() }
            
            // 1. 获取最新的两个日期
            var dates: [String] = []
            let dateQuery = "SELECT DISTINCT date FROM \"Options\" ORDER BY date DESC LIMIT 2"
            var dateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, dateQuery, -1, &dateStmt, nil) == SQLITE_OK {
                while sqlite3_step(dateStmt) == SQLITE_ROW {
                    dates.append(String(cString: sqlite3_column_text(dateStmt, 0)))
                }
            }
            sqlite3_finalize(dateStmt)
            
            if dates.isEmpty {
                continuation.resume(returning: ([], []))
                return
            }
            
            let latestDate = dates[0]
            let prevDate = dates.count > 1 ? dates[1] : "" // 如果只有一个日期，prevDate 为空，Join 会失败但不会崩
            
            // 2. 执行主查询
            let sql = """
                SELECT
                    t1.name,
                    t1.iv as iv_latest,
                    t1.price as price_latest,
                    t1.change as change_latest,
                    t2.iv as iv_prev,
                    t2.price as price_prev,
                    t2.change as change_prev
                FROM "Options" t1
                LEFT JOIN "Options" t2 ON t1.name = t2.name AND t2.date = ?
                JOIN "MNSPP" m ON t1.name = m.symbol
                WHERE t1.date = ?
                  AND m.marketcap > ?
                  AND t1.iv IS NOT NULL
            """
            
            var stmt: OpaquePointer?
            
            // 辅助结构体用于排序
            struct SortableItem {
                let item: OptionRankItem
                let sortVal: Double
            }
            var sortableItems: [SortableItem] = []
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (prevDate as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (latestDate as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 3, limit)
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let symbol = String(cString: sqlite3_column_text(stmt, 0))
                    let ivLatest = String(cString: sqlite3_column_text(stmt, 1))
                    let priceLatest = sqlite3_column_double(stmt, 2)
                    let changeLatest = sqlite3_column_double(stmt, 3)
                    
                    let ivPrev = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
                    let pricePrev = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
                    let changePrev = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
                    
                    let item = OptionRankItem(
                        symbol: symbol,
                        iv: ivLatest,
                        prev_iv: ivPrev,
                        price: priceLatest,
                        change: changeLatest,
                        prev_price: pricePrev,
                        prev_change: changePrev
                    )
                    
                    // 计算排序值 (IV 去掉 %)
                    let cleanIv = ivLatest.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                    let sortVal = Double(cleanIv) ?? 0.0
                    
                    sortableItems.append(SortableItem(item: item, sortVal: sortVal))
                }
            }
            sqlite3_finalize(stmt)
            
            // 3. 排序 (降序)
            sortableItems.sort { $0.sortVal > $1.sortVal }
            let sortedResult = sortableItems.map { $0.item }
            
            if sortedResult.isEmpty {
                continuation.resume(returning: ([], []))
                return
            }
            
            // 4. 截取 Top 20 和 Bottom 20
            let rankUp = Array(sortedResult.prefix(20))
            let rankDown = Array(sortedResult.suffix(20).reversed()) // 最小的20个，倒序排列
            
            continuation.resume(returning: (rankUp, rankDown))
        }
    }
}
