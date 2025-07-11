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
enum UpdateState {
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
        self.updateState = .checking
        print("开始检查更新...")
        
        // 1. 获取服务器版本信息
        guard let serverVersionResponse = await fetchServerVersion() else {
            let errorMessage = "无法获取服务器版本信息。"
            print(errorMessage)
            self.updateState = .error(message: errorMessage)
            return false
        }
        
        // 2. 获取本地版本信息
        let localVersion = UserDefaults.standard.string(forKey: localVersionKey) ?? "0.0"
        print("服务器版本: \(serverVersionResponse.version), 本地版本: \(localVersion)")
        
        // 3. 比较版本
        if serverVersionResponse.version.compare(localVersion, options: .numeric) == .orderedDescending {
            print("发现新版本，开始下载文件...")
            // 发现新版本，下载文件
            let downloadSuccess = await downloadFiles(from: serverVersionResponse)
            if downloadSuccess {
                print("所有文件下载成功。")
                // 清理旧文件
                cleanupOldFiles(keeping: serverVersionResponse.files)
                // 更新本地版本号
                UserDefaults.standard.set(serverVersionResponse.version, forKey: localVersionKey)
                print("本地版本已更新至: \(serverVersionResponse.version)")
                self.updateState = .finished
                return true // 有更新
            } else {
                let errorMessage = "文件下载失败。"
                print(errorMessage)
                self.updateState = .error(message: errorMessage)
                return false
            }
        } else {
            print("当前已是最新版本。")
            self.updateState = .finished
            return false // 无更新
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
        
        // 使用 TaskGroup 并行下载
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
                    // 在主线程更新UI状态
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
        
        // 定义文件基础名，用于识别哪些是需要版本管理的文件
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
                
                // 检查文件是否属于我们管理的基础文件名之一
                var shouldCleanup = false
                for baseName in baseFileNames {
                    if filename.hasPrefix("\(baseName)_") {
                        shouldCleanup = true
                        break
                    }
                }
                
                // 如果是受管理的文件，并且不在新文件列表中，则删除
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
    
    // 获取应用的 Documents 目录 URL
    static var documentsDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    /**
     在 Documents 目录中查找具有最新时间戳的文件。
     例如，对于 baseName="HighLow"，它会查找 "HighLow_250710.txt", "HighLow_250709.txt" 等，并返回最新的一个。
     
     - Parameters:
       - baseName: 文件名的基础部分 (例如, "HighLow")
     - Returns: 最新文件的 URL，如果找不到则返回 nil。
     */
    static func getLatestFileUrl(for baseName: String) -> URL? {
        let fileManager = FileManager.default
        let documentsURL = self.documentsDirectory
        
        do {
            // 获取 Documents 目录下的所有文件
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            
            var latestFile: (url: URL, timestamp: String)? = nil
            
            // 正则表达式，用于匹配 "baseName_YYMMDD.extension" 格式
            // 例如: "HighLow_250710.json" -> 匹配 "HighLow", "250710", ".json"
            let regex = try NSRegularExpression(pattern: "^\(baseName)_(\\d{6})\\..+$")

            for url in fileURLs {
                let filename = url.lastPathComponent
                let range = NSRange(location: 0, length: filename.utf16.count)
                
                if let match = regex.firstMatch(in: filename, options: [], range: range) {
                    // 提取时间戳 (YYMMDD)
                    if let timestampRange = Range(match.range(at: 1), in: filename) {
                        let timestamp = String(filename[timestampRange])
                        
                        // 如果是第一个匹配的文件，或者当前文件的时间戳更新
                        if latestFile == nil || timestamp > latestFile!.timestamp {
                            latestFile = (url, timestamp)
                        }
                    }
                }
            }
            
            // 如果找到了文件，返回其 URL
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
