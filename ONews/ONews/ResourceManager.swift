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
                syncMessage = "正在更新..."
                try await Task.sleep(nanoseconds: 1_000_000_000)
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

// ==================== 移植到外网服务器上替换用的完整代码 ====================
//// This enum simplifies error handling for the UI layer.
//enum SyncError: Error, LocalizedError {
//    case serverUnreachable(originalError: Error)
//    case serverError(statusCode: Int)
//    case decodingError(originalError: Error)
//    case securityError(originalError: Error)
//    case unknown(originalError: Error)
//    
//    // Provide user-friendly descriptions for alerts
//    var errorDescription: String? {
//        switch self {
//        case .serverUnreachable:
//            return "无法连接到服务器。请检查您的网络连接或稍后重试。"
//        case .serverError(let statusCode):
//            return "服务器遇到问题 (代码: \(statusCode))。请稍后重试。"
//        case .securityError:
//            return "无法建立安全的连接。请检查网络设置或联系支持。"
//        case .decodingError, .unknown:
//            return "发生未知错误，同步失败。请尝试刷新。"
//        }
//    }
//}
//
//
//// 数据模型保持不变
//struct FileInfo: Codable {
//    let name: String
//    let type: String
//}
//
//struct ServerVersion: Codable {
//    let version: String
//    let files: [FileInfo]
//}
//
//@MainActor
//class ResourceManager: ObservableObject {
//    
//    // --- 状态管理 (无变化) ---
//    @Published var isSyncing = false
//    @Published var syncMessage = "启动中..."
//    @Published var isDownloading = false
//    @Published var downloadProgress: Double = 0.0
//    @Published var progressText = ""
//    
//    // ==================== 2. Update for Production Server ====================
//    // IMPORTANT: Use HTTPS for remote servers. Replace with your actual domain.
//    private let serverBaseURL = "https://your-remote-server.com/api/ONews"
//    
//    private let fileManager = FileManager.default
//    private var documentsDirectory: URL {
//        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
//    }
//    
//    // --- 自定义URLSession (无变化) ---
//    private let urlSession: URLSession = {
//        let configuration = URLSessionConfiguration.default
//        configuration.timeoutIntervalForRequest = 15 // 15 seconds is a reasonable timeout for remote servers
//        configuration.waitsForConnectivity = false
//        return URLSession(configuration: configuration)
//    }()
//    
//    // MARK: - Main Sync Logic
//    
//    // The main logic now has a cleaner catch block because errors are pre-processed.
//    func checkAndDownloadUpdates() async throws {
//        self.isSyncing = true
//        self.isDownloading = false
//        self.syncMessage = "正在检查更新..."
//        self.progressText = ""
//        self.downloadProgress = 0.0
//        
//        do {
//            // All the logic remains the same here...
//            let serverVersion = try await getServerVersion()
//            let localFiles = try getLocalFiles()
//            
//            self.syncMessage = "正在清理旧资源..."
//            let validServerFiles = Set(serverVersion.files.map { $0.name })
//            let filesToDelete = localFiles.subtracting(validServerFiles)
//            let oldNewsItemsToDelete = filesToDelete.filter { $0.starts(with: "onews_") || $0.starts(with: "news_images_") }
//
//            if !oldNewsItemsToDelete.isEmpty {
//                for itemName in oldNewsItemsToDelete {
//                    let itemURL = documentsDirectory.appendingPathComponent(itemName)
//                    try? fileManager.removeItem(at: itemURL)
//                }
//            }
//
//            let filesToDownload = serverVersion.files.filter { !localFiles.contains($0.name) }
//            
//            if filesToDownload.isEmpty {
//                syncMessage = "当前资源已经是最新的了。"
//                try await Task.sleep(nanoseconds: 1_500_000_000)
//                self.isSyncing = false
//                return
//            }
//            
//            self.isDownloading = true
//            let totalFiles = filesToDownload.count
//            
//            for (index, fileInfo) in filesToDownload.enumerated() {
//                self.progressText = "\(index + 1)/\(totalFiles)"
//                self.downloadProgress = Double(index + 1) / Double(totalFiles)
//                
//                if fileInfo.type == "images" {
//                    self.syncMessage = "正在处理目录..."
//                    try await downloadDirectory(named: fileInfo.name)
//                } else {
//                    self.syncMessage = "正在下载文件..."
//                    try await downloadSingleFile(named: fileInfo.name)
//                }
//            }
//            
//            self.isDownloading = false
//            self.syncMessage = "更新完成！"
//            try await Task.sleep(nanoseconds: 1_000_000_000)
//            self.isSyncing = false
//            
//        } catch {
//            // Now we catch our own high-level SyncError
//            self.isSyncing = false
//            self.isDownloading = false
//            // Re-throw the error to be handled by the View
//            throw error
//        }
//    }
//    
//    // MARK: - Centralized Network Request Logic
//    
//    // ==================== 3. Centralized Request Function ====================
//    // This helper function handles all data requests, checks status codes, and maps errors.
//    private func performDataRequest(for url: URL) async throws -> Data {
//        do {
//            let (data, response) = try await urlSession.data(from: url)
//            
//            guard let httpResponse = response as? HTTPURLResponse else {
//                throw SyncError.unknown(originalError: URLError(.badServerResponse))
//            }
//            
//            // Check for successful status codes (200-299)
//            guard (200...299).contains(httpResponse.statusCode) else {
//                throw SyncError.serverError(statusCode: httpResponse.statusCode)
//            }
//            
//            return data
//            
//        } catch let error as SyncError {
//            // If it's already our custom error, just re-throw it.
//            throw error
//        } catch let error as URLError {
//            // Map URLErrors to our custom SyncError types.
//            switch error.code {
//            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .resourceUnavailable:
//                throw SyncError.serverUnreachable(originalError: error)
//            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
//                throw SyncError.securityError(originalError: error)
//            default:
//                throw SyncError.unknown(originalError: error)
//            }
//        } catch {
//            // Catch any other unexpected errors.
//            throw SyncError.unknown(originalError: error)
//        }
//    }
//
//    // ==================== 4. Refactor Helper Functions to use Centralized Logic ====================
//    
//    private func getServerVersion() async throws -> ServerVersion {
//        guard let url = URL(string: "\(serverBaseURL)/check_version") else { throw URLError(.badURL) }
//        
//        do {
//            let data = try await performDataRequest(for: url)
//            return try JSONDecoder().decode(ServerVersion.self, from: data)
//        } catch is Swift.DecodingError {
//            throw SyncError.decodingError(originalError: is Swift.DecodingError as! Error)
//        }
//    }
//    
//    private func getFileList(for directoryName: String) async throws -> [String] {
//        var components = URLComponents(string: "\(serverBaseURL)/list_files")!
//        components.queryItems = [URLQueryItem(name: "dirname", value: directoryName)]
//        guard let url = components.url else { throw URLError(.badURL) }
//        
//        do {
//            let data = try await performDataRequest(for: url)
//            return try JSONDecoder().decode([String].self, from: data)
//        } catch is Swift.DecodingError {
//            throw SyncError.decodingError(originalError: is Swift.DecodingError as! Error)
//        }
//    }
//    
//    // Download functions now also use the centralized logic for the initial request.
//    // The download task itself has slightly different error handling.
//    private func downloadDirectory(named directoryName: String) async throws {
//        let fileList = try await getFileList(for: directoryName)
//        if fileList.isEmpty { return }
//        
//        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
//        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true, attributes: nil)
//        
//        for (fileIndex, remoteFilename) in fileList.enumerated() {
//            self.syncMessage = "正在下载新闻图片... (\(fileIndex + 1)/\(fileList.count))"
//            do {
//                var components = URLComponents(string: "\(serverBaseURL)/download")!
//                components.queryItems = [URLQueryItem(name: "filename", value: "\(directoryName)/\(remoteFilename)")]
//                guard let url = components.url else { continue }
//                
//                // For downloads, we still use download(from:) but can wrap it similarly
//                let (tempURL, response) = try await urlSession.download(from: url)
//                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
//                    throw URLError(.badServerResponse)
//                }
//                
//                let destinationURL = localDirectoryURL.appendingPathComponent(remoteFilename)
//                if fileManager.fileExists(atPath: destinationURL.path) {
//                    try fileManager.removeItem(at: destinationURL)
//                }
//                try fileManager.moveItem(at: tempURL, to: destinationURL)
//            } catch {
//                // Individual file download failures are logged but don't stop the whole sync
//                print("⚠️ 下载文件 \(remoteFilename) 失败: \(error.localizedDescription)。将继续下一个文件。")
//            }
//        }
//    }
//    
//    private func downloadSingleFile(named filename: String) async throws {
//        var components = URLComponents(string: "\(serverBaseURL)/download")!
//        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
//        guard let url = components.url else { throw URLError(.badURL) }
//        
//        // Use the same robust download logic
//        let (tempURL, response) = try await urlSession.download(from: url)
//        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
//            throw SyncError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
//        }
//        
//        let destinationURL = documentsDirectory.appendingPathComponent(filename)
//        if fileManager.fileExists(atPath: destinationURL.path) {
//            try fileManager.removeItem(at: destinationURL)
//        }
//        try fileManager.moveItem(at: tempURL, to: destinationURL)
//    }
//    
//    private func getLocalFiles() throws -> Set<String> {
//        let contents = try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
//        return Set(contents)
//    }
//}
