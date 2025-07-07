import Foundation

// 数据模型保持不变
struct FileInfo: Codable {
    let name: String
    let type: String
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
    
    private let serverBaseURL = "http://192.168.50.148:5000/api/ONews" // IP地址暂时保持错误的，以测试健壮性
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // 创建一个自定义配置的URLSession，以控制超时
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // 设置一个较短的请求超时时间，例如10秒。
        // 如果10秒内服务器没有响应，请求就会失败，而不是等待默认的60秒。
        configuration.timeoutIntervalForRequest = 10
        
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
                    do {
                        try fileManager.removeItem(at: itemURL)
                        print("🗑️ 已成功删除: \(itemName)")
                    } catch {
                        print("⚠️ 删除资源 \(itemName) 失败: \(error.localizedDescription)")
                    }
                }
            } else {
                print("本地资源无需清理。")
            }

            // 3. 检查需要下载的文件
            let filesToDownload = serverVersion.files.filter { fileInfo in
                !localFiles.contains(fileInfo.name)
            }
            
            if filesToDownload.isEmpty {
                syncMessage = "当前资源已经是最新的了。"
                try await Task.sleep(nanoseconds: 1_500_000_000)
                self.isSyncing = false
                return
            }
            
            print("需要下载的文件或目录: \(filesToDownload.map { $0.name })")
            
            // 4. 进入下载阶段
            self.isDownloading = true
            let totalFiles = filesToDownload.count
            
            for (index, fileInfo) in filesToDownload.enumerated() {
                self.progressText = "\(index + 1)/\(totalFiles)"
                self.downloadProgress = Double(index + 1) / Double(totalFiles)
                
                if fileInfo.type == "images" {
                    self.syncMessage = "正在处理目录..."
                    try await downloadDirectory(named: fileInfo.name, totalFiles: totalFiles, currentIndex: index)
                } else {
                    self.syncMessage = "正在下载文件..."
                    try await downloadSingleFile(named: fileInfo.name)
                }
            }
            
            // 5. 同步完成
            self.isDownloading = false
            self.syncMessage = "更新完成！"
            self.progressText = ""
            try await Task.sleep(nanoseconds: 1_000_000_000)
            self.isSyncing = false
            
        } catch {
            // 6. 错误处理
            self.isSyncing = false
            self.isDownloading = false
            throw error
        }
    }
    
    // MARK: - Helper Functions
    
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
    
    private func downloadDirectory(named directoryName: String, totalFiles: Int, currentIndex: Int) async throws {
        // ... 内部逻辑不变，只需修改网络请求部分 ...
        let fileList = try await getFileList(for: directoryName)
        if fileList.isEmpty { return }
        
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
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
