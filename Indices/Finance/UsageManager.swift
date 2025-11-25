import SwiftUI
import Combine

@MainActor
class UsageManager: ObservableObject {
    static let shared = UsageManager()
    
    @Published var dailyCount: Int = 0
    @Published var maxFreeLimit: Int = 5 // 默认值，会从 version.json 更新
    
    private let countKey = "FinanceDailyUsageCount"
    private let dateKey = "FinanceLastUsageDate"
    
    private init() {
        checkReset()
    }
    
    // 检查是否需要重置计数（新的一天）
    private func checkReset() {
        let lastDate = UserDefaults.standard.object(forKey: dateKey) as? Date ?? Date.distantPast
        if !Calendar.current.isDateInToday(lastDate) {
            // 是新的一天，重置
            dailyCount = 0
            UserDefaults.standard.set(0, forKey: countKey)
            UserDefaults.standard.set(Date(), forKey: dateKey)
        } else {
            // 是今天，加载计数
            dailyCount = UserDefaults.standard.integer(forKey: countKey)
        }
    }
    
    // 更新最大限制（从 UpdateManager 调用）
    func updateLimit(_ limit: Int) {
        self.maxFreeLimit = limit
    }
    
    // 核心方法：尝试执行操作
    // 返回 true 表示允许操作（未超限或已订阅）
    // 返回 false 表示阻止操作（超限且未订阅）
    func canProceed(authManager: AuthManager) -> Bool {
        // 1. 如果已订阅，无限制
        if authManager.isSubscribed {
            return true
        }
        
        // 2. 检查并重置日期
        checkReset()
        
        // 3. 检查次数
        if dailyCount < maxFreeLimit {
            // 计数加一
            dailyCount += 1
            UserDefaults.standard.set(dailyCount, forKey: countKey)
            UserDefaults.standard.set(Date(), forKey: dateKey)
            print("UsageManager: 操作允许。今日已用: \(dailyCount)/\(maxFreeLimit)")
            return true
        } else {
            print("UsageManager: 操作拦截。已达今日上限。")
            return false
        }
    }
}