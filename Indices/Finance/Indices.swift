import SwiftUI
import Foundation

struct IndicesSector: Identifiable, Codable {
    var id: String { name }  // 使用name作为唯一标识符
    let name: String
    let symbols: [IndicesSymbol]
    
    private enum CodingKeys: String, CodingKey {
        case name, symbols
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.symbols = try container.decode([IndicesSymbol].self, forKey: .symbols)
    }
    
    init(name: String, symbols: [IndicesSymbol]) {
        self.name = name
        self.symbols = symbols
    }
}

struct IndicesSymbol: Identifiable, Codable {
    var id: String { symbol }  // 使用symbol作为唯一标识符
    let symbol: String
    let name: String
    var value: String
    var tags: [String]?
    
    private enum CodingKeys: String, CodingKey {
        case symbol, name, value, tags
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.symbol = try container.decode(String.self, forKey: .symbol)
        self.name = try container.decode(String.self, forKey: .name)
        self.value = try container.decode(String.self, forKey: .value)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags)
    }
    
    init(symbol: String, name: String, value: String, tags: [String]?) {
        self.symbol = symbol
        self.name = name
        self.value = value
        self.tags = tags
    }
}

struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int? { return nil }
    
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct SectorsPanel: Decodable {
    let sectors: [IndicesSector]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var sectors: [IndicesSector] = []
        
        // 获取所有sector的key，并按字母顺序排序
        let orderedKeys = container.allKeys
            .map { $0.stringValue }
            .sorted() // 如果需要按照其他规则排序，可以修改这里的排序逻辑
        
        // 按照固定顺序遍历
        for key in orderedKeys {
            let codingKey = DynamicCodingKeys(stringValue: key)!
            let symbolsContainer = try container.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: codingKey)
            var symbols: [IndicesSymbol] = []
            
            // 保存symbols的原始顺序
            let orderedSymbolKeys = symbolsContainer.allKeys
                .map { $0.stringValue }
                .sorted() // 保持symbol的排序一致性
            
            // 按照固定顺序遍历symbols
            for symbolKey in orderedSymbolKeys {
                let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                let symbolName = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                symbols.append(IndicesSymbol(symbol: symbolKey, name: symbolName, value: "", tags: nil))
            }
            
            // 只有当symbols不为空时才添加该sector
            if !symbols.isEmpty {
                let sector = IndicesSector(name: key, symbols: symbols)
                sectors.append(sector)
            }
        }
        
        self.sectors = sectors
    }
}

struct IndicesMarketCap: Codable {
    let symbol: String
    let marketCap: Double
    let peRatio: String
}

struct IndicesDescription: Codable {
    let stocks: [IndicesStock]
    let etfs: [IndicesETF]
}

struct IndicesStock: Codable {
    let symbol: String
    let tag: [String]
}

struct IndicesETF: Codable {
    let symbol: String
    let tag: [String]
}

struct IndicesDescriptionMap {
    let tag: [String]
}

struct IndicesContentView: View {
    @State private var isLoading = true
    @State private var sectors: [IndicesSector] = []
    @State private var marketCapData: [String: IndicesMarketCap] = [:]
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var descriptionMap: [String: IndicesDescriptionMap] = [:]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 100, maximum: .infinity), spacing: 8)
            ], spacing: 8) {
                ForEach(sectors, id: \.name) { sector in
                    NavigationLink {
                        SectorDetailView(sector: sector,
                                       marketCapData: $marketCapData,
                                       descriptionMap: $descriptionMap)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        SectorButtonView(sectorName: sector.name)
                    }
                }
            }
            .padding()
        }
        .overlay(Group {
            if isLoading {
                LoadingView()
            } else if sectors.isEmpty {
                Text("暂无可用数据。")
                    .foregroundColor(.gray)
            }
        })
        .alert(isPresented: $showError) {
            Alert(title: Text("错误"),
                  message: Text(errorMessage),
                  dismissButton: .default(Text("好的")))
        }
        .onAppear {
            loadData()
        }
    }
    
    // MARK: - 数据加载相关方法
    
    func loadData() {
        let dispatchGroup = DispatchGroup()
        
        dispatchGroup.enter()
        fetchJSON(filename: "Sectors_panel.json") { (sectorsPanel: SectorsPanel?, error) in
            if let sectorsPanel = sectorsPanel {
                self.sectors = sectorsPanel.sectors
            } else {
                self.errorMessage = error?.localizedDescription ?? "无法加载板块数据。"
                self.showError = true
            }
            dispatchGroup.leave()
        }
        
        dispatchGroup.enter()
        fetchMarketCap(filename: "marketcap_pe.txt") { data, error in
            if let data = data {
                self.marketCapData = data
            } else {
                self.errorMessage = error?.localizedDescription ?? "无法加载 MarketCap 数据。"
                self.showError = true
            }
            dispatchGroup.leave()
        }
        
        dispatchGroup.enter()
        fetchJSON(filename: "description.json") { (descriptionData: IndicesDescription?, error) in
            if let descriptionData = descriptionData {
                var map: [String: IndicesDescriptionMap] = [:]
                for stock in descriptionData.stocks {
                    map[stock.symbol.uppercased()] = IndicesDescriptionMap(tag: stock.tag)
                }
                for etf in descriptionData.etfs {
                    map[etf.symbol.uppercased()] = IndicesDescriptionMap(tag: etf.tag)
                }
                self.descriptionMap = map
            } else {
                self.errorMessage = error?.localizedDescription ?? "无法加载描述数据。"
                self.showError = true
            }
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) {
            self.isLoading = false
        }
    }
    
    // MARK: - 工具方法
    
    func fetchJSON<T: Decodable>(filename: String, completion: @escaping (T?, Error?) -> Void) {
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            completion(nil, NSError(domain: "Invalid file path.", code: 404, userInfo: nil))
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let decodedData = try decoder.decode(T.self, from: data)
            completion(decodedData, nil)
        } catch {
            completion(nil, error)
        }
    }
    
    func fetchMarketCap(filename: String, completion: @escaping ([String: IndicesMarketCap]?, Error?) -> Void) {
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            completion(nil, NSError(domain: "Invalid file path.", code: 404, userInfo: nil))
            return
        }
        
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let data = parseMarketCapData(text: text)
            completion(data, nil)
        } catch {
            completion(nil, error)
        }
    }
    
    func parseMarketCapData(text: String) -> [String: IndicesMarketCap] {
        var data: [String: IndicesMarketCap] = [:]
        let lines = text.split(separator: "\n")
        for line in lines {
            let parts = line.split(separator: ": ")
            if parts.count == 2 {
                let symbol = String(parts[0]).uppercased()
                let values = parts[1].split(separator: ", ")
                if values.count == 2 {
                    let marketCap = Double(values[0]) ?? 0.0
                    let peRatio = String(values[1])
                    data[symbol] = IndicesMarketCap(symbol: symbol, marketCap: marketCap, peRatio: peRatio)
                }
            }
        }
        return data
    }
}

// MARK: - 子视图组件

struct LoadingView: View {
    var body: some View {
        VStack {
            ProgressView("加载中，请稍候...")
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.5, anchor: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct SectorButtonView: View {
    let sectorName: String
    
    var body: some View {
        Text(sectorName.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 14))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue)
            .cornerRadius(8)
            .frame(minHeight: 44)
    }
}

struct SectorDetailView: View {
    let sector: IndicesSector
    @Binding var marketCapData: [String: IndicesMarketCap]
    @Binding var descriptionMap: [String: IndicesDescriptionMap]
    @State private var symbols: [IndicesSymbol] = []
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(symbols) { symbol in
                    SymbolItemView(symbol: symbol, sectorName: sector.name)
                }
            }
            .padding()
        }
        .navigationBarTitle(sector.name.replacingOccurrences(of: "_", with: " "),
                          displayMode: .inline)
        .alert(isPresented: $showError) {
            Alert(title: Text("错误"),
                  message: Text(errorMessage),
                  dismissButton: .default(Text("好的")))
        }
        .onAppear {
            loadSymbols()
        }
    }
    
    // 添加需要显示 description 的扇区列表
    private let sectorsWithDescription = [
        "Basic_Materials",
        "Communication_Services",
        "Consumer_Cyclical",
        "Energy",
        "Real_Estate",
        "Technology",
        "Utilities",
        "Consumer_Defensive",
        "Industrials",
        "Financial_Services",
        "Healthcare",
        "ETFs",
        "ETFs_US"
    ]
    
    func loadSymbols() {
        let compareMap = loadCompareAll()
        self.symbols = sector.symbols.map { symbol in
            var updatedSymbol = symbol
            
            // 更新 value - 使用原始大小写进行匹配
            if let value = compareMap[symbol.symbol] {
                updatedSymbol.value = value
            } else {
                updatedSymbol.value = "N/A"
            }
            
            // 只在指定的扇区中添加 description
            if sectorsWithDescription.contains(sector.name) {
                // 同样使用原始大小写
                if let description = descriptionMap[symbol.symbol] {
                    updatedSymbol.tags = description.tag
                }
            }
            
            return updatedSymbol
        }
    }

    func loadCompareAll() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "Compare_All.txt", withExtension: nil) else {
            self.errorMessage = "无法找到 compare_all.txt 文件。"
            self.showError = true
            return [:]
        }
        
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n")
            var map: [String: String] = [:]
            
            for line in lines {
                let parts = line.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    // 保持原始大小写
                    map[parts[0]] = parts[1]
                }
            }
            return map
        } catch {
            self.errorMessage = "无法读取 compare_all.txt 文件。"
            self.showError = true
            return [:]
        }
    }
}

// 优化 SymbolItemView 以更好地处理显示逻辑
struct SymbolItemView: View {
    let symbol: IndicesSymbol
    let sectorName: String  // 添加这一行来传递 sector 名称
    
    private var tableName: String {
        // 特殊处理 ETFs_US
        return sectorName == "ETFs_US" ? "ETFs" : sectorName
    }
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: symbol.symbol, groupName: tableName)) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(symbol.symbol) \(symbol.name)")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    if let tags = symbol.tags, !tags.isEmpty {
                        Text(tags.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Text(symbol.value)
                    .foregroundColor(getValueColor(value: symbol.value))
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .shadow(radius: 2)
            .padding(.vertical, 4)
        }
    }
    
    private func getValueColor(value: String) -> Color {
        if value.contains("+") {
            return .green
        } else if value.contains("-") {
            return .red
        } else if value == "N/A" {
            return .gray
        } else {
            return .green
        }
    }
}
