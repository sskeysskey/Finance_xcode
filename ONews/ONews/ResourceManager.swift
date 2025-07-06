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
    @Published var isSyncing = false          // 控制整个同步覆盖层的显示与隐藏
    @Published var syncMessage = "正在初始化..." // 显示当前操作的文本信息
    
    // --- 新增的状态，用于精确控制进度条 ---
    @Published var isDownloading = false      // 区分是“检查中”还是“下载中”
    @Published var downloadProgress: Double = 0.0 // 进度条的进度 (0.0 to 1.0)
    @Published var progressText = ""          // 进度文本，如 "1/6"
    
    private let serverBaseURL = "http://192.168.50.147:5000/api/ONews"
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - Main Sync Logic
    func checkAndDownloadUpdates() async throws {
        // 1. 初始化状态
        self.isSyncing = true
        self.isDownloading = false // 开始时不是下载状态，而是检查状态
        self.syncMessage = "正在检查更新..."
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            let serverVersion = try await getServerVersion()
            let localFiles = try getLocalFiles()
            
            let filesToDownload = serverVersion.files.filter { fileInfo in
                !localFiles.contains(fileInfo.name)
            }
            
            // 2. 检查是否需要下载
            if filesToDownload.isEmpty {
                syncMessage = "所有资源都是最新的。"
                // 等待短暂时间让用户看到消息，然后结束
                try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒
                self.isSyncing = false
                return
            }
            
            print("需要下载的文件或目录: \(filesToDownload.map { $0.name })")
            
            // 3. 进入下载阶段
            self.isDownloading = true // 切换到下载模式，UI会显示进度条
            let totalFiles = filesToDownload.count
            
            for (index, fileInfo) in filesToDownload.enumerated() {
                // 更新进度
                self.progressText = "\(index + 1)/\(totalFiles)"
                self.downloadProgress = Double(index + 1) / Double(totalFiles)
                
                if fileInfo.type == "images" {
                    self.syncMessage = "正在处理目录: \(fileInfo.name)..."
                    try await downloadDirectory(named: fileInfo.name, totalFiles: totalFiles, currentIndex: index)
                } else {
                    self.syncMessage = "正在下载文件: \(fileInfo.name)..."
                    try await downloadSingleFile(named: fileInfo.name)
                }
            }
            
            // 4. 同步完成
            self.isDownloading = false
            self.syncMessage = "同步完成！"
            self.progressText = ""
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            self.isSyncing = false
            
        } catch {
            // 5. 错误处理：直接向上抛出异常
            // 让调用方 (View) 来决定如何处理UI
            self.isSyncing = false
            self.isDownloading = false
            throw error // 将错误传递给 SourceListView 中的 catch 块
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
    
    // downloadDirectory 和 downloadSingleFile 保持不变，因为它们只负责下载逻辑
    // 进度更新的责任已经移交给了主函数 checkAndDownloadUpdates
    
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
            // 更新更详细的消息
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
