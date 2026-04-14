import SwiftUI

extension Color {
    // 动态主背景色
    static let appBg = Color(UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark 
            ? UIColor(red: 0.04, green: 0.04, blue: 0.09, alpha: 1.0)
            : UIColor.systemGroupedBackground
    })
    
    // 动态卡片背景色
    static let cardBg = Color(UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark 
            ? UIColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1.0)
            : UIColor.secondarySystemGroupedBackground
    })
    
    // 动态卡片高亮背景（悬浮）
    static let cardBgHover = Color(UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark 
            ? UIColor(red: 0.14, green: 0.14, blue: 0.22, alpha: 1.0)
            : UIColor.tertiarySystemGroupedBackground
    })
    
    // 动态标签背景色
    static let tagBg = Color(UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark 
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)
    })
    
    // 绿色边框（用于百分比 pill）
    static let pillBorder = Color(red: 0.2, green: 0.7, blue: 0.4)
    
    // 选项条颜色池
    static let barColors: [Color] = [
        .red, .blue, .green, .orange, .purple,
        .pink, .teal, .indigo, .mint, .cyan
    ]
    
    // MARK: - 新增：品牌高级渐变色
    static let brandStart = Color.indigo
    static let brandEnd = Color.purple
    
    // 漂浮动画彩色池
    static let floatingColors: [Color] = [
        .indigo, .purple, .pink, .teal, .cyan, .blue
    ]
}

// 渐变色扩展
extension LinearGradient {
    static let brandGradient = LinearGradient(
        colors: [Color.brandStart, Color.brandEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let brandGradientHorizontal = LinearGradient(
        colors: [Color.brandStart, Color.brandEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
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