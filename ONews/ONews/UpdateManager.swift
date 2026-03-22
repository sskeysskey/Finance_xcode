import Foundation
import CryptoKit
import SwiftUI
import Network // 引入 Network 框架

struct FileInfo: Codable {
    let name: String
    let type: String
    let md5: String?
}

struct ForceUpdateView: View {
    // 接收从服务器传来的 URL
    let storeURL: String
    
    // 把你代码里的真实 ID 作为默认备份
    // 如果服务器传空字符串，就用这个
    private let fallbackURL = "https://apps.apple.com/cn/app/id6754591885"
    
    var body: some View {
        ZStack {
            // 背景不能点击，防止用户绕过
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 30) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("需要更新")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                
                Text("我们发布了一个重要的版本升级。\n当前版本已停止服务，请更新后继续使用。")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                
                Button(action: {
                    // 【逻辑优化】
                    // 1. 优先使用服务器配置的 URL (storeURL)
                    // 2. 如果服务器没配，使用本地写死的 fallbackURL
                    let urlStr = storeURL.isEmpty ? fallbackURL : storeURL
                    
                    if let url = URL(string: urlStr) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Text("前往 App Store 更新")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        // 使用主色调
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
            }
            .padding()
        }
    }
}

// 为 ServerVersion 添加 locked_days 字段
struct ServerVersion: Codable {
    let version: String
    let min_app_version: String?
    let store_url: String?
    let locked_days: Int?
    let server_date: String? // 服务器返回的基准日期
    let notification: String? // 通知内容
    let update_time: String? // 服务器返回的更新时间
    let source_mappings: [String: String]?
    let files: [FileInfo]
}

@MainActor
class ResourceManager: ObservableObject {
    
    @Published var isSyncing = false
    // 初始值使用双语
    @Published var syncMessage = Localized.syncStarting 
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var progressText = ""
    @Published var showAlreadyUpToDateAlert = false

    // 强制更新控制开关
    @Published var showForceUpdate: Bool = false
    @Published var appStoreURL: String = ""

    // 存储最后更新时间，默认为空
    @Published var serverUpdateTime: String = "" 
    
    // 存储从服务器获取的配置
    @Published var serverLockedDays: Int = 0
    @Published var sourceMappings: [String: String] = [:]
    
    // 当前需要显示的通知（如果为 nil 则不显示）
    @Published var activeNotification: String? = nil

    @Published var serverDate: String = "" // 存储服务器日期
    
    private let serverBaseURL = "http://106.15.183.158:5001/api/ONews"
    // UserDefaults Key
    private let dismissedNotificationKey = "dismissedNotificationContent"
    
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // 【核心修改】配置 URLSession，完美适配国行网络授权弹窗
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // 1. 请求超时时间：延长至 15 秒，给用户留出阅读并点击网络授权弹窗的时间
        configuration.timeoutIntervalForRequest = 15.0
        // 2. 资源超时时间：整个下载过程的时间
        configuration.timeoutIntervalForResource = 60.0
        // 3. 【关键】设置为 true。这样在首次弹网络授权框时，请求会挂起等待，用户点允许后自动继续，不会报错。
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
    
    // 网络监视器 (保留用于 UI 状态展示，但不用于硬性拦截请求)
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    @Published var isWifiConnected: Bool = false
    // 【新增】增加一个通用的网络可用性标记
    @Published var isNetworkAvailable: Bool = true

    // ✅ 修复 1: 去掉 override 关键字
    init() {
        // 启动网络监听
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isWifiConnected = path.usesInterfaceType(.wifi)
                // 只要有网（WiFi或蜂窝）都算可用
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }
    
    deinit {
        networkMonitor.cancel()
    }
    
    // 特效数据获取失败时的默认词汇
    func fetchSourceNames() async -> [String] {
        do {
            // 复用已有的 getServerVersion 方法
            let version = try await getServerVersion()
            // 提取 source_mappings 的所有 value（即中文名称）
            if let mappings = version.source_mappings {
                let names = Array(mappings.values)
                return names
            }
        } catch {
            print("特效数据获取失败: \(error)")
        }
        // 使用双语字典中的默认词汇
        return [
            Localized.fallbackSource1,
            Localized.fallbackSource2,
            Localized.fallbackSource3,
            Localized.fallbackSource4,
            Localized.fallbackSource5,
            Localized.fallbackSource6
        ]
    }
    
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

    // 【新增】处理通知的逻辑
    // 当从服务器获取到新版本信息时调用此方法
    private func updateNotificationStatus(serverMessage: String?) {
        // 1. 如果服务器没有通知，直接清空
        guard let message = serverMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.activeNotification = nil
            return
        }
        
        // 2. 获取本地已关闭过的通知内容
        let dismissedMessage = UserDefaults.standard.string(forKey: dismissedNotificationKey)
        
        // 3. 只有当服务器通知内容 不等于 本地已关闭的内容时，才显示
        // 这样一旦内容变更（不相等），就会再次弹出
        if message != dismissedMessage {
            self.activeNotification = message
        } else {
            self.activeNotification = nil
        }
    }
    
    // 用户点击关闭按钮时调用
    func dismissNotification() {
        guard let message = activeNotification else { return }
        
        // 1. 保存当前内容到本地，标记为“已读/已关闭”
        UserDefaults.standard.set(message, forKey: dismissedNotificationKey)
        
        // 2. 隐藏 UI
        withAnimation {
            self.activeNotification = nil
        }
    }

    // MARK: - 按需下载单篇文章的图片 (面向UI)
    // 【核心修改】为函数增加一个 progressHandler 回调闭包
    func downloadImagesForArticle(
        timestamp: String,
        imageNames: [String],
        progressHandler: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        // 移除自定义网络拦截，交由 URLSession 自动处理等待
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
                    // 如果是 404 等服务器错误，抛出异常
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
                // 【关键】这里抛出错误，让上层捕获。
                // 如果是网络断开，urlSession 现在会立即抛出错误
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

    // MARK: - 批量离线下载所有图片
    func downloadAllOfflineImages(progressHandler: @escaping @MainActor (Int, Int) -> Void) async throws {
        // ✅ 修复 2: 在主线程获取 URL，因为 documentsDirectory 是 @MainActor 隔离的
        let docDir = self.documentsDirectory
        
        // 2. 遍历 JSON，解析出所有需要的图片
        // ✅ 修复 3: 使用捕获列表 [docDir] 将 URL 传入后台任务
        // ✅ 修复 4: 在后台任务中使用 FileManager.default，而不是 self.fileManager
        let allImagesToDownload = await Task.detached(priority: .userInitiated) { [docDir] in
            let fm = FileManager.default // 使用本地实例
            var tasks: [(urlPath: String, localPath: URL)] = []
            
            // 获取本地所有 onews_*.json 文件
            guard let localFiles = try? fm.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) else {
                return tasks
            }
            
            let jsonFiles = localFiles.filter { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            
            for fileURL in jsonFiles {
                guard let data = try? Data(contentsOf: fileURL),
                      let articlesMap = try? decoder.decode([String: [Article]].self, from: data) else {
                    continue
                }
                
                // 提取时间戳 (例如 onews_260131.json -> 260131)
                let filename = fileURL.deletingPathExtension().lastPathComponent
                let timestamp = filename.replacingOccurrences(of: "onews_", with: "")
                let directoryName = "news_images_\(timestamp)"
                
                // 扁平化所有文章的所有图片
                let allArticles = articlesMap.values.flatMap { $0 }
                let allImageNames = allArticles.flatMap { $0.images }
                
                // 去重
                let uniqueImages = Set(allImageNames)
                
                for imageName in uniqueImages {
                    let cleanName = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanName.isEmpty { continue }
                    
                    // 构造下载路径和本地保存路径
                    // 服务器路径格式: news_images_260131/xxx.jpg
                    let downloadPath = "\(directoryName)/\(cleanName)"
                    let localDir = docDir.appendingPathComponent(directoryName)
                    let localFile = localDir.appendingPathComponent(cleanName)
                    
                    // 检查本地是否已存在
                    if !fm.fileExists(atPath: localFile.path) {
                        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
                        tasks.append((urlPath: downloadPath, localPath: localFile))
                    }
                }
            }
            return tasks
        }.value // 等待后台任务完成
        
        // 3. 开始下载
        let total = allImagesToDownload.count
        if total == 0 {
            print("所有图片均已离线缓存，无需下载。")
            progressHandler(0, 0)
            return
        }
        
        print("开始离线下载，共缺 \(total) 张图片...")
        progressHandler(0, total)
        
        for (index, task) in allImagesToDownload.enumerated() {
            guard var components = URLComponents(string: "\(serverBaseURL)/download") else { continue }
            components.queryItems = [URLQueryItem(name: "filename", value: task.urlPath)]
            guard let url = components.url else { continue }
            
            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    // 如果单张失败，打印日志但不中断整个流程
                    print("⚠️ 下载失败: \(task.urlPath)")
                    continue
                }
                
                // 移动文件 (回到主线程操作文件是安全的，或者这里使用 fileManager 也可以，因为是串行)
                if fileManager.fileExists(atPath: task.localPath.path) {
                    try fileManager.removeItem(at: task.localPath)
                }
                try fileManager.moveItem(at: tempURL, to: task.localPath)
                
                // 更新进度
                progressHandler(index + 1, total)
                
            } catch {
                print("⚠️ 下载异常: \(task.urlPath) - \(error.localizedDescription)")
            }
        }
    }

    func checkAndDownloadAllNewsManifests(isManual: Bool = false) async throws {
        // 【核心修复】完全移除自定义的网络拦截，交由 URLSession 的 waitsForConnectivity 处理
        // 这样在首次启动弹网络授权框时，请求会自动挂起等待，用户点击允许后自动恢复。
        
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = Localized.fetchingManifest
        self.progressText = ""
        self.downloadProgress = 0.0
        
        do {
            let serverVersion = try await getServerVersion()
            
            // 【新增】获取到配置后，立即更新
            self.serverLockedDays = serverVersion.locked_days ?? 0
            
            let allJsonInfos = serverVersion.files
                .filter { $0.type == "json" && $0.name.starts(with: "onews_") }
                .sorted { $0.name < $1.name }
            
            if allJsonInfos.isEmpty {
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
                self.syncMessage = Localized.downloadingData
                try await downloadSingleFile(named: info.name)
            }
            
            self.isDownloading = false
            // self.syncMessage = "新闻源已准备就绪！\n\n请点击右下角“+”按钮。"
            self.progressText = ""
            resetStateAfterDelay()
            
        } catch {
            self.isSyncing = false
            self.isDownloading = false
            throw error
        }
    }

    func checkAndDownloadUpdates(isManual: Bool = false) async throws {
        // 同样移除网络拦截
        self.isSyncing = true
        self.isDownloading = false
        self.syncMessage = Localized.checkingUpdates
        self.progressText = ""
        self.downloadProgress = 0.0
        
        // 使用 defer 确保 isSyncing 最终关闭
        // 这防止了 UI 永久卡死在 loading 状态
        defer {
            Task { @MainActor in
                // 注意：这里不要立即设为 false，否则弹窗还没出来 loading 就没了
                // 我们会在 resetStateAfterDelay 里处理
                if !self.showAlreadyUpToDateAlert {
                    self.isSyncing = false
                }
            }
        }
        
        do {
            let serverVersion = try await getServerVersion()
            let localFiles = try getLocalFiles()
            
            // 【新增】获取到配置后，立即更新
            self.serverLockedDays = serverVersion.locked_days ?? 0
            print("ResourceManager: 从服务器获取到 locked_days = \(self.serverLockedDays)")
            
            self.syncMessage = Localized.cleaningOldResources
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
                    await MainActor.run {
                        // 使用 Localized.upToDate 设置提示文字
                        self.syncMessage = Localized.upToDate // "已是最新版本"
                        // 2. 触发 UI 弹窗标记
                        self.showAlreadyUpToDateAlert = true
                        // 稍微延迟一点关闭 syncing 状态，或者立即关闭让弹窗独立显示
                        self.isSyncing = false 
                    }
                    // 1.5秒后自动重置状态（让弹窗消失）
                    resetStateAfterDelay(seconds: 1)
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
                    self.syncMessage = Localized.downloadingFiles
                    try await downloadSingleFile(named: task.fileInfo.name)
                }
            }
            
            self.isDownloading = false
            self.syncMessage = Localized.updateComplete
            self.progressText = ""
            
            // 👇 【新增】文件全部下载并覆盖完毕后，发送通知让 UI 刷新
            NotificationCenter.default.post(name: .newsDataDidUpdate, object: nil)
            
            resetStateAfterDelay()
            
        } catch {
            self.isDownloading = false
            self.isSyncing = false // 出错时立即停止
            throw error
        }
    }

    // 【辅助方法】确保 resetStateAfterDelay 能正确重置 alert 状态
    private func resetStateAfterDelay(seconds: TimeInterval = 2) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                self.isSyncing = false
                self.syncMessage = ""
                self.progressText = ""
                // 【新增】自动关闭“已是最新”的弹窗
                withAnimation {
                    self.showAlreadyUpToDateAlert = false
                }
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

    // 【新增】版本号比对逻辑
    // 返回 true 表示 currentVersion < minVersion (需要强制更新)
    private func isVersion(_ current: String, lessThan min: String) -> Bool {
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let minParts = min.split(separator: ".").compactMap { Int($0) }
        
        let count = max(currentParts.count, minParts.count)
        
        for i in 0..<count {
            let v1 = i < currentParts.count ? currentParts[i] : 0
            let v2 = i < minParts.count ? minParts[i] : 0
            
            if v1 < v2 { return true }
            if v1 > v2 { return false }
        }
        return false // 版本相同
    }

    private func getServerVersion() async throws -> ServerVersion {
        guard let url = URL(string: "\(serverBaseURL)/check_version") else { 
            throw URLError(.badURL) 
        }
        let (data, _) = try await urlSession.data(from: url)
        let version = try JSONDecoder().decode(ServerVersion.self, from: data)
        
        await MainActor.run {
            self.serverDate = version.server_date ?? ""
            self.sourceMappings = version.source_mappings ?? [:]
            self.serverLockedDays = version.locked_days ?? 0
            self.updateNotificationStatus(serverMessage: version.notification)
            
            // 持久化存储，防止离线时丢失基准
            if let sDate = version.server_date {
                UserDefaults.standard.set(sDate, forKey: "LastKnownServerDate")
            }
            
            if let time = version.update_time { self.serverUpdateTime = time }
            
            // 【新增】强制更新检查核心逻辑
            if let minVersion = version.min_app_version,
               let storeUrl = version.store_url {
                
                // 获取当前 App 版本号 (Info.plist)
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                
                if isVersion(currentVersion, lessThan: minVersion) {
                    print("当前版本 \(currentVersion) 低于最低要求 \(minVersion)，触发强制更新。")
                    self.showForceUpdate = true
                    self.appStoreURL = storeUrl
                } else {
                    self.showForceUpdate = false
                }
            }
        }
        
        return version
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