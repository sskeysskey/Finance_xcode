import Foundation
import CryptoKit

// ==================== 2. 更新数据模型以包含 md5 ====================
struct FileInfo: Codable {
    let name: String
    let type: String
    // md5 是可选的，因为 "images" 类型的条目没有这个字段
    let md5: String?
}

struct ServerVersion: Codable {
    let version: String
    let files: [FileInfo]
}

@MainActor
class ResourceManager: ObservableObject {
    
    // --- 状态管理 (无变化) ---
    @Published var isSyncing = false
    @Published var syncMessage = "启动中..."
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var progressText = ""
    
    private let serverBaseURL = "http://192.168.50.148:5001/api/ONews"
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - 新增：轻量级同步函数 (供 WelcomeView 使用)
    
    /// 检查并仅下载最新的新闻清单文件（`onews_*.json`）。
    /// 此函数为新用户首次启动设计，不下载任何图片资源，以保证快速完成。
    func checkAndDownloadLatestNewsManifest() async throws {
        // 1. 初始化状态
        self.isSyncing = true
        self.isDownloading = false // 此方法不涉及下载阶段的进度条
        self.syncMessage = "正在获取新闻源列表..."
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            // 2. 获取服务器版本信息
            let serverVersion = try await getServerVersion()
            
            // 3. 从服务器文件列表中找到最新的一个 onews_*.json 文件
            guard let latestJsonInfo = serverVersion.files
                    .filter({ $0.type == "json" && $0.name.starts(with: "onews_") })
                    .sorted(by: { $0.name > $1.name }) // 按名称降序排序，第一个就是最新的
                    .first
            else {
                print("服务器上未找到任何 'onews_*.json' 文件。")
                // 即使没找到，也结束同步状态
                self.isSyncing = false
                return
            }
            
            print("找到最新的新闻清单文件: \(latestJsonInfo.name)")

            // 4. 决策：是否需要下载这个最新的JSON文件
            let localFileURL = documentsDirectory.appendingPathComponent(latestJsonInfo.name)
            var shouldDownload = false

            if fileManager.fileExists(atPath: localFileURL.path) {
                // 文件存在，检查MD5是否匹配
                guard let serverMD5 = latestJsonInfo.md5, let localMD5 = calculateMD5(for: localFileURL) else {
                    print("警告: 无法获取 \(latestJsonInfo.name) 的 MD5，将强制重新下载。")
                    shouldDownload = true
                    return
                }
                
                if serverMD5 != localMD5 {
                    print("MD5不匹配: \(latestJsonInfo.name) (服务器: \(serverMD5), 本地: \(localMD5))。计划更新。")
                    shouldDownload = true
                } else {
                    print("MD5匹配: \(latestJsonInfo.name) 已是最新。")
                }
            } else {
                // 文件不存在，直接下载
                print("新文件: \(latestJsonInfo.name)。计划下载。")
                shouldDownload = true
            }
            
            // 5. 执行下载（如果需要）
            if shouldDownload {
                self.syncMessage = "正在下载: \(latestJsonInfo.name)..."
                try await downloadSingleFile(named: latestJsonInfo.name)
                print("✅ 成功下载了 \(latestJsonInfo.name)")
            }
            
            // 6. 同步完成
            self.syncMessage = "完成！"
            try await Task.sleep(nanoseconds: 500_000_000) // 短暂显示完成信息
            self.isSyncing = false
            
        } catch {
            // 7. 错误处理
            self.isSyncing = false
            throw error
        }
    }

    // MARK: - Main Sync Logic (供 SourceListView 使用，保持不变)
    
    func checkAndDownloadUpdates() async throws {
        // ... 此函数内部逻辑保持不变 ...
        // 1. 初始化状态
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = "正在检查更新..."
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            // 2. 获取服务器版本信息和本地文件列表
            let serverVersion = try await getServerVersion()
            let localFiles = try getLocalFiles()
            
            // 2. 清理过时的本地文件和目录
            self.syncMessage = "正在清理旧资源..."
            let validServerFiles = Set(serverVersion.files.map { $0.name })
            let filesToDelete = localFiles.subtracting(validServerFiles)
            let oldNewsItemsToDelete = filesToDelete.filter {
                $0.starts(with: "onews_") || $0.starts(with: "news_images_")
            }

            if !oldNewsItemsToDelete.isEmpty {
                print("发现需要清理的过时资源: \(oldNewsItemsToDelete)")
                for itemName in oldNewsItemsToDelete {
                    let itemURL = documentsDirectory.appendingPathComponent(itemName)
                    try? fileManager.removeItem(at: itemURL)
                    print("🗑️ 已成功删除: \(itemName)")
                }
            } else {
                print("本地资源无需清理。")
            }

            // 4. 决策：找出需要下载或更新的文件
            var downloadTasks: [(fileInfo: FileInfo, isIncremental: Bool)] = []
            
            let jsonFilesFromServer = serverVersion.files.filter { $0.type == "json" }

            for jsonInfo in jsonFilesFromServer {
                let localFileURL = documentsDirectory.appendingPathComponent(jsonInfo.name)
                let correspondingImageDirName = "news_images_" + jsonInfo.name.components(separatedBy: "_").last!.replacingOccurrences(of: ".json", with: "")

                if fileManager.fileExists(atPath: localFileURL.path) {
                    guard let serverMD5 = jsonInfo.md5, let localMD5 = calculateMD5(for: localFileURL) else {
                        print("警告: 无法获取 \(jsonInfo.name) 的 MD5，跳过检查。")
                        continue
                    }
                    
                    if serverMD5 != localMD5 {
                        print("MD5不匹配: \(jsonInfo.name) (服务器: \(serverMD5), 本地: \(localMD5))。计划更新。")
                        downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                        if let imageDirInfo = serverVersion.files.first(where: { $0.name == correspondingImageDirName }) {
                             downloadTasks.append((fileInfo: imageDirInfo, isIncremental: true))
                        }
                    } else {
                        print("MD5匹配: \(jsonInfo.name) 已是最新。")
                    }
                    
                } else {
                    print("新文件: \(jsonInfo.name)。计划下载。")
                    downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                    if let imageDirInfo = serverVersion.files.first(where: { $0.name == correspondingImageDirName }) {
                        downloadTasks.append((fileInfo: imageDirInfo, isIncremental: false))
                    }
                }
            }
            
            // 5. 执行下载任务
            if downloadTasks.isEmpty {
                syncMessage = "正在更新..."
                try await Task.sleep(nanoseconds: 1_000_000_000)
                self.isSyncing = false
                return
            }
            
            print("需要处理的任务列表: \(downloadTasks.map { $0.fileInfo.name })")
            
            self.isDownloading = true
            let totalTasks = downloadTasks.count
            
            for (index, task) in downloadTasks.enumerated() {
                self.progressText = "\(index + 1)/\(totalTasks)"
                self.downloadProgress = Double(index + 1) / Double(totalTasks)
                
                switch (task.fileInfo.type, task.isIncremental) {
                case ("json", _):
                    self.syncMessage = "正在下载文件: \(task.fileInfo.name)..."
                    try await downloadSingleFile(named: task.fileInfo.name)
                
                case ("images", false):
                    self.syncMessage = "正在处理目录: \(task.fileInfo.name)..."
                    try await downloadDirectory(named: task.fileInfo.name)
                    
                case ("images", true):
                    self.syncMessage = "正在处理目录: \(task.fileInfo.name)..."
                    try await downloadDirectoryIncrementally(named: task.fileInfo.name)
                
                default:
                    print("警告: 遇到未知的任务类型 '\(task.fileInfo.type)'，跳过。")
                    continue
                }
            }
            
            // 6. 同步完成
            self.isDownloading = false
            self.syncMessage = "更新完成！"
            self.progressText = ""
            try await Task.sleep(nanoseconds: 1_000_000_000)
            self.isSyncing = false
            
        } catch {
            // 7. 错误处理
            self.isSyncing = false
            self.isDownloading = false
            throw error
        }
    }
    
    // MARK: - Helper Functions (无变化)
    
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
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()
        } catch {
            print("错误：计算文件 \(fileURL.lastPathComponent) 的 MD5 失败: \(error)")
            return nil
        }
    }

    private func downloadDirectoryIncrementally(named directoryName: String) async throws {
        let remoteFileList = try await getFileList(for: directoryName)
        if remoteFileList.isEmpty {
            print("目录 \(directoryName) 在服务器上为空，无需增量下载。")
            return
        }
        
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        
        let localContents = (try? fileManager.contentsOfDirectory(atPath: localDirectoryURL.path)) ?? []
        let localFileSet = Set(localContents)
        
        let filesToDownload = Set(remoteFileList).subtracting(localFileSet)
        
        if filesToDownload.isEmpty {
            print("目录 \(directoryName) 无需增量下载，文件已同步。")
            return
        }
        
        print("在目录 \(directoryName) 中发现 \(filesToDownload.count) 个新文件需要下载: \(filesToDownload)")
        
        let totalNewFiles = filesToDownload.count
        for (fileIndex, remoteFilename) in filesToDownload.enumerated() {
            self.syncMessage = "下载新图片... (\(fileIndex + 1)/\(totalNewFiles))"
            do {
                let downloadPath = "\(directoryName)/\(remoteFilename)"
                guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
                components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
                guard let url = components.url else { continue }
                
                let (tempURL, response) = try await urlSession.download(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                
                let destinationURL = localDirectoryURL.appendingPathComponent(remoteFilename)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)

            } catch {
                print("⚠️ 增量下载文件 \(remoteFilename) 失败: \(error.localizedDescription)。将继续下一个。")
            }
        }
    }
    
    private func getServerVersion() async throws -> ServerVersion {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else { throw URLError(.badURL) }
        let (data, _) = try await urlSession.data(from: url)
        return try JSONDecoder().decode(ServerVersion.self, from: data)
    }
    
    private func getLocalFiles() throws -> Set<String> {
        let contents = try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
        return Set(contents)
    }
    
    private func getFileList(for directoryName: String) async throws -> [String] {
        guard var components = URLComponents(string: "\(serverBaseURL)/list_files") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "dirname", value: directoryName)]
        guard let url = components.url else { throw URLError(.badURL) }
        
        print("准备获取目录清单: \(url.absoluteString)")
        let (data, _) = try await urlSession.data(from: url)
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    private func downloadDirectory(named directoryName: String) async throws {
        let fileList = try await getFileList(for: directoryName)
        if fileList.isEmpty { return }
        
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        try? fileManager.removeItem(at: localDirectoryURL)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        for (fileIndex, remoteFilename) in fileList.enumerated() {
            self.syncMessage = "正在下载新闻图片... (\(fileIndex + 1)/\(fileList.count))"
            do {
                let downloadPath = "\(directoryName)/\(remoteFilename)"
                guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
                components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
                guard let url = components.url else { continue }
                
                let (tempURL, response) = try await urlSession.download(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                
                let destinationURL = localDirectoryURL.appendingPathComponent(remoteFilename)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)

            } catch {
                print("⚠️ 下载文件 \(remoteFilename) 失败: \(error.localizedDescription)。将继续下一个文件。")
            }
        }
    }
    
    private func downloadSingleFile(named filename: String) async throws {
        guard var components = URLComponents(string: "\(serverBaseURL)/download") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components.url else { throw URLError(.badURL) }
        
        let (tempURL, response) = try await urlSession.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let destinationURL = documentsDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }
}
