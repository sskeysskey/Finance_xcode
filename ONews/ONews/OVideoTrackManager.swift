import Foundation

@MainActor
final class TrackingManager {
    static let shared = TrackingManager()
    private let baseURL = "http://106.15.183.158:5001/api/OVideo/track"
    
    // 内存缓存：一次启动内不重复发同一事件，减少网络请求
    private var sentInSession: Set<String> = []
    
    private init() {}
    
    enum EventType: String {
        case play              = "play"
        case downloadStart     = "download_start"
        case downloadComplete  = "download_complete"
    }
    
    /// 通用上报。失败不抛错，不影响主流程
    func track(event: EventType,
               userId: String?,
               videoURL: String,
               videoTitle: String,
               category: String? = nil) {
        guard let userId = userId, !userId.isEmpty else { return }
        let key = "\(userId)|\(videoURL)|\(event.rawValue)"
        if sentInSession.contains(key) { return }
        sentInSession.insert(key)
        
        Task.detached(priority: .background) {
            await Self.send(
                userId: userId,
                videoURL: videoURL,
                videoTitle: videoTitle,
                category: category ?? "",
                eventType: event.rawValue
            )
        }
    }
    
    private static func send(userId: String, videoURL: String,
                             videoTitle: String, category: String,
                             eventType: String) async {
        guard let url = URL(string: "http://106.15.183.158:5001/api/OVideo/track") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let body: [String: Any] = [
            "user_id": userId,
            "video_url": videoURL,
            "video_title": videoTitle,
            "category": category,
            "event_type": eventType
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}