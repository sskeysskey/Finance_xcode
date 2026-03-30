import Foundation

// MARK: - String 扩展：空字符串保护
extension String {
    /// 如果 trim 后为空则返回 nil，否则返回 trim 后的值
    var nonEmptyTrimmed: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - 单个选项
struct PredictionOption: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
    let change: String?
    
    // 清理标签（去掉排名前缀如 "1Ludvig Aberg" → "Ludvig Aberg"）
    var displayLabel: String {
        // ✅ 修复：使用正向先行断言 (?=[A-Za-z])，确保数字后面紧跟的是字母，
        // 避免误删 "19,999.99" 中的 "19" 或 "100 million" 中的 "100"
        let pattern = "^T?\\d+(?=[A-Za-z])"
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
    // trend 文件专用字段
    let isNew: Bool            // 对应 JSON 中 "new": 1/0
    let volumeTrend: String?   // 对应 JSON 中 "volume_trend"
    
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

// 排序模式枚举
enum ListSortMode: String, CaseIterable, Identifiable {
    case trend
    case new
    case highestVolume
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .trend: return "Trend"
        case .new: return "New"
        case .highestVolume: return "Top"
        }
    }
    
    var icon: String {
        switch self {
        case .trend: return "chart.line.uptrend.xyaxis"
        case .new: return "sparkles"
        case .highestVolume: return "chart.bar.fill"
        }
    }
}

// MARK: - JSON 解析（扁平结构 → 结构化）
class PredictionParser {
    static func parse(jsonData: Data, source: PredictionSource) -> [PredictionItem] {
        guard let rawArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            print("⚠️ [\(source.rawValue)] JSON 解析失败：无法转为 [[String: Any]]")
            return []
        }
        
        return rawArray.compactMap { dict -> PredictionItem? in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            
            // ✅ 修复：使用 nonEmptyTrimmed 保护，空字符串也走默认值
            let type = (dict["type"] as? String)?.nonEmptyTrimmed ?? "General"
            let subtype = (dict["subtype"] as? String)?.nonEmptyTrimmed ?? "Other"
            let volume = (dict["volume"] as? String)?.nonEmptyTrimmed ?? "0"
            let endDate = (dict["enddate"] as? String)?.nonEmptyTrimmed
            let hide = (dict["hide"] as? String)?.nonEmptyTrimmed ?? "0"
            let simpleValue = (dict["value"] as? String)?.nonEmptyTrimmed
            
            // 🔍 调试日志：如果原始值与解析后不一致，打印警告
            #if DEBUG
            let rawType = dict["type"]
            let rawSubtype = dict["subtype"]
            if rawType == nil || (rawType as? String)?.nonEmptyTrimmed == nil {
                print("⚠️ [\(source.rawValue)] \"\(name)\" → type 缺失或为空，已回退为 \"\(type)\"  (原始值: \(String(describing: rawType)))")
            }
            if rawSubtype == nil || (rawSubtype as? String)?.nonEmptyTrimmed == nil {
                print("⚠️ [\(source.rawValue)] \"\(name)\" → subtype 缺失或为空，已回退为 \"\(subtype)\"  (原始值: \(String(describing: rawSubtype)))")
            }
            #endif
            
            // 解析 new 字段 (0 或 1)
            let isNew: Bool
            if let newInt = dict["new"] as? Int {
                isNew = newInt == 1
            } else if let newBool = dict["new"] as? Bool {
                isNew = newBool
            } else {
                isNew = false
            }
            
            // 解析 volume_trend (可能是 Int、Double 或 String)
            var volumeTrendStr: String? = nil
            if let vt = dict["volume_trend"] as? Int {
                volumeTrendStr = String(vt)
            } else if let vt = dict["volume_trend"] as? Double {
                volumeTrendStr = String(Int(vt))
            } else if let vt = dict["volume_trend"] as? String {
                volumeTrendStr = vt
            }
            
            // 解析选项
            var options: [PredictionOption] = []
            var i = 1
            while let optLabel = dict["option\(i)"] as? String,
                let optValue = dict["value\(i)"] as? String {
                let optChange = dict["change\(i)"] as? String
                
                // 移除 isRankOnly 过滤，保留纯数字选项（例如预测次数 "1", "2" 等）
                options.append(PredictionOption(
                    label: optLabel,
                    value: optValue,
                    change: optChange
                ))
                
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
                source: source,
                isNew: isNew,
                volumeTrend: volumeTrendStr
            )
        }
    }
}