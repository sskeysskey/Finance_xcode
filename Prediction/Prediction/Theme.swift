import SwiftUI

extension Color {
    // 主背景
    static let appBg = Color(red: 0.04, green: 0.04, blue: 0.09)
    // 卡片背景
    static let cardBg = Color(red: 0.10, green: 0.10, blue: 0.16)
    // 卡片高亮背景（悬浮）
    static let cardBgHover = Color(red: 0.14, green: 0.14, blue: 0.22)
    // 标签背景色
    static let tagBg = Color.white.opacity(0.08)
    // 绿色边框（用于百分比 pill）
    static let pillBorder = Color(red: 0.2, green: 0.7, blue: 0.4)
    
    // 选项条颜色池
    static let barColors: [Color] = [
        .red, .blue, .green, .orange, .purple,
        .pink, .teal, .indigo, .mint, .cyan
    ]
}

// 格式化工具
struct Fmt {
    static func volume(_ str: String) -> String {
        guard let val = Double(str) else { return "$0" }
        if val >= 1_000_000_000 { return String(format: "$%.1fB", val / 1_000_000_000) }
        if val >= 1_000_000 { return String(format: "$%.1fM", val / 1_000_000) }
        if val >= 1_000 { return String(format: "$%.0fK", val / 1_000) }
        return String(format: "$%.0f", val)
    }
    
    static func percentValue(_ str: String) -> Double? {
        let cleaned = str.replacingOccurrences(of: "%", with: "")
                        .replacingOccurrences(of: "<", with: "")
                        .replacingOccurrences(of: ">", with: "")
                        .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }
}