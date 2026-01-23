import Foundation
import SwiftUI

// MARK: - 数据模型 (无修改)
struct VersionResponse: Codable {
    let version: String
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


// MARK: - UpdateManager
@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var updateState: UpdateState = .idle
    
    // 请确保此 IP 与 AppServer 运行的 IP 一致
    private let serverBaseURL = "http://106.15.183.158:5001/api/Finance"
    private let localVersionKey = "FinanceAppLocalDataVersion"
    
    private init() {}
    
    func checkForUpdates(isManual: Bool = false) async -> Bool {
        if case .checking = updateState, !isManual { return false }
        
        await MainActor.run { self.updateState = .checking }
        
        if isManual {
            try? await Task.sleep(for: .milliseconds(1))
        }
        
        print("开始检查更新... (手动触发: \(isManual))")
        
        let result = await fetchServerVersion()
        
        switch result {
        case .success(let serverVersionResponse):
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
        
        self.updateState = .downloading(progress: 0, total: totalTasks)
        
        return await withTaskGroup(of: Bool.self, body: { group in
            for fileInfo in allFiles {
                group.addTask {
                    // 小文件继续使用旧的下载方法
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
                    print("已清理旧文件: \(filename)")
                }
            }
        } catch {
            print("清理旧文件时出错: \(error)")
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
