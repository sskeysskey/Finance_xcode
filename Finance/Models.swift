// Models.swift

import SwiftUI
import Foundation

// MARK: - 基础协议
protocol MarketItem: Identifiable, Codable {
    var id: String { get }
    var groupName: String { get }
    var rawSymbol: String { get }
    var symbol: String { get }
    var value: String { get }
    var descriptions: String { get }
    var numericValue: Double { get }
}

// MARK: - Stock Model
struct Stock: MarketItem {
    var id: String
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
    let marketCap: Double?
    let pe: String?
    
    var numericValue: Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0.0
    }
    
    init(groupName: String, rawSymbol: String, symbol: String, value: String, descriptions: String, marketCap: Double? = nil, pe: String? = nil) {
        self.id = UUID().uuidString
        self.groupName = groupName
        self.rawSymbol = rawSymbol
        self.symbol = symbol
        self.value = value
        self.descriptions = descriptions
        self.marketCap = marketCap
        self.pe = pe
    }
}

// MARK: - ETF Model
struct ETF: MarketItem {
    var id: String
    let groupName: String
    let rawSymbol: String
    let symbol: String
    let value: String
    let descriptions: String
    
    var numericValue: Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0.0
    }
    
    init(groupName: String, rawSymbol: String, symbol: String, value: String, descriptions: String) {
        self.id = UUID().uuidString
        self.groupName = groupName
        self.rawSymbol = rawSymbol
        self.symbol = symbol
        self.value = value
        self.descriptions = descriptions
    }
}

// MARK: - Generic Market Item View
struct MarketItemRow<T: MarketItem>: View {
    let item: T
    
    var body: some View {
        NavigationLink(destination: ChartView(symbol: item.symbol, groupName: item.groupName)) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(item.groupName) \(item.rawSymbol)")
                    .font(.headline)
                Text(item.value)
                    .font(.subheadline)
                    .foregroundColor(item.numericValue > 0 ? .green : (item.numericValue < 0 ? .red : .gray))
                Text(item.descriptions)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(5)
        }
    }
}

// MARK: - Generic List View
struct MarketListView<T: MarketItem>: View {
    let title: String
    let items: [T]
    
    var body: some View {
        List(items) { item in
            MarketItemRow(item: item)
        }
        .navigationTitle(title)
    }
}

// MARK: - Type Aliases for Convenience
typealias StockListView = MarketListView<Stock>
typealias ETFListView = MarketListView<ETF>
