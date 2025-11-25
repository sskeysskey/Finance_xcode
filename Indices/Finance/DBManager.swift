import Foundation

// 移除 SQLite3 引用，改为纯网络请求
class DatabaseManager {
    static let shared = DatabaseManager()
    
    // 服务器地址，请确保与 UpdateManager 中一致
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    
    private init() {}
    
    // 移除 reconnectToLatestDatabase，因为不再持有本地连接
    func reconnectToLatestDatabase() {
        // 空实现，保持兼容性
    }
    
    // MARK: - Models
    
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
    
    struct EarningData: Codable {
        let date: Date
        let price: Double
        
        enum CodingKeys: String, CodingKey {
            case date, price
        }
        
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
    
    // MARK: - API Requests
    
    // 1. 获取所有市值数据 (Async)
    func fetchAllMarketCapData(from tableName: String) async -> [MarketCapInfo] {
        // tableName 参数在服务器端目前硬编码为 MNSPP，但保留参数以兼容
        guard let url = URL(string: "\(serverBaseURL)/query/market_cap") else { return [] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let results = try JSONDecoder().decode([MarketCapInfo].self, from: data)
            return results
        } catch {
            print("Network error fetching market cap: \(error)")
            return []
        }
    }
    
    // 2. 获取最新成交量 (Async)
    func fetchLatestVolume(forSymbol symbol: String, tableName: String) async -> Int64? {
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
        } catch {
            print("Network error fetching volume: \(error)")
            return nil
        }
    }
    
    // 3. 获取历史数据 (Async)
    func fetchHistoricalData(
        symbol: String,
        tableName: String,
        dateRange: DateRangeInput
    ) async -> [PriceData] {
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
            let results = try JSONDecoder().decode([PriceData].self, from: data)
            return results
        } catch {
            print("Network error fetching historical data: \(error)")
            return []
        }
    }
    
    // 4. 获取财报数据 (Async)
    func fetchEarningData(forSymbol symbol: String) async -> [EarningData] {
        guard var components = URLComponents(string: "\(serverBaseURL)/query/earning") else { return [] }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        
        guard let url = components.url else { return [] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let results = try JSONDecoder().decode([EarningData].self, from: data)
            return results
        } catch {
            print("Network error fetching earning data: \(error)")
            return []
        }
    }
    
    // 5. 获取收盘价 (Async)
    func fetchClosingPrice(forSymbol symbol: String, onDate date: Date, tableName: String) async -> Double? {
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
        } catch {
            print("Network error fetching closing price: \(error)")
            return nil
        }
    }
    
    // 6. 检查表是否有 Volume (Async - 实际逻辑在服务器端处理，这里仅保留接口或简化)
    // 由于服务器端的 query_historical 会自动处理 volume 字段，
    // 客户端其实不需要显式检查。为了兼容旧代码调用，可以返回 true (假设服务器处理) 或移除调用。
    // 这里我们简单返回 true，因为服务器 API 已经封装了 schema 检查。
    func checkIfTableHasVolume(tableName: String) async -> Bool {
        return true 
    }
}