import Foundation

final class TrackingManager {
    static let shared = TrackingManager()
    private let lock = NSLock()
    private var sent = Set<String>()
    private init() {}

    enum Event: String { case play, downloadStart = "download_start", downloadComplete = "download_complete" }

    /// 同步方法：在锁内检查并插入去重 key，返回 true 表示本次应当发送
    private func markIfNeeded(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sent.insert(key).inserted
    }

    /// 同步方法：发送失败后撤销去重标记
    private func unmark(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        sent.remove(key)
    }

    func track(_ e: Event, userId: String?, userType: String? = nil,
               videoURL: String, videoTitle: String, source: String? = nil) {
        guard let uid = userId, !uid.isEmpty else { return }
        let type = userType ?? (uid.hasPrefix("dev_") ? "device" : "apple")
        let key = "\(uid)|\(videoURL)|\(e.rawValue)"

        guard markIfNeeded(key) else { return }

        Task {
            guard let u = URL(string: "\(VideoAPI.baseURL)/track") else { return }
            var r = URLRequest(url: u)
            r.httpMethod = "POST"
            r.timeoutInterval = 10
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [
                "user_id": uid, "user_type": type,
                "video_url": videoURL, "video_title": videoTitle,
                "event_type": e.rawValue,
                "app_version": DeviceIdentity.appVersion
            ]
            if let s = source, !s.isEmpty { body["source"] = s }
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, resp) = try await URLSession.shared.data(for: r)
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                    throw URLError(.badServerResponse)
                }
            } catch {
                // 发送失败：撤销去重标记，下次同样的事件可以再发
                unmark(key)
            }
        }
    }
}