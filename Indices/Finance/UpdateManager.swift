import Foundation
import SwiftUI

// MARK: - 数据模型
struct VersionResponse: Codable {
    let version: String
    let files: [FileInfo]
}

struct FileInfo: Codable, Hashable {
    let name: String
    let type: String
}

// MARK: - 更新状态
// MARK: 修改 - 添加 Equatable 协议，以便在视图中进行比较
enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(progress: Double, total: Int)
    case finished
    case error(message: String)
}

// MARK: - UpdateManager
@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var updateState: UpdateState = .idle
    
    private let serverBaseURL = "http://192.168.50.148:5000/api/Finance"
    private let localVersionKey = "FinanceAppLocalDataVersion"
    
    private init() {}
    
    func checkForUpdates() async -> Bool {
        // 防止在检查或下载过程中重复触发
        guard updateState != .checking && updateState != .downloading(progress: 0, total: 0) else {
            print("正在进行更新，请勿重复操作。")
            return false
        }
        
        self.updateState = .checking
        print("开始检查更新...")
        
        // 1. 获取服务器版本信息
        guard let serverVersionResponse = await fetchServerVersion() else {
            let errorMessage = "无法获取服务器版本信息。"
            print(errorMessage)
            self.updateState = .error(message: errorMessage)
            
            // MARK: 新增 - 错误提示显示3秒后自动消失
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    self.updateState = .idle
                }
            }
            return false
        }
        
        // 2. 获取本地版本信息
        let localVersion = UserDefaults.standard.string(forKey: localVersionKey) ?? "0.0"
        print("服务器版本: \(serverVersionResponse.version), 本地版本: \(localVersion)")
        
        // 3. 比较版本
        if serverVersionResponse.version.compare(localVersion, options: .numeric) == .orderedDescending {
            print("发现新版本，开始下载文件...")
            let downloadSuccess = await downloadFiles(from: serverVersionResponse)
            if downloadSuccess {
                print("所有文件下载成功。")
                cleanupOldFiles(keeping: serverVersionResponse.files)
                UserDefaults.standard.set(serverVersionResponse.version, forKey: localVersionKey)
                print("本地版本已更新至: \(serverVersionResponse.version)")
                self.updateState = .finished
                return true
            } else {
                let errorMessage = "文件下载失败。"
                print(errorMessage)
                self.updateState = .error(message: errorMessage)
                
                // MARK: 新增 - 错误提示显示3秒后自动消失
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run {
                        self.updateState = .idle
                    }
                }
                return false
            }
        } else {
            print("当前已是最新版本。")
            self.updateState = .finished
            return false
        }
    }
    
    private func fetchServerVersion() async -> VersionResponse? {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decodedResponse = try JSONDecoder().decode(VersionResponse.self, from: data)
            return decodedResponse
        } catch {
            print("获取或解析版本文件失败: \(error)")
            return nil
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
            print("正在下载: \(filename)")
            let (data, _) = try await URLSession.shared.data(from: url)
            
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
