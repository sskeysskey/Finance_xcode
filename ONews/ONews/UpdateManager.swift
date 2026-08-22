import Foundation
import CryptoKit
import SwiftUI
import Network

struct FileInfo: Codable {
    let name: String
    let type: String
    let md5: String?
}

struct ForceUpdateView: View {
    let storeURL: String
    private let fallbackURL = "https://apps.apple.com/cn/app/id6754591885"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 80)).foregroundColor(.blue)
                Text("需要更新").font(.largeTitle.bold()).foregroundColor(.white)
                Text("我们发布了一个重要的版本升级。\n当前版本已停止服务，请更新后继续使用。")
                    .font(.body).multilineTextAlignment(.center)
                    .foregroundColor(.gray).padding(.horizontal)
                Button(action: {
                    let urlStr = storeURL.isEmpty ? fallbackURL : storeURL
                    if let url = URL(string: urlStr) { UIApplication.shared.open(url) }
                }) {
                    Text("前往 App Store 更新")
                        .font(.headline).foregroundColor(.white).padding()
                        .frame(maxWidth: .infinity).background(Color.blue).cornerRadius(12)
                }
                .padding(.horizontal, 40)
            }
            .padding()
        }
    }
}

// MARK: - 迁移配置数据模型
struct MigrationConfig: Codable, Equatable {
    let enabled: Bool
    let isForced: Bool
    let configId: String
    let newAppId: String
    let newAppUrl: String
    let fallbackUrl: String

    let titleZh: String
    let titleEn: String
    let subtitleZh: String
    let subtitleEn: String
    let contentZh: [String]
    let contentEn: [String]
    let subscriptionNoticeZh: String
    let subscriptionNoticeEn: String
    let primaryButtonZh: String
    let primaryButtonEn: String
    let secondaryButtonZh: String
    let secondaryButtonEn: String

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
        case primaryButtonZh = "primary_button_zh"
        case primaryButtonEn = "primary_button_en"
        case secondaryButtonZh = "secondary_button_zh"
        case secondaryButtonEn = "secondary_button_en"
    }
}

struct ServerVersion: Codable {
    let version: String
    let min_app_version: String?
    let store_url: String?
    let locked_days: Int?
    let server_date: String?
    let notification: String?
    let update_time: String?
    let source_mappings: [String: String]?
    let source_mappings_review: [String: String]?
    let review_mode: Bool?
    let video_module_enabled: Bool?
    let video_review_enabled: Bool?
    let video_mappings: [String: String]?
    let video_mappings_review: [String: String]?
    let video_review_max_year: Int?
    let migration: MigrationConfig?
    let files: [FileInfo]
}

@MainActor
class ResourceManager: ObservableObject {
    @Published var isSyncing = false
    @Published var syncMessage = Localized.syncStarting
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var progressText = ""
    @Published var showAlreadyUpToDateAlert = false

    // 【新增】静默刷新状态（仅内部/调试用，不驱动遮罩）
    @Published private(set) var isSilentSyncing = false

    @Published var showForceUpdate: Bool = false
    @Published var appStoreURL: String = ""
    @Published var serverUpdateTime: String = ""

    @Published var serverLockedDays: Int = 0
    @Published var realMappings: [String: String] = [:]
    @Published var reviewMappings: [String: String] = [:]
    @Published var serverReviewMode: Bool = false
    @Published var serverVideoModuleEnabled: Bool = true
    @Published var serverVideoReviewEnabled: Bool = true
    @Published var serverVideoReviewMaxYear: Int = 1980
    @Published var realVideoMappings: [String: String] = [:]
    @Published var reviewVideoMappings: [String: String] = [:]

    private let setupDuringReviewKey = "setupCompletedDuringReviewMode"

    // 【新增】静默刷新节流
    private var lastSilentSyncAt: Date?
    private var lastConfigRefreshAt: Date?

    var useReviewDisguise: Bool {
        guard serverReviewMode else { return false }
        let defaults = UserDefaults.standard
        let hasCompletedSetup = defaults.bool(forKey: "hasCompletedInitialSetup")
        let setupDuringReview = defaults.bool(forKey: setupDuringReviewKey)
        if !hasCompletedSetup { return true }
        if setupDuringReview { return true }
        return false
    }

    var sourceMappings: [String: String] {
        return useReviewDisguise ? reviewMappings : realMappings
    }

    var videoCategoryMappings: [String: String] {
        return useReviewDisguise ? reviewVideoMappings : realVideoMappings
    }

    var showVideoModule: Bool {
        if serverReviewMode {
            if !useReviewDisguise { return true }
            return serverVideoReviewEnabled
        } else {
            return serverVideoModuleEnabled
        }
    }

    var effectiveReviewVideoMaxYear: Int? {
        return useReviewDisguise ? serverVideoReviewMaxYear : nil
    }

    @Published var activeNotification: String? = nil
    @Published var serverDate: String = ""
    @Published var activeMigration: MigrationConfig? = nil
    @Published var showMigrationSheet: Bool = false

    private var pendingImageQueue: [(timestamp: String, name: String)] = []
    private var queuedImageKeys: Set<String> = []
    private var imageWorkerTask: Task<Void, Never>? = nil

    private let serverBaseURL = "http://106.15.183.158:5001/api/ONews"
    private let dismissedNotificationKey = "dismissedNotificationContent"
    private let migrationCacheKey = "CachedMigrationConfig"
    private let migrationDismissedConfigIdKey = "DismissedMigrationConfigId"

    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15.0
        configuration.timeoutIntervalForResource = 30.0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    @Published var isWifiConnected: Bool = false
    @Published var isNetworkAvailable: Bool = true
    private var hasReportedNetworkStatus = false

    init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.hasReportedNetworkStatus = true
                self?.isWifiConnected = path.usesInterfaceType(.wifi)
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: monitorQueue)
        loadMigrationFromCache()
    }

    deinit {
        networkMonitor.cancel()
    }

    // MARK: - ★★★ 【新增】静默刷新（不弹窗、不遮罩、带节流）★★★
    /// - minInterval: 距上次静默刷新至少间隔多少秒才真正发请求
    func silentRefresh(minInterval: TimeInterval = 60, reason: String = "") async {
        if isSyncing || isSilentSyncing { return }
        if hasReportedNetworkStatus && !isNetworkAvailable { return }
        if let last = lastSilentSyncAt, Date().timeIntervalSince(last) < minInterval { return }

        lastSilentSyncAt = Date()
        isSilentSyncing = true
        defer { isSilentSyncing = false }

        do {
            try await checkAndDownloadUpdates(isManual: false, silent: true)
            print("🔄 [静默刷新] 完成 (\(reason))")
        } catch {
            // 失败时缩短冷却，20 秒后可再试
            lastSilentSyncAt = Date().addingTimeInterval(-(max(0, minInterval - 20)))
            print("🔄 [静默刷新] 失败 (\(reason)): \(error.localizedDescription)")
        }
    }

    /// 【新增】只刷 version.json（开关/通知/锁天数/映射），不下载新闻 JSON。
    /// 供"只看视频"的用户或视频首页使用，省流量。
    func refreshServerConfig(minInterval: TimeInterval = 120) async {
        if hasReportedNetworkStatus && !isNetworkAvailable { return }
        if let last = lastConfigRefreshAt, Date().timeIntervalSince(last) < minInterval { return }
        lastConfigRefreshAt = Date()
        _ = try? await getServerVersion()
    }

    func fetchSourceNames() async -> [String] {
        do {
            let _ = try await getServerVersion()
            var names: [String] = []
            let fixedSourceKeys = ["wsj", "ft", "nytimes", "bloomberg", "reuters"]
            let mappings = self.sourceMappings
            for key in fixedSourceKeys {
                if let rawName = mappings[key] {
                    let parts = rawName.components(separatedBy: "|")
                    if let displayName = parts.first?.trimmingCharacters(in: .whitespaces),
                       !displayName.isEmpty {
                        names.append(displayName)
                    }
                }
            }
            if self.showVideoModule {
                names += self.videoCategoryMappings.values.map { rawName in
                    let parts = rawName.components(separatedBy: "|")
                    return parts.first?.trimmingCharacters(in: .whitespaces) ?? rawName
                }
            }
            if !names.isEmpty { return names }
        } catch {
            print("特效数据获取失败: \(error)")
        }
        return [
            Localized.fallbackSource1, Localized.fallbackSource2, Localized.fallbackSource3,
            Localized.fallbackSource4, Localized.fallbackSource5, Localized.fallbackSource6
        ]
    }

    func fetchShowcaseMappings() async -> (news: [String], video: [String]) {
        _ = try? await getServerVersion()
        let m = self.sourceMappings
        let order = NewsViewModel.preferredSourceOrder
        var news: [String] = []
        for key in order {
            if let v = m[key], !v.isEmpty { news.append(v) }
        }
        for (k, v) in m.sorted(by: { $0.key < $1.key }) where !order.contains(k) {
            if !v.isEmpty { news.append(v) }
        }
        let video = showVideoModule
            ? self.videoCategoryMappings.sorted(by: { $0.key < $1.key }).map { $0.value }
            : []
        return (news, video)
    }

    // MARK: - 检查图片是否存在而不下载
    func checkIfImagesExistForArticle(timestamp: String, imageNames: [String]) -> Bool {
        let sanitizedNames = imageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sanitizedNames.isEmpty else { return true }

        let directoryName = "news_images_\(timestamp)"
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        for imageName in sanitizedNames {
            let localImageURL = localDirectoryURL.appendingPathComponent(imageName)
            if !fileManager.fileExists(atPath: localImageURL.path) {
                return false
            }
        }
        return true
    }

    func enqueueImageDownloads(timestamp: String, imageNames: [String], priority: Bool = false) {
        let dirURL = documentsDirectory.appendingPathComponent("news_images_\(timestamp)")
        try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)

        var newItems: [(timestamp: String, name: String)] = []
        for raw in imageNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = "\(timestamp)/\(name)"
            if queuedImageKeys.contains(key) { continue }
            if fileManager.fileExists(atPath: dirURL.appendingPathComponent(name).path) { continue }
            queuedImageKeys.insert(key)
            newItems.append((timestamp: timestamp, name: name))
        }

        if !newItems.isEmpty {
            if priority {
                pendingImageQueue.insert(contentsOf: newItems, at: 0)
            } else {
                pendingImageQueue.append(contentsOf: newItems)
            }
        }
        startImageWorkerIfNeeded()
    }

    private func startImageWorkerIfNeeded() {
        guard imageWorkerTask == nil else { return }
        guard !pendingImageQueue.isEmpty else { return }

        imageWorkerTask = Task { @MainActor in
            while !self.pendingImageQueue.isEmpty {
                let item = self.pendingImageQueue.removeFirst()
                let key = "\(item.timestamp)/\(item.name)"
                let destURL = self.documentsDirectory
                    .appendingPathComponent("news_images_\(item.timestamp)/\(item.name)")

                if self.fileManager.fileExists(atPath: destURL.path) {
                    self.queuedImageKeys.remove(key)
                    NotificationCenter.default.post(
                        name: .articleImageDidDownload, object: nil,
                        userInfo: ["path": destURL.path])
                    continue
                }

                do {
                    try await self.downloadImagesForArticle(
                        timestamp: item.timestamp, imageNames: [item.name],
                        progressHandler: { _, _ in })
                    self.queuedImageKeys.remove(key)
                    NotificationCenter.default.post(
                        name: .articleImageDidDownload, object: nil,
                        userInfo: ["path": destURL.path])
                } catch {
                    self.queuedImageKeys.remove(key)
                    print("⚠️ [图片队列] 下载失败 \(item.name): \(error.localizedDescription)")
                    if !self.isNetworkAvailable {
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
            self.imageWorkerTask = nil
        }
    }

    @discardableResult
    func waitForImages(timestamp: String, imageNames: [String], timeout: TimeInterval) async -> Bool {
        enqueueImageDownloads(timestamp: timestamp, imageNames: imageNames, priority: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if checkIfImagesExistForArticle(timestamp: timestamp, imageNames: imageNames) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { break }
        }
        return checkIfImagesExistForArticle(timestamp: timestamp, imageNames: imageNames)
    }

    private func waitForNetworkAvailability(timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if hasReportedNetworkStatus && isNetworkAvailable { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return hasReportedNetworkStatus ? isNetworkAvailable : true
    }

    private func updateNotificationStatus(serverMessage: String?) {
        guard let message = serverMessage,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.activeNotification = nil
            return
        }
        let dismissedMessage = UserDefaults.standard.string(forKey: dismissedNotificationKey)
        if message != dismissedMessage {
            self.activeNotification = message
        } else {
            self.activeNotification = nil
        }
    }

    private func loadMigrationFromCache() {
        if let data = UserDefaults.standard.data(forKey: migrationCacheKey),
           let config = try? JSONDecoder().decode(MigrationConfig.self, from: data) {
            self.evaluateMigration(config)
        }
    }

    private func handleMigrationFromServer(_ config: MigrationConfig?) {
        if let config = config {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: migrationCacheKey)
            }
            evaluateMigration(config)
        } else {
            UserDefaults.standard.removeObject(forKey: migrationCacheKey)
            self.activeMigration = nil
            self.showMigrationSheet = false
        }
    }

    private func evaluateMigration(_ config: MigrationConfig) {
        guard config.enabled else {
            self.activeMigration = nil
            self.showMigrationSheet = false
            return
        }
        if config.isForced {
            self.activeMigration = config
            self.showMigrationSheet = true
            return
        }
        let dismissedId = UserDefaults.standard.string(forKey: migrationDismissedConfigIdKey)
        if dismissedId == config.configId {
            self.activeMigration = nil
            self.showMigrationSheet = false
        } else {
            self.activeMigration = config
            self.showMigrationSheet = true
        }
    }

    func dismissMigration() {
        guard let config = activeMigration, !config.isForced else { return }
        UserDefaults.standard.set(config.configId, forKey: migrationDismissedConfigIdKey)
        withAnimation {
            self.showMigrationSheet = false
            self.activeMigration = nil
        }
    }

    func dismissNotification() {
        guard let message = activeNotification else { return }
        UserDefaults.standard.set(message, forKey: dismissedNotificationKey)
        withAnimation { self.activeNotification = nil }
    }

    // MARK: - 按需下载单篇文章的图片
    func downloadImagesForArticle(
        timestamp: String,
        imageNames: [String],
        progressHandler: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        let sanitizedNames = imageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var uniqueNames: [String] = []
        var seen = Set<String>()
        for name in sanitizedNames where !seen.contains(name) {
            uniqueNames.append(name); seen.insert(name)
        }
        guard !uniqueNames.isEmpty else { return }

        let directoryName = "news_images_\(timestamp)"
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)

        var imagesToDownload: [String] = []
        for imageName in uniqueNames {
            let localImageURL = localDirectoryURL.appendingPathComponent(imageName)
            if !fileManager.fileExists(atPath: localImageURL.path) {
                imagesToDownload.append(imageName)
            }
        }
        guard !imagesToDownload.isEmpty else { return }

        let totalToDownload = imagesToDownload.count
        progressHandler(0, totalToDownload)

        for (index, imageName) in imagesToDownload.enumerated() {
            let downloadPath = "\(directoryName)/\(imageName)"
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
            components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
            guard let url = components.url else { continue }

            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let destinationURL = localDirectoryURL.appendingPathComponent(imageName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                progressHandler(index + 1, totalToDownload)
            } catch {
                print("⚠️ 下载图片失败 \(imageName): \(error.localizedDescription)")
                throw error
            }
        }
    }

    func preDownloadImagesForArticleSilently(timestamp: String, imageNames: [String]) async throws {
        let sanitizedNames = imageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var uniqueNames: [String] = []
        var seen = Set<String>()
        for name in sanitizedNames where !seen.contains(name) {
            uniqueNames.append(name); seen.insert(name)
        }
        guard !uniqueNames.isEmpty else { return }

        let directoryName = "news_images_\(timestamp)"
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)

        var imagesToDownload: [String] = []
        for imageName in uniqueNames {
            if !fileManager.fileExists(atPath: localDirectoryURL.appendingPathComponent(imageName).path) {
                imagesToDownload.append(imageName)
            }
        }
        guard !imagesToDownload.isEmpty else { return }

        for (index, imageName) in imagesToDownload.enumerated() {
            let downloadPath = "\(directoryName)/\(imageName)"
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
            components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
            guard let url = components.url else { continue }
            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { throw URLError(.badServerResponse) }
                let destinationURL = localDirectoryURL.appendingPathComponent(imageName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                print("✅ [静默预载] 成功 (\(index + 1)/\(imagesToDownload.count)): \(imageName)")
            } catch {
                print("⚠️ [静默预载] 失败 \(imageName): \(error.localizedDescription)")
                throw error
            }
        }
    }

    // MARK: - 批量离线下载所有图片（仅未读文章）
    func downloadAllOfflineImages(progressHandler: @escaping @MainActor (Int, Int) -> Void) async throws {
        let docDir = self.documentsDirectory

        let allImagesToDownload = await Task.detached(priority: .userInitiated) { [docDir] in
            let fm = FileManager.default
            var tasks: [(urlPath: String, localPath: URL)] = []
            let readRecords = (UserDefaults.standard.dictionary(forKey: "readTopics") as? [String: Date]) ?? [:]
            let readTopics = Set(readRecords.keys)

            guard let localFiles = try? fm.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else {
                return tasks
            }
            let jsonFiles = localFiles
                .filter { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            let decoder = JSONDecoder()
            for fileURL in jsonFiles {
                guard let data = try? Data(contentsOf: fileURL),
                      let articlesMap = try? decoder.decode([String: [Article]].self, from: data) else { continue }
                let filename = fileURL.deletingPathExtension().lastPathComponent
                let timestamp = filename.replacingOccurrences(of: "onews_", with: "")
                let directoryName = "news_images_\(timestamp)"
                let allArticles = articlesMap.values.flatMap { $0 }
                let unreadArticles = allArticles.filter { !readTopics.contains($0.topic) }
                let allImageNames = unreadArticles.flatMap { $0.images }

                var seen = Set<String>()
                for imageName in allImageNames {
                    let cleanName = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanName.isEmpty || seen.contains(cleanName) { continue }
                    seen.insert(cleanName)
                    let downloadPath = "\(directoryName)/\(cleanName)"
                    let localDir = docDir.appendingPathComponent(directoryName)
                    let localFile = localDir.appendingPathComponent(cleanName)
                    if !fm.fileExists(atPath: localFile.path) {
                        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
                        tasks.append((urlPath: downloadPath, localPath: localFile))
                    }
                }
            }
            return tasks
        }.value

        let total = allImagesToDownload.count
        if total == 0 { progressHandler(0, 0); return }
        progressHandler(0, total)

        for (index, task) in allImagesToDownload.enumerated() {
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
            components.queryItems = [URLQueryItem(name: "filename", value: task.urlPath)]
            guard let url = components.url else { continue }
            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { continue }
                if fileManager.fileExists(atPath: task.localPath.path) {
                    try fileManager.removeItem(at: task.localPath)
                }
                try fileManager.moveItem(at: tempURL, to: task.localPath)
                progressHandler(index + 1, total)
            } catch {
                print("⚠️ 下载异常: \(task.urlPath) - \(error.localizedDescription)")
            }
        }
    }

    func checkAndDownloadAllNewsManifests(isManual: Bool = false) async throws {
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = Localized.fetchingManifest
        self.progressText = ""
        self.downloadProgress = 0.0

        do {
            let serverVersion = try await getServerVersion()
            self.serverLockedDays = serverVersion.locked_days ?? 0

            let allJsonInfos = serverVersion.files
                .filter { $0.type == "json" && $0.name.starts(with: "onews_") }
                .sorted { $0.name < $1.name }

            if allJsonInfos.isEmpty { self.isSyncing = false; return }

            var tasksToDownload: [FileInfo] = []
            for jsonInfo in allJsonInfos {
                let localURL = documentsDirectory.appendingPathComponent(jsonInfo.name)
                var shouldDownload = false
                if fileManager.fileExists(atPath: localURL.path) {
                    if let serverMD5 = jsonInfo.md5, let localMD5 = calculateMD5(for: localURL) {
                        if serverMD5 != localMD5 { shouldDownload = true }
                    } else { shouldDownload = true }
                } else { shouldDownload = true }
                if shouldDownload { tasksToDownload.append(jsonInfo) }
            }

            if tasksToDownload.isEmpty {
                if isManual {
                    self.isSyncing = false
                    self.showAlreadyUpToDateAlert = true
                } else {
                    self.isSyncing = false
                }
                return
            }

            self.isDownloading = true
            self.syncMessage = Localized.downloadingData
            let fileNames = tasksToDownload.map { $0.name }

            try await downloadFilesConcurrently(fileNames: fileNames, maxConcurrent: 5) { [weak self] completed, total in
                guard let self = self else { return }
                self.progressText = "\(completed)/\(total)"
                self.downloadProgress = Double(completed) / Double(total)
            }

            self.isDownloading = false
            self.progressText = ""
            resetStateAfterDelay()

        } catch {
            self.isSyncing = false
            self.isDownloading = false
            throw error
        }
    }

    // MARK: - ★ 核心：增加 silent 参数 ★
    func checkAndDownloadUpdates(isManual: Bool = false, silent: Bool = false) async throws {
        if !silent {
            self.isSyncing = true
            self.isDownloading = false
            self.syncMessage = Localized.checkingUpdates
            self.progressText = ""
            self.downloadProgress = 0.0
        }
        // 手动刷新也刷新静默节流计时器，避免立刻又发一次
        if isManual { lastSilentSyncAt = Date() }

        let networkOK = await waitForNetworkAvailability(timeout: silent ? 2.0 : 4.0)
        guard networkOK else {
            if !silent { self.isSyncing = false }
            throw URLError(.notConnectedToInternet)
        }

        defer {
            if !silent {
                Task { @MainActor in
                    if !self.showAlreadyUpToDateAlert { self.isSyncing = false }
                }
            }
        }

        do {
            let serverVersion = try await getServerVersion()
            let localFiles = try getLocalFiles()

            self.serverLockedDays = serverVersion.locked_days ?? 0

            if !silent { self.syncMessage = Localized.cleaningOldResources }
            let validServerFiles = Set(serverVersion.files.map { $0.name })
            let filesToDelete = localFiles.subtracting(validServerFiles)
            let oldNewsItemsToDelete = filesToDelete.filter {
                $0.starts(with: "onews_") || $0.starts(with: "news_images_")
            }
            for itemName in oldNewsItemsToDelete {
                let itemURL = documentsDirectory.appendingPathComponent(itemName)
                try? fileManager.removeItem(at: itemURL)
                print("🗑️ 已成功删除: \(itemName)")
            }

            var downloadTasks: [(fileInfo: FileInfo, isIncremental: Bool)] = []
            let jsonFilesFromServer = serverVersion.files.filter { $0.type == "json" }
            let imageDirsFromServer = serverVersion.files.filter { $0.type == "images" }

            for jsonInfo in jsonFilesFromServer {
                let localFileURL = documentsDirectory.appendingPathComponent(jsonInfo.name)
                let correspondingImageDirName = "news_images_" +
                    jsonInfo.name.components(separatedBy: "_").last!
                        .replacingOccurrences(of: ".json", with: "")

                if fileManager.fileExists(atPath: localFileURL.path) {
                    guard let serverMD5 = jsonInfo.md5,
                          let localMD5 = calculateMD5(for: localFileURL) else { continue }
                    if serverMD5 != localMD5 {
                        downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                        let imageDirURL = documentsDirectory.appendingPathComponent(correspondingImageDirName)
                        try? fileManager.createDirectory(at: imageDirURL, withIntermediateDirectories: true)
                    }
                } else {
                    downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                    let imageDirURL = documentsDirectory.appendingPathComponent(correspondingImageDirName)
                    try? fileManager.createDirectory(at: imageDirURL, withIntermediateDirectories: true)
                }
            }

            for dirInfo in imageDirsFromServer {
                let localDirURL = documentsDirectory.appendingPathComponent(dirInfo.name)
                try? fileManager.createDirectory(at: localDirURL, withIntermediateDirectories: true)
            }

            if downloadTasks.isEmpty {
                // 静默模式：绝不弹「已是最新」
                if isManual && !silent {
                    await MainActor.run {
                        self.syncMessage = Localized.upToDate
                        self.showAlreadyUpToDateAlert = true
                        self.isSyncing = false
                    }
                    resetStateAfterDelay(seconds: 1)
                }
                return
            }

            if !silent {
                self.isDownloading = true
                self.syncMessage = Localized.downloadingFiles
            }

            let fileNames = downloadTasks
                .filter { $0.fileInfo.type == "json" }
                .map { $0.fileInfo.name }

            try await downloadFilesConcurrently(fileNames: fileNames, maxConcurrent: 5) { [weak self] completed, total in
                guard let self = self, !silent else { return }
                self.progressText = "\(completed)/\(total)"
                self.downloadProgress = Double(completed) / Double(total)
            }

            if !silent {
                self.isDownloading = false
                self.syncMessage = Localized.updateComplete
                self.progressText = ""
            }

            // 有真实新增/变更才广播，NewsViewModel 会决定「立刻刷新」或「延后刷新」
            NotificationCenter.default.post(name: .newsDataDidUpdate, object: nil)

            if !silent { resetStateAfterDelay() }

        } catch {
            if !silent {
                self.isDownloading = false
                self.isSyncing = false
            }
            throw error
        }
    }

    private func resetStateAfterDelay(seconds: TimeInterval = 2) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                self.isSyncing = false
                self.syncMessage = ""
                self.progressText = ""
                withAnimation { self.showAlreadyUpToDateAlert = false }
            }
        }
    }

    private func calculateMD5(for fileURL: URL) -> String? {
        var hasher = Insecure.MD5()
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { handle.closeFile() }
            while true {
                let data = handle.readData(ofLength: 1024 * 1024)
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
        } catch {
            print("错误：计算 MD5 失败: \(error)")
            return nil
        }
    }

    private func isVersion(_ current: String, lessThan min: String) -> Bool {
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let minParts = min.split(separator: ".").compactMap { Int($0) }
        let count = max(currentParts.count, minParts.count)
        for i in 0..<count {
            let v1 = i < currentParts.count ? currentParts[i] : 0
            let v2 = i < minParts.count ? minParts[i] : 0
            if v1 < v2 { return true }
            if v1 > v2 { return false }
        }
        return false
    }

    private func getServerVersion() async throws -> ServerVersion {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else { throw URLError(.badURL) }
        let (data, _) = try await urlSession.data(from: url)
        let version = try JSONDecoder().decode(ServerVersion.self, from: data)

        await MainActor.run {
            self.serverDate = version.server_date ?? ""
            self.realMappings = version.source_mappings ?? [:]
            self.reviewMappings = version.source_mappings_review ?? (version.source_mappings ?? [:])
            self.serverReviewMode = version.review_mode ?? false
            self.serverVideoModuleEnabled = version.video_module_enabled ?? true
            self.serverVideoReviewMaxYear = version.video_review_max_year ?? 1980
            self.serverVideoReviewEnabled = version.video_review_enabled ?? true
            self.realVideoMappings = version.video_mappings ?? [:]
            self.reviewVideoMappings = version.video_mappings_review ?? (version.video_mappings ?? [:])
            self.serverLockedDays = version.locked_days ?? 0
            self.updateNotificationStatus(serverMessage: version.notification)
            self.handleMigrationFromServer(version.migration)

            if let sDate = version.server_date {
                UserDefaults.standard.set(sDate, forKey: "LastKnownServerDate")
            }
            if let time = version.update_time { self.serverUpdateTime = time }

            if let minVersion = version.min_app_version, let storeUrl = version.store_url {
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                if isVersion(currentVersion, lessThan: minVersion) {
                    self.showForceUpdate = true
                    self.appStoreURL = storeUrl
                } else {
                    self.showForceUpdate = false
                }
            }

            // 【新增】让 NewsViewModel 立即同步 lockedDays 等配置
            NotificationCenter.default.post(name: .newsConfigDidUpdate, object: nil)
        }
        return version
    }

    private func getLocalFiles() throws -> Set<String> {
        let contents = try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
        return Set(contents)
    }

    private func downloadFilesConcurrently(
        fileNames: [String],
        maxConcurrent: Int = 6,
        progressHandler: @MainActor (Int, Int) -> Void
    ) async throws {
        let total = fileNames.count
        guard total > 0 else { return }
        progressHandler(0, total)
        var completed = 0

        try await withThrowingTaskGroup(of: String.self) { group in
            var index = 0
            let initialBatch = min(maxConcurrent, total)
            while index < initialBatch {
                let name = fileNames[index]
                group.addTask { try await self.downloadSingleFile(named: name); return name }
                index += 1
            }
            while let finishedName = try await group.next() {
                completed += 1
                progressHandler(completed, total)
                print("✅ 并发下载完成 (\(completed)/\(total)): \(finishedName)")
                if index < total {
                    let name = fileNames[index]
                    group.addTask { try await self.downloadSingleFile(named: name); return name }
                    index += 1
                }
            }
        }
    }

    private func downloadSingleFile(named filename: String) async throws {
        guard var components = URLComponents(string: "\(serverBaseURL)/download") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components.url else { throw URLError(.badURL) }

        let (tempURL, response) = try await urlSession.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { throw URLError(.badServerResponse) }

        let destinationURL = documentsDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }
}

extension Notification.Name {
    static let articleImageDidDownload = Notification.Name("articleImageDidDownload")
}