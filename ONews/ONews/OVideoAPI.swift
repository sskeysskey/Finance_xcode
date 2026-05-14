// API 接口、数据模型、排序枚举、缓存元数据
// 纯数据层，所有模块都依赖
// OVideoDataManager + HLSDownloadManager
// 业务逻辑管理器

import Foundation
import SwiftUI
import AVFoundation

// MARK: - 服务器地址
enum OVideoAPI {
    static let baseURL = "http://106.15.183.158:5001/api/OVideo"
    
    static func coverURL(for imageName: String) -> URL? {
        guard !imageName.isEmpty,
              let encoded = imageName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(baseURL)/cover/\(encoded)")
    }
    
    static func fetchVideos() async throws -> [OVideoCategory] {
        guard let url = URL(string: "\(baseURL)/videos") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OVideoResponse.self, from: data)
        return response.categories
    }
    
    static func resolveRealURL(episodeURL: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/resolve") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": episodeURL])
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 {
                throw NSError(domain: "OVideo", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "该视频暂不可用"])
            }
            if http.statusCode == 404 {
                throw NSError(domain: "OVideo", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "未找到可播放的资源"])
            }
            if http.statusCode >= 400 {
                throw NSError(domain: "OVideo", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "解析失败 (\(http.statusCode))"])
            }
        }
        let result = try JSONDecoder().decode(OVideoResolveResponse.self, from: data)
        return result.real_url
    }
}

// MARK: - 数据模型
struct OVideoResponse: Codable {
    let categories: [OVideoCategory]
}

struct OVideoCategory: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let items: [OVideoItem]
}

struct OVideoItem: Codable, Identifiable, Hashable {
    var id: String { url }
    let time: String?
    let name: String
    let url: String
    let info: String?
    let image: String?
    let director: String?
    let writers: [String]?
    let cast: [String]?
    let types: [String]?
    let region: String?
    let date: String?
    let alias: String?
    let intro: String?
    let ratings: [String: String]?
    let playlist: [OVideoChannel]
    
    enum CodingKeys: String, CodingKey {
        case time, name, url, info, image, date, alias, intro, playlist
        case director = "导演"
        case writers  = "编剧"
        case cast     = "主演"
        case types    = "类型"
        case region   = "地区"
        case ratings  = "评分"
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: OVideoItem, rhs: OVideoItem) -> Bool { lhs.url == rhs.url }
}

struct OVideoChannel: Codable, Hashable {
    let name: String
    let episodes: [String]
}

struct OVideoResolveResponse: Codable {
    let real_url: String
    let title: String?
}

// MARK: - 排序 / 筛选辅助
extension OVideoItem {
    var releaseDate: Date {
        guard let raw = date, !raw.isEmpty else { return .distantPast }
        let cleaned = raw.split(separator: "(").first.map(String.init) ?? raw
        let parts = cleaned.split(separator: "-")
        var comp = DateComponents()
        comp.year = 1970; comp.month = 1; comp.day = 1
        if parts.count >= 1, let y = Int(parts[0]) { comp.year = y }
        if parts.count >= 2, let m = Int(parts[1]) { comp.month = m }
        if parts.count >= 3, let d = Int(parts[2]) { comp.day = d }
        return Calendar.current.date(from: comp) ?? .distantPast
    }
    
    var releaseYear: Int? {
        guard let raw = date, !raw.isEmpty else { return nil }
        let cleaned = raw.split(separator: "(").first.map(String.init) ?? raw
        if let first = cleaned.split(separator: "-").first, let y = Int(first) { return y }
        return nil
    }
    
    var bestRating: Double {
        guard let r = ratings else { return 0 }
        return r.values.compactMap { Double($0) }.max() ?? 0
    }
}

enum VideoSortOption: String, CaseIterable {
    case date, rating
    func displayName(_ en: Bool) -> String {
        switch self {
        case .date:   return en ? "By Date" : "按时间"
        case .rating: return en ? "By Rating" : "按评分"
        }
    }
    /// 简短名，用于 Toolbar 上的状态指示
    func shortName(_ en: Bool) -> String {
        switch self {
        case .date:   return en ? "Date" : "时间"
        case .rating: return en ? "Rating" : "评分"
        }
    }
    var icon: String {
        self == .date ? "calendar" : "star.fill"
    }
}

// MARK: - 缓存元数据
struct VideoCacheMetadata: Codable {
    let title: String
    let coverImage: String?
    let savedAt: Date
}

// MARK: - 数据管理器
@MainActor
class OVideoDataManager: ObservableObject {
    @Published var categories: [OVideoCategory] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    private var hasLoaded = false
    
    func loadVideosIfNeeded() async {
        if hasLoaded { return }
        await loadVideos()
    }
    
    func loadVideos() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            self.categories = try await OVideoAPI.fetchVideos()
            self.hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    var allItems: [OVideoItem] { categories.flatMap { $0.items } }
    
    func sortItems(_ items: [OVideoItem], by option: VideoSortOption) -> [OVideoItem] {
        switch option {
        case .date:
            return items.sorted { $0.releaseDate > $1.releaseDate }
        case .rating:
            return items.sorted { a, b in
                if a.bestRating == b.bestRating { return a.releaseDate > b.releaseDate }
                return a.bestRating > b.bestRating
            }
        }
    }
    
    func search(keyword: String) -> [OVideoItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        return allItems.filter { item in
            item.name.lowercased().contains(kw)
            || (item.director?.lowercased().contains(kw) ?? false)
            || (item.cast?.contains(where: { $0.lowercased().contains(kw) }) ?? false)
            || (item.intro?.lowercased().contains(kw) ?? false)
        }
    }
}

// MARK: - HLS 下载管理器
class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!
    @Published var downloadProgress: [String: Double] = [:]
    @Published var localBookmarks: [String: Data] = [:]
    @Published var cacheMetadata: [String: VideoCacheMetadata] = [:]
    
    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    private let metadataKey  = "ONews_VideoCacheMetadata"
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        downloadSession = AVAssetDownloadURLSession(configuration: config,
                                                    assetDownloadDelegate: self,
                                                    delegateQueue: .main)
        loadBookmarks()
        loadMetadata()
    }
    
    func startDownload(urlString: String, title: String, coverImage: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let asset = AVURLAsset(url: url)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else { return }
        task.taskDescription = urlString
        task.resume()
        DispatchQueue.main.async {
            self.downloadProgress[urlString] = 0.0
            self.cacheMetadata[urlString] = VideoCacheMetadata(title: title,
                                                               coverImage: coverImage,
                                                               savedAt: Date())
            self.saveMetadata()
        }
    }
    
    func deleteDownload(urlString: String) {
        if let localURL = getLocalURL(for: urlString) {
            try? FileManager.default.removeItem(at: localURL)
        }
        localBookmarks.removeValue(forKey: urlString)
        cacheMetadata.removeValue(forKey: urlString)
        saveBookmarks()
        saveMetadata()
    }
    
    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmark = localBookmarks[urlString] else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        var percent = 0.0
        for value in loadedTimeRanges {
            let r = value.timeRangeValue
            percent += r.duration.seconds / timeRangeExpectedToLoad.duration.seconds
        }
        DispatchQueue.main.async {
            let current = self.downloadProgress[urlString] ?? 0.0
            self.downloadProgress[urlString] = min(1.0, max(current, percent))
        }
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let urlString = assetDownloadTask.taskDescription else { return }
        do {
            let bookmark = try location.bookmarkData(options: .minimalBookmark,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
            DispatchQueue.main.async {
                self.localBookmarks[urlString] = bookmark
                self.saveBookmarks()
            }
        } catch { print("保存书签失败: \(error)") }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlString = task.taskDescription else { return }
        DispatchQueue.main.async { self.downloadProgress.removeValue(forKey: urlString) }
    }
    
    private func saveBookmarks() {
        UserDefaults.standard.set(localBookmarks, forKey: bookmarksKey)
    }
    private func loadBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] {
            localBookmarks = saved
        }
    }
    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(cacheMetadata) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }
    private func loadMetadata() {
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let decoded = try? JSONDecoder().decode([String: VideoCacheMetadata].self, from: data) {
            cacheMetadata = decoded
        }
    }
}