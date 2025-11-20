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
                    
                    if symbolKey == "CrudeOil" || symbolKey == "Huangjin" || symbolKey == "Naturalgas" {
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
                    let topRowOrder = ["Strategy12", "Strategy34", "Today"]
                    let bottomRowNames = ["PE_valid", "PE_invalid", "Must"]
                    // 添加不需要显示的分组名称
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
                        
                        // MARK: - 最后渲染底部特定行 (Qualified, PE_valid, PE_invalid)
                        if !bottomSectors.isEmpty {
                            HStack(spacing: 12) {
                                ForEach(bottomSectors) { sector in
                                    NavigationLink {
                                        SectorDetailView(sector: sector)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                            SectorButtonView(sectorName: sector.name)
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
            Text("正在加载数据\n请稍候...\n如果长时间没有响应，请点击右上角刷新↻按钮重试...")
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct SectorButtonView: View {
    let sectorName: String
    
    private var displayName: String {
            switch sectorName {
            case "Strategy12":
                return "12"
            case "Strategy34":
                return "34"
            case "Basic_Materials":
                return "原材料"
            case "Commodities":
                return "大宗商品"
            case "Consumer_Cyclical":
                return "非必需"
            case "Consumer_Defensive":
                return "必需"
            case "Economic_All":
                return "全部Eco"
            case "Economics":
                return "Eco"
            case "Currencies":
                return "货币"
            case "Financial_Services":
                return "金融"
            case "Healthcare":
                return "健康"
            case "Technology":
                return "技术"
            case "Industrials":
                return "工业"
            case "Real_Estate":
                return "房地产"
            case "Communication_Services":
                return "通信服务"
            default:
                return sectorName.replacingOccurrences(of: "_", with: " ")
            }
        }
    
    var body: some View {
        Text(displayName)
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
            // ==================== 修改开始 ====================
            // 1. 触发财报趋势数据加载
            if let subSectors = sector.subSectors, !subSectors.isEmpty {
                // 如果有子分组，则为所有子分组中的 symbols 请求数据
                let allSymbols = subSectors.flatMap { $0.symbols.map { $0.symbol } }
                dataService.fetchEarningTrends(for: allSymbols)
            } else {
                // 如果没有子分组，则加载当前分组的 symbols
                loadSymbols()
                // 并为这些 symbols 请求数据
                dataService.fetchEarningTrends(for: symbols.map { $0.symbol })
            }
            // ==================== 修改结束 ====================
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

// ==================== 修改开始：整个 SymbolItemView 被重写 ====================
struct SymbolItemView: View {
    let symbol: IndicesSymbol
    let sectorName: String
    // 注入 DataService
    @EnvironmentObject private var dataService: DataService
    
    // 从 DataService 的缓存中获取当前 symbol 的财报趋势
    private var earningTrend: EarningTrend {
        dataService.earningTrends[symbol.symbol.uppercased()] ?? .insufficientData
    }
    
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
    
    private struct ParsedValue {
        let prefix: String?
        let percentage: String?
        let suffix: String?
    }
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: symbol.symbol, groupName: groupName)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // 应用财报趋势颜色
                    Text(symbol.symbol)
                        .font(.headline)
                        .foregroundColor(colorForEarningTrend(earningTrend))
                    
                    Spacer()
                    
                    // MARK: - 修改点：使用新的视图来显示分段颜色的值
                    compareValueView
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
        .onAppear {
            // 当视图出现时，如果缓存中没有数据，可以触发一次单独加载
            if earningTrend == .insufficientData {
                dataService.fetchEarningTrends(for: [symbol.symbol])
            }
        }
    }
    
    // MARK: - 新增视图构建器，用于渲染 compare_all 的值
    @ViewBuilder
    private var compareValueView: some View {
        let parsed = parseCompareValue(symbol.value)
        
        // 优先处理 "N/A" 的简单情况
        if parsed.prefix == nil && parsed.percentage == "N/A" && parsed.suffix == nil {
            Text("N/A")
                .foregroundColor(.gray)
                .fontWeight(.semibold)
        } else {
            // 使用 HStack 来组合三个文本部分
            HStack(spacing: 1) { // 使用较小的间距
                // 第一部分：前缀
                if let prefix = parsed.prefix {
                    Text(prefix)
                        .foregroundColor(.orange)
                }
                
                // 第二部分：百分比
                if let percentage = parsed.percentage {
                    Text(percentage)
                        .foregroundColor(colorForPercentage(percentage))
                }
                
                // 第三部分：后缀
                if let suffix = parsed.suffix, !suffix.isEmpty {
                    Text(suffix)
                        .foregroundColor(.gray)
                }
            }
            .fontWeight(.semibold)
        }
    }
    
    // MARK: - 新增的辅助函数
    
    /// 解析 compare_all 字符串 ("22后0.53%++") 为三部分
    private func parseCompareValue(_ value: String) -> ParsedValue {
        // 首先处理特殊值 "N/A"
        if value == "N/A" {
            return ParsedValue(prefix: nil, percentage: "N/A", suffix: nil)
        }

        // 正则表达式，用于匹配 "22后0.53%++" 或 "1.09%*+" 这样的格式
        // 捕获组 1: (\d+[前后未])?   - 可选的前缀，如 "22后"
        // 捕获组 2: (-?\d+\.?\d*%) - 百分比部分，如 "-1.05%"
        // 捕获组 3: (\S*)          - 可选的后缀，如 "++"
        let pattern = #"^(\d+[前后未])?(-?\d+\.?\d*%)(\S*)$"#
        
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, options: [], range: range) {
                
                // 提取第一部分（前缀）
                let prefixRange = match.range(at: 1)
                let prefix = prefixRange.location != NSNotFound ? (value as NSString).substring(with: prefixRange) : nil
                
                // 提取第二部分（百分比）
                let percentageRange = match.range(at: 2)
                let percentage = percentageRange.location != NSNotFound ? (value as NSString).substring(with: percentageRange) : nil
                
                // 提取第三部分（后缀）
                let suffixRange = match.range(at: 3)
                let suffix = suffixRange.location != NSNotFound ? (value as NSString).substring(with: suffixRange) : nil

                return ParsedValue(prefix: prefix, percentage: percentage, suffix: suffix)
            }
        }
        
        // 如果正则表达式不匹配，则将整个字符串作为 "percentage" 部分返回，以保证内容能够显示
        return ParsedValue(prefix: nil, percentage: value, suffix: nil)
    }

    /// 根据百分比字符串返回对应颜色
    private func colorForPercentage(_ percentageString: String?) -> Color {
        guard let percentageString = percentageString else { return .white }
        
        // 移除 '%' 符号并尝试转换为数字
        let numericString = percentageString.replacingOccurrences(of: "%", with: "")
        guard let number = Double(numericString) else {
            // 如果无法解析为数字（例如在正则不匹配的回退情况下），使用默认白色
            return .white
        }
        
        if number > 0 {
            return .red   // 正数：红色
        } else if number < 0 {
            return .green // 负数：绿色
        } else { // number is 0
            return .gray  // 零：灰色
        }
    }
    
    /// 根据 EarningTrend 返回颜色 (此函数保持不变)
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp:
            return .red
        case .negativeAndUp:
            return .purple
        case .positiveAndDown:
            return .cyan
        case .negativeAndDown:
            return .green
        case .insufficientData:
            return .primary // 默认颜色使用 .primary
        }
    }
    
    // 注意：旧的 colorForCompareValue 函数已被移除，不再需要
}
// ==================== 修改结束 ====================
