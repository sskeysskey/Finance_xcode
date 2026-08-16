import Foundation

final class TrackingManager {
    static let shared = TrackingManager()
    private let lock = NSLock()
    private var sent = Set<String>()
    private init() {}

    enum Event: String { case play, downloadStart = "download_start", downloadComplete = "download_complete" }

    func track(_ e: Event, userId: String?, userType: String? = nil,
               videoURL: String, videoTitle: String, source: String? = nil) {
        guard let uid = userId, !uid.isEmpty else { return }
        let type = userType ?? (uid.hasPrefix("dev_") ? "device" : "apple")
        let key = "\(uid)|\(videoURL)|\(e.rawValue)"
        lock.lock(); if sent.contains(key) { lock.unlock(); return }; sent.insert(key); lock.unlock()
        Task {
            guard let u = URL(string: "\(VideoAPI.baseURL)/track") else { return }
            var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["user_id": uid, "user_type": type,
                "video_url": videoURL, "video_title": videoTitle, "event_type": e.rawValue,
                "app_version": DeviceIdentity.appVersion]
            if let s = source, !s.isEmpty { body["source"] = s }
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: r)
        }
    }
}