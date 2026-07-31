import Foundation
import SwiftUI
import Combine
import Network // ✅ 引入 Network

// MARK: - 数据模型 (无修改)
struct VersionResponse: Codable {
    let version: String
    let server_date: String?
    let min_app_version: String?
    let store_url: String?

    let daily_free_limit: Int?
    let cost_config: [String: Int]?
    let bonus_points: Int?
    let sector_cost_overrides: [String: Int]?
    let featured_cards: [String: String]?
    let is_free_access_day: Bool?   // 【新增】服务器权威的免点数日标志

    let strategy_groups: [String]?
    let group_display_names: [String: String]?

    let Eco_Data: String?
    let Intro_Symbol: String?
    let option_cap_limit: Double?
    let notification: String?
    let files: [FileInfo]
}

struct FileInfo: Codable, Hashable {
    let name: String
    let type: String
    let updateType: String?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case updateType = "update_type"
    }
}

// MARK: - 更新状态 (无修改)
enum UpdateState: Equatable {
    case idle
    case checking
    case downloadingFile(name: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case downloading(progress: Double, total: Int)
    case updateCompleted
    case alreadyUpToDate
    case error(message: String)
    
    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.checking, .checking): return true
        case (let .downloadingFile(n1, p1, db1, tb1), let .downloadingFile(n2, p2, db2, tb2)):
            return n1 == n2 && p1 == p2 && db1 == db2 && tb1 == tb2
        case (let .downloading(p1, t1), let .downloading(p2, t2)):
            return p1 == p2 && t1 == t2
        case (.updateCompleted, .updateCompleted): return true
        case (.alreadyUpToDate, .alreadyUpToDate): return true
        case (let .error(m1), let .error(m2)):
            return m1 == m2
        default:
            return false
        }
    }
}


// MARK: - 网络错误类型枚举 (无修改)
enum NetworkErrorType {
    case clientOffline
    case serverUnreachable(String)
    case decodingFailed(String)
}

// MARK: - fetchServerVersion 的返回结果枚举 (无修改)
enum ServerVersionResult {
    case success(VersionResponse)
    case failure(NetworkErrorType)
}

// MARK: - 数据库下载结果枚举
enum DBDownloadResult {
    case success
    case skippedAlreadyLatest
    case failed
    case cancelled
}

// MARK: - UpdateManager
@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var updateState: UpdateState = .idle
    
    @Published var showForceUpdate: Bool = false
    @Published var appStoreURL: String = ""
    
    @Published var dbDownloadProgress: Double = 0.0
    @Published var isDownloadingDB: Bool = false
    @Published var activeNotification: String? = nil
    private let dismissedNotificationKey = "FinanceDismissedNotificationContent"
    
    // 【新增】离线数据库占用空间文案（个人中心展示）
    @Published var localDBSizeText: String = ""
    // 【新增】最近一次自动清理释放的空间文案（用于个人中心提示）
    @Published var lastCleanupFreedText: String? = nil
    
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    private let localVersionKey = "FinanceAppLocalDataVersion"
    
    private let dbDownloadDateKey = "FinanceDBDownloadDate"
    private let dbFilename = "Finance.db"
    // 【新增】SQLite 可能生成的旁支文件，删除主库时必须一并清理
    private var dbSidecarFiles: [String] {
        [dbFilename + "-wal", dbFilename + "-shm", dbFilename + "-journal"]
    }
    
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "UpdateManagerNetworkMonitor")
    @Published var isNetworkAvailable: Bool = true
    
    private var currentDownloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    var isPaused: Bool {
        return resumeData != nil
    }
    
    private init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: monitorQueue)
        refreshLocalDBSize()
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
    
    func updateNotificationStatus(serverMessage: String?) {
        guard let message = serverMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    func dismissNotification() {
        guard let message = activeNotification else { return }
        UserDefaults.standard.set(message, forKey: dismissedNotificationKey)
        withAnimation {
            self.activeNotification = nil
        }
    }

    func checkForUpdates(isManual: Bool = false) async -> Bool {
        if !isManual && !isNetworkAvailable {
            print("UpdateManager: 自动检查更新 - 检测到无网络，跳过网络请求，使用本地数据。")
            return false
        }
        
        if isManual && !isNetworkAvailable {
            self.updateState = .error(message: "当前无网络连接")
            resetStateAfterDelay()
            return false
        }

        if case .checking = updateState, !isManual { return false }
        
        await MainActor.run { self.updateState = .checking }
        
        if isManual {
            try? await Task.sleep(for: .milliseconds(1))
        }
        
        print("开始检查更新... (手动触发: \(isManual))")
        
        let result = await fetchServerVersion()
        
        switch result {
        case .success(let serverVersionResponse):
            if let serverDate = serverVersionResponse.server_date {
                UsageManager.shared.checkResetWithServerDate(serverDate)
            }

            if let limit = serverVersionResponse.daily_free_limit {
                UsageManager.shared.updateLimit(limit)
                print("UpdateManager: 已更新每日免费次数限制为 \(limit)")
            }
            
            if let costs = serverVersionResponse.cost_config {
                UsageManager.shared.updateCosts(costs)
                print("UpdateManager: 已更新扣点规则: \(costs)")
            }

            if let bonus = serverVersionResponse.bonus_points {
                UsageManager.shared.updateBonus(bonus)
            }
            if let overrides = serverVersionResponse.sector_cost_overrides {
                UsageManager.shared.updateSectorOverrides(overrides)
                print("UpdateManager: 已更新分组扣点覆盖: \(overrides)")
            }
            
            DataService.shared.updateFeaturedCards(serverVersionResponse.featured_cards ?? [:])
            DataService.shared.updateFreeAccessDay(serverVersionResponse.is_free_access_day)

            if let capLimit = serverVersionResponse.option_cap_limit {
                DataService.shared.updateOptionCapLimit(capLimit)
            }
            
            if let strategies = serverVersionResponse.strategy_groups {
                DataService.shared.updateStrategyConfig(
                    groups: strategies, 
                    names: serverVersionResponse.group_display_names ?? [:]
                )
            }

            DataService.shared.updateTimestamps(
                eco: serverVersionResponse.Eco_Data,
                intro: serverVersionResponse.Intro_Symbol
            )
            
            let localVersion = UserDefaults.standard.string(forKey: localVersionKey) ?? "0.0"
            print("服务器版本: \(serverVersionResponse.version), 本地版本: \(localVersion)")
            
            let isFirstTimeSetup = (UserDefaults.standard.string(forKey: localVersionKey) == nil)
            
            if isFirstTimeSetup || serverVersionResponse.version.compare(localVersion, options: .numeric) == .orderedDescending {
                print("发现新版本，开始下载文件...")
                
                let success = await downloadFiles(from: serverVersionResponse)
                
                if success {
                    cleanupOldFiles(keeping: serverVersionResponse.files)
                    UserDefaults.standard.set(serverVersionResponse.version, forKey: localVersionKey)
                    print("本地版本已更新至: \(serverVersionResponse.version)")
                    
                    // 【新增】数据版本已经变了 → 之前下载的离线库彻底失效，顺手清掉释放空间
                    cleanupStaleDatabaseIfNeeded()
                    
                    self.updateState = .updateCompleted
                    resetStateAfterDelay()
                    return true
                } else {
                    self.updateState = .error(message: "文件更新失败。")
                    resetStateAfterDelay()
                    return false
                }
            } else {
                print("当前已是最新版本。")
                if isManual {
                    self.updateState = .alreadyUpToDate
                    resetStateAfterDelay()
                } else {
                    self.updateState = .idle
                }
                return false
            }

        case .failure(let errorType):
            if isManual {
                let errorMessage: String
                switch errorType {
                case .clientOffline:
                    errorMessage = "网络未连接，请检查设置。"
                case .serverUnreachable:
                    errorMessage = "无法连接到服务器。"
                case .decodingFailed:
                    errorMessage = "服务器响应异常，请稍后重试。"
                }
                print("手动检查更新失败: \(errorMessage)")
                self.updateState = .error(message: errorMessage)
                resetStateAfterDelay()
            } else {
                print("后台自动检查更新失败，已静默处理。错误: \(errorType)")
                self.updateState = .idle
            }
            return false
        }
    }
    
    private func resetStateAfterDelay(seconds: TimeInterval = 2) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                self.updateState = .idle
            }
        }
    }
    
    private func fetchServerVersion() async -> ServerVersionResult {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else {
            return .failure(.decodingFailed("无效的URL"))
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("服务器返回了非预期的状态码: \(statusCode)")
                return .failure(.serverUnreachable("服务器返回状态码 \(statusCode)"))
            }
            
            let decodedResponse = try JSONDecoder().decode(VersionResponse.self, from: data)
            
            await MainActor.run {
                self.updateNotificationStatus(serverMessage: decodedResponse.notification)
                
                if let minVersion = decodedResponse.min_app_version,
                   let storeUrl = decodedResponse.store_url {
                    
                    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                    
                    if self.isVersion(currentVersion, lessThan: minVersion) {
                        print("检测到强制更新: 当前 \(currentVersion) < 最低 \(minVersion)")
                        self.showForceUpdate = true
                        self.appStoreURL = storeUrl
                    } else {
                        self.showForceUpdate = false
                    }
                }
            }
            
            return .success(decodedResponse)
            
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    print("网络错误：设备未连接到互联网。")
                    return .failure(.clientOffline)
                case .cannotFindHost, .cannotConnectToHost, .timedOut:
                    print("网络错误：无法连接到主机或请求超时。 \(urlError.localizedDescription)")
                    return .failure(.serverUnreachable(urlError.localizedDescription))
                default:
                    print("未分类的URL错误: \(urlError.localizedDescription)")
                    return .failure(.serverUnreachable(urlError.localizedDescription))
                }
            } else if error is DecodingError {
                print("数据解析错误: \(error.localizedDescription)")
                return .failure(.decodingFailed(error.localizedDescription))
            } else {
                print("未知网络错误: \(error.localizedDescription)")
                return .failure(.serverUnreachable(error.localizedDescription))
            }
        }
    }
    
    private func downloadFiles(from versionResponse: VersionResponse) async -> Bool {
        let allFiles = versionResponse.files
        let totalTasks = allFiles.count
        var completedTasks = 0
        
        if allFiles.isEmpty { return true }
        
        await MainActor.run {
            self.updateState = .downloading(progress: 0, total: totalTasks)
        }
        
        return await withTaskGroup(of: Bool.self, body: { group in
            for fileInfo in allFiles {
                group.addTask {
                    return await self.downloadFile(named: fileInfo.name)
                }
            }
            
            var allSuccess = true
            for await success in group {
                completedTasks += 1
                if !success {
                    allSuccess = false
                }
                
                let progress = Double(completedTasks) / Double(totalTasks)
                await MainActor.run {
                    self.updateState = .downloading(progress: progress, total: totalTasks)
                }
            }
            return allSuccess
        })
    }
    
    private func downloadFile(named filename: String) async -> Bool {
        if filename.hasPrefix("description_") {
            if FileManagerHelper.fileExists(named: filename) {
                print("UpdateManager: [增量优化] \(filename) 已存在且未变更，跳过下载。")
                return true
            }
        }
        
        guard let url = URL(string: "\(serverBaseURL)/download?filename=\(filename)") else {
            print("无效的下载URL for \(filename)")
            return false
        }
        
        do {
            print("正在下载最新数据: \(filename)")
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 60 
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("下载 \(filename) 失败，HTTP状态码: \(httpResponse.statusCode)")
                return false
            }
            
            if filename.hasSuffix("/") || filename.contains("/") {
                 let dirURL = FileManagerHelper.documentsDirectory.appendingPathComponent(filename).deletingLastPathComponent()
                 try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
            }
            
            let destinationURL = FileManagerHelper.documentsDirectory.appendingPathComponent(filename)
            try data.write(to: destinationURL)
            print("成功保存: \(filename) 到 Documents")
            return true
        } catch {
            print("下载或保存文件 \(filename) 失败: \(error)")
            return false
        }
    }

    // MARK: - 离线数据库管理逻辑
    
    /// 检查本地数据库是否有效（存在且是今天下载的）
    func isLocalDatabaseValid() -> Bool {
        guard FileManagerHelper.fileExists(named: dbFilename) else { return false }
        guard let savedDateStr = UserDefaults.standard.string(forKey: dbDownloadDateKey) else { return false }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())
        
        return savedDateStr == todayStr
    }
    
    /// 获取本地数据库路径
    func getLocalDatabasePath() -> String {
        return FileManagerHelper.documentsDirectory.appendingPathComponent(dbFilename).path
    }
    
    // MARK: - 【新增】离线数据库空间管理
    
    /// 本地是否存在离线库文件（不判断新旧）
    var localDatabaseExists: Bool {
        FileManagerHelper.fileExists(named: dbFilename)
    }
    
    /// 重新计算离线库占用空间（主库 + WAL/SHM 旁支文件）
    func refreshLocalDBSize() {
        var total = FileManagerHelper.fileSize(named: dbFilename)
        for f in dbSidecarFiles { total += FileManagerHelper.fileSize(named: f) }
        self.localDBSizeText = total > 0 ? FileManagerHelper.formatBytes(total) : ""
    }
    
    /// 【核心】自动清理"过期"的离线数据库
    /// 说明：客户端只会加载"当天下载"的库（见 isLocalDatabaseValid），
    ///      因此任何非今天下载的 Finance.db 都是永远不会被使用的僵尸文件，直接删除即可。
    @discardableResult
    func cleanupStaleDatabaseIfNeeded() -> Bool {
        // 正在下载中绝对不能动文件
        if isDownloadingDB { return false }
        // 有断点续传数据时也先不动（用户可能想继续下载）
        if resumeData != nil { return false }
        
        guard FileManagerHelper.fileExists(named: dbFilename) else {
            // 文件不存在却残留了日期标记 → 清掉，避免 isLocalDatabaseValid 误判
            if UserDefaults.standard.string(forKey: dbDownloadDateKey) != nil {
                UserDefaults.standard.removeObject(forKey: dbDownloadDateKey)
            }
            // 旁支文件也顺手清一下
            for f in dbSidecarFiles { _ = FileManagerHelper.deleteFile(named: f) }
            refreshLocalDBSize()
            return false
        }
        
        // 今天下载的 → 有效，保留
        if isLocalDatabaseValid() {
            refreshLocalDBSize()
            return false
        }
        
        let freed = deleteLocalDatabase(isAuto: true)
        if freed > 0 {
            self.lastCleanupFreedText = "已自动清理过期离线数据库，释放 \(FileManagerHelper.formatBytes(freed))"
        }
        return freed > 0
    }
    
    /// 删除本地离线数据库（含 WAL/SHM），返回释放的字节数
    @discardableResult
    func deleteLocalDatabase(isAuto: Bool = false) -> Int64 {
        // 1) 先断开 SQLite 连接（否则文件被占用，且后续查询会持有野指针）
        DatabaseManager.shared.closeDatabase()
        
        // 2) 统计并删除主文件 + 旁支文件
        var freed: Int64 = 0
        var names = [dbFilename]
        names.append(contentsOf: dbSidecarFiles)
        for name in names {
            let size = FileManagerHelper.fileSize(named: name)
            if FileManagerHelper.deleteFile(named: name) { freed += size }
        }
        
        // 3) 清理相关状态
        UserDefaults.standard.removeObject(forKey: dbDownloadDateKey)
        self.currentDownloadTask?.cancel()
        self.currentDownloadTask = nil
        self.resumeData = nil
        self.dbDownloadProgress = 0.0
        self.isDownloadingDB = false
        refreshLocalDBSize()
        objectWillChange.send()   // isPaused / localDatabaseExists 是计算属性，主动通知刷新
        
        // 4) 回到在线模式
        DatabaseManager.shared.reconnectToLatestDatabase()
        
        if freed > 0 {
            print("UpdateManager: \(isAuto ? "【自动】" : "【手动】")已删除离线数据库，释放 \(FileManagerHelper.formatBytes(freed))")
        }
        return freed
    }
    
    // MARK: - 取消数据库下载
    func cancelDatabaseDownload() {
        guard isDownloadingDB, let task = currentDownloadTask else { return }
        
        print("UpdateManager: 用户请求取消下载...")
        
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if let data = data {
                    print("UpdateManager: 已保存断点续传数据...")
                    self.resumeData = data
                }
                
                self.isDownloadingDB = false 
                self.objectWillChange.send() 
            }
        })
    }
    
    // MARK: - 下载数据库（支持断点续传）
    @discardableResult
    func downloadDatabase(force: Bool = false) async -> DBDownloadResult {
        if !force && isLocalDatabaseValid() {
            print("UpdateManager: 本地数据库已是最新，跳过。")
            return .skippedAlreadyLatest
        }
        
        let fileURL = FileManagerHelper.documentsDirectory.appendingPathComponent(dbFilename)
        
        // 【修改】强制重下且无断点数据 → 连带清掉旧库、WAL/SHM 和日期标记
        if force && resumeData == nil {
            _ = deleteLocalDatabase(isAuto: true)
        }
        
        await MainActor.run {
            self.isDownloadingDB = true
            if self.resumeData == nil {
                self.dbDownloadProgress = 0.0
            }
        }
        
        // 【修复】服务端已要求登录才能下载离线库，必须携带 user_id
        guard let uid = UsageManager.authedUserId,
            let encUid = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("UpdateManager: 未登录，禁止下载离线数据库")
            await MainActor.run { self.isDownloadingDB = false }
            return .failed
        }
        guard let url = URL(string: "\(serverBaseURL)/download?filename=\(dbFilename)&user_id=\(encUid)") else {
            print("UpdateManager: 无效的数据库下载 URL")
            await MainActor.run { self.isDownloadingDB = false }
            return .failed
        }
        
        var finalResult: DBDownloadResult = .failed
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = DownloadDelegate(
                    onProgress: { progress in
                        Task { @MainActor in
                            self.dbDownloadProgress = progress
                        }
                    },
                    onCompletion: { tempURL, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        
                        guard let tempURL = tempURL else {
                            continuation.resume(throwing: URLError(.badServerResponse))
                            return
                        }
                        do {
                            if FileManager.default.fileExists(atPath: fileURL.path) {
                                try FileManager.default.removeItem(at: fileURL)
                            }
                            try FileManager.default.moveItem(at: tempURL, to: fileURL)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                )
                
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForResource = 1000
                config.waitsForConnectivity = true
                
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                
                var taskCreated = false
                
                if let data = self.resumeData {
                    let task = session.downloadTask(withResumeData: data)
                    if let originalRequest = task.originalRequest, originalRequest.url == url {
                        print("UpdateManager: 发现有效断点数据，正在恢复下载...")
                        self.currentDownloadTask = task
                        taskCreated = true
                    } else {
                        print("UpdateManager: 断点数据与当前 URL 不匹配或无效，丢弃。")
                        self.resumeData = nil
                    }
                }
                
                if !taskCreated {
                    print("UpdateManager: 开始全新下载...")
                    self.currentDownloadTask = session.downloadTask(with: url)
                }
                
                self.currentDownloadTask?.resume()
                session.finishTasksAndInvalidate()
            }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let todayStr = formatter.string(from: Date())
            UserDefaults.standard.set(todayStr, forKey: dbDownloadDateKey)
            
            self.resumeData = nil
            
            print("UpdateManager: 数据库下载完成。")
            DatabaseManager.shared.reconnectToLatestDatabase()
            refreshLocalDBSize()          // 【新增】刷新占用空间
            self.lastCleanupFreedText = nil
            finalResult = .success
            
        } catch {
            let nsError = error as NSError
            
            if nsError.code == NSURLErrorCancelled {
                print("UpdateManager: 下载任务已取消。")
                finalResult = .cancelled
            }
            else if self.resumeData != nil, nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil {
                print("UpdateManager: 断点续传数据似乎已过期或损坏，尝试重新下载...")
                self.resumeData = nil
                
                Task {
                    _ = await self.downloadDatabase(force: true)
                }
                finalResult = .failed 
            } else {
                print("UpdateManager: 数据库下载失败: \(error)")
                finalResult = .failed
            }
        }
        
        if finalResult != .cancelled {
            await MainActor.run {
                self.isDownloadingDB = false
                self.dbDownloadProgress = finalResult == .success ? 1.0 : 0.0
                self.currentDownloadTask = nil
                self.refreshLocalDBSize()
            }
        }
        
        return finalResult
    }
    
    // MARK: - 清理旧的按时间戳命名的数据文件
    private func cleanupOldFiles(keeping newFiles: [FileInfo]) {
        print("开始清理旧文件...")
        let newFileNames = Set(newFiles.map { $0.name })
        let fileManager = FileManager.default
        let documentsURL = FileManagerHelper.documentsDirectory
        
        let baseFileNamesToClean = Set(newFiles.compactMap { fileInfo -> String? in
            if fileInfo.name.range(of: "_\\d{6}\\.", options: .regularExpression) != nil {
                return String(fileInfo.name.split(separator: "_").first ?? "")
            }
            return nil
        })
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            
            for url in fileURLs {
                let filename = url.lastPathComponent
                
                if !baseFileNamesToClean.contains(where: { filename.hasPrefix($0) }) {
                    continue
                }
                
                if !newFileNames.contains(filename) {
                    try fileManager.removeItem(at: url)
                    print("已清理旧文件: \(filename)")
                }
            }
        } catch {
            print("清理旧文件时出错: \(error)")
        }
    }
}

// MARK: - 下载代理类 (增加节流逻辑)
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onCompletion: (URL?, Error?) -> Void
    
    private var lastUpdateTime: TimeInterval = 0
    
    init(onProgress: @escaping (Double) -> Void, onCompletion: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            
            let now = Date().timeIntervalSince1970
            if now - lastUpdateTime > 0.1 || progress >= 1.0 {
                lastUpdateTime = now
                onProgress(progress)
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onCompletion(location, nil)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onCompletion(nil, error)
        }
    }
}

class FileManagerHelper {
    
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    static func fileExists(named filename: String) -> Bool {
        let url = documentsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    // 【新增】获取文件大小（字节）；不存在返回 0
    static func fileSize(named filename: String) -> Int64 {
        let url = documentsDirectory.appendingPathComponent(filename)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            return size
        }
        return 0
    }
    
    // 【新增】删除文件（成功返回 true）
    @discardableResult
    static func deleteFile(named filename: String) -> Bool {
        let url = documentsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("FileManagerHelper: 删除 \(filename) 失败: \(error)")
            return false
        }
    }
    
    // 【新增】字节数格式化
    static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
    
    static func getLatestFileUrl(for baseName: String) -> URL? {
        let fileManager = FileManager.default
        let documentsURL = self.documentsDirectory
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            var latestFile: (url: URL, timestamp: String)? = nil
            let regex = try NSRegularExpression(pattern: "^\(baseName)_(\\d{6})\\..+$")

            for url in fileURLs {
                let filename = url.lastPathComponent
                let range = NSRange(location: 0, length: filename.utf16.count)
                if let match = regex.firstMatch(in: filename, options: [], range: range) {
                    if let timestampRange = Range(match.range(at: 1), in: filename) {
                        let timestamp = String(filename[timestampRange])
                        if latestFile == nil || timestamp > latestFile!.timestamp {
                            latestFile = (url, timestamp)
                        }
                    }
                }
            }
            return latestFile?.url
        } catch {
            return nil
        }
    }
}