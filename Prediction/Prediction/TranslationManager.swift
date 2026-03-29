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
            case .english: return "EN"
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
    
    private var dict: [String: [String: String]] = [
        "names": [:],
        "options": [:],
        "types": [:],
        "subtypes": [:]
    ]
    
    private let languageKey = "Pred_DisplayLanguage"
    
    init() {
        if let saved = UserDefaults.standard.string(forKey: languageKey),
           let lang = Language(rawValue: saved) {
            language = lang
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
    
    /// 翻译选项标签 (传入 displayLabel，即已清洗掉排名前缀的文本)
    func option(_ key: String) -> String {
        guard language == .chinese else { return key }
        return dict["options"]?[key] ?? key
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
        let total = parsed.values.reduce(0) { $0 + $1.count }
        print("✅ TranslationManager: 已加载字典共 \(total) 条 (names: \(parsed["names"]?.count ?? 0), options: \(parsed["options"]?.count ?? 0), types: \(parsed["types"]?.count ?? 0), subtypes: \(parsed["subtypes"]?.count ?? 0))")
    }
}
