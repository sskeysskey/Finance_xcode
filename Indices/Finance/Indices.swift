import SwiftUI
import Foundation

// MARK: - Models

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
        
        // 获取所有 sector 的 key，并按字母顺序排序
        let orderedKeys = container.allKeys
            .map { $0.stringValue }
            .sorted()
        
        // 按照固定顺序遍历 sector
        for key in orderedKeys {
            let codingKey = DynamicCodingKeys(stringValue: key)!
            let symbolsContainer = try container.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: codingKey)
            var symbols: [IndicesSymbol] = []
            
            // 按照固定顺序遍历 symbols
            let orderedSymbolKeys = symbolsContainer.allKeys
                .map { $0.stringValue }
                .sorted()
            
            for symbolKey in orderedSymbolKeys {
                let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                let symbolName = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                symbols.append(IndicesSymbol(symbol: symbolKey, name: symbolName, value: "", tags: nil))
            }
            
            // 只有当 symbols 不为空时才添加该 sector
            if !symbols.isEmpty {
                let sector = IndicesSector(name: key, symbols: symbols)
                sectors.append(sector)
            }
        }
        
        self.sectors = sectors
    }
}

// MARK: - Views

struct IndicesContentView: View {
    @EnvironmentObject var dataService: DataService
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    // 自定义网格布局
    private let gridLayout = [
        GridItem(.adaptive(minimum: 100, maximum: .infinity), spacing: 12)
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                if let sectorsPanel = dataService.sectorsPanel {
                    LazyVGrid(columns: gridLayout, spacing: 12) {
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
                            .padding()
                    } else {
                        LoadingView()
                    }
                }
            }
//            .navigationTitle("Sectors")
            .alert(isPresented: Binding<Bool>(
                get: { dataService.errorMessage != nil },
                set: { _ in dataService.errorMessage = nil }
            )) {
                Alert(
                    title: Text("错误"),
                    message: Text(dataService.errorMessage ?? "未知错误"),
                    dismissButton: .default(Text("好的"))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

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
            .font(.subheadline).bold()
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [.blue, .purple]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(10)
            .shadow(color: Color.black.opacity(0.15), radius: 3, x: 2, y: 2)
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
            LazyVStack(spacing: 0) {
                ForEach(symbols) { symbol in
                    SymbolItemView(symbol: symbol, sectorName: sector.name)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationBarTitle(
            sector.name.replacingOccurrences(of: "_", with: " "),
            displayMode: .inline
        )
        .alert(isPresented: $showError) {
            Alert(
                title: Text("错误"),
                message: Text(errorMessage),
                dismissButton: .default(Text("好的"))
            )
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
            
            // 尝试获取 description
            if let description = dataService.descriptionData?.stocks.first(where: {
                $0.symbol.uppercased() == symbol.symbol.uppercased()
            })?.tag ?? dataService.descriptionData?.etfs.first(where: {
                $0.symbol.uppercased() == symbol.symbol.uppercased()
            })?.tag {
                updatedSymbol.tags = description
            }
            
            return updatedSymbol
        }
    }
}

struct SymbolItemView: View {
    let symbol: IndicesSymbol
    let sectorName: String
    
    private var tableName: String {
        // 特殊处理 ETFs_US
        return sectorName == "ETFs_US" ? "ETFs" : sectorName
    }
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: symbol.symbol, groupName: tableName)) {
            VStack(alignment: .leading, spacing: 8) {
                // 第一行：symbol和value
                HStack {
                    Text("\(symbol.symbol) \(symbol.name)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(symbol.value)
                        .foregroundColor(getValueColor(value: symbol.value))
                        .fontWeight(.semibold)
                }
                
                // 第二行：tags
                if let tags = symbol.tags, !tags.isEmpty {
                    Text(tags.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 2, y: 2)
            )
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
            return .blue
        }
    }
}

// MARK: - 你自己的 DataService、ChartView 等辅助可能需要在其他文件中实现
// 这里只保留主界面及其相关的结构体和视图示例。

// 示例：如果你需要预览，可以使用下面的 PreviewProvider
// 需要注意的是，DataService、ChartView 等需要自行实现。
/*
struct IndicesContentView_Previews: PreviewProvider {
    static var previews: some View {
        IndicesContentView()
            .environmentObject(DataService())
    }
}
*/
