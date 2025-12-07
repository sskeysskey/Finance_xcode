import SwiftUI
import Foundation

// MARK: - Extensions (颜色扩展，取自 V2)
extension Color {
    static let accentGradientStart = Color(red: 10/255, green: 132/255, blue: 255/255) // System Blue
    static let accentGradientEnd = Color(red: 94/255, green: 92/255, blue: 230/255)   // System Indigo
}

// MARK: - Models (保持不变)

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
                let importantKeys = ["USDJPY", "USDCNY", "DXY", "CNYI", "JPYI", "CHFI", "EURI", "CNYUSD"]
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
    // 【新增】
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    // 【新增】用于程序化导航
    @State private var selectedSector: IndicesSector?
    @State private var navigateToSector = false
    @State private var showSubscriptionSheet = false
    
    // 新增：控制跳转到“51周新低”二级页面
    @State private var navigateToWeekLow = false
    // 存储传给二级页面的数据
    @State private var weekLowSectorsData: [IndicesSector] = []
    
    // 定义分组名称
    private let economyGroupNames = Set(["Bonds", "Commodities", "crypto", "Currencies", "ETFs", "Economic_All", "Economics", "indices"])
    private let strategyGroupNames = Set(["Today", "short", "Short_Shift", "Strategy12", "Strategy34", "PE_valid", "PE_invalid", "Must"])
    // 这些是放在“51周新低”里面的
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
                let strategySectors = sectors.filter { strategyGroupNames.contains($0.name) }
                // 过滤出 51周新低 需要的数据，传递给二级页面
                let weekLowSectors = sectors.filter { weekLowGroupNames.contains($0.name) }
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        
                        // MARK: - 第一组：经济数据
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "经济数据", icon: "globe.asia.australia.fill", color: .blue)
                            
                            LazyVGrid(columns: gridLayout, spacing: 10) {
                                ForEach(economySectors) { sector in
                                    Button {
                                        handleSectorClick(sector)
                                    } label: {
                                        // 【修改点 2】使用新的 CompactSectorCard (带图标的紧凑卡片)
                                        CompactSectorCard(
                                            sectorName: sector.name,
                                            icon: getIcon(for: sector.name),
                                            baseColor: .blue
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        
                        // MARK: - 第二组：推荐股票
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "推荐股票", icon: "star.fill", color: .purple)
                            
                            LazyVGrid(columns: gridLayout, spacing: 10) {
                                ForEach(strategySectors) { sector in
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
                                
                                // 【修改点 3】51周新低按钮，样式更突出
                                Button {
                                    self.weekLowSectorsData = weekLowSectors
                                    self.navigateToWeekLow = true
                                } label: {
                                    CompactSectorCard(
                                        sectorName: "51周新低",
                                        icon: "arrow.down.right.circle.fill",
                                        baseColor: .orange,
                                        isSpecial: true
                                    )
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
        case "crypto": return "bitcoinsign.circle"
        case "Currencies": return "dollarsign.circle"
        case "ETFs": return "square.stack.3d.up"
        case "Technology": return "laptopcomputer"
        case "Energy": return "bolt.fill"
        case "Healthcare": return "heart.text.square"
        case "Real_Estate": return "house.fill"
        case "Today": return "sun.max.fill"
        case "Must": return "exclamationmark.shield.fill"
        case "Economics": return "chart.bar.xaxis"
        case "Economic_All": return "globe"
        case "Short_Shift": return "arrow.triangle.2.circlepath"
        case "short": return "arrow.down.circle"
        case "Strategy12": return "1.circle"
        case "Strategy34": return "3.circle"
        default: return "chart.pie.fill"
        }
    }
}

// MARK: - 新增：51周新低 专属页面 (完全移植自 V2)
struct FiftyOneLowView: View {
    let sectors: [IndicesSector]
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var usageManager: UsageManager
    
    @State private var selectedSector: IndicesSector?
    @State private var navigateToSector = false
    @State private var showSubscriptionSheet = false
    
    // 二级页面使用自适应网格，展示大卡片
    private let gridLayout = [GridItem(.adaptive(minimum: 150, maximum: .infinity), spacing: 16)]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("这些板块处于51周低位，可能存在反弹机会。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                LazyVGrid(columns: gridLayout, spacing: 16) {
                    ForEach(sectors) { sector in
                        Button {
                            handleSectorClick(sector)
                        } label: {
                            // 这里使用 V2 的大卡片样式
                            ModernSectorCard(sectorName: sector.name, icon: "chart.line.downtrend.xyaxis")
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top)
        }
        .navigationTitle("51周新低")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToSector) {
            if let sector = selectedSector {
                SectorDetailView(sector: sector)
            }
        }
        .sheet(isPresented: $showSubscriptionSheet) { SubscriptionView() }
    }
    
    private func handleSectorClick(_ sector: IndicesSector) {
        // 这里同样扣除点数
        if usageManager.canProceed(authManager: authManager, action: .openSector) {
            self.selectedSector = sector
            self.navigateToSector = true
        } else {
            self.showSubscriptionSheet = true
        }
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
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            Spacer()
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
    
    private var displayName: String {
        if isSpecial { return sectorName }
        switch sectorName {
        case "Strategy12": return "12"
        case "Strategy34": return "34"
        case "Economic_All": return "Eco All"
        case "Economics": return "Eco"
        case "Financial_Services": return "Finance"
        case "Communication_Services": return "Comm"
        case "Consumer_Cyclical": return "Cyclical"
        case "Consumer_Defensive": return "Defensive"
        case "Real_Estate": return "Estate"
        default: return sectorName.replacingOccurrences(of: "_", with: " ")
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
                gradient: Gradient(colors: isSpecial ? [.orange, .red] : [baseColor.opacity(0.8), baseColor.opacity(0.5)]),
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

// 【新增组件】ModernSectorCard (从 V2 移植)
// 专门用于“51周新低”二级页面，保持大尺寸和华丽效果
struct ModernSectorCard: View {
    let sectorName: String
    let icon: String
    var isSpecial: Bool = false
    
    private var displayName: String {
        switch sectorName {
        case "Basic_Materials": return "原材料"
        case "Communication_Services": return "通信服务"
        case "Consumer_Cyclical": return "非必需消费"
        case "Consumer_Defensive": return "必需消费"
        case "Financial_Services": return "金融服务"
        case "Real_Estate": return "房地产"
        case "Economic_All": return "全部经济"
        case "PE_valid": return "PE有效"
        case "PE_invalid": return "PE无效"
        default: return sectorName.replacingOccurrences(of: "_", with: " ")
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                Spacer()
            }
            
            Text(displayName)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(height: 110) // 保持 V2 的大尺寸
        .background(
            LinearGradient(
                gradient: Gradient(colors: isSpecial ? [.orange, .red] : [Color.accentGradientStart, Color.accentGradientEnd]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 4)
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