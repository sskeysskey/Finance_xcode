import SwiftUI
import Foundation

// MARK: - Models

struct IndicesSector: Identifiable, Codable {
    var id: String { name }
    let name: String
    let symbols: [IndicesSymbol]
    var subSectors: [IndicesSector]? // 添加子分组
    
    private enum CodingKeys: String, CodingKey {
        case name, symbols
    }
    
    init(name: String, symbols: [IndicesSymbol], subSectors: [IndicesSector]? = nil) {
        self.name = name
        self.symbols = symbols
        self.subSectors = subSectors
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.symbols = try container.decode([IndicesSymbol].self, forKey: .symbols)
        self.subSectors = nil
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
        
        let orderedKeys = container.allKeys
            .map { $0.stringValue }
            .sorted()
        
        for key in orderedKeys {
            let codingKey = DynamicCodingKeys(stringValue: key)!
            let symbolsContainer = try container.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: codingKey)
            let orderedSymbolKeys = symbolsContainer.allKeys
                .map { $0.stringValue }
                .sorted()
            
            if key == "Economics" {
                // 原 Economics 分组特殊处理
                var groupedSymbols: [String: [IndicesSymbol]] = [:]
                
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let symbolValue = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    
                    // 按前缀数字分组
                    if let prefixNumber = symbolValue.split(separator: " ").first,
                       let _ = Int(prefixNumber) {
                        let group = String(prefixNumber)
                        let symbolName = symbolValue.split(separator: " ")[1]
                        let symbol = IndicesSymbol(
                            symbol: symbolKey,
                            name: String(symbolName),
                            value: "",
                            tags: nil
                        )
                        
                        if groupedSymbols[group] == nil {
                            groupedSymbols[group] = []
                        }
                        groupedSymbols[group]?.append(symbol)
                    }
                }
                
                let subSectors = groupedSymbols.sorted(by: { $0.key < $1.key }).map { group, groupSymbols in
                    IndicesSector(name: group, symbols: groupSymbols)
                }
                
                let economicsSector = IndicesSector(
                    name: key,
                    symbols: [],
                    subSectors: subSectors
                )
                sectors.append(economicsSector)
            } else if key == "Commodities" {
                // Commodities 分组特殊处理：添加“重要”子分组，把 CrudeOil 和 Huangjin 放到其中
                var importantSymbols: [IndicesSymbol] = []
                var normalSymbols: [IndicesSymbol] = []
                
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let symbolName = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let symbol = IndicesSymbol(symbol: symbolKey, name: symbolName, value: "", tags: nil)
                    
                    if symbolKey == "CrudeOil" || symbolKey == "Huangjin" {
                        importantSymbols.append(symbol)
                    } else {
                        normalSymbols.append(symbol)
                    }
                }
                
                if !importantSymbols.isEmpty {
                    var subSectors: [IndicesSector] = []
                    // “重要”子分组
                    subSectors.append(IndicesSector(name: "重要", symbols: importantSymbols))
                    // 若还有其他 symbol，则增加“其他”子分组
                    if !normalSymbols.isEmpty {
                        subSectors.append(IndicesSector(name: "其他", symbols: normalSymbols))
                    }
                    let commoditiesSector = IndicesSector(name: key, symbols: [], subSectors: subSectors)
                    sectors.append(commoditiesSector)
                } else if !normalSymbols.isEmpty {
                    // 如果没有重要 symbol，则常规处理
                    let commoditiesSector = IndicesSector(name: key, symbols: normalSymbols)
                    sectors.append(commoditiesSector)
                }
            } else if key == "Currencies" {
                // Currencies 分组特殊处理：添加“重要”子分组，把 USDJPY 和 USDCNY 和 DXY 和 CNYI 放到其中
                var importantSymbols: [IndicesSymbol] = []
                var normalSymbols: [IndicesSymbol] = []
                
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let symbolName = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let symbol = IndicesSymbol(symbol: symbolKey, name: symbolName, value: "", tags: nil)
                    
                    if symbolKey == "USDJPY" || symbolKey == "USDCNY" || symbolKey == "DXY" || symbolKey == "CNYI" || symbolKey == "JPYI" || symbolKey == "CHFI" || symbolKey == "EURI" || symbolKey == "CNYUSD" {
                        importantSymbols.append(symbol)
                    } else {
                        normalSymbols.append(symbol)
                    }
                }
                
                if !importantSymbols.isEmpty {
                    var subSectors: [IndicesSector] = []
                    // “重要”子分组
                    subSectors.append(IndicesSector(name: "重要", symbols: importantSymbols))
                    // 如果还有其他 symbol，则增加“其他”子分组
                    if !normalSymbols.isEmpty {
                        subSectors.append(IndicesSector(name: "其他", symbols: normalSymbols))
                    }
                    let currenciesSector = IndicesSector(name: key, symbols: [], subSectors: subSectors)
                    sectors.append(currenciesSector)
                } else if !normalSymbols.isEmpty {
                    // 如果没有特别的 symbol，则常规处理
                    let currenciesSector = IndicesSector(name: key, symbols: normalSymbols)
                    sectors.append(currenciesSector)
                }
            } else {
                // 其他分组常规处理
                var symbols: [IndicesSymbol] = []
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let symbolName = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    symbols.append(IndicesSymbol(
                        symbol: symbolKey,
                        name: symbolName,
                        value: "",
                        tags: nil
                    ))
                }
                
                if !symbols.isEmpty {
                    let sector = IndicesSector(name: key, symbols: symbols)
                    sectors.append(sector)
                }
            }
        }
        
        self.sectors = sectors
    }
}

// MARK: - Views

struct IndicesContentView: View {
    @EnvironmentObject var dataService: DataService
    
    // 自定义网格布局，用于中间部分
    private let gridLayout = [
        GridItem(.adaptive(minimum: 100, maximum: .infinity), spacing: 12)
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                // 检查 sectorsPanel 是否有数据
                if let sectors = dataService.sectorsPanel?.sectors {
                    
                    // 1. 定义分组和顺序 (这部分逻辑保持不变)
                    let topRowOrder = ["Currencies", "Commodities", "Bonds"]
                    let bottomRowNames = ["Qualified_Symbol", "Earning_Filter"]
                    let excludedNames = topRowOrder + bottomRowNames
                    
                    // 2. 根据定义的规则，过滤和排序数据 (这部分逻辑保持不变)
                    
                    // 原顶部数据
                    let topSectors = sectors
                        .filter { topRowOrder.contains($0.name) }
                        .sorted { sector1, sector2 in
                            guard let firstIndex = topRowOrder.firstIndex(of: sector1.name),
                                  let secondIndex = topRowOrder.firstIndex(of: sector2.name) else {
                                return false
                            }
                            return firstIndex < secondIndex
                        }
                    
                    // 底部数据
                    let bottomSectors = sectors.filter { bottomRowNames.contains($0.name) }
                    
                    // 中间数据
                    let middleSectors = sectors.filter { !excludedNames.contains($0.name) }
                    
                    // 3. 渲染UI：使用 VStack 垂直排列三个部分 (****** 这里是修改的核心 ******)
                    VStack(spacing: 20) {
                        
                        // MARK: - 首先渲染中间网格部分
                        if !middleSectors.isEmpty {
                            LazyVGrid(columns: gridLayout, spacing: 12) {
                                ForEach(middleSectors) { sector in
                                    NavigationLink {
                                        SectorDetailView(sector: sector)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        SectorButtonView(sectorName: sector.name)
                                    }
                                }
                            }
                        }
                        
                        // MARK: - 其次渲染原来的顶部特定行 (Bonds, Currencies, Commodities)
                        if !topSectors.isEmpty {
                            HStack(spacing: 12) {
                                ForEach(topSectors) { sector in
                                    NavigationLink {
                                        SectorDetailView(sector: sector)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        SectorButtonView(sectorName: sector.name)
                                    }
                                }
                            }
                        }
                        
                        // MARK: - 最后渲染底部特定行 (Qualified_Symbol, Earning_Filter)
                        if !bottomSectors.isEmpty {
                            HStack(spacing: 12) {
                                ForEach(bottomSectors) { sector in
                                    NavigationLink {
                                        SectorDetailView(sector: sector)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        // ******** 这里是修改的核心 ********
                                        if sector.name == "Qualified_Symbol" {
                                            // 如果是 "Qualified_Symbol"，使用新的绚丽按钮
                                            DazzlingSectorButtonView(sectorName: sector.name)
                                        } else {
                                            // 否则，使用原来的普通按钮
                                            SectorButtonView(sectorName: sector.name)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    
                } else {
                    // 处理加载中或错误状态
                    if let error = dataService.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .padding()
                    } else {
                        LoadingView()
                    }
                }
            }
//            .navigationTitle("Sectors") // 保持你的设计
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
        VStack(spacing: 16) {
            // 圆形进度指示器
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.5)
            
            // 独立出来的文字，居中对齐
            Text("服务器连接异常\n请点击右上角刷新↻按钮...")
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
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

// =================================================================
// MARK: - 绚丽夺目的特殊按钮视图 (新代码)
// =================================================================
struct DazzlingSectorButtonView: View {
    let sectorName: String
    
    // 状态变量，用于驱动动画
    @State private var isAnimating = false

    var body: some View {
        // 使用 TimelineView 来创建持续更新的动画，性能更好
        TimelineView(.animation) { timeline in
            // 计算当前时间，用于驱动渐变动画
            let time = timeline.date.timeIntervalSince1970
            
            HStack(spacing: 8) {
                // 添加一个星星图标
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                
                Text(sectorName.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            // 主要背景：一个旋转的角向渐变，创造流光效果
            .background(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .red, .orange, .yellow, .green, .blue, .purple, .red
                    ]),
                    center: .center,
                    angle: .degrees(time * 45) // 角度随时间变化
                )
            )
            .cornerRadius(10)
            // 光泽扫过效果
            .overlay(
                ShimmerEffect()
                    .cornerRadius(10)
                    .mask(
                        RoundedRectangle(cornerRadius: 10)
                    )
            )
            // 脉冲动画
            .scaleEffect(isAnimating ? 1.05 : 1.0)
            // 辉光效果
            .shadow(color: .yellow.opacity(0.8), radius: isAnimating ? 12 : 6, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.2), radius: 3, x: 2, y: 2)
            .onAppear {
                // 启动脉冲动画
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
        }
    }
}

// 光泽效果的辅助视图
struct ShimmerEffect: View {
    @State private var startPoint: UnitPoint = .init(x: -1.8, y: -1.2)
    @State private var endPoint: UnitPoint = .init(x: 0, y: -0.2)
    
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                .white.opacity(0.5),
                .white.opacity(0.2),
                .white.opacity(0.0)
            ]),
            startPoint: startPoint,
            endPoint: endPoint
        )
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                startPoint = .init(x: 1, y: 1.2)
                endPoint = .init(x: 2.8, y: 2.2)
            }
        }
    }
}

struct SectorDetailView: View {
    let sector: IndicesSector
    @EnvironmentObject var dataService: DataService
    @State private var symbols: [IndicesSymbol] = []
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    // 新增：用于控制搜索页面显示的状态变量
    @State private var showSearchView = false
    
    var body: some View {
        ScrollView {
            // 如果存在子分组则遍历每个子分组显示
            if let subSectors = sector.subSectors, !subSectors.isEmpty {
                ForEach(subSectors, id: \.name) { subSector in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(subSector.name)
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 16)
                        
                        LazyVStack(spacing: 0) {
                            ForEach(loadSymbolsForSubSector(subSector.symbols)) { symbol in
                                SymbolItemView(symbol: symbol, sectorName: sector.name)
                            }
                        }
                    }
                }
            } else {
                // 否则按原规则显示当前分组的 symbol 数组
                LazyVStack(spacing: 0) {
                    ForEach(symbols) { symbol in
                        SymbolItemView(symbol: symbol, sectorName: sector.name)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
            // 如果没有子分组，则加载 symbol 数组
            if sector.subSectors == nil || sector.subSectors!.isEmpty {
                loadSymbols()
            }
        }
        // 新增：在导航栏添加工具栏
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    // 点击按钮时，触发导航
                    showSearchView = true
                }) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        // 新增：定义导航的目标视图
        .navigationDestination(isPresented: $showSearchView) {
            // 传入 dataService 并设置 isSearchActive 为 true，让搜索框自动激活
            SearchView(isSearchActive: true, dataService: dataService)
        }
    }
    
    func loadSymbolsForSubSector(_ symbols: [IndicesSymbol]) -> [IndicesSymbol] {
        let compareMap = dataService.compareData
        return symbols.map { symbol in
            var updatedSymbol = symbol
            let value = compareMap[symbol.symbol.uppercased()] ??
                        compareMap[symbol.symbol] ??
                        "N/A"
            updatedSymbol.value = value
            
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
    
    func loadSymbols() {
        let compareMap = dataService.compareData
        self.symbols = sector.symbols.map { symbol in
            var updatedSymbol = symbol
            let value = compareMap[symbol.symbol.uppercased()] ??
                        compareMap[symbol.symbol] ??
                        "N/A"
            updatedSymbol.value = value
            
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

// 修改 SymbolItemView 只显示 symbol
struct SymbolItemView: View {
    let symbol: IndicesSymbol
    let sectorName: String
    // 注入 DataService
    @EnvironmentObject private var dataService: DataService
    
    private var fallbackGroupName: String {
        switch sectorName {
        case "ETFs_US":
            return "ETFs"
        case "Economic_All":
            return "Economics"
        default:
            return sectorName
        }
    }
    
    // 最终要传给 ChartView 的 groupName
    private var groupName: String {
        dataService.getCategory(for: symbol.symbol)
            ?? fallbackGroupName
    }
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: symbol.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 8) {
                // 只显示 symbol
                HStack {
                    Text(symbol.symbol)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(symbol.value)
                        .foregroundColor(getValueColor(value: symbol.value))
                        .fontWeight(.semibold)
                }
                
                // 保持 tags 显示
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
