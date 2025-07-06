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
    
    // --- 状态管理 ---
    @Published var isSyncing = false
    @Published var syncMessage = "启动中..."
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var progressText = ""
    
    private let serverBaseURL = "http://192.168.50.147:5000/api/ONews"
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - Main Sync Logic
    func checkAndDownloadUpdates() async throws {
        // 1. 初始化状态
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = "正在检查更新..."
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            let serverVersion = try await getServerVersion()
            let localFiles = try getLocalFiles()
            
            // ==================== 核心修改区域开始 ====================
            // 2. 清理过时的本地文件和目录
            // 在比较需要下载的文件之前，先进行清理操作。
            self.syncMessage = "正在清理旧资源..."
            
            // 从服务器获取所有有效的文件/目录名集合
            let validServerFiles = Set(serverVersion.files.map { $0.name })
            
            // 找出本地存在，但服务器清单中已不存在的文件/目录
            let filesToDelete = localFiles.subtracting(validServerFiles)
            
            // 为了安全起见，我们只删除符合特定命名规则的旧文件，防止误删其他文件
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
                        // 如果删除失败，仅打印错误，不中断整个同步流程
                        print("⚠️ 删除资源 \(itemName) 失败: \(error.localizedDescription)")
                    }
                }
            } else {
                print("本地资源无需清理。")
            }
            // ==================== 核心修改区域结束 ====================

            // 3. 检查需要下载的文件
            // 这里的逻辑保持不变，它会对比服务器列表和（清理前的）本地文件列表
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
        let (data, _) = try await URLSession.shared.data(from: url)
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
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    private func downloadDirectory(named directoryName: String, totalFiles: Int, currentIndex: Int) async throws {
        let fileList = try await getFileList(for: directoryName)
        if fileList.isEmpty {
            print("目录 \(directoryName) 在服务器上为空，跳过。")
            return
        }
        print("目录 \(directoryName) 包含 \(fileList.count) 个文件，准备逐个下载。")
        
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        for (fileIndex, remoteFilename) in fileList.enumerated() {
            self.syncMessage = "正在下载新闻图片... (\(fileIndex + 1)/\(fileList.count))"
            
            let downloadPath = "\(directoryName)/\(remoteFilename)"
            
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else {
                print("❌ Invalid base URL for components")
                continue
            }
            components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
            guard let url = components.url else {
                print("❌ Could not create final URL from components for path: \(downloadPath)")
                continue
            }
            
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ 服务器响应错误 for \(url.absoluteString)")
                throw URLError(.badServerResponse)
            }
            
            let destinationURL = localDirectoryURL.appendingPathComponent(remoteFilename)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
        print("✅ 目录 \(directoryName) 内所有文件下载完成。")
    }
    
    private func downloadSingleFile(named filename: String) async throws {
        guard var components = URLComponents(string: "\(serverBaseURL)/download") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        print("✅ [1/3] 开始下载单个文件: \(url.absoluteString)")
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        print("✅ [2/3] 下载成功，临时文件位于: \(tempURL.path)")
        
        let destinationURL = documentsDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        print("✅ [3/3] 文件 \(filename) 已成功保存。")
    }
}
