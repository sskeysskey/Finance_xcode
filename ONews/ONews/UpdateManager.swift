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
    
    // 创建一个自定义配置的URLSession，以控制超时
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // 设置一个较短的请求超时时间，例如10秒。
        // 如果10秒内服务器没有响应，请求就会失败，而不是等待默认的60秒。
        configuration.timeoutIntervalForRequest = 5
        
        // 当网络路径不可用时（例如没有Wi-Fi/蜂窝网络），让请求立即失败，而不是等待网络恢复。
        configuration.waitsForConnectivity = false
        
        return URLSession(configuration: configuration)
    }()

    // MARK: - Main Sync Logic
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
            // 我们将创建一个任务列表，而不是简单的文件名列表
            var downloadTasks: [(fileInfo: FileInfo, isIncremental: Bool)] = []
            
            // 只处理 JSON 文件来驱动决策
            let jsonFilesFromServer = serverVersion.files.filter { $0.type == "json" }

            for jsonInfo in jsonFilesFromServer {
                let localFileURL = documentsDirectory.appendingPathComponent(jsonInfo.name)
                let correspondingImageDirName = "news_images_" + jsonInfo.name.components(separatedBy: "_").last!.replacingOccurrences(of: ".json", with: "")

                // 情况一：本地文件存在，需要检查MD5
                if fileManager.fileExists(atPath: localFileURL.path) {
                    guard let serverMD5 = jsonInfo.md5, let localMD5 = calculateMD5(for: localFileURL) else {
                        print("警告: 无法获取 \(jsonInfo.name) 的 MD5，跳过检查。")
                        continue
                    }
                    
                    // 如果MD5不匹配，则判定为需要更新
                    if serverMD5 != localMD5 {
                        print("MD5不匹配: \(jsonInfo.name) (服务器: \(serverMD5), 本地: \(localMD5))。计划更新。")
                        // 任务1: 覆盖下载JSON文件
                        downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                        // 任务2: 增量同步图片目录
                        if let imageDirInfo = serverVersion.files.first(where: { $0.name == correspondingImageDirName }) {
                             downloadTasks.append((fileInfo: imageDirInfo, isIncremental: true))
                        }
                    } else {
                        print("MD5匹配: \(jsonInfo.name) 已是最新。")
                    }
                    
                // 情况二：本地文件不存在，判定为全新下载
                } else {
                    print("新文件: \(jsonInfo.name)。计划下载。")
                    // 任务1: 下载新的JSON文件
                    downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                    // 任务2: 完整下载对应的图片目录
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
            
            // 4. 进入下载阶段
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
    
    // MARK: - Helper Functions
    
    // ==================== 4. 新增：MD5 计算辅助函数 ====================
    /// 计算指定文件的 MD5 哈希值
    /// - Parameter fileURL: 本地文件的URL
    /// - Returns: 32位的十六进制小写MD5字符串，如果失败则返回nil
    private func calculateMD5(for fileURL: URL) -> String? {
        // Insecure.MD5 在这里是安全的，因为它仅用于文件校验，而非密码学安全场景。
        var hasher = Insecure.MD5()
        
        do {
            // 使用 FileHandle 以块的方式读取文件，避免大文件一次性读入内存
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { handle.closeFile() }
            
            // 循环读取文件块直到末尾
            while true {
                let data = handle.readData(ofLength: 1024 * 1024) // 每次读取 1MB
                if data.isEmpty {
                    break // 文件末尾
                }
                hasher.update(data: data)
            }
            
            // 完成哈希计算并格式化为字符串
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()
            
        } catch {
            print("错误：计算文件 \(fileURL.lastPathComponent) 的 MD5 失败: \(error)")
            return nil
        }
    }
    // ===============================================================

    // ==================== 5. 新增：增量下载目录的函数 ====================
    /// 增量下载目录内容，只下载本地不存在的文件。
    private func downloadDirectoryIncrementally(named directoryName: String) async throws {
        // 1. 获取服务器上的文件列表
        let remoteFileList = try await getFileList(for: directoryName)
        if remoteFileList.isEmpty {
            print("目录 \(directoryName) 在服务器上为空，无需增量下载。")
            return
        }
        
        // 2. 获取本地目录中的文件列表
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        // 确保本地目录存在，如果不存在则创建
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        
        let localContents = (try? fileManager.contentsOfDirectory(atPath: localDirectoryURL.path)) ?? []
        let localFileSet = Set(localContents)
        
        // 3. 计算差集，得到需要下载的文件名
        let filesToDownload = Set(remoteFileList).subtracting(localFileSet)
        
        if filesToDownload.isEmpty {
            print("目录 \(directoryName) 无需增量下载，文件已同步。")
            return
        }
        
        print("在目录 \(directoryName) 中发现 \(filesToDownload.count) 个新文件需要下载: \(filesToDownload)")
        
        // 4. 遍历并下载新文件
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
    // ===============================================================
    
    // --- 以下是原有的网络请求函数，无需修改 ---
    
    private func getServerVersion() async throws -> ServerVersion {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else { throw URLError(.badURL) }
        // --- 修改: 使用我们自定义的urlSession ---
        let (data, _) = try await urlSession.data(from: url)
        return try JSONDecoder().decode(ServerVersion.self, from: data)
    }
    
    private func getLocalFiles() throws -> Set<String> {
        let contents = try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
        return Set(contents)
    }
    
    private func getFileList(for directoryName: String) async throws -> [String] {
        guard var components = URLComponents(string: "\(serverBaseURL)/list_files") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "dirname", value: directoryName)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        print("准备获取目录清单: \(url.absoluteString)")
        // --- 修改: 使用我们自定义的urlSession ---
        let (data, _) = try await urlSession.data(from: url)
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    /// 完整下载整个目录（用于新日期的内容）
    private func downloadDirectory(named directoryName: String) async throws {
        let fileList = try await getFileList(for: directoryName)
        if fileList.isEmpty { return }
        
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        // 先删除旧目录（如果有），再创建新目录，确保是完整的全新下载
        try? fileManager.removeItem(at: localDirectoryURL)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        for (fileIndex, remoteFilename) in fileList.enumerated() {
            self.syncMessage = "正在下载新闻图片... (\(fileIndex + 1)/\(fileList.count))"
            
            do {
                let downloadPath = "\(directoryName)/\(remoteFilename)"
                guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
                components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
                guard let url = components.url else { continue }
                
                // --- 修改: 使用我们自定义的urlSession ---
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
    
    /// 下载单个文件（如 onews_...json）
    private func downloadSingleFile(named filename: String) async throws {
        guard var components = URLComponents(string: "\(serverBaseURL)/download") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        // --- 修改: 使用我们自定义的urlSession ---
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
