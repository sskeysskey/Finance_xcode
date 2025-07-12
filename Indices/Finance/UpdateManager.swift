// /Users/yanzhang/Documents/Xcode/Indices/Finance/UpdateManager.swift

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
            
            if serverVersionResponse.version.compare(localVersion, options: .numeric) == .orderedDescending {
                print("发现新版本，开始下载文件...")
                let downloadSuccess = await downloadFiles(from: serverVersionResponse)
                if downloadSuccess {
                    print("所有文件下载成功。")
                    cleanupOldFiles(keeping: serverVersionResponse.files)
                    UserDefaults.standard.set(serverVersionResponse.version, forKey: localVersionKey)
                    print("本地版本已更新至: \(serverVersionResponse.version)")
                    self.updateState = .updateCompleted
                    resetStateAfterDelay()
                    return true
                } else {
                    let errorMessage = "文件下载失败。"
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
            
            let (data, _) = try await URLSession.shared.data(for: request)
            let decodedResponse = try JSONDecoder().decode(VersionResponse.self, from: data)
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
        let filesToDownload = versionResponse.files
        let totalFiles = filesToDownload.count
        var downloadedCount = 0
        
        self.updateState = .downloading(progress: 0, total: totalFiles)
        
        return await withTaskGroup(of: Bool.self, body: { group in
            for fileInfo in filesToDownload {
                group.addTask {
                    return await self.downloadFile(named: fileInfo.name)
                }
            }
            
            var allSuccess = true
            for await success in group {
                if success {
                    downloadedCount += 1
                    let progress = Double(downloadedCount) / Double(totalFiles)
                    await MainActor.run {
                        self.updateState = .downloading(progress: progress, total: totalFiles)
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
            
            let destinationURL = FileManagerHelper.documentsDirectory.appendingPathComponent(filename)
            try data.write(to: destinationURL)
            print("成功保存: \(filename) 到 Documents")
            return true
        } catch {
            print("下载或保存文件 \(filename) 失败: \(error)")
            return false
        }
    }
    
    private func cleanupOldFiles(keeping newFiles: [FileInfo]) {
        print("开始清理旧文件...")
        let newFileNames = Set(newFiles.map { $0.name })
        let fileManager = FileManager.default
        let documentsURL = FileManagerHelper.documentsDirectory
        
        let baseFileNames = Set(newFiles.map { fileInfo -> String in
            if let range = fileInfo.name.range(of: "_\\d{6}\\.", options: .regularExpression) {
                return String(fileInfo.name[..<range.lowerBound])
            }
            return fileInfo.name
        })
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            
            for url in fileURLs {
                let filename = url.lastPathComponent
                
                var shouldCleanup = false
                for baseName in baseFileNames {
                    if filename.hasPrefix("\(baseName)_") {
                        shouldCleanup = true
                        break
                    }
                }
                
                if shouldCleanup && !newFileNames.contains(filename) {
                    try fileManager.removeItem(at: url)
                    print("已删除旧文件: \(filename)")
                }
            }
        } catch {
            print("清理旧文件时出错: \(error)")
        }
    }
}

// ... FileManagerHelper 保持不变 ...
class FileManagerHelper {
    
    static var documentsDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
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
