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

struct IndicesContentView: View {
    @EnvironmentObject var dataService: DataService
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        ScrollView {
            if let sectorsPanel = dataService.sectorsPanel {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 100, maximum: .infinity), spacing: 8)
                ], spacing: 8) {
                    ForEach(sectorsPanel.sectors, id: \.name) { sector in
                        NavigationLink {
                            SectorDetailView(sector: sector)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            SectorButtonView(sectorName: sector.name)
                        }
                    }
                }
                .padding()
            } else {
                if let error = dataService.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    LoadingView()
                }
            }
        }
        .alert(isPresented: Binding<Bool>(
            get: { dataService.errorMessage != nil },
            set: { _ in dataService.errorMessage = nil }
        )) {
            Alert(title: Text("错误"),
                  message: Text(dataService.errorMessage ?? "未知错误"),
                  dismissButton: .default(Text("好的")))
        }
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
    @EnvironmentObject var dataService: DataService
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

    func loadSymbols() {
        let compareMap = dataService.compareData
        self.symbols = sector.symbols.map { symbol in
            var updatedSymbol = symbol
            
            // 使用大写进行查找
            let value = compareMap[symbol.symbol.uppercased()] ??
                       compareMap[symbol.symbol] ??
                       "N/A"
            updatedSymbol.value = value
            
            // 尝试获取 description，如果有就添加，没有就保持为 nil
            if let description = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == symbol.symbol.uppercased() })?.tag ??
                dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == symbol.symbol.uppercased() })?.tag {
                updatedSymbol.tags = description
            }
            
            return updatedSymbol
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
