import Foundation
import SwiftUI

// MARK: - 数据模型 (无修改)
struct VersionResponse: Codable {
    let version: String
    let files: [FileInfo]
}

struct FileInfo: Codable, Hashable {
    let name: String
    let type: String
    let updateType: String?

    // --- 新增此部分 ---
    enum CodingKeys: String, CodingKey {
        case name
        case type
        case updateType = "update_type" // 将 JSON 中的 "update_type" 映射到 Swift 的 updateType 属性
    }
    // --------------------
}

// MARK: - 新增：同步响应模型
struct SyncResponse: Codable {
    let lastId: Int
    let changes: [Change]
    
    enum CodingKeys: String, CodingKey {
        case lastId = "last_id"
        case changes
    }
}

struct Change: Codable {
    let logId: Int
    let table: String
    let op: String // "I", "U", "D"
    let rowid: Int
    let data: [String: JSONValue]? // 用于 I 和 U 操作
    
    enum CodingKeys: String, CodingKey {
        case logId = "log_id"
        case table, op, rowid, data
    }
}

// 用于解码 [String: Any] 的辅助类型
enum JSONValue: Codable {
    case int(Int)
    case double(Double)
    case string(String)
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}


// MARK: - 更新状态 (无修改)
enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(progress: Double, total: Int)
    case updateCompleted
    case alreadyUpToDate
    case error(message: String)
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


// MARK: - UpdateManager
@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var updateState: UpdateState = .idle
    
    private let serverBaseURL = "http://192.168.50.148:5000/api/Finance"
    private let localVersionKey = "FinanceAppLocalDataVersion"
    private let lastSyncIdKey = "FinanceLastSyncID" // 新增: 用于数据库同步
    
    private init() {}
    
    private var isInitialLoad: Bool {
        let localVersion = UserDefaults.standard.string(forKey: localVersionKey)
        return localVersion == nil || localVersion == "0.0"
    }
    
    func checkForUpdates(isManual: Bool = false) async -> Bool {
        if case .checking = updateState, !isManual { return false }
        if case .downloading = updateState { return false }
        
        if isManual { // 仅在手动检查时立即显示 "checking"
            self.updateState = .checking
            try? await Task.sleep(for: .milliseconds(1))
        }
        
        print("开始检查更新... (手动触发: \(isManual))")
        
        let result = await fetchServerVersion()
        
        switch result {
        case .success(let serverVersionResponse):
            let localVersion = UserDefaults.standard.string(forKey: localVersionKey) ?? "0.0"
            print("服务器版本: \(serverVersionResponse.version), 本地版本: \(localVersion)")
            
            // 首次安装时，即使版本号相同，也需要下载/同步一次
            let isFirstTimeSetup = (UserDefaults.standard.string(forKey: localVersionKey) == nil)
            
            if isFirstTimeSetup || serverVersionResponse.version.compare(localVersion, options: .numeric) == .orderedDescending {
                print(isFirstTimeSetup ? "首次启动，开始同步所有资源..." : "发现新版本，开始下载/同步文件...")
                
                // MARK: - 核心修改点
                // 现在 downloadAndSyncFiles 会处理下载和同步两种情况
                let success = await downloadAndSyncFiles(from: serverVersionResponse)
                
                if success {
                    print("所有文件更新成功。")
                    // 清理时要传入所有新文件的信息
                    cleanupOldFiles(keeping: serverVersionResponse.files)
                    UserDefaults.standard.set(serverVersionResponse.version, forKey: localVersionKey)
                    print("本地版本已更新至: \(serverVersionResponse.version)")
                    self.updateState = .updateCompleted
                    resetStateAfterDelay()
                    return true
                } else {
                    let errorMessage = "文件更新失败。"
                    self.updateState = .error(message: errorMessage)
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
    
    // MARK: - 重构的核心方法：downloadAndSyncFiles
    private func downloadAndSyncFiles(from versionResponse: VersionResponse) async -> Bool {
        let allFiles = versionResponse.files
        // ==================【请在这里加入调试代码】==================
            print("--- 开始调试 downloadAndSyncFiles ---")
            print("从 version.json 解析到的所有文件信息:")
            for file in allFiles {
                // 我们想知道 updateType 是否被正确解析
                print("- 文件名: \(file.name), 类型: \(file.type), 更新方式(updateType): \(file.updateType ?? "nil")")
            }
            print("-----------------------------------------")
            // ========================================================
        let totalTasks = allFiles.count
        var completedTasks = 0
        
        // 区分需要同步和需要下载的文件
        let syncableFiles = allFiles.filter { $0.updateType == "sync" }
        let downloadableFiles = allFiles.filter { $0.updateType != "sync" }
        
        // ==================【再在这里加入调试代码】==================
            print("--- 逻辑判断 ---")
            print("被识别为需要【同步】的文件数量: \(syncableFiles.count)")
            print("被识别为需要【下载】的文件数量: \(downloadableFiles.count)")
            
        if syncableFiles.first(where: { $0.name == "Finance.db" }) != nil {
                let dbExists = FileManagerHelper.fileExists(named: "Finance.db")
                print("Finance.db 被识别为同步文件。")
                print("检查本地文件是否存在 (fileExists): \(dbExists)")
                if !dbExists {
                    print("结论：本地数据库不存在，将执行全量下载。")
                } else {
                    print("结论：本地数据库已存在，将执行增量同步。")
                }
            } else {
                print("警告：Finance.db 未被识别为同步文件！")
            }
            print("------------------")
            // ========================================================
        
        self.updateState = .downloading(progress: 0, total: totalTasks)
        
        // 1. 先处理同步任务 (通常只有一个数据库文件)
        for fileInfo in syncableFiles {
            let success: Bool
            // 如果是首次安装，数据库文件不存在，需要全量下载一次
            if !FileManagerHelper.fileExists(named: "Finance.db") {
                print("本地数据库不存在，执行首次全量下载...")
                success = await downloadFile(named: fileInfo.name)
                // 下载成功后，需要获取服务器最新的 log id 并保存，以便下次增量同步
                if success {
                     await resetSyncIDToLatest()
                }
            } else {
                // 否则，执行增量同步
                print("执行数据库增量同步...")
                success = await syncDatabase()
            }
            
            if !success {
                print("数据库同步或下载失败: \(fileInfo.name)")
                return false // 一个失败则整个流程失败
            }
            
            completedTasks += 1
            let progress = Double(completedTasks) / Double(totalTasks)
            self.updateState = .downloading(progress: progress, total: totalTasks)
        }
        
        // 2. 并行处理所有下载任务
        if downloadableFiles.isEmpty {
             return true // 如果没有其他文件要下载，到此成功结束
        }
        
        return await withTaskGroup(of: Bool.self, body: { group in
            for fileInfo in downloadableFiles {
                group.addTask {
                    return await self.downloadFile(named: fileInfo.name)
                }
            }
            
            var allSuccess = true
            for await success in group {
                if success {
                    completedTasks += 1
                    let progress = Double(completedTasks) / Double(totalTasks)
                    await MainActor.run {
                        self.updateState = .downloading(progress: progress, total: totalTasks)
                    }
                } else {
                    allSuccess = false
                }
            }
            return allSuccess
        })
    }

    // MARK: - 新增：数据库同步逻辑
    private func syncDatabase() async -> Bool {
        let lastID = UserDefaults.standard.integer(forKey: lastSyncIdKey)
        guard let url = URL(string: "\(serverBaseURL)/sync?last_id=\(lastID)") else {
            print("无效的同步URL")
            return false
        }
        
        do {
            print("正在从 last_id: \(lastID) 开始同步...")
            let (data, _) = try await URLSession.shared.data(from: url)
            
            let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)
            
            if syncResponse.changes.isEmpty {
                print("没有需要同步的变更。")
                return true
            }
            
            print("获取到 \(syncResponse.changes.count) 条变更，准备应用...")
            
            // 调用 DBManager 应用变更
            let applySuccess = await DatabaseManager.shared.applySyncChanges(syncResponse.changes)
            
            if applySuccess {
                UserDefaults.standard.set(syncResponse.lastId, forKey: lastSyncIdKey)
                print("同步成功，新的 last_id 已更新为: \(syncResponse.lastId)")
                return true
            } else {
                print("应用数据库变更失败。")
                return false
            }
            
        } catch {
            print("同步失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // 新增辅助函数：当首次下载DB后，获取服务器最新log_id
    private func resetSyncIDToLatest() async {
        // 调用 sync 接口，但 last_id 给一个超大值，这样服务器不会返回任何 changes，
        // 只会返回当前最新的 log_id
        let veryLargeLastID = 999999999
        guard let url = URL(string: "\(serverBaseURL)/sync?last_id=\(veryLargeLastID)") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)
            UserDefaults.standard.set(syncResponse.lastId, forKey: lastSyncIdKey)
            print("已重置数据库同步点，最新 last_id 为: \(syncResponse.lastId)")
        } catch {
            print("获取最新 log_id 失败: \(error)")
            // 如果失败，下次同步会从 0 开始，可能会导致一些重复操作，但 REPLACE INTO 可以处理
            UserDefaults.standard.set(0, forKey: lastSyncIdKey)
        }
    }

    
    private func downloadFile(named filename: String) async -> Bool {
        guard let url = URL(string: "\(serverBaseURL)/download?filename=\(filename)") else {
            print("无效的下载URL for \(filename)")
            return false
        }
        
        do {
            print("正在下载最新数据: \(filename)")
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
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
                    print("已删除旧文件: \(filename)")
                }
            }
        } catch {
            print("清理旧文件时出错: \(error)")
        }
    }
}

// MARK: - FileManagerHelper (新增一个辅助方法)
class FileManagerHelper {
    
    static var documentsDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
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
            
            if let file = latestFile {
                print("找到最新文件 for '\(baseName)': \(file.url.lastPathComponent)")
                return file.url
            } else {
                print("警告: 未能在 Documents 中找到 for '\(baseName)' 的任何版本文件。")
                return nil
            }
            
        } catch {
            print("错误: 无法列出 Documents 目录中的文件: \(error)")
            return nil
        }
    }
}
