import SwiftUI
import Foundation

// MARK: - Models (保持不变)

struct IndicesSector: Identifiable, Codable {
    var id: String { name }
    let name: String
    // 【修改点 1】改为 var，以便后续注入数据
    var symbols: [IndicesSymbol]
    var subSectors: [IndicesSector]? 
    
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
                    
                    if symbolKey == "CrudeOil" || symbolKey == "Huangjin" || symbolKey == "Naturalgas" || symbolKey == "Silver" || symbolKey == "Copper"  {
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
                let importantKeys = ["USDJPY", "USDCNY", "DXY", "CNYI", "JPYI", "CHFI", "EURI"]
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let symbolName = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let symbol = IndicesSymbol(symbol: symbolKey, name: symbolName, value: "", tags: nil)
                    if importantKeys.contains(symbolKey) {
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
                
                // 注意：这里导致了 Strategy12 如果为空，就不会被加入 sectors 数组
                if !symbols.isEmpty {
                    let sector = IndicesSector(name: key, symbols: symbols)
                    sectors.append(sector)
                }
            }
        }
        
        // MARK: - 【修改后的逻辑】合并 Strategy12 和 Strategy34
        // 逻辑说明：
        // 1. 优先寻找 Strategy34，因为它可能包含数据。
        // 2. 如果找到了 Strategy34：
        //    a. 如果 Strategy12 也存在，则合并两者，保留 12 的名字。
        //    b. 如果 Strategy12 不存在 (因为JSON为空被过滤掉了)，则直接将 Strategy34 改名为 Strategy12。
        
        if let idx34 = sectors.firstIndex(where: { $0.name == "Strategy34" }) {
            let sector34 = sectors[idx34]
            
            if let idx12 = sectors.firstIndex(where: { $0.name == "Strategy12" }) {
                // 情况 A: 两个都有数据
                let sector12 = sectors[idx12]
                let mergedSymbols = sector12.symbols + sector34.symbols
                
                // 更新 Strategy12
                sectors[idx12] = IndicesSector(
                    name: "Strategy12",
                    symbols: mergedSymbols,
                    subSectors: sector12.subSectors
                )
                // 删除 Strategy34
                sectors.remove(at: idx34)
            } else {
                // 情况 B: 只有 Strategy34 有数据 (Strategy12 为空未被加载)
                // 直接将 Strategy34 重命名为 Strategy12，这样 UI 就能识别它了
                sectors[idx34] = IndicesSector(
                    name: "Strategy12", // 【关键】改名为 Strategy12
                    symbols: sector34.symbols,
                    subSectors: sector34.subSectors
                )
            }
        }
        // 如果只有 Strategy12 而没有 34，它本来就在 sectors 里，无需操作。
        
        self.sectors = sectors
    }
}

// MARK: - Views

struct IndicesContentView: View {
    @EnvironmentObject var dataService: DataService
    // 【新增】
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 【新增】用于程序化导航
    @State private var selectedSector: IndicesSector?
    @State private var navigateToSector = false
    @State private var showSubscriptionSheet = false
    
    // 新增：控制跳转到“52周新低”二级页面
    @State private var navigateToWeekLow = false
    // 存储传给二级页面的数据
    @State private var weekLowSectorsData: [IndicesSector] = []
    
    // 【新增】控制跳转到“10年新高”页面
    @State private var navigateToTenYearHigh = false
    
    // 【新增】控制跳转到期权列表页面
    @State private var navigateToOptionsList = false
    
    // 定义分组名称
    private let economyGroupNames = Set(["Bonds", "Commodities", "Crypto", "Currencies", "ETFs", "Economic_All", "Economics", "Indices"])
    
    private let weekLowGroupNames = Set(["Basic_Materials", "Communication_Services", "Consumer_Cyclical", "Consumer_Defensive", "Energy", "Financial_Services", "Healthcare", "Industrials", "Real_Estate", "Technology", "Utilities"])
    
    
    // 【修改点 1】改为 3 列布局，以适应图标样式但保持紧凑
    private let gridLayout = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    var body: some View {
        // 注意：这里不再包裹 NavigationStack，因为 Launcher 已经包了一层
        VStack(spacing: 0) {
            if let sectors = dataService.sectorsPanel?.sectors {
                
                // 1. 准备数据
                let economySectors = sectors.filter { economyGroupNames.contains($0.name) }
                let weekLowSectors = sectors.filter { weekLowGroupNames.contains($0.name) }
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        
                        // MARK: - 第一组：经济数据
                        VStack(alignment: .leading, spacing: 10) {
                            // 【修改】传入时间戳
                            SectionHeader(
                                title: "经济数据", 
                                icon: "globe.asia.australia.fill", 
                                color: .purple,
                                trailingText: dataService.ecoDataTimestamp.map { "Updated：\($0)" }
                            )
                            LazyVGrid(columns: gridLayout, spacing: 10) {
                                ForEach(economySectors) { sector in
                                    Button {
                                        handleSectorClick(sector)
                                    } label: {
                                        // 【修改点 2】使用新的 CompactSectorCard (带图标的紧凑卡片)
                                        CompactSectorCard(
                                            sectorName: sector.name,
                                            icon: getIcon(for: sector.name),
                                            baseColor: .purple
                                        )
                                    }
                                }
                                
                                // 【新增】期权按钮 (放在经济数据组末尾)
                                Button {
                                    // 直接跳转，无需检查权限
                                    self.navigateToOptionsList = true
                                } label: {
                                    CompactSectorCard(
                                        sectorName: "期权",
                                        icon: "doc.text.magnifyingglass", // 类似报表的图标
                                        baseColor: .purple,
                                        isSpecial: false // 保持组内一致
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        
                        // MARK: - 第二组：每日荐股 (在此处添加按钮)
                        VStack(alignment: .leading, spacing: 10) {
                            // 【修改】传入时间戳
                            SectionHeader(
                                title: "每日荐股", 
                                icon: "star.fill", 
                                color: .blue,
                                trailingText: dataService.introSymbolTimestamp.map { "Updated：\($0)" }
                            )
                            
                            LazyVGrid(columns: gridLayout, spacing: 10) {
                                
                                // 【核心修改】遍历服务器下发的 orderedStrategyGroups 字符串数组
                                // 这样顺序完全由 JSON 决定
                                ForEach(dataService.orderedStrategyGroups, id: \.self) { groupName in
                                    
                                    // 1. 判断是否是【52周新低】
                                    if groupName == "WeekLow" {
                                        Button {
                                            // 逻辑：使用 openSpecialList 权限，跳转 navigateToWeekLow
                                            if usageManager.canProceed(authManager: authManager, action: .openSpecialList) {
                                                self.weekLowSectorsData = weekLowSectors
                                                self.navigateToWeekLow = true
                                            } else {
                                                self.showSubscriptionSheet = true
                                            }
                                        } label: {
                                            CompactSectorCard(
                                                sectorName: groupName, // 会自动去 groupDisplayMap 找中文名
                                                icon: getIcon(for: groupName),
                                                baseColor: .blue,
                                                isSpecial: false
                                            )
                                        }
                                        
                                    // 2. 判断是否是【10年新高】
                                    } else if groupName == "TenYearHigh" {
                                        Button {
                                            // 逻辑：使用 openSpecialList 权限，跳转 navigateToTenYearHigh
                                            if usageManager.canProceed(authManager: authManager, action: .openSpecialList) {
                                                self.navigateToTenYearHigh = true
                                            } else {
                                                self.showSubscriptionSheet = true
                                            }
                                        } label: {
                                            CompactSectorCard(
                                                sectorName: groupName, // 会自动去 groupDisplayMap 找中文名
                                                icon: getIcon(for: groupName),
                                                baseColor: .blue,
                                                isSpecial: false
                                            )
                                        }
                                        
                                    // 3. 判断是否是【普通板块】(在 sectors 数据中存在)
                                    } else if let sector = sectors.first(where: { $0.name == groupName }) {
                                        // 渲染普通板块
                                        Button {
                                            handleSectorClick(sector)
                                        } label: {
                                            CompactSectorCard(
                                                sectorName: sector.name,
                                                icon: getIcon(for: sector.name),
                                                baseColor: .blue
                                            )
                                        }
                                    }
                                    
                                    // 4. 如果 JSON 里配置了名字，但本地 sectors 里找不到数据，也没有匹配到特殊逻辑
                                    // 则自动隐藏，不显示空白
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 10)
                }
                
                // 导航跳转逻辑
                .navigationDestination(isPresented: $navigateToSector) {
                    if let sector = selectedSector {
                        SectorDetailView(sector: sector)
                    }
                }
                // 【修改点 4】跳转到移植过来的 FiftyOneLowView
                .navigationDestination(isPresented: $navigateToWeekLow) {
                    FiftyOneLowView(sectors: weekLowSectorsData)
                }
                // 【新增】跳转到 10年新高 页面
                .navigationDestination(isPresented: $navigateToTenYearHigh) {
                    TenYearHighView()
                }
                // 【新增】跳转到期权列表
                .navigationDestination(isPresented: $navigateToOptionsList) {
                    OptionsListView()
                }
                
            } else {
                LoadingView()
            }
        }
        .background(Color(UIColor.systemGroupedBackground)) // 稍微灰一点的背景，突出卡片
        .alert(isPresented: Binding<Bool>(
            get: { dataService.errorMessage != nil },
            set: { _ in dataService.errorMessage = nil }
        )) {
            Alert(title: Text("错误"), message: Text(dataService.errorMessage ?? ""), dismissButton: .default(Text("好的")))
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func handleSectorClick(_ sector: IndicesSector) {
        // 使用 .openSector 行为类型
        if usageManager.canProceed(authManager: authManager, action: .openSector) {
            self.selectedSector = sector
            self.navigateToSector = true
        } else {
            self.showSubscriptionSheet = true
        }
    }
    
    // 【修改点 5】图标映射逻辑 (从 V2 移植)
    private func getIcon(for name: String) -> String {
        switch name {
        case "Bonds": return "banknote"
        case "Commodities": return "drop.fill"
        case "Crypto": return "bitcoinsign.circle"
        case "Currencies": return "dollarsign.circle"
        case "ETFs": return "square.stack.3d.up"
        case "Indices": return "building.columns.fill" // 【本次新增】交易所图标
        case "Technology": return "laptopcomputer"
        case "Energy": return "bolt.fill"
        case "Healthcare": return "heart.text.square"
        case "Real_Estate": return "house.fill"
        case "Today": return "sun.max.fill"
        case "Must": return "exclamationmark.shield.fill"
        case "Economics": return "chart.bar.xaxis"
        case "Economic_All": return "globe"
        case "Short_Shift": return "chart.line.downtrend.xyaxis"
        case "Short": return "arrow.down.circle"
        case "PE_Deep": return "arrow.up.circle"
        case "OverSell_W": return "flame.fill"
        case "PE_invalid": return "1.circle"
        case "PE_valid": return "2.circle"
        case "PE_W": return "4.circle"
        case "Strategy12": return "3.circle"
        case "Strategy34": return "4.circle"
        case "WeekLow": return "arrow.down.right.circle.fill"
        case "TenYearHigh": return "arrow.up.right.circle.fill"
        default: return "chart.pie.fill"
        }
    }
}

// MARK: - 【新增】界面 A：期权 Symbol 列表
struct OptionsListView: View {
    @EnvironmentObject var dataService: DataService
    // 【新增】引入权限环境
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 【新增】控制导航状态
    @State private var selectedSymbol: String?
    @State private var navigateToDetail = false
    @State private var showSubscriptionSheet = false
    
    var sortedSymbols: [String] {
        let allSymbols = dataService.optionsData.keys
        
        // 1. 筛选出没有市值数据的（或市值 <= 0），按字母顺序排序
        let noCapSymbols = allSymbols.filter { symbol in
            guard let item = dataService.marketCapData[symbol.uppercased()] else {
                return true // 字典里找不到，视为无市值
            }
            return item.rawMarketCap <= 0 // 或者是数据异常导致为0
        }.sorted()
        
        // 2. 筛选出有市值数据的，按 rawMarketCap 从大到小排序
        let hasCapSymbols = allSymbols.filter { symbol in
            guard let item = dataService.marketCapData[symbol.uppercased()] else {
                return false
            }
            return item.rawMarketCap > 0
        }.sorted { s1, s2 in
            let cap1 = dataService.marketCapData[s1.uppercased()]?.rawMarketCap ?? 0
            let cap2 = dataService.marketCapData[s2.uppercased()]?.rawMarketCap ?? 0
            return cap1 > cap2 // 降序：大 -> 小
        }
        
        // 3. 将无市值的放在前面，有市值的放在后面
        return noCapSymbols + hasCapSymbols
    }
    
    var body: some View {
        List {
            if sortedSymbols.isEmpty {
                Text("暂无期权异动数据")
                    .foregroundColor(.secondary)
            } else {
                ForEach(sortedSymbols, id: \.self) { symbol in
                    // 【修改】将 NavigationLink 改为 Button 以便拦截点击
                    Button {
                        // 【核心修改】点击具体 Symbol 时扣除 10 点
                        if usageManager.canProceed(authManager: authManager, action: .viewOptionsDetail) {
                            self.selectedSymbol = symbol
                            self.navigateToDetail = true
                        } else {
                            self.showSubscriptionSheet = true
                        }
                    } label: {
                        // 【修改点 1】获取该 symbol 的详细信息
                        let info = getInfo(for: symbol)
                        
                        HStack {
                            // 【修改点 2】使用 VStack 模仿搜索结果的布局
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    // 1. 代码
                                    Text(symbol)
                                        .font(.headline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    
                                    // 2. 名称 (如果有)
                                    if !info.name.isEmpty {
                                        Text(info.name)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                
                                // 3. 标签 (如果有，限制一行，超出显示...)
                                if !info.tags.isEmpty {
                                    Text(info.tags.joined(separator: ", "))
                                        .font(.caption) // 字体稍小
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)   // 限制一行
                                        .truncationMode(.tail) // 超出部分用省略号
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("期权异动")
        .navigationBarTitleDisplayMode(.inline)
        // 【新增】程序化导航
        .navigationDestination(isPresented: $navigateToDetail) {
            if let sym = selectedSymbol {
                OptionsDetailView(symbol: sym)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    // 【修改点 3】新增辅助函数：查找名称和标签
    private func getInfo(for symbol: String) -> (name: String, tags: [String]) {
        let upperSymbol = symbol.uppercased()
        
        // 1. 先在股票列表中查找
        if let stock = dataService.descriptionData?.stocks.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (stock.name, stock.tag)
        }
        
        // 2. 如果没找到，去 ETF 列表中查找
        if let etf = dataService.descriptionData?.etfs.first(where: { $0.symbol.uppercased() == upperSymbol }) {
            return (etf.name, etf.tag)
        }
        
        // 3. 实在找不到，返回空
        return ("", [])
    }
}

// MARK: - 【新增】界面 B：期权详情表格
struct OptionsDetailView: View {
    let symbol: String
    @EnvironmentObject var dataService: DataService
    
    // 0 = Calls, 1 = Puts
    @State private var selectedTypeIndex = 0
    
    // 控制跳转到 ChartView 的状态
    @State private var navigateToChart = false
    
    // 存储从服务器获取的汇总数据
    @State private var summaryCall: String = ""
    @State private var summaryPut: String = ""
    
    var filteredData: [OptionItem] {
        // ... (保持原有的筛选排序逻辑不变) ...
        guard let items = dataService.optionsData[symbol] else { return [] }
        
        let filtered = items.filter { item in
            let itemType = item.type.uppercased()
            if selectedTypeIndex == 0 {
                return itemType.contains("CALL") || itemType == "C"
            } else {
                return itemType.contains("PUT") || itemType == "P"
            }
        }
        
        return filtered.sorted { item1, item2 in
            let val1 = Double(item1.change) ?? 0
            let val2 = Double(item2.change) ?? 0
            return abs(val1) > abs(val2)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ... (保持原本的 Picker, Header, List 视图内容不变) ...
            
            // 1. 顶部切换开关
            Picker("Type", selection: $selectedTypeIndex) {
                // 如果有数据，显示 "Calls 4.74%"，否则只显示 "Calls"
                Text(summaryCall.isEmpty ? "Calls" : "Calls  \(summaryCall)").tag(0)
                
                // 如果有数据，显示 "Puts -3.26%"，否则只显示 "Puts"
                Text(summaryPut.isEmpty ? "Puts" : "Puts  \(summaryPut)").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .background(Color(UIColor.systemBackground))
            
            // 2. 表格头
            HStack(spacing: 4) {
                Text("Expiry").frame(maxWidth: .infinity, alignment: .leading)
                Text("Strike").frame(width: 55, alignment: .trailing)
                Text("Dist").frame(width: 55, alignment: .trailing)
                Text("Open Int").frame(width: 65, alignment: .trailing)
                Text("1-Day").frame(width: 60, alignment: .trailing)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(Color(UIColor.systemBackground))
            
            Divider()
            
            // 3. 数据列表 (保持不变)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("TopAnchor")
                        
                        if filteredData.isEmpty {
                            Text("暂无数据")
                                .foregroundColor(.secondary)
                                .padding(.top, 20)
                        } else {
                            ForEach(filteredData) { item in
                                HStack(spacing: 4) {
                                    OptionCellView(text: item.expiryDate, alignment: .leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    OptionCellView(text: item.strike, alignment: .trailing)
                                        .frame(width: 55, alignment: .trailing)
                                    OptionCellView(text: item.distance, alignment: .trailing)
                                        .frame(width: 55, alignment: .trailing)
                                        .font(.system(size: 12))
                                    OptionCellView(text: item.openInterest, alignment: .trailing)
                                        .frame(width: 65, alignment: .trailing)
                                    OptionCellView(text: item.change, alignment: .trailing)
                                        .frame(width: 60, alignment: .trailing)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal)
                                .background(Color(UIColor.systemBackground))
                                Divider().padding(.leading)
                            }
                        }
                    }
                }
                .onChange(of: selectedTypeIndex) { oldValue, newValue in
                    proxy.scrollTo("TopAnchor", anchor: .top)
                }
            }
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        // 【新增 2】添加导航栏右侧按钮
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    navigateToChart = true
                }) {
                    Text("切换到股价模式")
                        .font(.system(size: 13, weight: .bold)) // 字体稍微加粗
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue) // 彩色背景 (你可以改成 .purple 或 .orange)
                        .cornerRadius(14)       // 圆角胶囊样式
                        .shadow(color: Color.blue.opacity(0.3), radius: 2, x: 0, y: 1)
                }
            }
        }
        // 【新增 3】处理跳转逻辑
        .navigationDestination(isPresented: $navigateToChart) {
            // ChartView 需要 groupName 来查找数据库表
            // 我们尝试从 DataService 获取分类，如果找不到(比如纯期权标的)，给一个默认值 "US" 或 "Indices"
            let groupName = dataService.getCategory(for: symbol) ?? "US"
            
            ChartView(symbol: symbol, groupName: groupName)
        }
        // 【在此处添加代码】 👇
        .task {
            print("正在获取 \(symbol) 的期权汇总数据...") // 调试日志
            // 异步请求数据
            if let summary = await DatabaseManager.shared.fetchOptionsSummary(forSymbol: symbol) {
                // 回到主线程更新 UI
                await MainActor.run {
                    if let c = summary.call { self.summaryCall = c }
                    if let p = summary.put { self.summaryPut = p }
                }
            }
        }
    }
}

// MARK: - 【修改】辅助视图：处理带 "new" 的单元格显示
struct OptionCellView: View {
    let text: String
    var alignment: Alignment = .leading
    
    var isNew: Bool {
        text.lowercased().contains("new")
    }
    
    var displayString: String {
        if isNew {
            // 移除 "new" 并去除首尾空格
            return text.replacingOccurrences(of: "new", with: "", options: .caseInsensitive)
                       .trimmingCharacters(in: .whitespaces)
        }
        return text
    }
    
    var body: some View {
        Text(displayString)
            .font(.system(size: 14, weight: isNew ? .bold : .regular))
            // 如果含有 new，显示为橙红色，否则显示默认颜色
            .foregroundColor(isNew ? .orange : .primary)
            .multilineTextAlignment(textAlignment)
    }
    
    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        default: return .leading
        }
    }
}

// MARK: - 【新增】10年新高 专属页面
struct TenYearHighView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部说明
                HStack {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.red)
                    Text("这些股票处于10年高位，动能强劲。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                if dataService.tenYearHighSectors.isEmpty {
                    // 空状态处理
                    VStack(spacing: 20) {
                        Spacer()
                        Text("暂无数据或正在加载...")
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .frame(height: 200)
                } else {
                    // 遍历所有分组
                    LazyVStack(spacing: 16) {
                        ForEach(dataService.tenYearHighSectors) { sector in
                            CollapsibleSectorSection(sector: sector)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("10年新高")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
    }
}

// MARK: - 【重要】可折叠的分组视图 (复用组件)
struct CollapsibleSectorSection: View {
    let sector: IndicesSector
    // 默认展开
    @State private var isExpanded: Bool = false
    @EnvironmentObject var dataService: DataService // 新增
    
    // 【新增】名称映射逻辑
    private var displayName: String {
        // 优先用服务器给的中文名
        if let remoteName = dataService.groupDisplayMap[sector.name] {
            return remoteName
        }
        // 兜底：处理常见的行业分组
        switch sector.name {
        case "Basic_Materials": return "原材料&金属"
        case "Communication_Services": return "通信服务"
        case "Consumer_Cyclical": return "非必需消费品"
        case "Consumer_Defensive": return "必需消费品"
        case "Energy": return "能源行业"
        case "Financial_Services": return "金融服务"
        case "Healthcare": return "医疗保健"
        case "Industrials": return "工业领域"
        case "Real_Estate": return "房地产行业"
        case "Technology": return "技术与科技"
        case "Utilities": return "公共事业&基础设施"
        default:
            // 默认处理：将下划线替换为空格
            return sector.name.replacingOccurrences(of: "_", with: " ")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 头部 (点击可折叠/展开)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    // 【修改点】这里使用计算属性 displayName 代替原来的直接替换逻辑
                    Text(displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("(\(sector.symbols.count))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.gray)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
            }
            
            // 2. 内容区域 (Symbols)
            if isExpanded {
                VStack(spacing: 0) {
                    Divider() // 分隔线
                    
                    ForEach(sector.symbols) { symbol in
                        // 复用现有的 SymbolItemView
                        SymbolItemView(symbol: symbol, sectorName: sector.name)
                            .padding(.horizontal, 8) // 稍微内缩一点
                            .padding(.vertical, 2)
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cornerRadius(12)
        // 给整个卡片加阴影
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

// MARK: - 【修改】52周新低 专属页面
struct FiftyOneLowView: View {
    let sectors: [IndicesSector]
    
    // 1. 【新增】引入 DataService 以获取价格和标签数据
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var showSubscriptionSheet = false
    
    // 2. 【新增】计算属性：将原始 sectors 数据与 compareData/tags 数据合并
    var enrichedSectors: [IndicesSector] {
        let compareMap = dataService.compareData
        
        // 性能优化：将 Tags 预处理为字典，避免在循环中进行 O(N) 查找
        var tagMap: [String: [String]] = [:]
        if let stocks = dataService.descriptionData?.stocks {
            for stock in stocks {
                tagMap[stock.symbol.uppercased()] = stock.tag
            }
        }
        if let etfs = dataService.descriptionData?.etfs {
            for etf in etfs {
                tagMap[etf.symbol.uppercased()] = etf.tag
            }
        }
        
        return sectors.map { sector in
            var newSector = sector
            // 现在因为 IndicesSector.symbols 是 var，所以可以修改了
            newSector.symbols = sector.symbols.map { symbol in
                var updatedSymbol = symbol
                let upperSymbol = symbol.symbol.uppercased()
                
                // A. 注入 Value (价格/涨跌幅)
                // 优先使用大写 key 匹配，其次使用原始 key
                let value = compareMap[upperSymbol] ??
                            compareMap[symbol.symbol] ??
                            "N/A"
                updatedSymbol.value = value
                
                // B. 注入 Tags (标签) - 使用字典查找 O(1)
                updatedSymbol.tags = tagMap[upperSymbol]
                
                return updatedSymbol
            }
            return newSector
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部说明
                HStack {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .foregroundColor(.blue)
                    Text("这些板块处于52周低位，可能存在反弹机会。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                if sectors.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Text("暂无数据或正在加载...")
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .frame(height: 200)
                } else {
                    // 使用 LazyVStack 垂直排列可折叠分组
                    LazyVStack(spacing: 16) {
                        // 3. 【修改】这里遍历 enrichedSectors 而不是原始的 sectors
                        ForEach(enrichedSectors) { sector in
                            CollapsibleSectorSection(sector: sector)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("52周新低")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.5)
            
            Text("正在加载数据\n请稍候...\n如果长时间没有响应，请点击右上角刷新↻按钮重试...")
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - 新增：UI 组件

struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color
    // 【新增】可选的尾部文字
    var trailingText: String? = nil 
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Spacer()
            
            // 【新增】如果有文字则显示
            if let text = trailingText {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, 4)
    }
}

// 【新增组件】CompactSectorCard
// 专门为主页设计：结合了 V2 的渐变色和图标，但高度压缩，确保一屏能显示更多内容
struct CompactSectorCard: View {
    let sectorName: String
    let icon: String
    let baseColor: Color
    var isSpecial: Bool = false
    @EnvironmentObject var dataService: DataService // 确保能拿到 dataService

    private var displayName: String {
        if isSpecial { return sectorName }
        
        // 【核心逻辑】优先从服务器配置的字典里找
        if let remoteName = dataService.groupDisplayMap[sectorName] {
            return remoteName
        }
        
        // 兜底逻辑：如果服务器没配，则走原来的 switch 或 格式化
        switch sectorName {
        // 这里的硬编码可以逐渐删掉，只保留一些特殊的转换
        default: 
            return sectorName.replacingOccurrences(of: "_", with: " ")
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18)) // 图标大小适中
                .foregroundColor(.white)
            
            Text(displayName)
                .font(.system(size: 12, weight: .bold)) // 字体稍小
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 65) // 【关键】固定高度 65，比 V1 的 44 高一点以容纳图标，但远小于 V2 的 110
        .background(
            LinearGradient(
                // gradient: Gradient(colors: isSpecial ? [.orange, .red] : [baseColor.opacity(0.8), baseColor.opacity(0.5)]),
                gradient: Gradient(colors: isSpecial ? [.blue, .blue] : [baseColor.opacity(0.8), baseColor.opacity(0.5)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(12)
        .shadow(color: baseColor.opacity(0.2), radius: 2, x: 0, y: 2)
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
            VStack(alignment: .leading, spacing: 0) {
                
                // MARK: - 特殊处理 ETFs 分组
                if sector.name == "ETFs" {
                    // 1. Pinned (原 Sectors_panel 中的内容)
                    // 【修改】使用新的漂亮标题组件
                    EtfSectionHeader(title: "Pinned", icon: "pin.fill", color: .blue)
                    
                    LazyVStack(spacing: 0) {
                        ForEach(symbols) { symbol in
                            SymbolItemView(symbol: symbol, sectorName: sector.name)
                        }
                    }
                    
                    // 2. Top 10 (来自 CompareETFs.txt)
                    if !dataService.etfTopGainers.isEmpty {
                        // 【修改】红色上升主题
                        EtfSectionHeader(title: "Top 10 Gainers", icon: "chart.line.uptrend.xyaxis", color: .red)
                        
                        LazyVStack(spacing: 0) {
                            ForEach(dataService.etfTopGainers) { symbol in
                                SymbolItemView(symbol: symbol, sectorName: sector.name)
                            }
                        }
                    }
                    
                    // 3. Bottom 10 (来自 CompareETFs.txt)
                    if !dataService.etfTopLosers.isEmpty {
                        // 【修改】绿色下降主题
                        EtfSectionHeader(title: "Bottom 10 Losers", icon: "chart.line.downtrend.xyaxis", color: .green)
                        
                        LazyVStack(spacing: 0) {
                            ForEach(dataService.etfTopLosers) { symbol in
                                SymbolItemView(symbol: symbol, sectorName: sector.name)
                            }
                        }
                    }
                    
                } else {
                    // 如果存在子分组则遍历每个子分组显示
                    // MARK: - 常规分组处理 (保持不变)
                    if let subSectors = sector.subSectors, !subSectors.isEmpty {
                        ForEach(subSectors, id: \.name) { subSector in
                            VStack(alignment: .leading, spacing: 8) {
                                // 常规子分组标题也可以稍微美化一下，或者保持原样
                                Text(subSector.name)
                                    .font(.headline)
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .foregroundColor(.secondary)
                                
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
            
            // 【新增】如果是 ETFs 页面，额外触发 Top/Bottom 数据的财报趋势加载
            if sector.name == "ETFs" {
                let extraSymbols = dataService.etfTopGainers.map { $0.symbol } + dataService.etfTopLosers.map { $0.symbol }
                if !extraSymbols.isEmpty {
                    dataService.fetchEarningTrends(for: extraSymbols)
                }
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

// MARK: - 【新增】漂亮的 ETF 分组标题组件

struct EtfSectionHeader: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            // 1. 左侧图标：带圆形淡色背景
            ZStack {
                Circle()
                    .fill(color.opacity(0.15)) // 淡色背景
                    .frame(width: 38, height: 38)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(color)
            }
            
            // 2. 标题文字
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Spacer()
            
            // 3. 右侧装饰条：渐变胶囊形状
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 50, height: 4)
        }
        .padding(.top, 24) // 增加顶部间距，与上一组内容分开
        .padding(.bottom, 12) // 底部留白
        .padding(.horizontal, 4)
    }
}

struct SymbolItemView: View {
    let symbol: IndicesSymbol
    let sectorName: String
    // 注入 DataService
    @EnvironmentObject private var dataService: DataService
    
    // 【新增】引入权限管理
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 【新增】控制导航和弹窗
    @State private var isNavigationActive = false
    // 【修改】移除 showLoginSheet，因为点击条目时不再弹出登录
    // @State private var showLoginSheet = false
    @State private var showSubscriptionSheet = false
    
    // 从 DataService 的缓存中获取当前 symbol 的财报趋势
    private var earningTrend: EarningTrend {
        dataService.earningTrends[symbol.symbol.uppercased()] ?? .insufficientData
    }
    
    private var fallbackGroupName: String {
        switch sectorName {
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
        // 【修改】将 NavigationLink 改为 Button
        Button(action: {
            // 【修改】使用 .viewChart 行为类型
            if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                isNavigationActive = true
            } else {
                // 【核心修改】
                // 无论是否登录，只要超过限额，直接弹出订阅窗口。
                // 登录窗口仅由首页左上角菜单触发（如果未屏蔽）。
                showSubscriptionSheet = true
            }
        }) {
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
        // 【新增】程序化导航
        .navigationDestination(isPresented: $isNavigationActive) {
            ChartView(symbol: symbol.symbol, groupName: groupName)
        }
        // 【修改】移除了 .sheet(isPresented: $showLoginSheet) ...
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
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
}
