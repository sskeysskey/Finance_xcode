import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - 数据模型（直接复用）
struct VideoItem: Identifiable {
    let id = UUID()
    let title: String
    let url: String
}

// MARK: - 下载管理器（直接复用，注意改 UserDefaults key 避免冲突）
class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!
    @Published var downloadProgress: [String: Double] = [:]
    @Published var localBookmarks: [String: Data] = [:]
    
    // ⚠️ 改个独立 key，避免和其他 app 冲突
    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    
    override init() {
        super.init()
        
        // 初始化后台下载 Session
        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        downloadSession = AVAssetDownloadURLSession(configuration: config,
                                                    assetDownloadDelegate: self,
                                                    delegateQueue: .main)
        loadBookmarks()
    }
    
    // 开始下载
    func startDownload(urlString: String, title: String) {
        guard let url = URL(string: urlString) else { return }
        let asset = AVURLAsset(url: url)
        
        // 创建 HLS 下载任务
        guard let task = downloadSession.makeAssetDownloadTask(asset: asset,
                                                               assetTitle: title,
                                                               assetArtworkData: nil,
                                                               options: nil) else { return }
        
        // 使用 taskDescription 记录这个任务对应的原始 URL，方便回调时识别
        task.taskDescription = urlString
        task.resume()
        
        DispatchQueue.main.async {
            // 修复闪回问题：初始进度设为 0.0，而不是 0.01
            self.downloadProgress[urlString] = 0.0
        }
    }
    
    // 删除本地缓存
    func deleteDownload(urlString: String) {
        guard let localURL = getLocalURL(for: urlString) else { return }
        do {
            try FileManager.default.removeItem(at: localURL)
            localBookmarks.removeValue(forKey: urlString)
            saveBookmarks()
            // 修复报错：将 title 改为 urlString
            print("已删除本地缓存: \(urlString)")
        } catch {
            print("删除失败: \(error)")
        }
    }
    
    // 获取本地播放地址（通过解析 Bookmark）
    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmarkData = localBookmarks[urlString] else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
            if isStale {
                print("书签已过期")
            }
            return url
        } catch {
            print("解析本地路径失败: \(error)")
            return nil
        }
    }
    
    // MARK: - AVAssetDownloadDelegate 代理方法
    
    // 1. 监听下载进度
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        
        var percentComplete = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange = value.timeRangeValue
            percentComplete += loadedTimeRange.duration.seconds / timeRangeExpectedToLoad.duration.seconds
        }
        
        DispatchQueue.main.async {
            // 修复闪回问题：取当前进度和新进度的最大值，确保进度条只增不减
            let currentProgress = self.downloadProgress[urlString] ?? 0.0
            let newProgress = max(currentProgress, percentComplete)
        
            // 【核心修复】：使用 min(1.0, ...) 确保进度值不会超过 1.0，从而消除警告
            self.downloadProgress[urlString] = min(1.0, newProgress)
        }
    }
    
    // 2. 下载完成，获取本地存储路径
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        
        do {
            // ⚠️ 核心：必须保存为 BookmarkData，因为 iOS App 每次重启/更新，沙盒绝对路径都会变
            let bookmark = try location.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            DispatchQueue.main.async {
                self.localBookmarks[urlString] = bookmark
                self.saveBookmarks()
            }
        } catch {
            print("保存书签失败: \(error)")
        }
    }
    
    // 3. 任务结束（成功或失败）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { return }
        DispatchQueue.main.async {
            self.downloadProgress.removeValue(forKey: urlString)
            if let error = error {
                print("下载失败: \(error.localizedDescription)")
            } else {
                print("下载成功: \(urlString)")
            }
        }
    }
    
    // MARK: - 数据持久化
    private func saveBookmarks() {
        UserDefaults.standard.set(localBookmarks, forKey: bookmarksKey)
    }
    
    private func loadBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] {
            localBookmarks = saved
        }
    }
}

// MARK: - 播放器封装（直接复用）
struct VideoPlayerView: UIViewControllerRepresentable {
    let videoURL: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        player.play()
        return controller
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 主视图（⚠️ 关键修改：去掉 NavigationView，因为 ONews 已经在 NavigationStack 里了）
struct VideoModuleView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    let videos = [
        VideoItem(title: "视频 1 (ffzy)", url: "https://vip.ffzy-plays.com/20260424/52786_73fd522f/index.m3u8"),
        VideoItem(title: "视频 1.5", url: "https://cnvod.jimxtc.com/20260328/14496_7903be1c/index.m3u8?sign=3f5af365605d8a78bdacdb4148975698"),
        VideoItem(title: "视频 2 (fengbao)", url: "https://s1.fengbao9.com/video/pizibaoyihuqianxiandierji/a410bff188fb/index.m3u8"),
        VideoItem(title: "视频 3 (dytt)", url: "https://vip.dytt-cine.com/20260109/66739_80d68c37/index.m3u8")
    ]

    var body: some View {
        // ⚠️ 注意：这里不再包 NavigationView！直接用 List
        List(videos) { video in
            HStack {
                let isDownloaded = downloadManager.localBookmarks[video.url] != nil
                let playURL = isDownloaded ? downloadManager.getLocalURL(for: video.url)! : URL(string: video.url)!
                
                NavigationLink(destination: VideoPlayerView(videoURL: playURL)
                                .navigationTitle(video.title)
                                .navigationBarTitleDisplayMode(.inline)
                                .ignoresSafeArea()) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.title).font(.headline)
                        if isDownloaded {
                            Text(isGlobalEnglishMode ? "✅ Cached (Offline)" : "✅ 已缓存 (离线可用)")
                                .font(.caption).foregroundColor(.green)
                        } else if let progress = downloadManager.downloadProgress[video.url] {
                            ProgressView(value: progress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            Text("\(isGlobalEnglishMode ? "Downloading: " : "下载中: ")\(Int(progress * 100))%")
                                .font(.caption).foregroundColor(.blue)
                        } else {
                            Text(isGlobalEnglishMode ? "Online" : "在线播放")
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                }
                Spacer()
                
                if isDownloaded {
                    Button(action: { downloadManager.deleteDownload(urlString: video.url) }) {
                        Image(systemName: "trash").foregroundColor(.red)
                    }.buttonStyle(BorderlessButtonStyle())
                } else if downloadManager.downloadProgress[video.url] == nil {
                    Button(action: { downloadManager.startDownload(urlString: video.url, title: video.title) }) {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundColor(.blue).font(.title3)
                    }.buttonStyle(BorderlessButtonStyle())
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(isGlobalEnglishMode ? "Video Library" : "影视频道")
        .navigationBarTitleDisplayMode(.inline)
    }
}