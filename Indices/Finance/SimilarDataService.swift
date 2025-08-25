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
    // 【新增】: 用于存储板块/类别数据
    var sectorsData: [String: [String]] = [:]
    
    private init() {
        loadAllData()
    }
    
    func loadAllData() {
        print("DataService1: 开始加载所有数据...")
        loadDescriptionData1()
        loadWeightGroups()
        loadCompareData1()
        loadSectorsData() // 【新增】: 调用新的加载方法
        print("DataService1: 所有数据加载完毕。")
    }
    
    // 【新增】: 根据 symbol 获取其所属的类别/表名
    func getCategory(for symbol: String) -> String? {
        // 使用 sectorsData 字典进行查找
        for (category, symbols) in sectorsData {
            // 为了匹配不区分大小写，将两个 symbol 都转为大写
            if symbols.map({ $0.uppercased() }).contains(symbol.uppercased()) {
                return category
            }
        }
        return nil // 如果未找到，返回 nil
    }
    
    // 【新增】: 加载 Sectors_All.json 文件
    private func loadSectorsData() {
        guard let url = FileManagerHelper.getLatestFileUrl(for: "Sectors_All") else {
            print("DataService1: Sectors_All 文件未在 Documents 中找到")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decodedData = try JSONDecoder().decode([String: [String]].self, from: data)
            self.sectorsData = decodedData
        } catch {
            print("DataService1: 解析 Sectors_All.json 文件时出错: \(error)")
        }
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
                    // 【修改】: 存储时使用大写的 symbol 作为键，以保证后续查找的一致性
                    compareData1[components[0].uppercased()] = components[1]
                }
            }
        } catch {
            print("DataService1: 解析 Compare_All 文件时出错: \(error)")
        }
    }
}
