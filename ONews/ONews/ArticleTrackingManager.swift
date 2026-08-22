import Foundation
import UIKit

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

    static func articleKey(sourceId: String?, topic: String) -> String {
        let src = sourceId ?? "unknown"
        return "\(src)|\(topic)"
    }

    /// 【需求3】这篇文章是"订阅看"、"点数看"还是"免费老新闻"
    @MainActor
    private static func resolveAccessType(article: Article) -> String {
        let auth = AuthManager.shared
        if auth.isPermanentVIP { return "vip_permanent" }
        if auth.isSubscribed   { return "subscription" }
        let key = FreeQuotaManager.newsKey(article)
        if NewsQuotaManager.shared.isNewsUnlocked(key) { return "points" }
        return "free"
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

        let access = Self.resolveAccessType(article: article)   // 【新增】

        Task {
            await Self.send(
                userId: user.id, userType: user.type,
                articleKey: key, articleTopic: article.topic,
                sourceId: sourceId ?? "",
                articleDate: article.timestamp,
                eventType: event.rawValue,
                accessType: access
            )
        }
    }

    private static func send(userId: String, userType: String,
                             articleKey: String, articleTopic: String,
                             sourceId: String, articleDate: String,
                             eventType: String, accessType: String) async {
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
            "access_type": accessType,          // 【新增】
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}