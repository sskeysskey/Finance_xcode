import Foundation
import CryptoKit
import SwiftUI
import Network
import Combine

@MainActor
class SyncManager: ObservableObject {
    
    @Published var isSyncing = false
    @Published var syncMessage = "正在检查更新..."
    @Published var showForceUpdate = false
    @Published var appStoreURL = ""
    @Published var serverUpdateTime = ""
    @Published var welcomeTopics: [String] = []
    @Published var activeNotification: String? = nil
    @Published var showAlreadyUpToDateAlert = false
    
    // 本地加载的数据
    @Published var polymarketItems: [PredictionItem] = []
    @Published var kalshiItems: [PredictionItem] = []
    
    private let serverBaseURL = "http://106.15.183.158:5001/api/Prediction"
    private let dismissedNotificationKey = "Pred_dismissedNotification"
    
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 30.0
        config.waitsForConnectivity = false
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
                    if self.polymarketItems.isEmpty && self.kalshiItems.isEmpty {
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
        
        // Polymarket
        if let polyFile = findLatestFile(prefix: "polymarket_", in: docDir),
           let data = try? Data(contentsOf: polyFile) {
            self.polymarketItems = PredictionParser.parse(jsonData: data, source: .polymarket)
        }
        
        // Kalshi
        if let kalshiFile = findLatestFile(prefix: "kalshi_", in: docDir),
           let data = try? Data(contentsOf: kalshiFile) {
            self.kalshiItems = PredictionParser.parse(jsonData: data, source: .kalshi)
        }
    }
    
    private func findLatestFile(prefix: String, in directory: URL) -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
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
                if isManual {
                    showAlreadyUpToDateAlert = true
                    isSyncing = false
                    resetAfterDelay()
                }
                return
            }
            
            // 下载
            for info in tasksToDownload {
                try await downloadFile(named: info.name)
            }
            
            // 下载完成后重新加载数据
            loadLocalData()
            resetAfterDelay()
            
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
            $0.hasPrefix("polymarket_") || $0.hasPrefix("kalshi_")
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

// MARK: - 强制更新视图
struct ForceUpdateView: View {
    let storeURL: String
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 30) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 80)).foregroundColor(.blue)
                Text("需要更新").font(.largeTitle.bold()).foregroundColor(.white)
                Text("请更新至最新版本后继续使用。")
                    .foregroundColor(.gray).multilineTextAlignment(.center)
                Button {
                    if let url = URL(string: storeURL) { UIApplication.shared.open(url) }
                } label: {
                    Text("前往更新").font(.headline).foregroundColor(.white)
                        .padding().frame(maxWidth: .infinity)
                        .background(Color.blue).cornerRadius(12)
                }
                .padding(.horizontal, 40)
            }
        }
    }
}
