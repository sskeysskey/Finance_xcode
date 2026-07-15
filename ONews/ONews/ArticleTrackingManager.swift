import Foundation
import UIKit

// ✨ 新增：标记为 @MainActor，以安全访问同样是 @MainActor 的 AuthManager.shared
@MainActor
final class NewsTrackingManager {
    static let shared = NewsTrackingManager()
    private let baseURL = "http://106.15.183.158:5001/api/ONews/track"
    
    private let lock = NSRecursiveLock()
    private var sentInSession: Set<String> = []
    
    private init() {}
    
    enum EventType: String {
        case view        = "view"
        case listen      = "listen"
    }
    
    /// 获取用户 ID：登录用 Apple ID，未登录用 IDFV
    // ✨ 新增：因为访问了 AuthManager，这里也需要 @MainActor 隔离
    @MainActor
    static func resolveUser() -> (id: String, type: String)? {
        if let appleId = AuthManager.shared.userIdentifier, !appleId.isEmpty {
            return (appleId, "apple")
        }
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            return ("dev_" + idfv, "device")
        }
        return nil
    }
    
    /// 文章唯一键（跨设备一致）
    static func articleKey(sourceId: String?, topic: String) -> String {
        let src = sourceId ?? "unknown"
        return "\(src)|\(topic)"
    }
    
    func track(event: EventType, article: Article, sourceId: String?) {
        guard let user = Self.resolveUser() else { return }
        let key = Self.articleKey(sourceId: sourceId, topic: article.topic)
        
        let dedupKey = "\(user.id)|\(key)|\(event.rawValue)"
        lock.lock()
        if sentInSession.contains(dedupKey) {
            lock.unlock(); return
        }
        sentInSession.insert(dedupKey)
        lock.unlock()
        
        Task {
            await Self.send(
                userId: user.id, userType: user.type,
                articleKey: key, articleTopic: article.topic,
                sourceId: sourceId ?? "",
                articleDate: article.timestamp,
                eventType: event.rawValue
            )
        }
    }
    
    private static func send(userId: String, userType: String,
                             articleKey: String, articleTopic: String,
                             sourceId: String, articleDate: String,
                             eventType: String) async {
        guard let url = URL(string: "http://106.15.183.158:5001/api/ONews/track") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let body: [String: Any] = [
            "user_id": userId,
            "user_type": userType,
            "article_key": articleKey,
            "article_topic": articleTopic,
            "source_id": sourceId,
            "article_date": articleDate,
            "event_type": eventType,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""  // 【新增】
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}