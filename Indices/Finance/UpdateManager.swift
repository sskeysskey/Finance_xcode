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
    // 【新增】扣点配置字典
    let cost_config: [String: Int]?
    // 【修改点 1】新增策略分组配置字段
    let strategy_groups: [String]?
    let group_display_names: [String: String]?
    
    // 【新增】解析新字段
    let Eco_Data: String?
    let Intro_Symbol: String?

    // 【新增】
    let option_cap_limit: Double?
    
    let files: [FileInfo]
}

struct FileInfo: Codable, Hashable {
    let name: String
    let type: String
    // updateType 不再需要 sync 逻辑，但为了兼容旧 JSON 结构可以保留定义
    let updateType: String?

    // --- 新增此部分 ---
    enum CodingKeys: String, CodingKey {
        case name
        case type
        case updateType = "update_type" // 将 JSON 中的 "update_type" 映射到 Swift 的 updateType 属性
    }
}

// MARK: - 更新状态 (无修改)
enum UpdateState: Equatable {
    case idle
    case checking
    // --- 修改此行：移除了 speed 参数 ---
    case downloadingFile(name: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case downloading(progress: Double, total: Int)
    case updateCompleted
    case alreadyUpToDate
    case error(message: String)
    
    // Equatable 的实现需要更新
    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.checking, .checking): return true
        // --- 修改此行：匹配新的 case 定义 ---
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
    /// 客户端网络问题 (例如，未连接到互联网)
    case clientOffline
    /// 服务器无法访问 (例如，IP错误、服务器关闭、超时)
    case serverUnreachable(String)
    /// 数据解析失败 (例如，服务器返回了无效的JSON)
    case decodingFailed(String)
}

// MARK: - fetchServerVersion 的返回结果枚举 (无修改)
enum ServerVersionResult {
    case success(VersionResponse)
    case failure(NetworkErrorType)
}

// MARK: - 【新增】数据库下载结果枚举
enum DBDownloadResult {
    case success            // 下载成功
    case skippedAlreadyLatest // 跳过：已经是最新
    case failed             // 失败
}

// MARK: - UpdateManager
@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var updateState: UpdateState = .idle
    
    // 【新增】强制更新状态控制
    @Published var showForceUpdate: Bool = false
    @Published var appStoreURL: String = ""
    
    // 【新增】数据库下载进度 (0.0 - 1.0)
    @Published var dbDownloadProgress: Double = 0.0
    @Published var isDownloadingDB: Bool = false
    
    // 服务器配置
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    private let localVersionKey = "FinanceAppLocalDataVersion"
    
    // 【新增】本地数据库相关 Key
    private let dbDownloadDateKey = "FinanceDBDownloadDate"
    private let dbFilename = "Finance.db"
    
    // 【新增】网络监视器
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "UpdateManagerNetworkMonitor")
    @Published var isNetworkAvailable: Bool = true
    
    private init() {
        // 【新增】启动监听
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                // 只要有网（WiFi或蜂窝）都算可用
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }
    
    // 【新增】版本号比对辅助方法
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
    
    func checkForUpdates(isManual: Bool = false) async -> Bool {
        // 【核心修改】如果是自动检查（启动时）且没有网络，直接返回 false
        // 这样就不会卡在 fetchServerVersion 的超时上
        if !isManual && !isNetworkAvailable {
            print("UpdateManager: 自动检查更新 - 检测到无网络，跳过网络请求，使用本地数据。")
            return false
        }
        
        // 如果是手动刷新，我们允许它尝试，因为用户预期会有加载过程
        // 或者也可以在这里弹窗提示
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

            // 1. 更新每日免费限制
            if let limit = serverVersionResponse.daily_free_limit {
                UsageManager.shared.updateLimit(limit)
                print("UpdateManager: 已更新每日免费次数限制为 \(limit)")
            }
            
            // 2. 更新扣点配置
            if let costs = serverVersionResponse.cost_config {
                UsageManager.shared.updateCosts(costs)
                print("UpdateManager: 已更新扣点规则: \(costs)")
            }

            // 【新增】更新期权市值阀值
            if let capLimit = serverVersionResponse.option_cap_limit {
                DataService.shared.updateOptionCapLimit(capLimit)
            }
            
            // 【新增 2】更新策略分组配置
            // 如果服务器返回了配置，就更新；否则保持默认
            if let strategies = serverVersionResponse.strategy_groups {
                // 调用 DataService 更新配置并持久化
                // 同时也把 display_names 传过去
                DataService.shared.updateStrategyConfig(
                    groups: strategies, 
                    names: serverVersionResponse.group_display_names ?? [:]
                )
            }

            // 【新增】更新界面显示的时间戳
            DataService.shared.updateTimestamps(
                eco: serverVersionResponse.Eco_Data,
                intro: serverVersionResponse.Intro_Symbol
            )
            
            let localVersion = UserDefaults.standard.string(forKey: localVersionKey) ?? "0.0"
            print("服务器版本: \(serverVersionResponse.version), 本地版本: \(localVersion)")
            
            // 首次安装时，即使版本号相同，也需要下载/同步一次
            let isFirstTimeSetup = (UserDefaults.standard.string(forKey: localVersionKey) == nil)
            
            if isFirstTimeSetup || serverVersionResponse.version.compare(localVersion, options: .numeric) == .orderedDescending {
                print("发现新版本，开始下载文件...")
                
                // 仅下载 JSON/Text 文件，不再处理 DB
                let success = await downloadFiles(from: serverVersionResponse)
                
                if success {
                    cleanupOldFiles(keeping: serverVersionResponse.files)
                    UserDefaults.standard.set(serverVersionResponse.version, forKey: localVersionKey)
                    print("本地版本已更新至: \(serverVersionResponse.version)")
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

        // MARK: - 核心修改部分
        // 这里是实现您需求的关键
        case .failure(let errorType):
            // 只有在用户“手动”刷新时，才显示网络相关的错误提示
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
                // 如果是应用启动时的“自动”检查，则静默失败，不打扰用户
                print("后台自动检查更新失败，已静默处理。错误: \(errorType)")
                self.updateState = .idle // 直接重置状态，UI上不会有任何提示
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
            
            // --- 新增：检查 HTTP 状态码 ---
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("服务器返回了非预期的状态码: \(statusCode)")
                // 你可以认为这也是一种服务器无法访问的错误
                return .failure(.serverUnreachable("服务器返回状态码 \(statusCode)"))
            }
            // ---------------------------------
            
            // 只有在状态码是 200 的情况下，才尝试解码
            let decodedResponse = try JSONDecoder().decode(VersionResponse.self, from: data)
            
            // 【新增】在这里插入强制更新检查逻辑
            await MainActor.run {
                if let minVersion = decodedResponse.min_app_version,
                   let storeUrl = decodedResponse.store_url {
                    
                    // 获取当前 App 版本 (Info.plist)
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
            // ... catch 块的逻辑保持不变
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
                // 加上这一句，可以帮助调试
                // if let responseString = String(data: data, encoding: .utf8) { print(responseString) }
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
        
        // 初始状态
        await MainActor.run {
            self.updateState = .downloading(progress: 0, total: totalTasks)
        }
        
        return await withTaskGroup(of: Bool.self, body: { group in
            for fileInfo in allFiles {
                group.addTask {
                    // 小文件继续使用旧的下载方法
                    return await self.downloadFile(named: fileInfo.name)
                }
            }
            
            var allSuccess = true
            for await success in group {
                completedTasks += 1
                // 只有成功才算 true，但无论成功失败都要更新进度，避免进度条卡住
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
        guard let url = URL(string: "\(serverBaseURL)/download?filename=\(filename)") else {
            print("无效的下载URL for \(filename)")
            return false
        }
        
        do {
            print("正在下载最新数据: \(filename)")
            
            // MARK: - 【修改点】优化网络请求配置
            // 1. 缩短超时时间：文本文件通常很小，15秒足够。如果15秒下不下来，说明网络有问题，不如快速失败。
            // 2. 禁用等待连接：避免在网络切换时无限挂起。
            var request = URLRequest(url: url)
            request.timeoutInterval = 15 // 从 60 改为 15
            request.cachePolicy = .reloadIgnoringLocalCacheData // 确保不读缓存
            
            // 使用配置更严格的 Session (可选，这里直接用 request 配置即可)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // 检查 HTTP 状态码
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("下载 \(filename) 失败，HTTP状态码: \(httpResponse.statusCode)")
                return false
            }
            
            // 如果是目录类型，先创建目录
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
        // 1. 检查文件是否存在
        guard FileManagerHelper.fileExists(named: dbFilename) else { return false }
        
        // 2. 检查记录的下载日期
        guard let savedDateStr = UserDefaults.standard.string(forKey: dbDownloadDateKey) else { return false }
        
        // 3. 获取今天的日期字符串
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())
        
        // 4. 比较
        return savedDateStr == todayStr
    }
    
    /// 获取本地数据库路径
    func getLocalDatabasePath() -> String {
        return FileManagerHelper.documentsDirectory.appendingPathComponent(dbFilename).path
    }
    
    // MARK: - 【修改点】下载数据库（返回结果枚举）
    // 之前返回 Void，现在返回 DBDownloadResult 以便 UI 做出响应
    @discardableResult
    func downloadDatabase(force: Bool = false) async -> DBDownloadResult {
        // 1. 防重复检查
        if !force && isLocalDatabaseValid() {
            print("UpdateManager: 本地数据库已是最新（今日已下载），跳过下载。")
            return .skippedAlreadyLatest // 【修改】返回跳过状态
        }
        
        let fileURL = FileManagerHelper.documentsDirectory.appendingPathComponent(dbFilename)
        try? FileManager.default.removeItem(at: fileURL)
        
        await MainActor.run {
            self.isDownloadingDB = true
            self.dbDownloadProgress = 0.0
        }
        
        guard let url = URL(string: "\(serverBaseURL)/download?filename=\(dbFilename)") else {
            print("UpdateManager: 无效的数据库下载 URL")
            await MainActor.run { self.isDownloadingDB = false }
            return .failed // 【修改】返回失败
        }
        
        var downloadSuccess = false
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 创建 Delegate 实例
                let delegate = DownloadDelegate(
                    onProgress: { progress in
                        // 回调在 Session 队列，需切回主线程更新 UI
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
                            // 移动临时文件到目标位置
                            // 如果目标存在先删除（虽然上面删过了，但为了保险）
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
                
                // 创建自定义 Session
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                task.resume()
                
                // 保持 delegate 引用，防止被释放（虽然 session 会持有 delegate，但显式持有更安全）
                // 在这个闭包作用域内 session 是活着的
                session.finishTasksAndInvalidate() 
            }
            
            // 下载成功后的逻辑
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let todayStr = formatter.string(from: Date())
            UserDefaults.standard.set(todayStr, forKey: dbDownloadDateKey)
            
            print("UpdateManager: 数据库下载完成，已保存。日期: \(todayStr)")
            DatabaseManager.shared.reconnectToLatestDatabase()
            downloadSuccess = true
            
        } catch {
            print("UpdateManager: 数据库下载失败: \(error)")
            downloadSuccess = false
        }
        
        await MainActor.run {
            self.isDownloadingDB = false
            self.dbDownloadProgress = 1.0
        }
        
        return downloadSuccess ? .success : .failed // 【修改】返回最终结果
    }
    
    // MARK: - 修改后的清理逻辑
    private func cleanupOldFiles(keeping newFiles: [FileInfo]) {
        print("开始清理旧文件...")
        // 包含所有新版本文件的文件名集合，包括像 Finance.db 这样的固定名称文件
        let newFileNames = Set(newFiles.map { $0.name })
        let fileManager = FileManager.default
        let documentsURL = FileManagerHelper.documentsDirectory
        
        // 需要清理的文件的基本名称（不含时间戳的部分）
        // 我们只对那些文件名里包含时间戳模式的文件进行“按前缀清理”
        let baseFileNamesToClean = Set(newFiles.compactMap { fileInfo -> String? in
            // 如果文件是按时间戳管理的，才把它加入清理列表
            if fileInfo.name.range(of: "_\\d{6}\\.", options: .regularExpression) != nil {
                return String(fileInfo.name.split(separator: "_").first ?? "")
            }
            return nil
        })
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            
            for url in fileURLs {
                let filename = url.lastPathComponent
                
                // 跳过不应该被自动清理的固定文件，比如 Finance.db
                if !baseFileNamesToClean.contains(where: { filename.hasPrefix($0) }) {
                    continue
                }
                
                // 如果一个带时间戳的文件，其完整文件名不在新版本文件列表中，则删除
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

// MARK: - 【修改】下载代理类 (增加节流逻辑)
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onCompletion: (URL?, Error?) -> Void
    
    // 增加一个时间戳记录，用于节流
    private var lastUpdateTime: TimeInterval = 0
    
    init(onProgress: @escaping (Double) -> Void, onCompletion: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }
    
    // 进度回调：系统底层每下载一块数据调用一次，效率极高
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            
            // 【核心优化】节流逻辑：
            // 只有当距离上次更新超过 0.1 秒，或者进度已经完成 (1.0) 时，才回调 UI 更新。
            // 这避免了高速下载时主线程被成千上万次 UI 刷新请求卡死。
            let now = Date().timeIntervalSince1970
            if now - lastUpdateTime > 0.1 || progress >= 1.0 {
                lastUpdateTime = now
                onProgress(progress)
            }
        }
    }
    
    // 下载完成回调：文件已下载到临时位置 location
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onCompletion(location, nil)
    }
    
    // 任务结束回调（处理错误）
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
    
    // 新增：检查文件是否存在
    static func fileExists(named filename: String) -> Bool {
        let url = documentsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path)
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