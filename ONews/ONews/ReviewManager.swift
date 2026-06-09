import SwiftUI
import StoreKit

class ReviewManager {
    // 单例模式
    static let shared = ReviewManager()
    
    // 持久化存储新闻阅读计数
    @AppStorage("userReadArticleCount") private var readCount: Int = 0
    
    // 【新增】持久化存储视频交互计数（包括播放返回、详情页返回等）
    @AppStorage("userVideoInteractionCount") private var videoInteractionCount: Int = 0
    
    // 新闻触发弹窗的阈值：
    private let reviewThresholds: Set<Int> = [10, 25, 50, 100, 200]
    
    // 【新增】视频触发弹窗的阈值：第 10, 20, 50, 100 次交互（考虑到视频消费频次低于新闻，阈值设得稍低且有节制）
    private let videoThresholds: Set<Int> = [10, 20, 50, 100]
    
    private init() {}
    
    /// 记录一次“有效的阅读行为”
    func recordInteraction() {
        readCount += 1
        print("ReviewManager: 当前新闻阅读计数为 \(readCount)")
        
        if reviewThresholds.contains(readCount) {
            requestReview()
        }
    }
    
    /// 【新增】记录一次“有效的视频交互行为”（如播放完毕返回、退出详情页等）
    func recordVideoInteraction() {
        videoInteractionCount += 1
        print("ReviewManager: 当前视频交互计数为 \(videoInteractionCount)")
        
        if videoThresholds.contains(videoInteractionCount) {
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
            
            // 根据系统版本调用不同的 API
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