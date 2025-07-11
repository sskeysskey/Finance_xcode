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
            loadAllData()
        }
        
        // MARK: - 修改
        // 合并加载方法
        func loadAllData() {
            print("DataService1: 开始加载所有数据...")
            loadDescriptionData1()
            loadWeightGroups()
            loadCompareData1()
            print("DataService1: 所有数据加载完毕。")
        }
        
        private func loadDescriptionData1() {
            guard let url = FileManagerHelper.getLatestFileUrl(for: "description") else {
                print("DataService1: description 文件未在 Documents 中找到")
                return
            }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                self.descriptionData1 = try decoder.decode(DescriptionData1.self, from: data)
            } catch {
                print("DataService1: 解析 description 文件时出错: \(error)")
            }
        }
        
        func loadWeightGroups() {
            guard let url = FileManagerHelper.getLatestFileUrl(for: "tags_weight") else {
                print("DataService1: tags_weight 文件未在 Documents 中找到")
                return
            }
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
                print("DataService1: 解析 tags_weight 文件时出错: \(error)")
            }
        }
        
        private func loadCompareData1() {
            guard let url = FileManagerHelper.getLatestFileUrl(for: "Compare_All") else {
                print("DataService1: Compare_All 文件未在 Documents 中找到")
                return
            }
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
                print("DataService1: 解析 Compare_All 文件时出错: \(error)")
            }
        }
}
