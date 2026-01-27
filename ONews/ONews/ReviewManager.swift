import SwiftUI
import StoreKit

class ReviewManager {
    // 单例模式
    static let shared = ReviewManager()
    
    // 持久化存储阅读计数
    @AppStorage("userReadArticleCount") private var readCount: Int = 0
    
    // 触发弹窗的阈值：第 5, 20, 50, 100, 200 篇
    private let reviewThresholds: Set<Int> = [5, 20, 50, 100, 200]
    
    private init() {}
    
    /// 记录一次“有效的阅读行为”
    func recordInteraction() {
        readCount += 1
        print("ReviewManager: 当前阅读计数为 \(readCount)")
        
        if reviewThresholds.contains(readCount) {
            requestReview()
        }
    }
    
    /// 请求评分弹窗
    private func requestReview() {
        print("ReviewManager: 达到阈值，请求评分弹窗...")
        
        DispatchQueue.main.async {
            // 获取当前活跃的 WindowScene
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
                return
            }
            
            // 【修复核心】：根据系统版本调用不同的 API
            if #available(iOS 16.0, *) {
                // iOS 16+ / iOS 18+ 使用新的 AppStore API
                AppStore.requestReview(in: scene)
            } else {
                // 旧版本兼容 (iOS 14.0 - 15.x)
                SKStoreReviewController.requestReview(in: scene)
            }
        }
    }
}
