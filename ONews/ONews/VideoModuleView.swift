import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - 服务器地址 (与 ResourceManager 保持一致)
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
    let ratings: [String: String]? // 修改点：将 [String]? 改为 [String: String]?
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
            print("加载视频失败: \(error)")
        }
    }
    
    /// 本地搜索（覆盖 name / 导演 / 主演 / 简介）
    func search(keyword: String) -> [OVideoItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        var results: [OVideoItem] = []
        for cat in categories {
            for item in cat.items {
                if item.name.lowercased().contains(kw)
                    || (item.director?.lowercased().contains(kw) ?? false)
                    || (item.cast?.contains(where: { $0.lowercased().contains(kw) }) ?? false)
                    || (item.intro?.lowercased().contains(kw) ?? false) {
                    results.append(item)
                }
            }
        }
        return results
    }
}

// MARK: - HLS 下载管理器 (复用原逻辑)
class HLSDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = HLSDownloadManager()
    private var downloadSession: AVAssetDownloadURLSession!
    @Published var downloadProgress: [String: Double] = [:]
    @Published var localBookmarks: [String: Data] = [:]
    
    private let bookmarksKey = "ONews_SavedHLSBookmarks"
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.miniplayer.hlsdownload")
        downloadSession = AVAssetDownloadURLSession(configuration: config,
                                                    assetDownloadDelegate: self,
                                                    delegateQueue: .main)
        loadBookmarks()
    }
    
    func startDownload(urlString: String, title: String) {
        guard let url = URL(string: urlString) else { return }
        let asset = AVURLAsset(url: url)
        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset, assetTitle: title, assetArtworkData: nil, options: nil
        ) else { return }
        task.taskDescription = urlString
        task.resume()
        DispatchQueue.main.async { self.downloadProgress[urlString] = 0.0 }
    }
    
    func deleteDownload(urlString: String) {
        guard let localURL = getLocalURL(for: urlString) else { return }
        do {
            try FileManager.default.removeItem(at: localURL)
            localBookmarks.removeValue(forKey: urlString)
            saveBookmarks()
        } catch { print("删除失败: \(error)") }
    }
    
    func getLocalURL(for urlString: String) -> URL? {
        guard let bookmark = localBookmarks[urlString] else { return nil }
        var isStale = false
        do {
            return try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        } catch { return nil }
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
}

// MARK: - 播放器封装
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

// MARK: - 主入口视图
struct VideoModuleView: View {
    @StateObject private var dataManager = OVideoDataManager()
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var selectedCategoryIndex = 0
    @State private var showSearch = false
    
    var body: some View {
        VStack(spacing: 0) {
            if dataManager.isLoading && dataManager.categories.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = dataManager.errorMessage, dataManager.categories.isEmpty {
                errorView(error)
            } else if dataManager.categories.isEmpty {
                Text(isGlobalEnglishMode ? "No content" : "暂无内容")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                categoryTabs
                    .background(Color(UIColor.systemBackground))
                
                Divider()
                
                TabView(selection: $selectedCategoryIndex) {
                    ForEach(Array(dataManager.categories.enumerated()), id: \.offset) { idx, cat in
                        VideoGridView(items: cat.items)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Video Library" : "影视频道")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                }
                .disabled(dataManager.categories.isEmpty)
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                VideoSearchView(dataManager: dataManager)
            }
        }
        .task { await dataManager.loadVideosIfNeeded() }
        .refreshable { await dataManager.loadVideos() }
    }
    
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(msg)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(isGlobalEnglishMode ? "Retry" : "重试") {
                Task { await dataManager.loadVideos() }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color.blue).foregroundColor(.white)
            .cornerRadius(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 顶部分类 Tab
    private var categoryTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(Array(dataManager.categories.enumerated()), id: \.offset) { idx, cat in
                        VStack(spacing: 6) {
                            Text(categoryDisplayName(cat.name))
                                .font(.system(size: selectedCategoryIndex == idx ? 17 : 15,
                                              weight: selectedCategoryIndex == idx ? .bold : .medium))
                                .foregroundColor(selectedCategoryIndex == idx ? .primary : .secondary)
                            Rectangle()
                                .fill(selectedCategoryIndex == idx ? Color.accentColor : .clear)
                                .frame(width: 22, height: 3)
                                .cornerRadius(1.5)
                        }
                        .id(idx)
                        .onTapGesture {
                            withAnimation(.easeInOut) {
                                selectedCategoryIndex = idx
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }
            .onChange(of: selectedCategoryIndex) { newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }
    
    private func categoryDisplayName(_ key: String) -> String {
        if isGlobalEnglishMode { return key }
        switch key {
        case "Movie":  return "电影"
        case "Drama":  return "剧集"
        case "Show":   return "综艺"
        case "Anime":  return "动漫"
        case "TV":     return "电视剧"
        default:       return key
        }
    }
}

// MARK: - 视频网格（小红书风格两列）
struct VideoGridView: View {
    let items: [OVideoItem]
    
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    var body: some View {
        if items.isEmpty {
            Text("暂无内容")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(destination: VideoDetailView(item: item)) {
                            VideoCardView(item: item)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - 卡片（封面 + info 角标 + 名称 + 日期）
struct VideoCardView: View {
    let item: OVideoItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                coverImage
                
                if let info = item.info, !info.isEmpty {
                    Text(info)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.65))
                        )
                        .padding(6)
                }
            }
            
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            
            if let date = item.date, !date.isEmpty {
                Text(date)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
    
    @ViewBuilder
    private var coverImage: some View {
        if let imageName = item.image,
           !imageName.isEmpty,
           let url = OVideoAPI.coverURL(for: imageName) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                        ProgressView()
                    }
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                        Image(systemName: "photo").foregroundColor(.secondary)
                    }
                @unknown default:
                    EmptyView()
                }
            }
            .aspectRatio(2/3, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
            .cornerRadius(10)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .aspectRatio(2/3, contentMode: .fill)
                .cornerRadius(10)
                .overlay(Image(systemName: "film").foregroundColor(.secondary))
        }
    }
}

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var selectedChannelIndex = 0
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                if let cast = item.cast, !cast.isEmpty {
                    sectionBlock(title: isGlobalEnglishMode ? "Cast" : "主演",
                                 content: cast.joined(separator: " / "))
                }
                auxInfoSection
                if let intro = item.intro, !intro.isEmpty {
                    sectionBlock(title: isGlobalEnglishMode ? "Synopsis" : "简介", content: intro)
                }
                Divider().padding(.horizontal, 16)
                playlistSection
                Spacer(minLength: 30)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // 顶部：图 + 基本信息
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let imageName = item.image,
                   !imageName.isEmpty,
                   let url = OVideoAPI.coverURL(for: imageName) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Rectangle().fill(Color.secondary.opacity(0.15))
                        }
                    }
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 120, height: 170)
            .clipped()
            .cornerRadius(10)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                if let director = item.director, !director.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Director" : "导演", value: director)
                }
                if let writers = item.writers, !writers.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Writers" : "编剧",
                            value: writers.joined(separator: "、"))
                }
                if let types = item.types, !types.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Genre" : "类型",
                            value: types.joined(separator: "、"))
                }
                if let region = item.region, !region.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Region" : "地区", value: region)
                }
                if let ratings = item.ratings, !ratings.isEmpty {
                    HStack(spacing: 6) {
                        // 修改点：因为 ratings 变成了字典，所以需要遍历字典的键值对。
                        // 为了保证每次显示的顺序一致，这里使用 sorted(by:) 对键进行了排序。
                        ForEach(ratings.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            Text("\(key) \(value)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
    
    private var auxInfoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = item.date, !date.isEmpty {
                Text(date).font(.system(size: 12)).foregroundColor(.secondary)
            }
            if let alias = item.alias, !alias.isEmpty {
                Text(alias).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - 播放列表区
    private var playlistSection: some View {
        Group {
            if item.playlist.isEmpty {
                Text(isGlobalEnglishMode ? "No sources" : "暂无可用资源")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isGlobalEnglishMode ? "Sources" : "播放列表")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 16)
                    
                    // Channel tabs
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(item.playlist.enumerated()), id: \.offset) { idx, ch in
                                Button {
                                    withAnimation { selectedChannelIndex = idx }
                                } label: {
                                    Text(ch.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(selectedChannelIndex == idx ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule().fill(selectedChannelIndex == idx
                                                           ? Color.accentColor
                                                           : Color.secondary.opacity(0.15))
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // 集数按钮
                    if selectedChannelIndex < item.playlist.count {
                        let channel = item.playlist[selectedChannelIndex]
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)],
                                  spacing: 10) {
                            ForEach(Array(channel.episodes.enumerated()), id: \.offset) { epIdx, epURL in
                                NavigationLink(destination:
                                    VideoPlayerPageView(
                                        episodeURL: epURL,
                                        videoTitle: "\(item.name) · \(episodeLabel(index: epIdx, channel: channel))"
                                    )
                                ) {
                                    Text(episodeLabel(index: epIdx, channel: channel))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
    
    // 小工具
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
    }
    
    private func sectionBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
            Text(content)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineSpacing(2)
        }
        .padding(.horizontal, 16)
    }
    
    private func episodeLabel(index: Int, channel: OVideoChannel) -> String {
        if channel.episodes.count == 1 {
            return item.info ?? "HD"
        } else {
            return isGlobalEnglishMode ? "EP \(index + 1)" : "第\(index + 1)集"
        }
    }
}

// MARK: - 播放页（嵌入式播放 + 缓存）
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // 播放器区
            ZStack {
                Color.black
                if isResolving {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(isGlobalEnglishMode ? "Resolving..." : "解析中...")
                            .foregroundColor(.white).font(.caption)
                    }
                } else if let error = resolveError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button(isGlobalEnglishMode ? "Retry" : "重试") {
                            Task { await resolve() }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.white.opacity(0.9))
                        .foregroundColor(.black)
                        .cornerRadius(16)
                    }
                } else if let real = realURL {
                    let playURL = downloadManager.getLocalURL(for: real) ?? URL(string: real)!
                    VideoPlayerView(videoURL: playURL)
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            
            // 下方控制区
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(videoTitle)
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 16).padding(.top, 16)
                    
                    if let real = realURL {
                        cacheSection(realURL: real)
                    }
                    
                    // 小提示
                    if realURL != nil && downloadManager.localBookmarks[realURL!] != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.slash").foregroundColor(.green)
                            Text(isGlobalEnglishMode
                                 ? "Playing from local cache"
                                 : "当前正在使用本地缓存播放")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    Spacer(minLength: 30)
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if realURL == nil { await resolve() }
        }
    }
    
    // 缓存控件
    @ViewBuilder
    private func cacheSection(realURL: String) -> some View {
        let isDownloaded = downloadManager.localBookmarks[realURL] != nil
        let progress = downloadManager.downloadProgress[realURL]
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "icloud.and.arrow.down").foregroundColor(.blue)
                Text(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                
                if isDownloaded {
                    Button {
                        downloadManager.deleteDownload(urlString: realURL)
                    } label: {
                        Label(isGlobalEnglishMode ? "Delete" : "删除缓存",
                              systemImage: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.12))
                            .cornerRadius(16)
                    }
                } else if progress != nil {
                    Text("\(Int((progress ?? 0) * 100))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                } else {
                    Button {
                        downloadManager.startDownload(urlString: realURL, title: videoTitle)
                    } label: {
                        Label(isGlobalEnglishMode ? "Download" : "缓存到本地",
                              systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(16)
                    }
                }
            }
            
            if isDownloaded {
                Label(isGlobalEnglishMode ? "Cached, available offline" : "已缓存，可离线播放",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            } else if let p = progress {
                ProgressView(value: p)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
            } else {
                Text(isGlobalEnglishMode
                     ? "Cache this video for offline playback later."
                     : "缓存后可离线播放，建议在 Wi-Fi 环境下操作。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
    
    private func resolve() async {
        isResolving = true
        resolveError = nil
        do {
            let url = try await OVideoAPI.resolveRealURL(episodeURL: episodeURL)
            self.realURL = url
        } catch {
            self.resolveError = error.localizedDescription
        }
        isResolving = false
    }
}

// MARK: - 搜索视图
struct VideoSearchView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var keyword: String = ""
    @FocusState private var searchFocused: Bool
    
    private var results: [OVideoItem] { dataManager.search(keyword: keyword) }
    
    var body: some View {
        VStack(spacing: 0) {
            // 自定义搜索栏
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(isGlobalEnglishMode
                              ? "Search name / director / cast..."
                              : "搜索视频名称 / 导演 / 演员",
                              text: $keyword)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !keyword.isEmpty {
                        Button { keyword = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(10)
                
                Button(isGlobalEnglishMode ? "Cancel" : "取消") { dismiss() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintView(icon: "magnifyingglass",
                         text: isGlobalEnglishMode ? "Type to search" : "输入关键词开始搜索")
            } else if results.isEmpty {
                hintView(icon: "tray",
                         text: isGlobalEnglishMode ? "No results" : "暂无搜索结果")
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ], spacing: 14) {
                        ForEach(results) { item in
                            NavigationLink(destination: VideoDetailView(item: item)) {
                                VideoCardView(item: item)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8).padding(.bottom, 30)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { searchFocused = true }
    }
    
    private func hintView(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}