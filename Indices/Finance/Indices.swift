import SwiftUI
import Foundation
import Charts

// MARK: - Models

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

// MARK: - Helper: 交易日计算工具
struct TradingDateHelper {
    // 美股休市日列表 (2025-2026)
    // 格式: yyyy-MM-dd
    static let holidays: Set<String> = [
        // 2026
        "2026-01-01", // New Year's Day
        "2026-01-19", // Martin Luther King, Jr. Day
        "2026-02-16", // Washington's Birthday
        "2026-04-03", // Good Friday
        "2026-05-25", // Memorial Day
        "2026-06-19", // Juneteenth National Independence Day
        "2026-07-03", // Independence Day (Observed)
        "2026-09-07", // Labor Day
        "2026-11-26", // Thanksgiving Day
        "2026-12-25", // Christmas Day

        // --- 2027 ---
        "2027-01-01", // New Year's Day
        "2027-01-18", // Martin Luther King, Jr. Day
        "2027-02-15", // Washington's Birthday
        "2027-03-26", // Good Friday
        "2027-05-31", // Memorial Day
        "2027-06-18", // Juneteenth (Observed, June 19 is Sat)
        "2027-07-05", // Independence Day (Observed, July 4 is Sun)
        "2027-09-06", // Labor Day
        "2027-11-25", // Thanksgiving Day
        "2027-12-24", // Christmas Day (Observed, Dec 25 is Sat)

        // --- 2028 ---
        // 注意：2028年元旦是周六，根据NYSE规则，前一年(2027)12月31日不补休，照常开市。
        "2028-01-17", // Martin Luther King, Jr. Day
        "2028-02-21", // Washington's Birthday
        "2028-04-14", // Good Friday
        "2028-05-29", // Memorial Day
        "2028-06-19", // Juneteenth
        "2028-07-04", // Independence Day
        "2028-09-04", // Labor Day
        "2028-11-23", // Thanksgiving Day
        "2028-12-25", // Christmas Day

        // --- 2029 ---
        "2029-01-01", // New Year's Day
        "2029-01-15", // Martin Luther King, Jr. Day
        "2029-02-19", // Washington's Birthday
        "2029-03-30", // Good Friday
        "2029-05-28", // Memorial Day
        "2029-06-19", // Juneteenth
        "2029-07-04", // Independence Day
        "2029-09-03", // Labor Day
        "2029-11-22", // Thanksgiving Day
        "2029-12-25"  // Christmas Day
    ]
    
    /// 获取相对于当前时间(或指定时间)的"最近一个有效交易日"的日期字符串
    static func getLastExpectedTradingDateString(from date: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        // 1. 从"昨天"开始找
        // 为什么从昨天开始？因为如果是"今天"，盘中可能还没收盘数据，通常我们显示的是上一个收盘日的数据。
        var targetDate = calendar.date(byAdding: .day, value: -1, to: date)!
        
        // 2. 循环回推，直到找到一个既不是周末也不是节假日的日子
        while true {
            let dateStr = formatter.string(from: targetDate)
            
            // 检查周末 (1=Sunday, 7=Saturday)
            let weekday = calendar.component(.weekday, from: targetDate)
            let isWeekend = (weekday == 1 || weekday == 7)
            
            // 检查节假日
            let isHoliday = holidays.contains(dateStr)
            
            if !isWeekend && !isHoliday {
                return dateStr
            }
            
            // 如果是周末或节假日，继续往前推一天
            targetDate = calendar.date(byAdding: .day, value: -1, to: targetDate)!
        }
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
                // Commodities 分组特殊处理
                var importantSymbols: [IndicesSymbol] = []
                var normalSymbols: [IndicesSymbol] = []
                
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    
                    // 【逻辑 1】Commodities: 优先显示 Value，为空则显示 Key
                    let jsonValue = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let displayName = jsonValue.isEmpty ? symbolKey : jsonValue
                    
                    let symbol = IndicesSymbol(symbol: symbolKey, name: displayName, value: "", tags: nil)
                    
                    if symbolKey == "CrudeOil" || symbolKey == "Huangjin" || symbolKey == "Naturalgas" || symbolKey == "Silver" || symbolKey == "Copper"  {
                        importantSymbols.append(symbol)
                    } else {
                        normalSymbols.append(symbol)
                    }
                }
                
                if !importantSymbols.isEmpty {
                    var subSectors: [IndicesSector] = []
                    subSectors.append(IndicesSector(name: "重要", symbols: importantSymbols))
                    if !normalSymbols.isEmpty {
                        subSectors.append(IndicesSector(name: "其他", symbols: normalSymbols))
                    }
                    let commoditiesSector = IndicesSector(name: key, symbols: [], subSectors: subSectors)
                    sectors.append(commoditiesSector)
                } else if !normalSymbols.isEmpty {
                    let commoditiesSector = IndicesSector(name: key, symbols: normalSymbols)
                    sectors.append(commoditiesSector)
                }
            } else if key == "Currencies" {
                // Currencies 分组特殊处理
                var importantSymbols: [IndicesSymbol] = []
                var normalSymbols: [IndicesSymbol] = []
                let importantKeys = ["USDJPY", "USDCNY", "DXY", "CNYI", "JPYI", "CHFI", "EURI"]
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    
                    // 【逻辑 2】Currencies: 强制只显示 Symbol (Key)，忽略冒号后面的 Value
                    // 注意：必须执行 decode 以消耗掉这个 token，否则解析会出错，但我们不使用它的返回值
                    let _ = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let displayName = symbolKey // <--- 强制使用 Key
                    
                    let symbol = IndicesSymbol(symbol: symbolKey, name: displayName, value: "", tags: nil)
                    
                    if importantKeys.contains(symbolKey) {
                        importantSymbols.append(symbol)
                    } else {
                        normalSymbols.append(symbol)
                    }
                }
                if !importantSymbols.isEmpty {
                    var subSectors: [IndicesSector] = []
                    subSectors.append(IndicesSector(name: "重要", symbols: importantSymbols))
                    if !normalSymbols.isEmpty {
                        subSectors.append(IndicesSector(name: "其他", symbols: normalSymbols))
                    }
                    let currenciesSector = IndicesSector(name: key, symbols: [], subSectors: subSectors)
                    sectors.append(currenciesSector)
                } else if !normalSymbols.isEmpty {
                    let currenciesSector = IndicesSector(name: key, symbols: normalSymbols)
                    sectors.append(currenciesSector)
                }
            } else {
                // 其他分组常规处理 (包含 Strategy12, Strategy34, PE_Volume 等)
                var symbols: [IndicesSymbol] = []
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    
                    // 【逻辑 3】常规处理: 优先显示 Value，为空则显示 Key
                    let jsonValue = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    
                    // 如果 JSON 里的值是空的，我们默认让 name 等于 symbolKey，确保 UI 有内容显示
                    let displayName = jsonValue.isEmpty ? symbolKey : jsonValue
                    
                    // MARK: - 【修改点】针对 PE_Volume 进行过滤
                    // 如果是 PE_Volume 分组，且显示名称中不包含“听”，则跳过
                    if key == "PE_Volume" && !displayName.contains("听") {
                        continue
                    }
                    
                    symbols.append(IndicesSymbol(
                        symbol: symbolKey,   // 存储原始代码，如 "CRL"
                        name: displayName,   // 存储显示名，如 "CRL听"
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
        
        // 合并 Strategy12 和 Strategy34
        if let idx34 = sectors.firstIndex(where: { $0.name == "Strategy34" }) {
            let sector34 = sectors[idx34]
            
            if let idx12 = sectors.firstIndex(where: { $0.name == "Strategy12" }) {
                // 情况 A: 两个都有数据
                let sector12 = sectors[idx12]
                let mergedSymbols = sector12.symbols + sector34.symbols
                
                sectors[idx12] = IndicesSector(
                    name: "Strategy12",
                    symbols: mergedSymbols,
                    subSectors: sector12.subSectors
                )
                sectors.remove(at: idx34)
            } else {
                // 情况 B: 只有 Strategy34 有数据
                sectors[idx34] = IndicesSector(
                    name: "Strategy12",
                    symbols: sector34.symbols,
                    subSectors: sector34.subSectors
                )
            }
        }
        
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

    // 原代码: @State private var navigateToOptionRank = false 
    @State private var navigateToBigOrders = false 
    
    // 【新增】控制跳转到期权列表页面
    @State private var navigateToOptionsList = false
    
    // 定义分组名称
    private let economyGroupNames = Set(["Bonds", "Commodities", "Crypto", "Currencies", "ETFs", "Economic_All", "Economics", "Indices"])
    
    private let weekLowGroupNames = Set(["Basic_Materials", "Communication_Services", "Consumer_Cyclical", "Consumer_Defensive", "Energy", "Financial_Services", "Healthcare", "Industrials", "Real_Estate", "Technology", "Utilities"])

    // 【新增】需要使用历史分组展示的策略组名单
    private let historyBasedGroups: Set<String> = [
        "PE_Volume", "PE_Volume_up", "Short", "Short_W", "PE_Volume_high",
        "PE_W", "PE_Deeper", "OverSell_W", "PE_Deep", "PE_valid", "PE_invalid",
        "ETF_Volume_high", "ETF_Volume_low"
    ]
    
    // 【新增】用于导航到历史详情页
    @State private var selectedHistoryGroup: String?
    @State private var navigateToHistoryDetail = false
    
    // 【修改点 1】改为 3 列布局
    private let gridLayout = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            if let sectors = dataService.sectorsPanel?.sectors {
                
                // 1. 准备数据
                let economySectors = sectors.filter { economyGroupNames.contains($0.name) }
                let weekLowSectors = sectors.filter { weekLowGroupNames.contains($0.name) }
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        
                        // MARK: - 第一组：经济数据
                        VStack(alignment: .leading, spacing: 10) {
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
                                        CompactSectorCard(
                                            sectorName: sector.name,
                                            icon: getIcon(for: sector.name),
                                            baseColor: .purple
                                        )
                                    }
                                }
                                
                                // 【新增】期权按钮
                                Button {
                                    self.navigateToOptionsList = true
                                } label: {
                                    CompactSectorCard(
                                        sectorName: "期权异动",
                                        icon: "doc.text.magnifyingglass",
                                        baseColor: .purple,
                                        isSpecial: false, // 这里保持 false 或 true 均可，因为 customGradient 优先级更高
                                        customGradient: [.purple, .blue] // 【修改】传入以紫色为主的渐变
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        
                        // MARK: - 第二组：每日荐股
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(
                                title: "每日荐股",
                                icon: "star.fill",
                                color: .blue,
                                trailingText: dataService.introSymbolTimestamp.map { "Updated：\($0)" }
                            )
                            
                            LazyVGrid(columns: gridLayout, spacing: 10) {
                                // 【修改】将复杂的闭包逻辑提取到 view(for:sectors:) 函数中
                                ForEach(dataService.orderedStrategyGroups, id: \.self) { groupName in
                                    view(for: groupName, sectors: sectors, weekLowSectors: weekLowSectors)
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
                .navigationDestination(isPresented: $navigateToWeekLow) {
                    FiftyOneLowView(sectors: weekLowSectorsData)
                }
                .navigationDestination(isPresented: $navigateToTenYearHigh) {
                    TenYearHighView()
                }
                // 【修改点 2】修改导航目的地，指向 OptionBigOrdersView
                .navigationDestination(isPresented: $navigateToBigOrders) {
                    OptionBigOrdersView()
                }
                // 【新增】跳转到期权列表 (现在这部分代码在 Options.swift 中)
                .navigationDestination(isPresented: $navigateToOptionsList) {
                    OptionsListView()
                }
                .navigationDestination(isPresented: $navigateToHistoryDetail) {
                    if let groupName = selectedHistoryGroup {
                        StrategyHistoryDetailView(groupName: groupName)
                    }
                }
            } else {
                LoadingView()
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .alert(isPresented: Binding<Bool>(
            get: { dataService.errorMessage != nil },
            set: { _ in dataService.errorMessage = nil }
        )) {
            Alert(title: Text("错误"), message: Text(dataService.errorMessage ?? ""), dismissButton: .default(Text("好的")))
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    // 【新增】辅助 ViewBuilder，帮助编译器拆解复杂的 ForEach 内部逻辑
    @ViewBuilder
    private func view(for groupName: String, sectors: [IndicesSector], weekLowSectors: [IndicesSector]) -> some View {
        // 【修改】处理需要历史分组展示的策略组
        if historyBasedGroups.contains(groupName) {
            // ✅ 【新增】先检查该分组是否有实际数据，为空则不渲染任何内容
            if let groupData = dataService.earningHistoryData[groupName], !groupData.isEmpty {
                Button {
                    if usageManager.canProceed(authManager: authManager, action: .openSector) {
                        self.selectedHistoryGroup = groupName
                        self.navigateToHistoryDetail = true
                    } else {
                        self.showSubscriptionSheet = true
                    }
                } label: {
                    CompactSectorCard(
                        sectorName: groupName,
                        icon: getIcon(for: groupName),
                        baseColor: .indigo,
                        isSpecial: groupName == "PE_Volume" || groupName == "PE_Volume_up" || 
                                groupName == "Short" || groupName == "Short_W" || groupName == "PE_Volume_high",
                        customGradient: (groupName == "PE_Volume" || groupName == "PE_Volume_up" || 
                                        groupName == "Short" || groupName == "Short_W" || groupName == "PE_Volume_high") 
                                        ? [.blue, .purple] : nil
                    )
                }
            }
        // 如果 groupData 为 nil 或空，@ViewBuilder 自动返回 EmptyView，什么都不显示
        } else if groupName == "52NewLow" {
            Button {
                if usageManager.canProceed(authManager: authManager, action: .openSpecialList) {
                    self.weekLowSectorsData = weekLowSectors
                    self.navigateToWeekLow = true
                } else {
                    self.showSubscriptionSheet = true
                }
            } label: {
                CompactSectorCard(
                    sectorName: groupName,
                    icon: getIcon(for: groupName),
                    baseColor: .blue,
                    isSpecial: false
                )
            }
        } else if groupName == "TenYearHigh" {
            Button {
                if usageManager.canProceed(authManager: authManager, action: .openSpecialList) {
                    self.navigateToTenYearHigh = true
                } else {
                    self.showSubscriptionSheet = true
                }
            } label: {
                CompactSectorCard(
                    sectorName: groupName,
                    icon: getIcon(for: groupName),
                    baseColor: .blue,
                    isSpecial: false
                )
            }
            } else if groupName == "OptionBigOrder" {
                // 期权大单：蓝紫配色
                Button {
                    if usageManager.canProceed(authManager: authManager, action: .viewBigOrders) {
                        self.navigateToBigOrders = true
                    } else {
                        self.showSubscriptionSheet = true
                    }
                } label: {
                    CompactSectorCard(
                        sectorName: groupName, // <--- 改为使用变量 groupName (即 "OptionRank")
                        icon: getIcon(for: groupName),
                        baseColor: .indigo,
                        isSpecial: true,
                        customGradient: [.blue, .purple] // 【修改】传入以蓝色为主的渐变
                    )
                }
            // 【新增】专门处理 PE_Volume_up (放量反转)，开启特殊配色
            // 【修改点】将 PE_Volume (左侧) 和 PE_Volume_up (右侧) 合并处理，都使用蓝紫配色
            } else if (groupName == "PE_Volume" || groupName == "PE_Volume_up" || groupName == "ETF_Volume_high" || groupName == "ETF_Volume_low" || groupName == "PE_Volume_high"), 
                  let sector = sectors.first(where: { $0.name == groupName }) {
                Button {
                    handleSectorClick(sector) // 保持原有的点击跳转逻辑
                } label: {
                    CompactSectorCard(
                        sectorName: sector.name,
                        icon: getIcon(for: sector.name),
                        baseColor: .indigo,
                        isSpecial: true,
                        customGradient: [.blue, .purple] // 【修改】传入以蓝色为主的渐变
                    )
                }
        } else if let sector = sectors.first(where: { $0.name == groupName }) {
            // 其他普通板块
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
    }
    
    private func handleSectorClick(_ sector: IndicesSector) {
        if usageManager.canProceed(authManager: authManager, action: .openSector) {
            self.selectedSector = sector
            self.navigateToSector = true
        } else {
            self.showSubscriptionSheet = true
        }
    }
    
    private func getIcon(for name: String) -> String {
        switch name {
        case "Bonds": return "banknote"
        case "Commodities": return "drop.fill"
        case "Crypto": return "bitcoinsign.circle"
        case "Currencies": return "dollarsign.circle"
        case "ETFs": return "square.stack.3d.up"
        case "Indices": return "building.columns.fill"
        case "Technology": return "laptopcomputer"
        case "Energy": return "bolt.fill"
        case "Healthcare": return "heart.text.square"
        case "Real_Estate": return "house.fill"
        case "Today": return "sun.max.fill"
        case "Must": return "exclamationmark.shield.fill"
        case "Economics": return "chart.bar.xaxis"
        case "Economic_All": return "globe"
        case "Short_W": return "chart.line.downtrend.xyaxis"
        case "Short": return "arrow.down.circle"
        case "PE_Volume": return "7.circle"
        case "PE_Volume_up": return "arrow.up.circle"
        case "PE_Volume_high": return "arrow.up.circle"
        case "ETF_Volume_high": return "arrow.up.circle"
        case "ETF_Volume_low": return "arrow.down.circle"
        case "OverSell_W": return "flame.fill"
        case "PE_invalid": return "1.circle"
        case "PE_valid": return "2.circle"
        case "PE_W": return "4.circle"
        case "PE_Deeper": return "5.circle"
        case "PE_Deep": return "6.circle"
        case "Strategy12": return "3.circle"
        case "Strategy34": return "4.circle"
        case "52NewLow": return "arrow.down.right.circle.fill"
        case "TenYearHigh": return "arrow.up.right.circle.fill"
        case "OptionRank": return "chart.line.uptrend.xyaxis"
        case "OptionBigOrder": return "dollarsign.circle.fill" // 大单用美金图标
        default: return "chart.pie.fill"
        }
    }
}

// MARK: - 10年新高 专属页面
struct TenYearHighView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                    VStack(spacing: 20) {
                        Spacer()
                        Text("暂无数据或正在加载...")
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .frame(height: 200)
                } else {
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

// MARK: - 可折叠的分组视图
struct CollapsibleSectorSection: View {
    let sector: IndicesSector
    @State private var isExpanded: Bool = false
    @EnvironmentObject var dataService: DataService
    
    private var displayName: String {
        if let remoteName = dataService.groupDisplayMap[sector.name] {
            return remoteName
        }
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
            return sector.name.replacingOccurrences(of: "_", with: " ")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
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
            
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(sector.symbols) { symbol in
                        SymbolItemView(symbol: symbol, sectorName: sector.name)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

// MARK: - 52周新低 专属页面
struct FiftyOneLowView: View {
    let sectors: [IndicesSector]
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    @State private var showSubscriptionSheet = false
    
    var enrichedSectors: [IndicesSector] {
        let compareMap = dataService.compareData
        let tagMap = dataService.symbolTagsMap // 直接获取 O(1) 字典，不要每次滑动再重复建立！
        
        return sectors.map { sector in
            var newSector = sector
            newSector.symbols = sector.symbols.map { symbol in
                var updatedSymbol = symbol
                let upperSymbol = symbol.symbol.uppercased()
                
                updatedSymbol.value = compareMap[upperSymbol] ?? compareMap[symbol.symbol] ?? "N/A"
                updatedSymbol.tags = tagMap[upperSymbol]
                
                return updatedSymbol
            }
            return newSector
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                    LazyVStack(spacing: 16) {
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

// MARK: - UI 组件
struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color
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

struct CompactSectorCard: View {
    let sectorName: String
    let icon: String
    let baseColor: Color
    var isSpecial: Bool = false
    // 【新增】允许传入自定义渐变色数组
    var customGradient: [Color]? = nil
    
    @EnvironmentObject var dataService: DataService
    
    private var displayName: String {
        // 【修改前】
        // if isSpecial { return sectorName } 
        // 这一行导致了直接返回英文 Key，删掉或注释掉它
        
        // 【修改后】
        // 1. 优先查表 (version.json 中的 group_display_names)
        if let remoteName = dataService.groupDisplayMap[sectorName] {
            return remoteName
        }
        
        // 2. 查不到（比如"期权大单"这种手动写的中文，或者没有配置的key），就直接显示原名
        return sectorName.replacingOccurrences(of: "_", with: " ")
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.white)
            
            Text(displayName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 65)
        .background(
            LinearGradient(
                // 【修改】优先使用 customGradient，其次是 isSpecial 的默认紫蓝，最后是 baseColor
                gradient: Gradient(colors: customGradient ?? (isSpecial ? [.purple, .blue] : [baseColor.opacity(0.8), baseColor.opacity(0.5)])),
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
    @State private var showSearchView = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if sector.name == "ETFs" {
                    EtfSectionHeader(title: "Pinned", icon: "pin.fill", color: .blue)
                    LazyVStack(spacing: 0) {
                        ForEach(symbols) { symbol in
                            SymbolItemView(symbol: symbol, sectorName: sector.name)
                        }
                    }
                    if !dataService.etfTopGainers.isEmpty {
                        EtfSectionHeader(title: "Top 10 Gainers", icon: "chart.line.uptrend.xyaxis", color: .red)
                        LazyVStack(spacing: 0) {
                            ForEach(dataService.etfTopGainers) { symbol in
                                SymbolItemView(symbol: symbol, sectorName: sector.name)
                            }
                        }
                    }
                    if !dataService.etfTopLosers.isEmpty {
                        EtfSectionHeader(title: "Bottom 10 Losers", icon: "chart.line.downtrend.xyaxis", color: .green)
                        LazyVStack(spacing: 0) {
                            ForEach(dataService.etfTopLosers) { symbol in
                                SymbolItemView(symbol: symbol, sectorName: sector.name)
                            }
                        }
                    }
                } else {
                    if let subSectors = sector.subSectors, !subSectors.isEmpty {
                        ForEach(subSectors, id: \.name) { subSector in
                            VStack(alignment: .leading, spacing: 8) {
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
            // 原有的财报趋势加载
            if let subSectors = sector.subSectors, !subSectors.isEmpty {
                let allSymbols = subSectors.flatMap { $0.symbols.map { $0.symbol } }
                dataService.fetchEarningTrends(for: allSymbols)
                
                // 【新增】批量加载期权数据
                Task { await dataService.fetchOptionsMetrics(for: allSymbols) }
                
            } else {
                loadSymbols()
                let symbolList = symbols.map { $0.symbol }
                dataService.fetchEarningTrends(for: symbolList)
                
                // 【新增】批量加载期权数据
                Task { await dataService.fetchOptionsMetrics(for: symbolList) }
            }
            if sector.name == "ETFs" {
                let extraSymbols = dataService.etfTopGainers.map { $0.symbol } + dataService.etfTopLosers.map { $0.symbol }
                if !extraSymbols.isEmpty {
                    dataService.fetchEarningTrends(for: extraSymbols)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showSearchView = true
                }) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .navigationDestination(isPresented: $showSearchView) {
            SearchView(isSearchActive: true, dataService: dataService)
        }
    }
    
    func loadSymbolsForSubSector(_ symbols: [IndicesSymbol]) -> [IndicesSymbol] {
        let compareMap = dataService.compareData
        let tagMap = dataService.symbolTagsMap // 使用哈希表
        return symbols.map { symbol in
            var updatedSymbol = symbol
            let upperSymbol = symbol.symbol.uppercased()
            updatedSymbol.value = compareMap[upperSymbol] ?? compareMap[symbol.symbol] ?? "N/A"
            updatedSymbol.tags = tagMap[upperSymbol]
            return updatedSymbol
        }
    }
    
    func loadSymbols() {
        let compareMap = dataService.compareData
        let tagMap = dataService.symbolTagsMap // 使用哈希表
        self.symbols = sector.symbols.map { symbol in
            var updatedSymbol = symbol
            let upperSymbol = symbol.symbol.uppercased()
            updatedSymbol.value = compareMap[upperSymbol] ?? compareMap[symbol.symbol] ?? "N/A"
            updatedSymbol.tags = tagMap[upperSymbol]
            return updatedSymbol
        }
    }
}

struct EtfSectionHeader: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 38, height: 38)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(color)
            }
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Spacer()
            
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
        .padding(.top, 24)
        .padding(.bottom, 12)
        .padding(.horizontal, 4)
    }
}

struct SymbolItemView: View {
    let symbol: IndicesSymbol
    let sectorName: String
    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var isNavigationActive = false
    @State private var showSubscriptionSheet = false
    
    // 【修改】直接计算属性，不再需要 @State
    private var optionsMetrics: (iv: String, sum: String)? {
        dataService.optionsMetricsCache[symbol.symbol] // Key 可能是 uppercased 还是原样？
        // 建议统一一下，假设 Server 返回的和 symbol.symbol 一致。
        // 如果不一致，试一下 dataService.optionsMetricsCache[symbol.symbol.uppercased()]
    }
    
    // 【修改】判断是否显示
    private var showOptionsMetrics: Bool {
        return optionsMetrics != nil
    }
    
    // 【定义】不需要改变显示逻辑的“经济数据”板块列表
    private let economySectors: Set<String> = [
        "ETFs", "Bonds", "Crypto", "Indices", "Currencies",
        "Economics", "Economic_All", "Commodities"
    ]
    
    private var earningTrend: EarningTrend {
        dataService.earningTrends[symbol.symbol.uppercased()] ?? .insufficientData
    }
    
    private var fallbackGroupName: String {
        switch sectorName {
        case "Economic_All": return "Economics"
        default: return sectorName
        }
    }
    
    private var groupName: String {
        dataService.getCategory(for: symbol.symbol) ?? fallbackGroupName
    }
    
    // 用于原逻辑的解析结构
    private struct ParsedValue {
        let prefix: String?
        let percentage: String?
        let suffix: String?
    }
    
    var body: some View {
        Button(action: {
            if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                isNavigationActive = true
            } else {
                showSubscriptionSheet = true
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // 【修改点】：这里由原来的 symbol.symbol 改为 symbol.name
                    // 这样列表就会显示 "CRL听"
                    Text(symbol.name)
                        .font(.headline)
                        .foregroundColor(colorForEarningTrend(earningTrend))
                    
                    Spacer()
                    
                    // 【核心修改】根据板块名称决定显示哪种视图
                    rightSideInfoView
                }
                
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
        .navigationDestination(isPresented: $isNavigationActive) {
            ChartView(symbol: symbol.symbol, groupName: groupName)
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onAppear {
            // 将网络请求包装在少量延迟或轻量级检查中
            if earningTrend == .insufficientData {
                dataService.fetchEarningTrends(for: [symbol.symbol])
            }
        }
    }
    
    // MARK: - 视图选择器
    @ViewBuilder
    private var rightSideInfoView: some View {
        if economySectors.contains(sectorName) {
            // 1. 经济数据：保持原样 (Prefix + Percentage + Suffix)
            originalCompareView
        } else {
            // 2. 股票/策略：新样式 (Prefix Only + Option Data)
            stockOptionStyleView
        }
    }
    
    // MARK: - 样式 1: 原有的显示逻辑 (用于经济数据)
    @ViewBuilder
    private var originalCompareView: some View {
        let parsed = parseOriginalValue(symbol.value)
        if parsed.prefix == nil && parsed.percentage == "N/A" && parsed.suffix == nil {
            Text("N/A")
                .foregroundColor(.gray)
                .fontWeight(.semibold)
        } else {
            HStack(spacing: 1) {
                if let prefix = parsed.prefix {
                    Text(prefix).foregroundColor(.orange)
                }
                if let percentage = parsed.percentage {
                    Text(percentage).foregroundColor(colorForPercentage(percentage))
                }
                if let suffix = parsed.suffix, !suffix.isEmpty {
                    Text(suffix).foregroundColor(.gray)
                }
            }
            .font(.system(size: 16)) // 保持原有大小
            .fontWeight(.semibold)
        }
    }
    
    // MARK: - 样式 2: 新的显示逻辑 (用于股票)
    @ViewBuilder
    private var stockOptionStyleView: some View {
        HStack(spacing: 8) { // 数值间稍微隔开
            
            // 1. 只提取前缀 (03后, 02前, 未)
            // 无论有没有期权数据，只要有前缀就显示
            if let prefix = extractPrefixOnly(from: symbol.value) {
                Text(prefix)
                    .foregroundColor(.orange)
                    .fontWeight(.semibold)
            }
            
            // 2. 显示期权数据 (IV 和 Sum)
            // 只有当 showOptionsMetrics 为 true (意味着日期校验通过) 时才显示
            if showOptionsMetrics, let metrics = optionsMetrics {
                // IV
                Text(metrics.iv)
                    .foregroundColor(colorForValueString(metrics.iv))
                    .fontWeight(.semibold)
                
                // Sum (Price + Change)
                Text(metrics.sum)
                    .foregroundColor(colorForValueString(metrics.sum))
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 14)) // 字体稍小一点以适应更多数据
    }
    
    // MARK: - 逻辑处理方法
    
    // 解析原有的格式 (Prefix + Percentage + Suffix)
    private func parseOriginalValue(_ value: String) -> ParsedValue {
        if value == "N/A" {
            return ParsedValue(prefix: nil, percentage: "N/A", suffix: nil)
        }
        // 正则：(前缀)?(百分比)(后缀)?
        let pattern = #"^(\d+[前后未])?(-?\d+\.?\d*%)(\S*)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, options: [], range: range) {
                
                var prefix: String? = nil
                var percentage: String? = nil
                var suffix: String? = nil
                
                let prefixRange = match.range(at: 1)
                if prefixRange.location != NSNotFound {
                    prefix = (value as NSString).substring(with: prefixRange)
                }
                
                let percentageRange = match.range(at: 2)
                if percentageRange.location != NSNotFound {
                    percentage = (value as NSString).substring(with: percentageRange)
                }
                
                let suffixRange = match.range(at: 3)
                if suffixRange.location != NSNotFound {
                    suffix = (value as NSString).substring(with: suffixRange)
                }
                
                return ParsedValue(prefix: prefix, percentage: percentage, suffix: suffix)
            }
        }
        // 如果匹配失败，直接把整个 value 当作 percentage 显示（容错）
        return ParsedValue(prefix: nil, percentage: value, suffix: nil)
    }
    
    // 【新逻辑】只提取前缀
    private func extractPrefixOnly(from value: String) -> String? {
        if value == "N/A" { return nil }
        // 只要匹配开头是 "数字+前后未" 即可
        let pattern = #"^(\d+[前后未])"#
        
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, options: [], range: range) {
                if let r = Range(match.range(at: 1), in: value) {
                    return String(value[r])
                }
            }
        }
        return nil
    }
    
    // 颜色判断辅助
    private func colorForPercentage(_ percentageString: String?) -> Color {
        guard let percentageString = percentageString else { return .white }
        let numericString = percentageString.replacingOccurrences(of: "%", with: "")
        guard let number = Double(numericString) else { return .white }
        if number > 0 { return .red }
        else if number < 0 { return .green }
        else { return .gray }
    }
    
    private func colorForValueString(_ valueStr: String) -> Color {
        // 去除 %, 空格 等非数字字符进行判断
        let cleanStr = valueStr.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let val = Double(cleanStr) {
            if val > 0 { return .red }
            if val < 0 { return .green }
        }
        return .gray
    }
    
    // ... (保留 colorForEarningTrend 等其他辅助函数)
    
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp: return .red
        case .negativeAndUp: return .purple
        case .positiveAndDown: return .cyan
        case .negativeAndDown: return .green
        case .insufficientData: return .primary
        }
    }
}

// MARK: - 带日期折叠的策略详情页
struct StrategyHistoryDetailView: View {
    let groupName: String
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 【修改】改为计算属性初始化，确保第一个日期默认展开
    @State private var expandedDates: Set<String> = []
    @State private var hasInitialized: Bool = false // 【新增】用于标记是否已初始化
    @State private var showSubscriptionSheet = false
    
    // 【修改点 1】只获取最近的 5 个日期
    private var sortedDates: [String] {
        guard let datesMap = dataService.earningHistoryData[groupName] else { return [] }
        // 先排序，然后取前3个，最后转回 Array
        return Array(datesMap.keys.sorted(by: >).prefix(5))
    }
    
    // 显示名称
    // private var displayName: String {
    //     if let remoteName = dataService.groupDisplayMap[groupName] {
    //         return remoteName
    //     }
    //     return groupName.replacingOccurrences(of: "_", with: " ")
    // }

    // 【修改点】将显示名称逻辑改为直接返回原始英文名
    private var displayName: String {
        // 如果你希望完全保留原始字符（如 Short_W）：
        return groupName
    }
    
    var body: some View {
        ScrollView {
            // 1. 新增 ScrollViewReader
            ScrollViewReader { proxy in
                LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) { // 👈 开启吸顶功能
                    // 这里遍历的 sortedDates 已经是限制过数量的了
                    ForEach(Array(sortedDates.enumerated()), id: \.1) { index, dateStr in
                        if let symbols = dataService.earningHistoryData[groupName]?[dateStr] {
                            StrategyDateSectionView(
                                dateStr: dateStr,
                                symbols: symbols,
                                groupName: groupName,
                                // 【修改】统一使用 expandedDates 判断
                                isExpanded: expandedDates.contains(dateStr),
                                isFirstSection: index == 0,
                                onToggle: {
                                    withAnimation {
                                        if expandedDates.contains(dateStr) {
                                            // 2. 核心修复：折叠时自动定位回这个标题的顶部
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                withAnimation {
                                                    proxy.scrollTo(dateStr, anchor: .top)
                                                }
                                            }
                                            expandedDates.remove(dateStr)
                                        } else {
                                            expandedDates.insert(dateStr)
                                        }
                                    }
                                }
                            )
                            .id(dateStr) // 3. 绑定唯一 ID 锚点
                        }
                    }
                    
                    // 【可选】提示用户仅显示最近数据
                    if let datesMap = dataService.earningHistoryData[groupName], datesMap.keys.count > 5 {
                        Text("仅显示最近 5 个交易日数据")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onAppear {
            // 【新增】首次加载时，将第一个日期加入展开集合
            if !hasInitialized, let firstDate = sortedDates.first {
                expandedDates.insert(firstDate)
                hasInitialized = true
            }
            
            // ✅ 【关键改动】onAppear 只预加载 EarningTrends 和 OptionsMetrics，
            //    不再批量预加载 fetchHistoryPriceChanges，改为点开哪个日期才加载哪个
            let allSymbols = sortedDates.flatMap { date in
                (dataService.earningHistoryData[groupName]?[date] ?? []).map { $0.cleanTicker }
            }
            
            // 【核心修复 3】使用 Task 延迟 0.3 秒，避开刚进入页面时的动画和列表初始排版高峰期
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 等待 0.3 秒
                
                dataService.fetchEarningTrends(for: allSymbols)
                
                // 预加载期权指标
                await dataService.fetchOptionsMetrics(for: allSymbols)
                // ❌ 已移除：fetchHistoryPriceChanges 的批量预加载
            }
        }
    }
}

// MARK: - 策略页的日期折叠组件
struct StrategyDateSectionView: View {
    let dateStr: String
    let symbols: [String]
    let groupName: String
    let isExpanded: Bool
    let isFirstSection: Bool
    let onToggle: () -> Void
    
    // ✅ 【新增】懒加载状态，仅在首次展开时触发一次请求
    @State private var isFetchInitiated = false
    
    @EnvironmentObject var dataService: DataService
    
    var body: some View {
        Section {
            // 展开的内容（列表区域）
            if isExpanded {
                VStack(spacing: 0) { 
                    ForEach(symbols, id: \.self) { symbol in
                        StrategySymbolRow(
                            symbol: symbol, 
                            dateStr: dateStr, 
                            groupName: groupName,
                            isLatestDate: isFirstSection,
                            isFetchInitiated: isFetchInitiated  // ✅ 【新增】向下传递状态
                        )
                        
                        if symbol != symbols.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12) // 内容部分独立圆角
                .padding(.horizontal)
                .padding(.top, 4) // 和上面的 Header 拉开视觉层次
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .transition(.opacity)
            }
        } header: {
            // 头部点击区域（吸顶部分）
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .foregroundColor(isExpanded ? .blue : .gray)
                        .font(.system(size: 20))
                    
                    Text(dateStr)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // 最新日期标记
                    if isFirstSection {
                        Text("最新")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    Text("\(symbols.count) 个")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(UIColor.systemGray5))
                        .cornerRadius(8)
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
            }
            .cornerRadius(12) // 头部独立圆角
            .padding(.horizontal)
            .padding(.bottom, 2)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        // ✅ 【核心新增】展开时触发懒加载，只对旧日期（非最新）处理，且只触发一次
        .onChange(of: isExpanded) { newValue in
            guard newValue, !isFirstSection, !isFetchInitiated else { return }
            isFetchInitiated = true
            
            let cleanSymbols = symbols.map { $0.cleanTicker }
            let items = cleanSymbols.map { (symbol: $0, dateStr: dateStr) }
            dataService.fetchHistoryPriceChanges(for: items)
        }
    }
}

// MARK: - 策略页的 Symbol 行组件
struct StrategySymbolRow: View {
    let symbol: String
    let dateStr: String
    let groupName: String
    let isLatestDate: Bool
    let isFetchInitiated: Bool  // ✅ 【新增】由父组件传入，区分"未请求"和"请求中"
    let cleanSymbol: String
    
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var navigateToChart = false
    @State private var showSubscriptionSheet = false
    // ✅ 【新增】超时兜底：请求发出后 10 秒仍无数据，显示 "—"
    @State private var showDash = false

    private static let _prefixFullRegex = try? NSRegularExpression(pattern: #"^(\d{4}[前后未])"#)
    private static let _prefixDateRegex = try? NSRegularExpression(pattern: #"^(\d{4})"#)

    init(symbol: String, dateStr: String, groupName: String, isLatestDate: Bool, isFetchInitiated: Bool) {
        self.symbol = symbol
        self.dateStr = dateStr
        self.groupName = groupName
        self.isLatestDate = isLatestDate
        self.isFetchInitiated = isFetchInitiated
        self.cleanSymbol = symbol.cleanTicker
    }
    
    private var earningTrend: EarningTrend {
        dataService.earningTrends[cleanSymbol.uppercased()] ?? .insufficientData
    }
    
    private var optionsMetrics: (iv: String, sum: String)? {
        dataService.optionsMetricsCache[cleanSymbol.uppercased()]
    }
    
    // ✅ 【新增】从缓存读取涨跌幅，与 EarningHistoryView 保持一致
    private var priceChange: Double? {
        let key = "\(cleanSymbol.uppercased())_\(dateStr)"
        return dataService.historyPriceChanges[key]
    }
    
    var body: some View {
        // 【修改点 2】：直接在 body 中进行 O(1) 的同步计算，绝不触发重新渲染
        let sym = self.cleanSymbol.uppercased()
        
        // 1. 获取 Tags
        let rawTags = dataService.symbolTagsMap[sym] ?? []
        let computedTags = rawTags.map { ($0, dataService.tagWeightLookup[$0] ?? 1.0) }
        
        // 2. 获取分类
        let computedCategory = dataService.symbolCategoryMap[sym] ?? "Stocks"
        
        // 3. 计算前缀和颜色
        let prefixInfo = getPrefixAndColor(for: sym)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(symbol)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(colorForEarningTrend(earningTrend))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                
                Spacer()
                
                HStack(spacing: 8) {
                    if let prefix = prefixInfo.prefix {
                        Text(prefix)
                            .foregroundColor(prefixInfo.color)
                            .fontWeight(.semibold)
                    }
                    if let metrics = optionsMetrics {
                        Text(metrics.iv)
                            .foregroundColor(colorForValueString(metrics.iv))
                            .fontWeight(.semibold)
                        Text(metrics.sum)
                            .foregroundColor(colorForValueString(metrics.sum))
                            .fontWeight(.semibold)
                    }
                    if isLatestDate {
                        // 最新日期：显示 PE
                        if let capItem = dataService.marketCapData[sym],
                           let pe = capItem.peRatio {
                            Text("PE \(String(format: "%.1f", pe))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        // ✅ 【核心改动】旧日期：使用懒加载指示器，与 EarningHistoryView 完全一致
                        priceChangeIndicator
                    }
                }
                .font(.system(size: 14))
            }
            if !computedTags.isEmpty {
                FlowLayoutTags(tags: computedTags)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            if usageManager.canProceed(authManager: authManager, action: .viewChart) {
                navigateToChart = true
            } else {
                showSubscriptionSheet = true
            }
        }
        .navigationDestination(isPresented: $navigateToChart) {
            ChartView(symbol: cleanSymbol, groupName: computedCategory)
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        // ✅ 【新增】isFetchInitiated 变为 true 后，启动 10 秒超时计时器
        .task(id: isFetchInitiated) {
            guard isFetchInitiated, !isLatestDate else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if priceChange == nil {
                showDash = true
            }
        }
    }

    // ✅ 【新增】涨跌幅指示器，完全对齐 EarningHistoryView 的 priceChangeIndicator
    @ViewBuilder
    private var priceChangeIndicator: some View {
        if let change = priceChange {
            // 已有数据：显示带颜色的百分比
            let isPositive = change >= 0
            Text(String(format: "%+.1f%%", change * 100))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(isPositive ? .red : .green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((isPositive ? Color.red : Color.green).opacity(0.1))
                .cornerRadius(4)
        } else if showDash {
            // 超时或无数据：显示破折号
            Text("—")
                .font(.system(size: 14))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        } else if isFetchInitiated {
            // 请求已发出，等待结果：显示小转圈
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 22, height: 22)
        }
        // isFetchInitiated == false 时什么都不显示（尚未展开，不占位）
    }

    // MARK: - 辅助方法（保持不变）
    private func getPrefixAndColor(for sym: String) -> (prefix: String?, color: Color) {
        guard let value = dataService.compareData[sym] else {
            return (nil, .white)
        }
        
        var foundPrefix: String? = nil
        var foundColor: Color = .white
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        
        // 提取前缀
        if let re = StrategySymbolRow._prefixFullRegex,
           let m = re.firstMatch(in: value, options: [], range: nsRange),
           let r = Range(m.range(at: 1), in: value) {
            foundPrefix = String(value[r])
        }
        
        // 提取日期并计算颜色
        if let re = StrategySymbolRow._prefixDateRegex,
           let m = re.firstMatch(in: value, options: [], range: nsRange),
           let r = Range(m.range(at: 1), in: value) {
            
            let mdStr = String(value[r])
            let cal = Calendar.current
            let now = Date()
            let curM = cal.component(.month, from: now)
            let curD = cal.component(.day, from: now)
            
            let splitIdx = mdStr.index(mdStr.startIndex, offsetBy: 2)
            if let mo = Int(mdStr[..<splitIdx]),
               let dy = Int(mdStr[splitIdx...]) {
                foundColor = (mo > curM || (mo == curM && dy >= curD)) ? .orange : .white
            }
        }
        
        return (foundPrefix, foundColor)
    }

    // MARK: - 辅助方法（保持不变）
    private func colorForEarningTrend(_ trend: EarningTrend) -> Color {
        switch trend {
        case .positiveAndUp:    return .red
        case .negativeAndUp:    return .purple
        case .positiveAndDown:  return .cyan
        case .negativeAndDown:  return .green
        case .insufficientData: return .primary
        }
    }

    private func colorForValueString(_ valueStr: String) -> Color {
        let cleanStr = valueStr.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let val = Double(cleanStr) {
            if val > 0 { return .red }
            if val < 0 { return .green }
        }
        return .gray
    }
}

// MARK: - 字符串扩展：提取纯净的股票代码
extension String {
    // 【关键修复】静态属性：整个 App 生命周期只编译一次，消除每次渲染的编译开销
    private static let _cleanTickerRegex = try? NSRegularExpression(pattern: "^([A-Za-z0-9-]+)")

    var cleanTicker: String {
        guard let regex = String._cleanTickerRegex else { return self }
        let range = NSRange(location: 0, length: self.utf16.count)
        if let match = regex.firstMatch(in: self, options: [], range: range),
           let r = Range(match.range(at: 1), in: self) {
            return String(self[r])
        }
        return self
    }
}
