import SwiftUI
import Foundation
import Charts

// MARK: - Models

struct IndicesSector: Identifiable, Codable {
    var id: String { name }
    let name: String
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
    static let holidays: Set<String> = [
        // 2026
        "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03",
        "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07",
        "2026-11-26", "2026-12-25",
        // 2027
        "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26",
        "2027-05-31", "2027-06-18", "2027-07-05", "2027-09-06",
        "2027-11-25", "2027-12-24",
        // 2028
        "2028-01-17", "2028-02-21", "2028-04-14", "2028-05-29",
        "2028-06-19", "2028-07-04", "2028-09-04", "2028-11-23",
        "2028-12-25",
        // 2029
        "2029-01-01", "2029-01-15", "2029-02-19", "2029-03-30",
        "2029-05-28", "2029-06-19", "2029-07-04", "2029-09-03",
        "2029-11-22", "2029-12-25"
    ]
    
    static func getLastExpectedTradingDateString(from date: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var targetDate = calendar.date(byAdding: .day, value: -1, to: date)!
        while true {
            let dateStr = formatter.string(from: targetDate)
            let weekday = calendar.component(.weekday, from: targetDate)
            let isWeekend = (weekday == 1 || weekday == 7)
            let isHoliday = holidays.contains(dateStr)
            if !isWeekend && !isHoliday { return dateStr }
            targetDate = calendar.date(byAdding: .day, value: -1, to: targetDate)!
        }
    }
}

extension TradingDateHelper {
    static func getYesterday() -> Date {
        return Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    }

    static func getNextTradingDay() -> Date {
        let calendar = Calendar.current
        var nextDay = calendar.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        while true {
            let dateStr = formatter.string(from: nextDay)
            let weekday = calendar.component(.weekday, from: nextDay)
            let isWeekend = (weekday == 1 || weekday == 7)
            let isHoliday = holidays.contains(dateStr)
            if !isWeekend && !isHoliday { return nextDay }
            nextDay = calendar.date(byAdding: .day, value: 1, to: nextDay)!
        }
    }
}

struct IndicesSymbol: Identifiable, Codable {
    var id: String { symbol }
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
                var groupedSymbols: [String: [IndicesSymbol]] = [:]
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let symbolValue = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    if let prefixNumber = symbolValue.split(separator: " ").first,
                       let _ = Int(prefixNumber) {
                        let group = String(prefixNumber)
                        let symbolName = symbolValue.split(separator: " ")[1]
                        let symbol = IndicesSymbol(symbol: symbolKey, name: String(symbolName), value: "", tags: nil)
                        if groupedSymbols[group] == nil { groupedSymbols[group] = [] }
                        groupedSymbols[group]?.append(symbol)
                    }
                }
                let subSectors = groupedSymbols.sorted(by: { $0.key < $1.key }).map { group, groupSymbols in
                    IndicesSector(name: group, symbols: groupSymbols)
                }
                sectors.append(IndicesSector(name: key, symbols: [], subSectors: subSectors))
                
            } else if key == "Commodities" {
                var importantSymbols: [IndicesSymbol] = []
                var normalSymbols: [IndicesSymbol] = []
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let jsonValue = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let displayName = jsonValue.isEmpty ? symbolKey : jsonValue
                    let symbol = IndicesSymbol(symbol: symbolKey, name: displayName, value: "", tags: nil)
                    if symbolKey == "CrudeOil" || symbolKey == "Huangjin" || symbolKey == "Naturalgas" || symbolKey == "Silver" || symbolKey == "Copper" {
                        importantSymbols.append(symbol)
                    } else {
                        normalSymbols.append(symbol)
                    }
                }
                if !importantSymbols.isEmpty {
                    var subSectors: [IndicesSector] = []
                    subSectors.append(IndicesSector(name: "重要", symbols: importantSymbols))
                    if !normalSymbols.isEmpty { subSectors.append(IndicesSector(name: "其他", symbols: normalSymbols)) }
                    sectors.append(IndicesSector(name: key, symbols: [], subSectors: subSectors))
                } else if !normalSymbols.isEmpty {
                    sectors.append(IndicesSector(name: key, symbols: normalSymbols))
                }
                
            } else if key == "Currencies" {
                var importantSymbols: [IndicesSymbol] = []
                var normalSymbols: [IndicesSymbol] = []
                let importantKeys = ["USDJPY", "USDCNY", "DXY", "CNYI", "JPYI", "CHFI", "EURI"]
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let _ = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let symbol = IndicesSymbol(symbol: symbolKey, name: symbolKey, value: "", tags: nil)
                    if importantKeys.contains(symbolKey) { importantSymbols.append(symbol) }
                    else { normalSymbols.append(symbol) }
                }
                if !importantSymbols.isEmpty {
                    var subSectors: [IndicesSector] = []
                    subSectors.append(IndicesSector(name: "重要", symbols: importantSymbols))
                    if !normalSymbols.isEmpty { subSectors.append(IndicesSector(name: "其他", symbols: normalSymbols)) }
                    sectors.append(IndicesSector(name: key, symbols: [], subSectors: subSectors))
                } else if !normalSymbols.isEmpty {
                    sectors.append(IndicesSector(name: key, symbols: normalSymbols))
                }
                
            } else {
                var symbols: [IndicesSymbol] = []
                for symbolKey in orderedSymbolKeys {
                    let symbolCodingKey = DynamicCodingKeys(stringValue: symbolKey)!
                    let jsonValue = try symbolsContainer.decode(String.self, forKey: symbolCodingKey)
                    let displayName = jsonValue.isEmpty ? symbolKey : jsonValue
                    if key == "PE_Volume" && !displayName.contains("听") { continue }
                    symbols.append(IndicesSymbol(symbol: symbolKey, name: displayName, value: "", tags: nil))
                }
                if !symbols.isEmpty { sectors.append(IndicesSector(name: key, symbols: symbols)) }
            }
        }
        
        // 合并 Strategy12 和 Strategy34
        if let idx34 = sectors.firstIndex(where: { $0.name == "Strategy34" }) {
            let sector34 = sectors[idx34]
            if let idx12 = sectors.firstIndex(where: { $0.name == "Strategy12" }) {
                let sector12 = sectors[idx12]
                let mergedSymbols = sector12.symbols + sector34.symbols
                sectors[idx12] = IndicesSector(name: "Strategy12", symbols: mergedSymbols, subSectors: sector12.subSectors)
                sectors.remove(at: idx34)
            } else {
                sectors[idx34] = IndicesSector(name: "Strategy12", symbols: sector34.symbols, subSectors: sector34.subSectors)
            }
        }
        
        self.sectors = sectors
    }
}

// MARK: - Views

struct IndicesContentView: View {
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedSector: IndicesSector?
    @State private var navigateToSector = false
    @State private var showSubscriptionSheet = false
    @State private var navigateToWeekLow = false
    @State private var weekLowSectorsData: [IndicesSector] = []
    @State private var navigateToTenYearHigh = false
    @State private var navigateToBigOrders = false
    @State private var navigateToOptionsList = false
    
    // 【修改点】：从经济数据面板中彻底移除 "ETFs"
    private let economyGroupNames = Set(["Bonds", "Commodities", "Crypto", "Currencies", "Economic_All", "Economics", "Indices"])
    private let weekLowGroupNames = Set(["Basic_Materials", "Communication_Services", "Consumer_Cyclical", "Consumer_Defensive", "Energy", "Financial_Services", "Healthcare", "Industrials", "Real_Estate", "Technology", "Utilities"])
    private let historyBasedGroups: Set<String> = [
        "PE_Volume", "PE_Volume_up", "Short", "Short_W", "PE_Volume_high",
        "PE_W", "PE_Deeper", "OverSell_W", "PE_Deep", "PE_valid", "PE_invalid",
        "ETF_Volume_high", "ETF_Volume_low"
    ]
    
    @State private var selectedHistoryGroup: String?
    @State private var navigateToHistoryDetail = false
    
    private let gridLayout = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            if let sectors = dataService.sectorsPanel?.sectors {
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
                                    Button { handleSectorClick(sector) } label: {
                                        CompactSectorCard(sectorName: sector.name, icon: getIcon(for: sector.name), baseColor: .purple)
                                    }
                                }
                                // 期权异动
                                Button { self.navigateToOptionsList = true } label: {
                                    CompactSectorCard(sectorName: "期权异动", icon: "doc.text.magnifyingglass", baseColor: .purple, isSpecial: false, customGradient: [.purple, .blue])
                                }
                                // 期权大单 (移动到这里)
                                Button {
                                    if usageManager.canProceed(authManager: authManager, action: .viewBigOrders) {
                                        self.navigateToBigOrders = true
                                    } else {
                                        self.showSubscriptionSheet = true
                                    }
                                } label: {
                                    CompactSectorCard(sectorName: "OptionBigOrder", icon: getIcon(for: "OptionBigOrder"), baseColor: .indigo, isSpecial: true, customGradient: [.blue, .purple])
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
                                // 过滤掉 OptionBigOrder 避免重复显示
                                ForEach(dataService.orderedStrategyGroups.filter { $0 != "OptionBigOrder" }, id: \.self) { groupName in
                                    view(for: groupName, sectors: sectors, weekLowSectors: weekLowSectors)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 10)
                }
                .navigationDestination(isPresented: $navigateToSector) {
                    if let sector = selectedSector { SectorDetailView(sector: sector) }
                }
                .navigationDestination(isPresented: $navigateToWeekLow) {
                    FiftyOneLowView(sectors: weekLowSectorsData)
                }
                .navigationDestination(isPresented: $navigateToTenYearHigh) {
                    TenYearHighView()
                }
                .navigationDestination(isPresented: $navigateToBigOrders) {
                    OptionBigOrdersView()
                }
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
    
    @ViewBuilder
    private func view(for groupName: String, sectors: [IndicesSector], weekLowSectors: [IndicesSector]) -> some View {
        if historyBasedGroups.contains(groupName) {
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
        } else if groupName == "52NewLow" {
            Button {
                if usageManager.canProceed(authManager: authManager, action: .openSpecialList) {
                    self.weekLowSectorsData = weekLowSectors
                    self.navigateToWeekLow = true
                } else {
                    self.showSubscriptionSheet = true
                }
            } label: {
                CompactSectorCard(sectorName: groupName, icon: getIcon(for: groupName), baseColor: .blue, isSpecial: false)
            }
        } else if groupName == "TenYearHigh" {
            Button {
                if usageManager.canProceed(authManager: authManager, action: .openSpecialList) {
                    self.navigateToTenYearHigh = true
                } else {
                    self.showSubscriptionSheet = true
                }
            } label: {
                CompactSectorCard(sectorName: groupName, icon: getIcon(for: groupName), baseColor: .blue, isSpecial: false)
            }
        } else if (groupName == "PE_Volume" || groupName == "PE_Volume_up" || groupName == "ETF_Volume_high" || groupName == "ETF_Volume_low" || groupName == "PE_Volume_high"),
              let sector = sectors.first(where: { $0.name == groupName }) {
            Button { handleSectorClick(sector) } label: {
                CompactSectorCard(sectorName: sector.name, icon: getIcon(for: sector.name), baseColor: .indigo, isSpecial: true, customGradient: [.blue, .purple])
            }
        } else if let sector = sectors.first(where: { $0.name == groupName }) {
            Button { handleSectorClick(sector) } label: {
                CompactSectorCard(sectorName: sector.name, icon: getIcon(for: sector.name), baseColor: .blue)
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
        case "OptionBigOrder": return "dollarsign.circle.fill"
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
                    Image(systemName: "flame.fill").foregroundColor(.red)
                    Text("这些股票处于10年高位，动能强劲。")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                if dataService.tenYearHighSectors.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Text("暂无数据或正在加载...").foregroundColor(.gray)
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
        if let remoteName = dataService.groupDisplayMap[sector.name] { return remoteName }
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
        default: return sector.name.replacingOccurrences(of: "_", with: " ")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }) {
                HStack {
                    Text(displayName).font(.headline).foregroundColor(.primary)
                    Text("(\(sector.symbols.count))").font(.subheadline).foregroundColor(.secondary)
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
        let tagMap = dataService.symbolTagsMap
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
                    Image(systemName: "chart.line.downtrend.xyaxis").foregroundColor(.blue)
                    Text("这些板块处于52周低位，可能存在反弹机会。")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                if sectors.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Text("暂无数据或正在加载...").foregroundColor(.gray)
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
            Image(systemName: icon).foregroundColor(color)
            Text(title).font(.headline).fontWeight(.bold).foregroundColor(.primary)
            Spacer()
            if let text = trailingText {
                Text(text).font(.caption).foregroundColor(.secondary).padding(.trailing, 8)
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
    var customGradient: [Color]? = nil
    
    @EnvironmentObject var dataService: DataService
    
    private var displayName: String {
        if let remoteName = dataService.groupDisplayMap[sectorName] { return remoteName }
        return sectorName.replacingOccurrences(of: "_", with: " ")
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(.white)
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
                gradient: Gradient(colors: customGradient ?? (isSpecial ? [.purple, .blue] : [baseColor.opacity(0.8), baseColor.opacity(0.5)])),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
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
                // 【修改点】：移除了 sector.name == "ETFs" 的特殊处理
                if let subSectors = sector.subSectors, !subSectors.isEmpty {
                    ForEach(subSectors, id: \.name) { subSector in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(subSector.name)
                                .font(.headline).padding(.horizontal).padding(.top, 16).foregroundColor(.secondary)
                            LazyVStack(spacing: 0) {
                                ForEach(loadSymbolsForSubSector(subSector.symbols)) { symbol in
                                    SymbolItemView(symbol: symbol, sectorName: sector.name)
                                }
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(symbols) { symbol in SymbolItemView(symbol: symbol, sectorName: sector.name) }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .navigationBarTitle(sector.name.replacingOccurrences(of: "_", with: " "), displayMode: .inline)
        .alert(isPresented: $showError) {
            Alert(title: Text("错误"), message: Text(errorMessage), dismissButton: .default(Text("好的")))
        }
        .onAppear {
            if let subSectors = sector.subSectors, !subSectors.isEmpty {
                let allSymbols = subSectors.flatMap { $0.symbols.map { $0.symbol } }
                dataService.fetchEarningTrends(for: allSymbols)
                Task { await dataService.fetchOptionsMetrics(for: allSymbols) }
            } else {
                loadSymbols()
                let symbolList = symbols.map { $0.symbol }
                dataService.fetchEarningTrends(for: symbolList)
                Task { await dataService.fetchOptionsMetrics(for: symbolList) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showSearchView = true }) {
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
        let tagMap = dataService.symbolTagsMap
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
        let tagMap = dataService.symbolTagsMap
        self.symbols = sector.symbols.map { symbol in
            var updatedSymbol = symbol
            let upperSymbol = symbol.symbol.uppercased()
            updatedSymbol.value = compareMap[upperSymbol] ?? compareMap[symbol.symbol] ?? "N/A"
            updatedSymbol.tags = tagMap[upperSymbol]
            return updatedSymbol
        }
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
    
    private var optionsMetrics: (iv: String, sum: String)? {
        dataService.optionsMetricsCache[symbol.symbol]
    }
    
    private var showOptionsMetrics: Bool { return optionsMetrics != nil }
    private static let _datePatternRegex = try? NSRegularExpression(pattern: #"^(\d+)([前后未])"#)
    
    private let economySectors: Set<String> = [
        "Bonds", "Crypto", "Indices", "Currencies",
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
                    Text(symbol.name)
                        .font(.headline)
                        .foregroundColor(colorForEarningTrend(earningTrend))
                    Spacer()
                    rightSideInfoView
                }
                if let tags = symbol.tags, !tags.isEmpty {
                    Text(tags.joined(separator: ", "))
                        .font(.footnote).foregroundColor(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)).shadow(color: Color.black.opacity(0.05), radius: 2, x: 2, y: 2))
            .padding(.vertical, 4)
        }
        .navigationDestination(isPresented: $isNavigationActive) {
            ChartView(symbol: symbol.symbol, groupName: groupName)
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
        .onAppear {
            if earningTrend == .insufficientData {
                dataService.fetchEarningTrends(for: [symbol.symbol])
            }
        }
    }
    
    @ViewBuilder
    private var rightSideInfoView: some View {
        if economySectors.contains(sectorName) {
            originalCompareView
        } else {
            stockOptionStyleView
        }
    }
    
    @ViewBuilder
    private var originalCompareView: some View {
        let parsed = parseOriginalValue(symbol.value)
        if parsed.prefix == nil && parsed.percentage == "N/A" && parsed.suffix == nil {
            Text("N/A").foregroundColor(.gray).fontWeight(.semibold)
        } else {
            HStack(spacing: 1) {
                if let prefix = parsed.prefix { Text(prefix).foregroundColor(.orange) }
                if let percentage = parsed.percentage { Text(percentage).foregroundColor(colorForPercentage(percentage)) }
                if let suffix = parsed.suffix, !suffix.isEmpty { Text(suffix).foregroundColor(.gray) }
            }
            .font(.system(size: 16))
            .fontWeight(.semibold)
        }
    }
    
    @ViewBuilder
    private var stockOptionStyleView: some View {
        let prefixInfo = getPrefixAndColor(from: symbol.value)
        HStack(spacing: 8) {
            if let prefix = prefixInfo.prefix {
                Text(prefix)
                    .foregroundColor(prefixInfo.color)   // ← 改为动态颜色
                    .fontWeight(.semibold)
            }
            if showOptionsMetrics, let metrics = optionsMetrics {
                Text(metrics.iv).foregroundColor(colorForValueString(metrics.iv)).fontWeight(.semibold)
                Text(metrics.sum).foregroundColor(colorForValueString(metrics.sum)).fontWeight(.semibold)
            }
        }
        .font(.system(size: 14))
    }

    private func getPrefixAndColor(from value: String) -> (prefix: String?, color: Color) {
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        var foundPrefix: String? = nil
        var suffixPart: String = ""
        var targetDate: Date? = nil

        if let match = SymbolItemView._datePatternRegex?.firstMatch(in: value, options: [], range: nsRange) {
            if let rFull = Range(match.range(at: 1), in: value),
            let rSuffix = Range(match.range(at: 2), in: value),
            let rFullMatch = Range(match.range(at: 0), in: value) {
                foundPrefix = String(value[rFullMatch])
                let dateStr = String(value[rFull])
                suffixPart = String(value[rSuffix])

                let formatter = DateFormatter()
                formatter.dateFormat = "MMdd"
                targetDate = formatter.date(from: dateStr)

                if let date = targetDate {
                    let components = Calendar.current.dateComponents([.month, .day], from: date)
                    let currentYear = Calendar.current.component(.year, from: Date())
                    var candidateDate = Calendar.current.date(from: DateComponents(
                        year: currentYear, month: components.month, day: components.day))!
                    let diff = Calendar.current.dateComponents([.month], from: candidateDate, to: Date()).month ?? 0
                    if diff > 6 {
                        candidateDate = Calendar.current.date(byAdding: .year, value: -1, to: candidateDate)!
                    } else if diff < -6 {
                        candidateDate = Calendar.current.date(byAdding: .year, value: 1, to: candidateDate)!
                    }
                    targetDate = candidateDate
                }
            }
        }

        guard let target = targetDate else { return (foundPrefix, .white) }

        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.startOfDay(for: TradingDateHelper.getYesterday())
        let nextTradingDay = Calendar.current.startOfDay(for: TradingDateHelper.getNextTradingDay())

        var finalColor: Color = .white
        if target < yesterday {
            finalColor = .white
        } else if target == yesterday {
            finalColor = (suffixPart == "后") ? .red : .white
        } else if target == today {
            finalColor = .orange
        } else if target == nextTradingDay {
            finalColor = (suffixPart == "前") ? .red : .orange
        } else {
            finalColor = .orange
        }

        return (foundPrefix, finalColor)
    }
    
    private func parseOriginalValue(_ value: String) -> ParsedValue {
        if value == "N/A" { return ParsedValue(prefix: nil, percentage: "N/A", suffix: nil) }
        let pattern = #"^(\d+[前后未])?(-?\d+\.?\d*%)(\S*)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, options: [], range: range) {
                var prefix: String? = nil
                var percentage: String? = nil
                var suffix: String? = nil
                let prefixRange = match.range(at: 1)
                if prefixRange.location != NSNotFound { prefix = (value as NSString).substring(with: prefixRange) }
                let percentageRange = match.range(at: 2)
                if percentageRange.location != NSNotFound { percentage = (value as NSString).substring(with: percentageRange) }
                let suffixRange = match.range(at: 3)
                if suffixRange.location != NSNotFound { suffix = (value as NSString).substring(with: suffixRange) }
                return ParsedValue(prefix: prefix, percentage: percentage, suffix: suffix)
            }
        }
        return ParsedValue(prefix: nil, percentage: value, suffix: nil)
    }
    
    private func colorForPercentage(_ percentageString: String?) -> Color {
        guard let percentageString = percentageString else { return .white }
        let numericString = percentageString.replacingOccurrences(of: "%", with: "")
        guard let number = Double(numericString) else { return .white }
        if number > 0 { return .red }
        else if number < 0 { return .green }
        else { return .gray }
    }
    
    private func colorForValueString(_ valueStr: String) -> Color {
        let cleanStr = valueStr.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let val = Double(cleanStr) {
            if val > 0 { return .red }
            if val < 0 { return .green }
        }
        return .gray
    }
    
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

// MARK: - 策略详情页（仅显示最新日期，无时间分组）
struct StrategyHistoryDetailView: View {
    let groupName: String
    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager

    /// 只取最新日期的 symbol 列表
    private var latestSymbols: [String] {
        guard let datesMap = dataService.earningHistoryData[groupName],
              let latestDate = datesMap.keys.sorted(by: >).first else { return [] }
        return datesMap[latestDate] ?? []
    }

    /// 标题直接用原始 groupName（与 EarningHistoryView 保持一致的规则）
    private var displayName: String { groupName }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(latestSymbols, id: \.self) { symbol in
                    StrategySymbolRow(symbol: symbol, groupName: groupName)

                    if symbol != latestSymbols.last {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            let cleanSymbols = latestSymbols.map { $0.cleanTicker }
            // 触发 symbol 上色
            dataService.fetchEarningTrends(for: cleanSymbols)
            // 触发期权指标（轻微延迟避免进场动画卡顿）
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await dataService.fetchOptionsMetrics(for: cleanSymbols)
            }
        }
    }
}

// MARK: - 策略页的 Symbol 行组件（无时间分组版）
struct StrategySymbolRow: View {
    let symbol: String
    let groupName: String
    let cleanSymbol: String

    @EnvironmentObject var dataService: DataService
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager

    @State private var navigateToChart = false
    @State private var showSubscriptionSheet = false

    // 静态正则，整个 App 生命周期只编译一次
    private static let _datePatternRegex = try? NSRegularExpression(pattern: #"^(\d+)([前后未])"#)

    init(symbol: String, groupName: String) {
        self.symbol = symbol
        self.groupName = groupName
        self.cleanSymbol = symbol.cleanTicker
    }

    private var earningTrend: EarningTrend {
        dataService.earningTrends[cleanSymbol.uppercased()] ?? .insufficientData
    }

    private var optionsMetrics: (iv: String, sum: String)? {
        dataService.optionsMetricsCache[cleanSymbol.uppercased()]
    }

    var body: some View {
        let sym = cleanSymbol.uppercased()
        let rawTags = dataService.symbolTagsMap[sym] ?? []
        let computedTags = rawTags.map { ($0, dataService.tagWeightLookup[$0] ?? 1.0) }
        let computedCategory = dataService.symbolCategoryMap[sym] ?? "Stocks"
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
                    // 前缀（如"03后"）
                    if let prefix = prefixInfo.prefix {
                        Text(prefix)
                            .foregroundColor(prefixInfo.color)
                            .fontWeight(.semibold)
                    }
                    // 期权指标
                    if let metrics = optionsMetrics {
                        Text(metrics.iv)
                            .foregroundColor(colorForValueString(metrics.iv))
                            .fontWeight(.semibold)
                        Text(metrics.sum)
                            .foregroundColor(colorForValueString(metrics.sum))
                            .fontWeight(.semibold)
                    }
                    // PE（始终显示，因为只展示最新日期）
                    if let capItem = dataService.marketCapData[sym], let pe = capItem.peRatio {
                        Text("PE \(String(format: "%.1f", pe))")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
    }

    // MARK: - 前缀解析 + 颜色判断（保持原有逻辑不变）
    private func getPrefixAndColor(for sym: String) -> (prefix: String?, color: Color) {
        guard let value = dataService.compareData[sym] else { return (nil, .white) }

        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        var foundPrefix: String? = nil
        var suffixPart: String = ""
        var targetDate: Date? = nil

        if let match = StrategySymbolRow._datePatternRegex?.firstMatch(in: value, options: [], range: nsRange) {
            if let rFull = Range(match.range(at: 1), in: value),
               let rSuffix = Range(match.range(at: 2), in: value),
               let rFullMatch = Range(match.range(at: 0), in: value) {
                foundPrefix = String(value[rFullMatch])
                let dateStr = String(value[rFull])
                suffixPart = String(value[rSuffix])

                let formatter = DateFormatter()
                formatter.dateFormat = "MMdd"
                targetDate = formatter.date(from: dateStr)

                if let date = targetDate {
                    let components = Calendar.current.dateComponents([.month, .day], from: date)
                    let currentYear = Calendar.current.component(.year, from: Date())
                    var candidateDate = Calendar.current.date(from: DateComponents(year: currentYear, month: components.month, day: components.day))!
                    let diff = Calendar.current.dateComponents([.month], from: candidateDate, to: Date()).month ?? 0
                    if diff > 6 {
                        candidateDate = Calendar.current.date(byAdding: .year, value: -1, to: candidateDate)!
                    } else if diff < -6 {
                        candidateDate = Calendar.current.date(byAdding: .year, value: 1, to: candidateDate)!
                    }
                    targetDate = candidateDate
                }
            }
        }

        guard let target = targetDate else { return (foundPrefix, .white) }

        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.startOfDay(for: TradingDateHelper.getYesterday())
        let nextTradingDay = Calendar.current.startOfDay(for: TradingDateHelper.getNextTradingDay())

        var finalColor: Color = .white
        if target < yesterday {
            finalColor = .white
        } else if target == yesterday {
            finalColor = (suffixPart == "后") ? .red : .white
        } else if target == today {
            finalColor = .orange
        } else if target == nextTradingDay {
            finalColor = (suffixPart == "前") ? .red : .orange
        } else {
            finalColor = .orange
        }

        return (foundPrefix, finalColor)
    }

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
    private static let _cleanTickerRegex = try? NSRegularExpression(pattern: "^([A-Za-z0-9-]+)")

    var cleanTicker: String {
        guard let regex = String._cleanTickerRegex else { return self }
        let range = NSRange(location: 0, length: self.utf16.count)
        if let match = regex.firstMatch(in: self, options: [], range: range),
           let r = Range(match.range(at: 1), in: self) {
            return String(self[r]).replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
        }
        return self
    }
}