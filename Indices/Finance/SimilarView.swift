// SimilarView.swift
import SwiftUI
import Foundation
import Combine

struct SimilarView: View {
    @EnvironmentObject var dataService: DataService  // 注入 DataService
    @ObservedObject var viewModel: SimilarViewModel
    
//    var symbol: String
    let symbol: String
    
    init(symbol: String) {
        self.symbol = symbol
        self.viewModel = SimilarViewModel(symbol: symbol)
    }
    
    var body: some View {
        VStack {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            } else if viewModel.isLoading {
                ProgressView("Loading...")
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.relatedSymbols.sorted(by: { $0.totalWeight > $1.totalWeight }), id: \.symbol) { item in
                            // 使用 NavigationLink 并传递正确的 groupName
                            NavigationLink(destination: ChartView(symbol: item.symbol, groupName: dataService.getCategory(for: item.symbol) ?? "Unknown")) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.symbol)
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundColor(.green)
                                            .shadow(radius: 1) // 添加轻微阴影效果，使文字更突出
                                        Text("\(item.totalWeight, specifier: "%.2f")")
                                            .font(.subheadline)
                                        Text("\(item.compareValue)")
                                            .font(.subheadline)
                                    }
                                    Spacer()
                                    Text(item.allTags.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                .padding()
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationBarTitle("Similar Symbols", displayMode: .inline)
    }
}

class SimilarViewModel: ObservableObject {
    @Published var relatedSymbols: [RelatedSymbol] = []
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private let symbol: String
    
    init(symbol: String) {
        self.symbol = symbol
        loadSimilarSymbols()
    }
    
    private func loadSimilarSymbols() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 加载数据
            let dataService = DataService1.shared
            
            // 获取 tags_weight 数据
            dataService.loadWeightGroups()
            
            // 获取 symbol 的 tags 及权重
            let targetTagsWithWeight = self.findTagsBySymbol(symbol: self.symbol, data: dataService.descriptionData1)
            
            guard !targetTagsWithWeight.isEmpty else {
                DispatchQueue.main.async {
                    self.errorMessage = "未找到该 symbol 的 tags"
                    self.isLoading = false
                }
                return
            }
            
            // 查找相似的 symbols
            let relatedSymbolsDict = self.findSymbolsByTags(targetTagsWithWeight: targetTagsWithWeight, weightGroups: dataService.tagsWeightConfig, data: dataService.descriptionData1)
            
            // 移除原始 symbol
            var stocks = relatedSymbolsDict["stocks"] ?? []
            var etfs = relatedSymbolsDict["etfs"] ?? []
            stocks.removeAll { $0.symbol.uppercased() == self.symbol.uppercased() }
            etfs.removeAll { $0.symbol.uppercased() == self.symbol.uppercased() }
            
            // 创建 RelatedSymbol 数组并设置分类
            let stocksRelated = stocks.map { item -> RelatedSymbol in
                let totalWeight = item.matchedTags.reduce(0.0) { $0 + $1.weight }
                let compareValue = dataService.compareData1[item.symbol] ?? ""
                let allTags = item.allTags
                return RelatedSymbol(symbol: item.symbol, totalWeight: totalWeight, compareValue: compareValue, allTags: allTags)
            }
            
            let etfsRelated = etfs.map { item -> RelatedSymbol in
                let totalWeight = item.matchedTags.reduce(0.0) { $0 + $1.weight }
                let compareValue = dataService.compareData1[item.symbol] ?? ""
                let allTags = item.allTags
                return RelatedSymbol(symbol: item.symbol, totalWeight: totalWeight, compareValue: compareValue, allTags: allTags)
            }
            
            let allSymbols = stocksRelated + etfsRelated
            
            // 按 totalWeight 降序排序
            let sortedSymbols = allSymbols.sorted { $0.totalWeight > $1.totalWeight }
            
            DispatchQueue.main.async {
                self.relatedSymbols = sortedSymbols
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func findTagsBySymbol(symbol: String, data: DescriptionData1?) -> [(tag: String, weight: Double)] {
        guard let data = data else { return [] }
        var tagsWithWeight: [(String, Double)] = []
        
        for category in ["stocks", "etfs"] {
            let items: [SymbolItem]
            if category == "stocks" {
                items = data.stocks
            } else {
                items = data.etfs
            }
            
            for item in items {
                if item.symbol.uppercased() == symbol.uppercased() {
                    for tag in item.tag {
                        if let weightKey = DataService1.shared.tagsWeightConfig.first(where: { $0.value.contains(tag) })?.key {
                            tagsWithWeight.append((tag, weightKey))
                        } else {
                            tagsWithWeight.append((tag, 1.0)) // 默认权重
                        }
                    }
                    return tagsWithWeight
                }
            }
        }
        return tagsWithWeight
    }
    
    private func findSymbolsByTags(targetTagsWithWeight: [(tag: String, weight: Double)], weightGroups: [Double: [String]], data: DescriptionData1?) -> [String: [MatchedSymbol]] {
        var relatedSymbols: [String: [MatchedSymbol]] = ["stocks": [], "etfs": []]
        
        // 创建目标标签字典，键为小写标签，值为权重
        var targetTagsDict: [String: Double] = [:]
        for (tag, weight) in targetTagsWithWeight {
            targetTagsDict[tag.lowercased()] = weight
        }
        
        guard let data = data else { return relatedSymbols }
        
        for category in ["stocks", "etfs"] {
            let items: [SymbolItem]
            if category == "stocks" {
                items = data.stocks
            } else {
                items = data.etfs
            }
            
            for item in items {
                var matchedTags: [(tag: String, weight: Double)] = []
                var usedTags = Set<String>()
                
                // 第一阶段：完全匹配
                for tag in item.tag {
                    let tagLower = tag.lowercased()
                    if let weight = targetTagsDict[tagLower], !usedTags.contains(tagLower) {
                        matchedTags.append((tag, weight))
                        usedTags.insert(tagLower)
                    }
                }
                
                // 第二阶段：部分匹配
                for tag in item.tag {
                    let tagLower = tag.lowercased()
                    if usedTags.contains(tagLower) { continue }
                    for (targetTag, _) in targetTagsDict {
                        if (tagLower.contains(targetTag) || targetTag.contains(tagLower)) && tagLower != targetTag && !usedTags.contains(targetTag) {
                            matchedTags.append((tag, 1.0))
                            usedTags.insert(targetTag)
                            break
                        }
                    }
                }
                
                if !matchedTags.isEmpty {
                    relatedSymbols[category]?.append(MatchedSymbol(symbol: item.symbol, matchedTags: matchedTags, allTags: item.tag))
                }
            }
        }
        
        // 按总权重降序排序
        for category in relatedSymbols.keys {
            relatedSymbols[category]?.sort { (a, b) -> Bool in
                let totalA = a.matchedTags.reduce(0.0) { $0 + $1.weight }
                let totalB = b.matchedTags.reduce(0.0) { $0 + $1.weight }
                return totalA > totalB
            }
        }
        
        return relatedSymbols
    }
}

struct MatchedSymbol {
    let symbol: String
    let matchedTags: [(tag: String, weight: Double)]
    let allTags: [String]
}

struct RelatedSymbol: Identifiable {
    let id = UUID()
    let symbol: String
    let totalWeight: Double
    let compareValue: String
    let allTags: [String]
}
