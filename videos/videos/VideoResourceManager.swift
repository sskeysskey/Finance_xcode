import SwiftUI
import Network

// MARK: - 迁移配置（与 ONews 完全一致的结构）
struct MigrationConfig: Codable, Equatable {
    let enabled: Bool
    let isForced: Bool
    let configId: String
    let newAppId: String
    let newAppUrl: String
    let fallbackUrl: String
    let titleZh: String, titleEn: String
    let subtitleZh: String, subtitleEn: String
    let contentZh: [String], contentEn: [String]
    let subscriptionNoticeZh: String, subscriptionNoticeEn: String
    let primaryButtonZh: String, primaryButtonEn: String
    let secondaryButtonZh: String, secondaryButtonEn: String

    enum CodingKeys: String, CodingKey {
        case enabled, isForced = "is_forced"
        case configId = "config_id"
        case newAppId = "new_app_id"
        case newAppUrl = "new_app_url"
        case fallbackUrl = "fallback_url"
        case titleZh = "title_zh", titleEn = "title_en"
        case subtitleZh = "subtitle_zh", subtitleEn = "subtitle_en"
        case contentZh = "content_zh", contentEn = "content_en"
        case subscriptionNoticeZh = "subscription_notice_zh"
        case subscriptionNoticeEn = "subscription_notice_en"
        case primaryButtonZh = "primary_button_zh", primaryButtonEn = "primary_button_en"
        case secondaryButtonZh = "secondary_button_zh", secondaryButtonEn = "secondary_button_en"
    }
}

// MARK: - 服务器配置
struct VideoAppConfig: Codable {
    let config_version: String?
    let review_mode: Bool?
    let video_module_enabled: Bool?
    let video_review_enabled: Bool?
    let video_review_max_year: Int?
    let video_mappings: [String: String]?
    let video_mappings_review: [String: String]?
    let min_app_version: String?
    let store_url: String?
    let notification: String?
    let update_time: String?
    let migration: MigrationConfig?
    let video_module_blocked: Bool?
}

// MARK: - 强制更新
struct ForceUpdateView: View {
    let storeURL: String
    @AppStorage("isGlobalEnglishMode") private var en = false
    private let fallback = "https://apps.apple.com/cn/app/id0000000000"   // ← 换成新 App 的链接

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 78)).foregroundColor(.blue)
                Text(en ? "Update Required" : "需要更新")
                    .font(.largeTitle.bold()).foregroundColor(.white)
                Text(en ? "This version is no longer supported. Please update to continue."
                        : "当前版本已停止服务，请更新后继续使用。")
                    .font(.body).multilineTextAlignment(.center)
                    .foregroundColor(.gray).padding(.horizontal)
                Button {
                    let s = storeURL.isEmpty ? fallback : storeURL
                    if let u = URL(string: s) { UIApplication.shared.open(u) }
                } label: {
                    Text(en ? "Update on the App Store" : "前往 App Store 更新")
                        .font(.headline).foregroundColor(.white)
                        .padding().frame(maxWidth: .infinity)
                        .background(Color.blue).cornerRadius(12)
                }
                .padding(.horizontal, 40)
            }
            .padding()
        }
    }
}

// MARK: - 配置管理器（名字仍叫 ResourceManager，方便视频文件零改动复用）
@MainActor
final class ResourceManager: ObservableObject {

    @Published var showForceUpdate = false
    @Published var appStoreURL = ""
    @Published var activeNotification: String? = nil
    @Published var serverUpdateTime = ""

    @Published var serverReviewMode = false
    @Published var serverVideoModuleEnabled = true
    @Published var serverVideoReviewEnabled = true
    @Published var serverVideoReviewMaxYear = 1980
    @Published var realVideoMappings: [String: String] = [:]
    @Published var reviewVideoMappings: [String: String] = [:]

    @Published var activeMigration: MigrationConfig? = nil
    @Published var showMigrationSheet = false

    @Published var isWifiConnected = false
    @Published var isNetworkAvailable = true
    @Published var isLoadingConfig = false

    private let baseURL = "http://106.15.183.158:5001/api/OVideo"
    private let cacheKey = "OVideo_CachedAppConfig"
    private let dismissedNotifKey = "dismissedNotificationContent"
    private let dismissedMigrationKey = "DismissedMigrationConfigId"
    private let setupDuringReviewKey = "setupCompletedDuringReviewMode"

    private var lastRefreshAt: Date?
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "OVideoNet")
    private var hasNetworkReport = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.hasNetworkReport = true
                self?.isWifiConnected = path.usesInterfaceType(.wifi)
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        monitor.start(queue: monitorQueue)
        loadFromCache()
    }
    deinit { monitor.cancel() }

    // MARK: 审核伪装（与 ONews 完全一致的规则）
    var useReviewDisguise: Bool {
        guard serverReviewMode else { return false }
        let d = UserDefaults.standard
        if !d.bool(forKey: "hasCompletedInitialSetup") { return true }
        if d.bool(forKey: setupDuringReviewKey) { return true }
        return false
    }

    var videoCategoryMappings: [String: String] {
        useReviewDisguise ? reviewVideoMappings : realVideoMappings
    }

    var showVideoModule: Bool {
        if serverReviewMode {
            return useReviewDisguise ? serverVideoReviewEnabled : true
        }
        return serverVideoModuleEnabled
    }

    var effectiveReviewVideoMaxYear: Int? {
        useReviewDisguise ? serverVideoReviewMaxYear : nil
    }

    /// 首启展示用的频道名（"中文|English" 原样返回，由 UI 决定取哪半边）
    var showcaseChannels: [String] {
        let order = ["vid_movie", "vid_west_drama", "vid_asia_drama", "vid_anime", "vid_show"]
        let m = videoCategoryMappings
        var out = order.compactMap { m[$0] }
        for (k, v) in m.sorted(by: { $0.key < $1.key }) where !order.contains(k) { out.append(v) }
        return out.filter { !$0.isEmpty }
    }

    // MARK: 拉取配置
    func refreshServerConfig(minInterval: TimeInterval = 120, userId: String? = nil) async {
        if hasNetworkReport && !isNetworkAvailable { return }
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < minInterval { return }
        lastRefreshAt = Date()
        isLoadingConfig = true
        defer { isLoadingConfig = false }

        var comps = URLComponents(string: "\(baseURL)/app_config")!
        if let uid = userId, !uid.isEmpty { comps.queryItems = [.init(name: "user_id", value: uid)] }
        guard let url = comps.url else { return }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: req)
            let cfg = try JSONDecoder().decode(VideoAppConfig.self, from: data)
            apply(cfg)
            UserDefaults.standard.set(data, forKey: cacheKey)
        } catch {
            lastRefreshAt = Date().addingTimeInterval(-(max(0, minInterval - 20)))
            print("⚠️ [配置] 拉取失败: \(error.localizedDescription)")
        }
    }

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cfg = try? JSONDecoder().decode(VideoAppConfig.self, from: data) else { return }
        apply(cfg)
    }

    private func apply(_ cfg: VideoAppConfig) {
        serverReviewMode          = cfg.review_mode ?? false
        serverVideoModuleEnabled  = cfg.video_module_enabled ?? true
        serverVideoReviewEnabled  = cfg.video_review_enabled ?? true
        serverVideoReviewMaxYear  = cfg.video_review_max_year ?? 1980
        realVideoMappings         = cfg.video_mappings ?? [:]
        reviewVideoMappings       = cfg.video_mappings_review ?? (cfg.video_mappings ?? [:])
        serverUpdateTime          = cfg.update_time ?? ""

        updateNotification(cfg.notification)
        handleMigration(cfg.migration)

        if let minV = cfg.min_app_version, let store = cfg.store_url {
            let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            showForceUpdate = isVersion(cur, lessThan: minV)
            appStoreURL = store
        }
    }

    private func isVersion(_ cur: String, lessThan minV: String) -> Bool {
        let a = cur.split(separator: ".").compactMap { Int($0) }
        let b = minV.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x < y { return true }
            if x > y { return false }
        }
        return false
    }

    // MARK: 公告
    private func updateNotification(_ msg: String?) {
        guard let m = msg?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
            activeNotification = nil; return
        }
        activeNotification = (m == UserDefaults.standard.string(forKey: dismissedNotifKey)) ? nil : m
    }

    func dismissNotification() {
        guard let m = activeNotification else { return }
        UserDefaults.standard.set(m, forKey: dismissedNotifKey)
        withAnimation { activeNotification = nil }
    }

    // MARK: 迁移
    private func handleMigration(_ cfg: MigrationConfig?) {
        guard let cfg = cfg, cfg.enabled else {
            activeMigration = nil; showMigrationSheet = false; return
        }
        if cfg.isForced {
            activeMigration = cfg; showMigrationSheet = true; return
        }
        if UserDefaults.standard.string(forKey: dismissedMigrationKey) == cfg.configId {
            activeMigration = nil; showMigrationSheet = false
        } else {
            activeMigration = cfg; showMigrationSheet = true
        }
    }

    func dismissMigration() {
        guard let cfg = activeMigration, !cfg.isForced else { return }
        UserDefaults.standard.set(cfg.configId, forKey: dismissedMigrationKey)
        withAnimation { showMigrationSheet = false; activeMigration = nil }
    }
}
