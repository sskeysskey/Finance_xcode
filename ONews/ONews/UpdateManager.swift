// /Users/yanzhang/Coding/Xcode/ONews/ONews/UpdateManager.swift
import Foundation
import CryptoKit

struct FileInfo: Codable {
    let name: String
    let type: String
    let md5: String?
}

struct ServerVersion: Codable {
    let version: String
    let files: [FileInfo]
}

@MainActor
class ResourceManager: ObservableObject {
    
    @Published var isSyncing = false
    @Published var syncMessage = "启动中..."
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var progressText = ""
    
    @Published var showAlreadyUpToDateAlert = false
    
    private let serverBaseURL = "http://106.15.183.158:5001/api/ONews"
    
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    // MARK: - 检查图片是否存在而不下载
    func checkIfImagesExistForArticle(timestamp: String, imageNames: [String]) -> Bool {
        let sanitizedNames = imageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !sanitizedNames.isEmpty else {
            return true
        }
        
        let directoryName = "news_images_\(timestamp)"
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        
        for imageName in sanitizedNames {
            let localImageURL = localDirectoryURL.appendingPathComponent(imageName)
            if !fileManager.fileExists(atPath: localImageURL.path) {
                print("检查发现图片缺失: \(imageName)")
                return false
            }
        }
        
        print("检查发现所有图片均已本地存在。")
        return true
    }

    // MARK: - 按需下载单篇文章的图片 (面向UI)
    // 【核心修改】为函数增加一个 progressHandler 回调闭包
    func downloadImagesForArticle(
        timestamp: String,
        imageNames: [String],
        progressHandler: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        let sanitizedNames = imageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var uniqueNames: [String] = []
        var seen = Set<String>()
        for name in sanitizedNames {
            if !seen.contains(name) {
                uniqueNames.append(name)
                seen.insert(name)
            }
        }
        
        guard !uniqueNames.isEmpty else { return }
        
        let directoryName = "news_images_\(timestamp)"
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        
        var imagesToDownload: [String] = []
        for imageName in uniqueNames {
            let localImageURL = localDirectoryURL.appendingPathComponent(imageName)
            if !fileManager.fileExists(atPath: localImageURL.path) {
                imagesToDownload.append(imageName)
            }
        }
        
        guard !imagesToDownload.isEmpty else {
            print("所有图片已存在，无需下载")
            return
        }
        
        let totalToDownload = imagesToDownload.count
        print("需要下载 \(totalToDownload) 张图片")
        
        // 【修改】在下载开始前，立即调用一次回调，用于初始化UI
        progressHandler(0, totalToDownload)
        
        for (index, imageName) in imagesToDownload.enumerated() {
            let downloadPath = "\(directoryName)/\(imageName)"
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
            components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
            guard let url = components.url else { continue }
            
            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                
                let destinationURL = localDirectoryURL.appendingPathComponent(imageName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                
                // 【修改】每成功下载一张图片，就调用回调函数更新进度
                // `index + 1` 表示当前已完成的数量
                let completedCount = index + 1
                progressHandler(completedCount, totalToDownload)
                print("✅ 已下载图片 (\(completedCount)/\(totalToDownload)): \(imageName)")
                
            } catch {
                print("⚠️ 下载图片失败 \(imageName): \(error.localizedDescription)")
                throw error
            }
        }
    }
    
    // MARK: - 静默预下载单篇文章的图片 (后台任务)
    func preDownloadImagesForArticleSilently(timestamp: String, imageNames: [String]) async throws {
        let sanitizedNames = imageNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var uniqueNames: [String] = []
        var seen = Set<String>()
        for name in sanitizedNames {
            if !seen.contains(name) {
                uniqueNames.append(name)
                seen.insert(name)
            }
        }
        
        guard !uniqueNames.isEmpty else { return }
        
        let directoryName = "news_images_\(timestamp)"
        let localDirectoryURL = documentsDirectory.appendingPathComponent(directoryName)
        
        try? fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        
        var imagesToDownload: [String] = []
        for imageName in uniqueNames {
            let localImageURL = localDirectoryURL.appendingPathComponent(imageName)
            if !fileManager.fileExists(atPath: localImageURL.path) {
                imagesToDownload.append(imageName)
            }
        }
        
        guard !imagesToDownload.isEmpty else {
            print("[静默预载] 所有目标图片已存在，无需下载。")
            return
        }
        
        print("[静默预载] 发现 \(imagesToDownload.count) 张需要预下载的图片。")
        
        for (index, imageName) in imagesToDownload.enumerated() {
            let downloadPath = "\(directoryName)/\(imageName)"
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
            components.queryItems = [URLQueryItem(name: "filename", value: downloadPath)]
            guard let url = components.url else { continue }
            
            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                
                let destinationURL = localDirectoryURL.appendingPathComponent(imageName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                print("✅ [静默预载] 成功 (\(index + 1)/\(imagesToDownload.count)): \(imageName)")
                
            } catch {
                print("⚠️ [静默预载] 失败 \(imageName): \(error.localizedDescription)")
                throw error
            }
        }
    }

    func checkAndDownloadAllNewsManifests(isManual: Bool = false) async throws {
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = "正在获取新闻清单列表..."
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            let serverVersion = try await getServerVersion()
            
            let allJsonInfos = serverVersion.files
                .filter { $0.type == "json" && $0.name.starts(with: "onews_") }
                .sorted { $0.name < $1.name }
            
            if allJsonInfos.isEmpty {
                print("服务器上未找到任何 'onews_*.json' 文件。")
                self.isSyncing = false
                return
            }
            
            var tasksToDownload: [FileInfo] = []
            for jsonInfo in allJsonInfos {
                let localURL = documentsDirectory.appendingPathComponent(jsonInfo.name)
                var shouldDownload = false
                
                if fileManager.fileExists(atPath: localURL.path) {
                    if let serverMD5 = jsonInfo.md5, let localMD5 = calculateMD5(for: localURL) {
                        if serverMD5 != localMD5 {
                            print("MD5不匹配，需要更新: \(jsonInfo.name)")
                            shouldDownload = true
                        } else {
                            print("已是最新: \(jsonInfo.name)")
                        }
                    } else {
                        print("缺少MD5，强制重新下载: \(jsonInfo.name)")
                        shouldDownload = true
                    }
                } else {
                    print("本地不存在，准备下载: \(jsonInfo.name)")
                    shouldDownload = true
                }
                
                if shouldDownload {
                    tasksToDownload.append(jsonInfo)
                }
            }
            
            if tasksToDownload.isEmpty {
                if isManual {
                    self.isSyncing = false
                    self.showAlreadyUpToDateAlert = true
                } else {
                    self.isSyncing = false
                }
                return
            }
            
            self.isDownloading = true
            let total = tasksToDownload.count
            for (index, info) in tasksToDownload.enumerated() {
                self.progressText = "\(index + 1)/\(total)"
                self.downloadProgress = Double(index + 1) / Double(total)
                self.syncMessage = "正在下载: \(info.name)..."
                try await downloadSingleFile(named: info.name)
            }
            
            self.isDownloading = false
            self.syncMessage = "新闻源已准备就绪！\n\n请点击右下角“+”按钮。"
            self.progressText = ""
            resetStateAfterDelay()
            
        } catch {
            self.isSyncing = false
            self.isDownloading = false
            throw error
        }
    }

    func checkAndDownloadUpdates(isManual: Bool = false) async throws {
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = "正在检查更新..."
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            let serverVersion = try await getServerVersion()
            let localFiles = try getLocalFiles()
            
            self.syncMessage = "正在清理旧资源..."
            let validServerFiles = Set(serverVersion.files.map { $0.name })
            let filesToDelete = localFiles.subtracting(validServerFiles)
            let oldNewsItemsToDelete = filesToDelete.filter {
                $0.starts(with: "onews_") || $0.starts(with: "news_images_")
            }

            if !oldNewsItemsToDelete.isEmpty {
                print("发现需要清理的过时资源: {oldNewsItemsToDelete}")
                for itemName in oldNewsItemsToDelete {
                    let itemURL = documentsDirectory.appendingPathComponent(itemName)
                    try? fileManager.removeItem(at: itemURL)
                    print("🗑️ 已成功删除: \(itemName)")
                }
            } else {
                print("本地资源无需清理。")
            }

            var downloadTasks: [(fileInfo: FileInfo, isIncremental: Bool)] = []
            
            let jsonFilesFromServer = serverVersion.files.filter { $0.type == "json" }
            let imageDirsFromServer = serverVersion.files.filter { $0.type == "images" }

            for jsonInfo in jsonFilesFromServer {
                let localFileURL = documentsDirectory.appendingPathComponent(jsonInfo.name)
                let correspondingImageDirName = "news_images_" + jsonInfo.name.components(separatedBy: "_").last!.replacingOccurrences(of: ".json", with: "")

                if fileManager.fileExists(atPath: localFileURL.path) {
                    guard let serverMD5 = jsonInfo.md5, let localMD5 = calculateMD5(for: localFileURL) else {
                        print("警告: 无法获取 \(jsonInfo.name) 的 MD5，跳过检查。")
                        continue
                    }
                    
                    if serverMD5 != localMD5 {
                        print("MD5不匹配: \(jsonInfo.name)。计划更新。")
                        downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                        let imageDirURL = documentsDirectory.appendingPathComponent(correspondingImageDirName)
                        try? fileManager.createDirectory(at: imageDirURL, withIntermediateDirectories: true)
                    } else {
                        print("MD5匹配: \(jsonInfo.name) 已是最新。")
                    }
                    
                } else {
                    print("新文件: \(jsonInfo.name)。计划下载。")
                    downloadTasks.append((fileInfo: jsonInfo, isIncremental: false))
                    let imageDirURL = documentsDirectory.appendingPathComponent(correspondingImageDirName)
                    try? fileManager.createDirectory(at: imageDirURL, withIntermediateDirectories: true)
                }
            }
            
            for dirInfo in imageDirsFromServer {
                let localDirURL = documentsDirectory.appendingPathComponent(dirInfo.name)
                try? fileManager.createDirectory(at: localDirURL, withIntermediateDirectories: true)
            }
            
            if downloadTasks.isEmpty {
                if isManual {
                    self.syncMessage = "当前已是最新"
                    resetStateAfterDelay()
                } else {
                    self.isSyncing = false
                }
                return
            }
            
            print("需要处理的任务列表: \(downloadTasks.map { $0.fileInfo.name })")
            
            self.isDownloading = true
            let totalTasks = downloadTasks.count
            
            for (index, task) in downloadTasks.enumerated() {
                self.progressText = "\(index + 1)/\(totalTasks)"
                self.downloadProgress = Double(index + 1) / Double(totalTasks)
                
                if task.fileInfo.type == "json" {
                    self.syncMessage = "正在下载文件: \(task.fileInfo.name)..."
                    try await downloadSingleFile(named: task.fileInfo.name)
                }
            }
            
            self.isDownloading = false
            self.syncMessage = "更新完成！"
            self.progressText = ""
            resetStateAfterDelay()
            
        } catch {
            self.isSyncing = false
            self.isDownloading = false
            throw error
        }
    }
    
    // MARK: - Helper Functions
    
    private func resetStateAfterDelay(seconds: TimeInterval = 2) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                self.isSyncing = false
                self.syncMessage = ""
                self.progressText = ""
            }
        }
    }
    
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

    private func getServerVersion() async throws -> ServerVersion {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else { throw URLError(.badURL) }
        let (data, _) = try await urlSession.data(from: url)
        return try JSONDecoder().decode(ServerVersion.self, from: data)
    }
    
    private func getLocalFiles() throws -> Set<String> {
        let contents = try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
        return Set(contents)
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
