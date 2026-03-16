import Foundation
import SwiftUI
import Combine

@MainActor
class PreferenceManager: ObservableObject {
    
    @Published var selectedSubtypes: Set<String> = []
    
    private let storageKey = "Pred_SelectedSubtypes"
    
    init() {
        if let saved = UserDefaults.standard.array(forKey: storageKey) as? [String] {
            selectedSubtypes = Set(saved)
        }
    }
    
    func save() {
        UserDefaults.standard.set(Array(selectedSubtypes), forKey: storageKey)
    }
    
    func toggle(_ subtype: String) {
        if selectedSubtypes.contains(subtype) {
            selectedSubtypes.remove(subtype)
        } else {
            selectedSubtypes.insert(subtype)
        }
    }
    
    func selectAll(subtypes: [String]) {
        selectedSubtypes = Set(subtypes)
    }
    
    var hasPreferences: Bool { !selectedSubtypes.isEmpty }
    
    // 从数据中提取 type → [subtype] 映射
    static func extractCategories(from items: [PredictionItem]) -> [(type: String, subtypes: [String])] {
        var typeMap: [String: Set<String>] = [:]
        
        for item in items {
            let t = item.type
            let s = item.subtype
            typeMap[t, default: Set()].insert(s)
        }
        
        return typeMap
            .sorted { $0.key < $1.key }
            .map { (type: $0.key, subtypes: $0.value.sorted()) }
    }
}
