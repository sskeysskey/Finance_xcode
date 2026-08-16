import SwiftUI
import Combine

@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    @Published var isEnglish: Bool {
        didSet { UserDefaults.standard.set(isEnglish, forKey: "isGlobalEnglishMode") }
    }
    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "isGlobalEnglishMode") == nil {
            let lang = Locale.preferredLanguages.first ?? "en"
            d.set(!lang.hasPrefix("zh"), forKey: "isGlobalEnglishMode")
        }
        isEnglish = d.bool(forKey: "isGlobalEnglishMode")
    }
    func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}

/// 非 View 环境下的取值（Manager 内部用）
func T(_ zh: String, _ en: String) -> String {
    UserDefaults.standard.bool(forKey: "isGlobalEnglishMode") ? en : zh
}

extension Color {
    static let cardBG = Color(nsColor: .controlBackgroundColor)
    static let winBG  = Color(nsColor: .windowBackgroundColor)
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: b)
}
func formatSpeed(_ bps: Double) -> String {
    if bps <= 0 { return "—" }
    return formatBytes(Int64(bps)) + "/s"
}