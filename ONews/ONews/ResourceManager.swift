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
    
    @Published var isSyncing = false
    @Published var syncMessage = "正在初始化..."
    
    private let serverBaseURL = "http://192.168.50.147:5000/api/ONews"
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - Main Sync Logic
    
    func checkAndDownloadUpdates() async throws {
        self.isSyncing = true
        
        syncMessage = "正在连接服务器检查更新..."
        let serverVersion = try await getServerVersion()
        
        let localFiles = try getLocalFiles()
        
        let filesToDownload = serverVersion.files.filter { fileInfo in
            !localFiles.contains(fileInfo.name)
        }
        
        if filesToDownload.isEmpty {
            syncMessage = "所有资源都是最新的。"
            self.isSyncing = false
            return
        }
        
        print("需要下载的文件或目录: \(filesToDownload.map { $0.name })")
        
        for (index, fileInfo) in filesToDownload.enumerated() {
            let progressPrefix = "(\(index + 1)/\(filesToDownload.count))"
            
            if fileInfo.type == "images" {
                syncMessage = "\(progressPrefix) 正在处理目录: \(fileInfo.name)..."
                try await downloadDirectory(named: fileInfo.name, progressPrefix: progressPrefix)
            } else {
                syncMessage = "\(progressPrefix) 正在下载文件: \(fileInfo.name)..."
                try await downloadSingleFile(named: fileInfo.name)
            }
        }
        
        syncMessage = "同步完成！"
        self.isSyncing = false
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
        // ==================== 核心修改点 1: 使用 URLComponents ====================
        guard var components = URLComponents(string: "\(serverBaseURL)/list_files") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "dirname", value: directoryName)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        // ======================================================================
        
        print("准备获取目录清单: \(url.absoluteString)")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    private func downloadDirectory(named directoryName: String, progressPrefix: String) async throws {
        let fileList = try await getFileList(for: directoryName)
        if fileList.isEmpty {
            print("目录 \(directoryName) 在服务器上为空，跳过。")
            return
        }
        print("目录 \(directoryName) 包含 \(fileList.count) 个文件，准备逐个下载。")
        
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        for (fileIndex, remoteFilename) in fileList.enumerated() {
            self.syncMessage = "\(progressPrefix) \(directoryName) (\(fileIndex + 1)/\(fileList.count)): \(remoteFilename)"
            
            let downloadPath = "\(directoryName)/\(remoteFilename)"
            
            // ==================== 核心修改点 2: 使用 URLComponents ====================
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else {
                print("❌ Invalid base URL for components")
                continue
            }
            components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
            guard let url = components.url else {
                print("❌ Could not create final URL from components for path: \(downloadPath)")
                continue
            }
            // ======================================================================
            
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
        // ==================== 核心修改点 3: 使用 URLComponents ====================
        guard var components = URLComponents(string: "\(serverBaseURL)/download") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        // ======================================================================
        
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
