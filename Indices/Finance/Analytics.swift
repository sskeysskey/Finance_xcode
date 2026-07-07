import Foundation
import UIKit

/// 美股模块 - 用户点击行为统计
/// 与视频/新闻统计逻辑一致：登录用户用 Apple ID，未登录用 dev_ 前缀的设备ID
final class FinanceAnalytics {
    static let shared = FinanceAnalytics()
    
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    private let deviceIdKey = "FinanceAnalyticsDeviceID"
    
    private init() {}
    
    /// 未登录用户的稳定设备ID（dev_ 前缀，与服务器约定一致）
    private var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let newId = "dev_" + vendorId
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }
    
    /// 记录一次卡片/入口点击
    /// - Parameters:
    ///   - cardKey: 卡片/入口唯一标识 (如 "Bonds"、"对比"、"股票")
    ///   - cardName: 展示名称 (中文，可选)
    ///   - authManager: 用于判断登录状态 & 取 Apple ID
    @MainActor
    func track(cardKey: String, cardName: String = "", authManager: AuthManager) {
        let userId: String
        let userType: String
        if authManager.isLoggedIn, let uid = authManager.userIdentifier, !uid.isEmpty {
            userId = uid
            userType = "apple"
        } else {
            userId = deviceId
            userType = "device"
        }
        send(userId: userId, userType: userType, cardKey: cardKey, cardName: cardName)
    }
    
    private func send(userId: String, userType: String, cardKey: String, cardName: String) {
        guard let url = URL(string: "\(serverBaseURL)/track") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        let body: [String: Any] = [
            "user_id": userId,
            "user_type": userType,
            "card_key": cardKey,
            "card_name": cardName,
            "event_type": "click"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data
        
        // 后台静默发送，失败不打扰用户
        URLSession.shared.dataTask(with: request).resume()
    }
}