import Foundation
import CryptoKit
import SwiftUI
import Network
import Combine

@MainActor
class PredictionSyncManager: ObservableObject {
    
    @Published var isSyncing = false
    @Published var syncMessage = "正在检查更新..."
    @Published var showForceUpdate = false
    @Published var appStoreURL = ""
    @Published var serverUpdateTime = ""
    @Published var welcomeTopics: [String] = []
    @Published var activeNotification: String? = nil
    @Published var showAlreadyUpToDateAlert = false
    
    // 本地加载的数据（主文件，按 volume 排序）
    @Published var polymarketItems: [PredictionItem] = []
    @Published var kalshiItems: [PredictionItem] = []
    
    // Trend 文件数据（按趋势排序，含 new / volume_trend 字段）
    @Published var polymarketTrendItems: [PredictionItem] = []
    @Published var kalshiTrendItems: [PredictionItem] = []
    
    // ✅ 新增：数据加载完成版本号，每次 loadLocalData 全部完成后 +1
    // 父视图应该监听这个来触发新分类检测，而非监听各个 items 数组
    @Published var dataGeneration: Int = 0

    // ✅ 新增：数据源可用性标志（来自服务器文件清单）
    // 默认 true，避免首屏闪烁；拿到服务器响应后会被精确更新
    @Published var hasPolymarketAvailable: Bool = true
    @Published var hasKalshiAvailable: Bool = true
    
    private let serverBaseURL = "http://106.15.183.158:5001/api/Prediction"
    private let dismissedNotificationKey = "Pred_dismissedNotification"
    
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        // 延长超时时间，给用户留出点击网络授权弹窗的时间
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 60.0
        // 【关键优化】设置为 true。首次弹网络授权框时请求会挂起等待，点允许后自动继续。
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
    
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "PredNetMonitor")
    @Published var isNetworkAvailable = true
    @Published var isWifiConnected = false
    
    init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let isNowAvailable = path.status == .satisfied
                self?.isNetworkAvailable = isNowAvailable
                self?.isWifiConnected = path.usesInterfaceType(.wifi)
                
                // 【新增】如果网络刚刚恢复（比如用户刚点了“允许连网”），且本地毫无数据，则自动触发下载
                if isNowAvailable, let self = self {
                    if self.polymarketItems.isEmpty && self.kalshiItems.isEmpty
                        && self.polymarketTrendItems.isEmpty && self.kalshiTrendItems.isEmpty {
                        Task {
                            try? await self.checkAndSync()
                        }
                    }
                }
            }
        }
        networkMonitor.start(queue: monitorQueue)
        loadLocalData()
    }
    
    deinit { networkMonitor.cancel() }
    
    // MARK: - 加载本地 JSON 数据
    func loadLocalData() {
        // 扫描 Documents 目录中的 polymarket 和 kalshi JSON
        let docDir = documentsDirectory
        
        // === 主文件 (排除 trend 文件) ===
        
        // Polymarket 主文件
        if let polyFile = findLatestFile(prefix: "polymarket_", in: docDir, excluding: "_trend_"),
           let data = try? Data(contentsOf: polyFile) {
            self.polymarketItems = PredictionParser.parse(jsonData: data, source: .polymarket)
        } else {
            // ✅ 改动：如果找不到文件，确保清空旧数据（防止残留）
            self.polymarketItems = []
        }
        
        // Kalshi 主文件
        if let kalshiFile = findLatestFile(prefix: "kalshi_", in: docDir, excluding: "_trend_"),
           let data = try? Data(contentsOf: kalshiFile) {
            self.kalshiItems = PredictionParser.parse(jsonData: data, source: .kalshi)
        } else {
            self.kalshiItems = []
        }
        
        // === Trend 文件 ===
        
        // Polymarket Trend（可能不存在，兼容处理）
        if let polyTrendFile = findLatestFile(prefix: "polymarket_trend_", in: docDir),
           let data = try? Data(contentsOf: polyTrendFile) {
            self.polymarketTrendItems = PredictionParser.parse(jsonData: data, source: .polymarket)
        } else {
            self.polymarketTrendItems = []
        }
        
        // Kalshi Trend
        if let kalshiTrendFile = findLatestFile(prefix: "kalshi_trend_", in: docDir),
           let data = try? Data(contentsOf: kalshiTrendFile) {
            self.kalshiTrendItems = PredictionParser.parse(jsonData: data, source: .kalshi)
        } else {
            self.kalshiTrendItems = []
        }
        
        // ✅ 四个数组全部赋值完毕后，递增版本号作为"数据已就绪"的单一信号
        dataGeneration += 1
    }
    
    // 【修改】支持排除特定子串的文件
    private func findLatestFile(prefix: String, in directory: URL, excluding: String? = nil) -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix) && url.pathExtension == "json" else { return false }
                // 如果指定了排除关键词，过滤掉包含该关键词的文件
                if let exclude = excluding, name.contains(exclude) { return false }
                return true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }
    
    // MARK: - 同步逻辑
    func checkAndSync(isManual: Bool = false) async throws {
        if !isManual && !isNetworkAvailable {
            print("自动同步: 无网络，使用本地数据")
            return
        }
        if isManual && !isNetworkAvailable {
            throw URLError(.notConnectedToInternet)
        }
        
        isSyncing = true
        defer {
            Task { @MainActor in
                if !showAlreadyUpToDateAlert { isSyncing = false }
            }
        }
        
        do {
            let serverVersion = try await fetchServerVersion()
            
            // 清理旧文件
            try cleanOldFiles(validFiles: Set(serverVersion.files.map { $0.name }))
            
            // 检查需要下载的文件
            let jsonFiles = serverVersion.files.filter { $0.type == "json" }
            var tasksToDownload: [PredictionFileInfo] = []
            
            for fileInfo in jsonFiles {
                let localURL = documentsDirectory.appendingPathComponent(fileInfo.name)
                if fileManager.fileExists(atPath: localURL.path) {
                    if let serverMD5 = fileInfo.md5,
                       let localMD5 = calculateMD5(for: localURL),
                       serverMD5 != localMD5 {
                        tasksToDownload.append(fileInfo)
                    }
                } else {
                    tasksToDownload.append(fileInfo)
                }
            }
            
            if tasksToDownload.isEmpty {
                // ✅ 修复：在触发 loadLocalData 前提前结束 isSyncing，防止弹窗检测时获取到空数据闪退
                isSyncing = false
                
                // ✅ 即使没有新文件要下载，也重新加载一次本地数据
                // （cleanOldFiles 可能删除了不再有效的旧 polymarket 文件）
                loadLocalData()
                
                if isManual {
                    showAlreadyUpToDateAlert = true
                    resetAfterDelay()
                }
                return
            }
            
            // 下载
            for info in tasksToDownload {
                try await downloadFile(named: info.name)
            }
            
            // ✅ 修复：在触发 loadLocalData 前提前结束 isSyncing，防止弹窗检测时获取到空数据闪退
            isSyncing = false
            
            // 下载完成后重新加载数据
            loadLocalData()
            
            // ✅ 修复：只在手动同步时才调用 resetAfterDelay()
            // 自动同步时不需要，避免 withAnimation 在新分类弹窗动画期间触发干扰
            if isManual {
                resetAfterDelay()
            }
            
        } catch {
            isSyncing = false
            throw error
        }
    }
    
    // MARK: - 获取欢迎页 Topics
    func fetchWelcomeTopics() async -> [String] {
        do {
            let version = try await fetchServerVersion()
            return version.welcome_topics ?? defaultTopics
        } catch {
            return defaultTopics
        }
    }

    /// ✅ 新增：轻量级检查服务器可用的预测数据源
    /// 仅请求 check_version，不下载文件，用于首屏快速判断哪些入口可显示
    func refreshAvailabilityFromServer() async {
        guard isNetworkAvailable else { return }
        do {
            _ = try await fetchServerVersion()
        } catch {
            print("预测数据源可用性检查失败: \(error.localizedDescription)")
        }
    }
    
    private let defaultTopics = [
        "Presidential Race 🇺🇸", "Bitcoin 📈", "Premier League ⚽",
        "World Cup 🏆", "Fed Rates 🏦", "Oscar 🎬"
    ]
    
    // MARK: - 私有方法
    private func fetchServerVersion() async throws -> PredictionServerVersion {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await urlSession.data(from: url)
        let version = try JSONDecoder().decode(PredictionServerVersion.self, from: data)
        
        await MainActor.run {
            self.welcomeTopics = version.welcome_topics ?? defaultTopics
            if let time = version.update_time { self.serverUpdateTime = time }
            updateNotification(version.notification)
            checkForceUpdate(version)

            // ✅ 新增：根据服务器文件清单更新数据源可用性
            let jsonNames = version.files.filter { $0.type == "json" }.map { $0.name }
            self.hasPolymarketAvailable = jsonNames.contains { $0.hasPrefix("polymarket_") }
            self.hasKalshiAvailable = jsonNames.contains { $0.hasPrefix("kalshi_") }
        }
        
        return version
    }
    
    private func checkForceUpdate(_ version: PredictionServerVersion) {
        guard let minVer = version.min_app_version,
              let storeUrl = version.store_url else { return }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if isVersion(current, lessThan: minVer) {
            showForceUpdate = true
            appStoreURL = storeUrl
        }
    }
    
    private func isVersion(_ current: String, lessThan min: String) -> Bool {
        let c = current.split(separator: ".").compactMap { Int($0) }
        let m = min.split(separator: ".").compactMap { Int($0) }
        let count = max(c.count, m.count)
        for i in 0..<count {
            let v1 = i < c.count ? c[i] : 0
            let v2 = i < m.count ? m[i] : 0
            if v1 < v2 { return true }
            if v1 > v2 { return false }
        }
        return false
    }
    
    private func updateNotification(_ message: String?) {
        guard let msg = message, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            activeNotification = nil; return
        }
        let dismissed = UserDefaults.standard.string(forKey: dismissedNotificationKey)
        activeNotification = (msg != dismissed) ? msg : nil
    }
    
    func dismissNotification() {
        guard let msg = activeNotification else { return }
        UserDefaults.standard.set(msg, forKey: dismissedNotificationKey)
        withAnimation { activeNotification = nil }
    }
    
    private func downloadFile(named filename: String) async throws {
        guard var components = URLComponents(string: "\(serverBaseURL)/download") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components.url else { throw URLError(.badURL) }
        
        let (tempURL, response) = try await urlSession.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let dest = documentsDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: tempURL, to: dest)
        print("✅ Downloaded: \(filename)")
    }
    
    private func cleanOldFiles(validFiles: Set<String>) throws {
        let contents = try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
        let predictionFiles = contents.filter {
            $0.hasPrefix("polymarket_") || $0.hasPrefix("kalshi_") || $0 == "translation_dict.json"
        }
        for file in predictionFiles where !validFiles.contains(file) {
            let url = documentsDirectory.appendingPathComponent(file)
            try? fileManager.removeItem(at: url)
            print("🗑️ Cleaned: \(file)")
        }
    }
    
    private func calculateMD5(for url: URL) -> String? {
        var hasher = Insecure.MD5()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }
    
    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                isSyncing = false
                withAnimation { showAlreadyUpToDateAlert = false }
            }
        }
    }
}

// MARK: - 服务器版本信息
struct PredictionServerVersion: Codable {
    let version: String
    let min_app_version: String?
    let store_url: String?
    let notification: String?
    let update_time: String?
    let server_date: String?
    let welcome_topics: [String]?
    let files: [PredictionFileInfo]
}

struct PredictionFileInfo: Codable {
    let name: String
    let type: String
    let md5: String?
}