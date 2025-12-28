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
    
    // 【新增】控制跳转到期权列表页面
    @State private var navigateToOptionsList = false
    
    // 定义分组名称
    private let economyGroupNames = Set(["Bonds", "Commodities", "Crypto", "Currencies", "ETFs", "Economic_All", "Economics", "Indices"])
    
    private let weekLowGroupNames = Set(["Basic_Materials", "Communication_Services", "Consumer_Cyclical", "Consumer_Defensive", "Energy", "Financial_Services", "Healthcare", "Industrials", "Real_Estate", "Technology", "Utilities"])
    
    
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
                                        sectorName: "期权",
                                        icon: "doc.text.magnifyingglass",
                                        baseColor: .purple,
                                        isSpecial: false
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
                // 【新增】跳转到期权列表 (现在这部分代码在 Options.swift 中)
                .navigationDestination(isPresented: $navigateToOptionsList) {
                    OptionsListView()
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
        if groupName == "WeekLow" {
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
        } else if let sector = sectors.first(where: { $0.name == groupName }) {
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
            newSector.symbols = sector.symbols.map { symbol in
                var updatedSymbol = symbol
                let upperSymbol = symbol.symbol.uppercased()
                
                let value = compareMap[upperSymbol] ??
                            compareMap[symbol.symbol] ??
                            "N/A"
                updatedSymbol.value = value
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
    @EnvironmentObject var dataService: DataService
    
    private var displayName: String {
        if isSpecial { return sectorName }
        if let remoteName = dataService.groupDisplayMap[sectorName] {
            return remoteName
        }
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
            if let subSectors = sector.subSectors, !subSectors.isEmpty {
                let allSymbols = subSectors.flatMap { $0.symbols.map { $0.symbol } }
                dataService.fetchEarningTrends(for: allSymbols)
            } else {
                loadSymbols()
                dataService.fetchEarningTrends(for: symbols.map { $0.symbol })
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
                    Text(symbol.symbol)
                        .font(.headline)
                        .foregroundColor(colorForEarningTrend(earningTrend))
                    Spacer()
                    compareValueView
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
            if earningTrend == .insufficientData {
                dataService.fetchEarningTrends(for: [symbol.symbol])
            }
        }
    }
    
    @ViewBuilder
    private var compareValueView: some View {
        let parsed = parseCompareValue(symbol.value)
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
            .fontWeight(.semibold)
        }
    }
    
    private func parseCompareValue(_ value: String) -> ParsedValue {
        if value == "N/A" {
            return ParsedValue(prefix: nil, percentage: "N/A", suffix: nil)
        }
        let pattern = #"^(\d+[前后未])?(-?\d+\.?\d*%)(\S*)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, options: [], range: range) {
                let prefixRange = match.range(at: 1)
                let prefix = prefixRange.location != NSNotFound ? (value as NSString).substring(with: prefixRange) : nil
                let percentageRange = match.range(at: 2)
                let percentage = percentageRange.location != NSNotFound ? (value as NSString).substring(with: percentageRange) : nil
                let suffixRange = match.range(at: 3)
                let suffix = suffixRange.location != NSNotFound ? (value as NSString).substring(with: suffixRange) : nil
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
