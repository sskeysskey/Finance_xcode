// DataService1.swift
import Foundation

protocol SymbolItem {
    var symbol: String { get }
    var tag: [String] { get }
}

struct DescriptionData1: Codable {
    let stocks: [Stock1]
    let etfs: [ETF1]
}

struct Stock1: Codable, SymbolItem {
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    let value: String
}

struct ETF1: Codable, SymbolItem {
    let symbol: String
    let name: String
    let tag: [String]
    let description1: String
    let description2: String
    let value: String
}

class DataService1 {
    static let shared = DataService1()
    
    var descriptionData1: DescriptionData1?
    var tagsWeightConfig: [Double: [String]] = [:]
    var compareData1: [String: String] = [:]
    
    private init() {
        loadDescriptionData1()
        loadWeightGroups()
        loadCompareData1()
    }
    
    private func loadDescriptionData1() {
        guard let path = Bundle.main.path(forResource: "description", ofType: "json") else {
            print("description.json 文件未找到")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            self.descriptionData1 = try decoder.decode(DescriptionData1.self, from: data)
        } catch {
            print("解析 description.json 时出错: \(error)")
        }
    }
    
    func loadWeightGroups() {
        guard let path = Bundle.main.path(forResource: "tags_weight", ofType: "json") else {
            print("tags_weight.json 文件未找到")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            let rawData = try JSONSerialization.jsonObject(with: data, options: []) as? [String: [String]]
            var weightGroups: [Double: [String]] = [:]
            if let rawData = rawData {
                for (k, v) in rawData {
                    if let key = Double(k) {
                        weightGroups[key] = v
                    }
                }
            }
            self.tagsWeightConfig = weightGroups
        } catch {
            print("解析 tags_weight.json 时出错: \(error)")
        }
    }
    
    private func loadCompareData1() {
        guard let path = Bundle.main.path(forResource: "Compare_All", ofType: "txt") else {
            print("Compare_All.txt 文件未找到")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")
            for line in lines {
                let components = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if components.count == 2 {
                    compareData1[components[0]] = components[1]
                }
            }
        } catch {
            print("解析 Compare_All.txt 时出错: \(error)")
        }
    }
}
