import SwiftUI
import Foundation

// 定义公共协议
protocol SearchDescribableItem {
    var symbol: String { get }
    var name: String { get }
    var tag: [String] { get }
    var description1: String { get }
    var description2: String { get }
}

struct SearchStock: Identifiable, Codable, SearchDescribableItem {
    let id = UUID()
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    
    enum CodingKeys: String, CodingKey {
        case symbol, name, tag, description1, description2
    }
}

// 使 ETF 遵循 DescribableItem 协议
struct SearchETF: Identifiable, Codable, SearchDescribableItem {
    let id = UUID()
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    
    enum CodingKeys: String, CodingKey {
        case symbol, name, tag, description1, description2
    }
}

struct SelectedSymbol: Identifiable {
    let id = UUID()
    let result: SearchResult
    let category: String
}

struct SearchDescriptionData: Codable {
    let stocks: [SearchStock]
    let etfs: [SearchETF]
}

struct SearchMarketCapDataItem {
    let marketCap: Double
    let peRatio: Double?
}

// 定义匹配类别
enum MatchCategory: String, CaseIterable, Identifiable {
    case symbol = "Symbol Matches"
    case name = "Name Matches"
    case stockTag = "Stock Tag Matches"
    case etfTag = "ETF Tag Matches"
    case description = "Description Matches"
    var id: String { self.rawValue }
    
    // 添加权重属性
    var priority: Int {
        switch self {
        case .symbol:     return 1000  // 最高优先级
        case .stockTag:   return 800   // stock tag 优先于 etf tag
        case .etfTag:     return 700
        case .name:       return 500
        case .description: return 300  // 最低优先级
        }
    }
}

class SearchResult: Identifiable, ObservableObject {
    let id = UUID()
    @Published var symbol: String
    @Published var name: String
    @Published var tag: [String]
    @Published var marketCap: String?
    @Published var peRatio: String?
    @Published var compare: String?
    @Published var volume: String?
    
    init(symbol: String, name: String, tag: [String], marketCap: String? = nil,
         peRatio: String? = nil, compare: String? = nil, volume: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.tag = tag
        self.marketCap = marketCap
        self.peRatio = peRatio
        self.compare = compare
        self.volume = volume
    }
}

// 定义分组后的搜索结果结构
struct GroupedSearchResults: Identifiable {
    var id = UUID()
    var category: MatchCategory
    var results: [SearchResult]
    let highestScore: Int  // 新添加的属性
}

// MARK: - Views
struct SearchContentView: View {
    @State private var showSearch = false
    
    var body: some View {
        NavigationStack {  // 使用 NavigationStack
            VStack {
                Button(action: {
                    showSearch = true
                }) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("点击搜索")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding()
                
                Spacer()
            }
            .navigationDestination(isPresented: $showSearch) {
                SearchView(isSearchActive: true)
            }
        }
    }
}

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var showClearButton: Bool = false
    @State private var showSearchHistory: Bool = false
    @State private var groupedSearchResults: [GroupedSearchResults] = []
    @State private var isLoading: Bool = false
    @State private var selectedCategory: String? = nil
    @State private var showChart: Bool = false
    @State private var selectedResult: SearchResult? = nil
    @State private var selectedSymbol: SelectedSymbol? = nil
    @State private var isFirstAppear = true  // 新增状态变量
    @ObservedObject var viewModel = SearchViewModel()
    @FocusState private var isSearchFieldFocused: Bool
    
    // 添加初始化参数
    let isSearchActive: Bool
    
    init(isSearchActive: Bool = false) {
        self.isSearchActive = isSearchActive
        // 如果需要显示历史记录，设置初始值
        if isSearchActive {
            _showSearchHistory = State(initialValue: true)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            searchBar
                .padding()
            
            // 主要内容区域
            ZStack {
                // 搜索历史
                if showSearchHistory {
                    SearchHistoryView(viewModel: viewModel, onSelect: { term in
                        searchText = term
                        startSearch()
                    })
                    .transition(.opacity)
                    .zIndex(1) // 确保历史记录始终在最上层
                }
                
                // 加载指示器
                if isLoading {
                    ProgressView("正在搜索...")
                        .padding()
                }
                
                // 搜索结果列表
                if !showSearchHistory && !groupedSearchResults.isEmpty {
                    searchResultsList
                        .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: Binding<Bool>(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Alert(
                    title: Text("错误"),
                    message: Text(viewModel.errorMessage ?? ""),
                    dismissButton: .default(Text("确定"))
                )
            }
            // 使用 sheet(item:) 展示 ChartView
            .sheet(item: $selectedSymbol) { selected in
                ChartView(symbol: selected.result.symbol, groupName: selected.category)
            }
        }
        .onAppear {
            if isSearchActive && isFirstAppear {
                // 只在首次进入搜索页面时激活输入框焦点
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                    isFirstAppear = false  // 标记不再是首次加载
                }
            }
        }
//        .ignoresSafeArea(.keyboard) // 防止键盘顶起视图
    }
    
    // MARK: - 搜索栏
    private var searchBar: some View {
        HStack {
            TextField("请输入要搜索的关键字", text: $searchText, onEditingChanged: { isEditing in
                withAnimation {
                    // 只在文本为空且正在编辑时显示搜索历史
                    showSearchHistory = isEditing && searchText.isEmpty
                    if isEditing && searchText.isEmpty {
                        groupedSearchResults = [] // 只在合适的时机清空搜索结果
                    }
                }
            }, onCommit: {
                startSearch()
            })
            .focused($isSearchFieldFocused)
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .onChange(of: searchText) { oldValue, newValue in
                showClearButton = !newValue.isEmpty
                if newValue.isEmpty {
                    withAnimation {
                        showSearchHistory = true
                        groupedSearchResults = [] // 清空搜索结果
                    }
                }
            }
            
            if showClearButton {
                Button(action: {
                    searchText = ""
                    withAnimation {
                        showSearchHistory = true
                        groupedSearchResults = [] // 清空搜索结果
                        isSearchFieldFocused = true  // 添加这一行，设置输入框焦点
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .transition(.opacity)
            }
            
            Button(action: {
                startSearch()
                isSearchFieldFocused = false
            }) {
                Text("搜索")
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
    }
    
    // MARK: - 搜索结果列表
    private var searchResultsList: some View {
        List {
            ForEach(groupedSearchResults) { groupedResult in
                if !groupedResult.results.isEmpty {
                    Section(header: Text(groupedResult.category.rawValue)
                        .font(.headline)
                        .foregroundColor(.blue)) {
                        ForEach(groupedResult.results) { result in
                            NavigationLink(destination: {
                                if let category = viewModel.getCategory(for: result.symbol) {
                                    ChartView(symbol: result.symbol, groupName: category)
                                }
                            }) {
                                SearchResultRow(result: result)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    func startSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearchFieldFocused = false
        isLoading = true
        showSearchHistory = false
        
        viewModel.performSearch(query: searchText) { groupedResults in
            DispatchQueue.main.async {
                withAnimation {
                    self.groupedSearchResults = groupedResults
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - 搜索结果行视图
struct SearchResultRow: View {
    let result: SearchResult
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(result.symbol) - \(result.name)")
                .font(.headline)
            Text(result.tag.joined(separator: ", "))
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let marketCap = result.marketCap, let peRatio = result.peRatio {
                Text("\(marketCap) \(peRatio)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let compare = result.compare {
                Text("\(compare)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let volume = result.volume {
                Text("\(volume)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 搜索历史视图
struct SearchHistoryView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onSelect: (String) -> Void
    
    var body: some View {
        VStack {
            if viewModel.searchHistory.isEmpty {
                Text("暂无搜索历史")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.searchHistory, id: \.self) { term in
                            HStack {
                                Text(term)
                                    .onTapGesture {
                                        onSelect(term)
                                    }
                                Spacer()
                                Button(action: {
                                    viewModel.removeSearchHistory(term: term)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(8)
                .shadow(radius: 5)
                .padding([.horizontal, .bottom])
            }
        }
    }
}
