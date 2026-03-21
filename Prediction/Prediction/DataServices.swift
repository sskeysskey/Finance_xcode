import Foundation

// MARK: - 单个选项
struct PredictionOption: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
    let change: String?
    
    // 清理标签（去掉排名前缀如 "1Ludvig Aberg" → "Ludvig Aberg"）
    var displayLabel: String {
        let pattern = "^T?\\d+"
        if let range = label.range(of: pattern, options: .regularExpression) {
            let cleaned = String(label[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? label : cleaned
        }
        return label
    }
}

// MARK: - 预测项目
struct PredictionItem: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let subtype: String
    let volume: String
    let endDate: String?
    let hide: String
    let simpleValue: String?   // 用于无option的简单项 (如 "4%")
    let options: [PredictionOption]
    let source: PredictionSource
    
    var isSimple: Bool { simpleValue != nil && options.isEmpty }
    var isHidden: Bool { hide == "1" }
    var marketCount: Int { isSimple ? 1 : options.count }
    
    // 简单项自动生成 Yes/No options 补充单选项 "Other" 逻辑
    var displayOptions: [PredictionOption] {
        // 情况 1：纯简单项（只有 value，没有任何 option）→ 自动生成 Yes / No
        if isSimple, let val = simpleValue {
            let yesPercent = val
            let noPercent = computeNoPercent(from: val)
            return [
                PredictionOption(label: "Yes", value: yesPercent, change: nil),
                PredictionOption(label: "No", value: noPercent, change: nil)
            ]
        }
        
        // 情况 2：只有 1 个 option → 自动补充 "Other"
        if options.count == 1, let first = options.first {
            let otherPercent = computeNoPercent(from: first.value)
            return [
                first,
                PredictionOption(label: "Other", value: otherPercent, change: nil)
            ]
        }
        
        // 情况 3：多个 option → 直接返回
        return options
    }
    
    private func computeNoPercent(from yesStr: String) -> String {
        let cleaned = yesStr.replacingOccurrences(of: "%", with: "")
                            .replacingOccurrences(of: "<", with: "")
                            .replacingOccurrences(of: ">", with: "")
                            .trimmingCharacters(in: .whitespaces)
        if let yesVal = Double(cleaned) {
            let noVal = max(0, 100 - yesVal)
            if yesStr.contains("<") {
                return ">\(Int(noVal))%"
            }
            if yesStr.contains(">") {
                return "<\(Int(noVal))%"
            }
            return "\(Int(noVal))%"
        }
        return "N/A"
    }
}

enum PredictionSource: String, CaseIterable, Identifiable {
    case polymarket = "Polymarket"
    case kalshi = "Kalshi"
    var id: String { rawValue }
}

// MARK: - JSON 解析（扁平结构 → 结构化）
class PredictionParser {
    static func parse(jsonData: Data, source: PredictionSource) -> [PredictionItem] {
        guard let rawArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            return []
        }
        
        return rawArray.compactMap { dict -> PredictionItem? in
            guard let name = dict["name"] as? String else { return nil }
            
            let type = dict["type"] as? String ?? "General"
            let subtype = dict["subtype"] as? String ?? "Other"
            let volume = dict["volume"] as? String ?? "0"
            let endDate = dict["enddate"] as? String
            let hide = dict["hide"] as? String ?? "0"
            let simpleValue = dict["value"] as? String
            
            // 解析选项
            var options: [PredictionOption] = []
            var i = 1
            while let optLabel = dict["option\(i)"] as? String,
                  let optValue = dict["value\(i)"] as? String {
                let optChange = dict["change\(i)"] as? String
                
                // 过滤纯数字/排名标记的冗余项
                let isRankOnly = optLabel.range(of: "^T?\\d+$", options: .regularExpression) != nil
                if !isRankOnly {
                    options.append(PredictionOption(
                        label: optLabel,
                        value: optValue,
                        change: optChange
                    ))
                }
                i += 1
            }
            
            return PredictionItem(
                name: name,
                type: type,
                subtype: subtype,
                volume: volume,
                endDate: endDate,
                hide: hide,
                simpleValue: simpleValue,
                options: options,
                source: source
            )
        }
    }
}