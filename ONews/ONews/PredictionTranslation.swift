import SwiftUI
import Foundation
import Combine

@MainActor
class TranslationManager: ObservableObject {
    
    enum Language: String, CaseIterable, Identifiable {
        case chinese = "zh"
        case english = "en"
        
        var id: String { rawValue }
        
        var label: String {
            switch self {
            case .chinese: return "中"
            case .english: return "英"
            }
        }
        
        var icon: String {
            switch self {
            case .chinese: return "character"
            case .english: return "a.circle"
            }
        }
    }
    
    @Published var language: Language = .chinese
    // ✅ 新增：用于强制触发视图更新的计数器
    @Published var reloadTrigger: Int = 0
    
    private var dict: [String: [String: String]] = [
        "names": [:],
        "options": [:],
        "types": [:],
        "subtypes": [:]
    ]
    
    /// 预编译的选项词级别替换规则
    private var optionReplacements: [(regex: NSRegularExpression, template: String)] = []
    
    /// ✅ 新增：翻译缓存，避免每次搜索都重新执行庞大的正则循环
    private var optionCache: [String: String] = [:]
    
    private let languageKey = "Pred_DisplayLanguage"
    
    init() {
        if let saved = UserDefaults.standard.string(forKey: languageKey),
           let lang = Language(rawValue: saved) {
            // 如果用户之前保存过语言偏好，使用保存的偏好
            language = lang
        } else {
            // 如果没有保存过，根据系统语言自动设置默认值
            let systemLang = Locale.preferredLanguages.first ?? "en"
            if systemLang.hasPrefix("zh") {
                language = .chinese
            } else {
                language = .english
            }
        }
        loadDictionary()
    }
    
    // MARK: - 语言切换
    
    func toggle() {
        language = (language == .chinese) ? .english : .chinese
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
    }
    
    // MARK: - 翻译查找
    
    /// 翻译预测标题 (name)
    func name(_ key: String) -> String {
        guard language == .chinese else { return key }
        return dict["names"]?[key] ?? key
    }
    
    /// 翻译选项标签：先尝试完整匹配（向后兼容），再逐词替换
    func option(_ key: String) -> String {
        guard language == .chinese else { return key }
        
        // 1. 完整匹配（兼容已有的完整短语条目）
        if let exact = dict["options"]?[key] { return exact }
        
        // ✅ 2. 检查缓存
        if let cached = optionCache[key] { return cached }
        
        // 3. 逐词替换（极度消耗性能，因此必须缓存）
        var result = key
        for entry in optionReplacements {
            let range = NSRange(result.startIndex..., in: result)
            result = entry.regex.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: entry.template
            )
        }
        
        // ✅ 4. 写入缓存
        optionCache[key] = result
        return result
    }
    
    /// 翻译大类名 (type)
    func type(_ key: String) -> String {
        guard language == .chinese else { return key }
        return dict["types"]?[key] ?? key
    }
    
    /// 翻译子类名 (subtype)
    func subtype(_ key: String) -> String {
        guard language == .chinese else { return key }
        return dict["subtypes"]?[key] ?? key
    }
    
    // MARK: - 加载字典
    
    func reload() {
        loadDictionary()
        // ✅ 新增：字典加载完成后，修改此变量，强制所有观察此对象的视图刷新
        reloadTrigger += 1 
    }
    
    private func loadDictionary() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docsDir.appendingPathComponent("translation_dict.json")
        
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
            print("⚠️ TranslationManager: 字典文件未找到或解析失败，将使用英文原文")
            return
        }
        
        dict = parsed
        optionCache.removeAll() // ✅ 重新加载字典时清空缓存
        buildOptionReplacements()
        
        let total = parsed.values.reduce(0) { $0 + $1.count }
        print("✅ TranslationManager: 已加载字典共 \(total) 条")
    }
    
    // MARK: - 预编译选项替换规则
    
    /// 将 options 字典编译为正则替换数组，按 key 长度降序排列
    /// 这样 "New York" 会先于 "New" 被匹配，避免短词误替换长词组的一部分
    private func buildOptionReplacements() {
        guard let options = dict["options"], !options.isEmpty else {
            optionReplacements = []
            return
        }
        
        let sorted = options.sorted { $0.key.count > $1.key.count }
        optionReplacements = sorted.compactMap { (key, value) in
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            // 转义模板中的 $ 和 \ 以避免被当作反向引用
            let safeTemplate = NSRegularExpression.escapedTemplate(for: value)
            return (regex: regex, template: safeTemplate)
        }
    }
}