import Foundation

enum TimeRange: String, CaseIterable {
    case oneMonth = "1 Month"
    case threeMonths = "3 Months"
    case sixMonths = "6 Months"
    case oneYear = "1 Year"
    case twoYears = "2 Years"
    case fiveYears = "5 Years"
    case tenYears = "10 Years"
    
    func getStartDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .twoYears:
            return calendar.date(byAdding: .year, value: -2, to: now) ?? now
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: now) ?? now
        case .tenYears:
            return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        }
    }
}
