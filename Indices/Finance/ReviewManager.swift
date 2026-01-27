import SwiftUI
import StoreKit

class ReviewManager {
    // 单例模式
    static let shared = ReviewManager()
    
    // 持久化存储交互次数
    // 注意：这里的 Key 我改了一下，避免和上一个 App 混淆，虽然不同 App 沙盒是隔离的
    @AppStorage("financeAppInteractionCount") private var interactionCount: Int = 0
    
    // 定义触发弹窗的阈值：看第 5, 20, 50, 100 张图表时触发
    private let reviewThresholds: Set<Int> = [5, 20, 50, 100, 200]
    
    private init() {}
    
    /// 记录一次“有效的交互行为”
    func recordInteraction() {
        interactionCount += 1
        print("ReviewManager: 当前交互计数为 \(interactionCount)")
        
        if reviewThresholds.contains(interactionCount) {
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
            
            // 兼容 iOS 14 - iOS 18+
            if #available(iOS 16.0, *) {
                AppStore.requestReview(in: scene)
            } else {
                SKStoreReviewController.requestReview(in: scene)
            }
        }
    }
}
