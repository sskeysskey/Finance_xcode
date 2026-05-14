import SwiftUI
import AVKit
import AVFoundation
import Combine

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
    /// 从 "2026-02-17(中国大陆)" 或 "2025" / "2025-10" 等中解析出 Date
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
    
    /// 取豆瓣 / IMDB 的最高评分
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
    var icon: String {
        self == .date ? "calendar" : "star.fill"
    }
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

// MARK: - 缓存元数据
struct VideoCacheMetadata: Codable {
    let title: String
    let coverImage: String?
    let savedAt: Date
}

// MARK: - HLS 下载管理器（扩展 metadata）
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

// MARK: - 顶层入口 (只有首页 + 底部栏; 分类/搜索/缓存改为 push 新页面)
struct VideoModuleView: View {
    @StateObject private var dataManager = OVideoDataManager()
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var selectedCategoryIndex = 0
    @State private var sortOption: VideoSortOption = .date
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VideoBrowseView(dataManager: dataManager,
                            selectedCategoryIndex: $selectedCategoryIndex,
                            sortOption: $sortOption)
                .padding(.bottom, 60)
            
            VideoBottomBar(dataManager: dataManager)
        }
        .task { await dataManager.loadVideosIfNeeded() }
        .refreshable { await dataManager.loadVideos() }
    }
}

// MARK: - 底部栏 (分类/搜索/缓存用 NavigationLink push)
struct VideoBottomBar: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    var body: some View {
        HStack(spacing: 0) {
            // 首页:当前页,点击时不做事 (或可滚动到顶部)
            barButton(icon: "square.grid.2x2.fill",
                      zh: "首页", en: "Home",
                      isActive: true) { }
            
            NavigationLink {
                VideoFilterView(dataManager: dataManager)
            } label: {
                barLabel(icon: "line.3.horizontal.decrease.circle",
                         zh: "分类", en: "Filter", isActive: false)
            }
            
            NavigationLink {
                VideoSearchTabView(dataManager: dataManager)
            } label: {
                barLabel(icon: "magnifyingglass",
                         zh: "搜索", en: "Search", isActive: false)
            }
            
            NavigationLink {
                VideoCacheView()
            } label: {
                barLabel(icon: "arrow.down.circle",
                         zh: "缓存", en: "Cache", isActive: false)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().frame(height: 0.5)
                    .foregroundColor(.secondary.opacity(0.2)), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
    
    private func barButton(icon: String, zh: String, en: String,
                           isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barLabel(icon: icon, zh: zh, en: en, isActive: isActive)
        }
    }
    
    private func barLabel(icon: String, zh: String, en: String, isActive: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
            Text(isGlobalEnglishMode ? en : zh)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(isActive ? .accentColor : .secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - 首页 (瀑布流 + Navbar 分类/排序)
struct VideoBrowseView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @Binding var selectedCategoryIndex: Int
    @Binding var sortOption: VideoSortOption
    
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    private var currentItems: [OVideoItem] {
        guard selectedCategoryIndex < dataManager.categories.count else { return [] }
        return dataManager.sortItems(dataManager.categories[selectedCategoryIndex].items,
                                     by: sortOption)
    }
    
    private var currentCategoryDisplay: String {
        guard selectedCategoryIndex < dataManager.categories.count
        else { return isGlobalEnglishMode ? "Video" : "影视" }
        return categoryDisplayName(dataManager.categories[selectedCategoryIndex].name)
    }
    
    var body: some View {
        Group {
            if dataManager.isLoading && dataManager.categories.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = dataManager.errorMessage, dataManager.categories.isEmpty {
                errorView(err)
            } else if dataManager.categories.isEmpty {
                Text(isGlobalEnglishMode ? "No content" : "暂无内容")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    WaterfallGridView(items: currentItems)
                        .padding(.top, 10)
                        .padding(.bottom, 20)
                }
                .background(Color(UIColor.systemGroupedBackground))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 中间：分类下拉
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(Array(dataManager.categories.enumerated()), id: \.offset) { idx, cat in
                        Button {
                            withAnimation { selectedCategoryIndex = idx }
                        } label: {
                            if idx == selectedCategoryIndex {
                                Label(categoryDisplayName(cat.name), systemImage: "checkmark")
                            } else {
                                Text(categoryDisplayName(cat.name))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentCategoryDisplay)
                            .font(.system(size: 17, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            
            // 右边：排序
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(VideoSortOption.allCases, id: \.self) { opt in
                        Button {
                            withAnimation { sortOption = opt }
                        } label: {
                            if opt == sortOption {
                                Label(opt.displayName(isGlobalEnglishMode), systemImage: "checkmark")
                            } else {
                                Label(opt.displayName(isGlobalEnglishMode), systemImage: opt.icon)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 18, weight: .medium))
                }
            }
        }
    }
    
    private func categoryDisplayName(_ key: String) -> String {
        if isGlobalEnglishMode { return key }
        switch key {
        case "Movie": return "电影"
        case "Drama": return "剧集"
        case "Show":  return "综艺"
        case "Anime": return "动漫"
        case "TV":    return "电视剧"
        default:      return key
        }
    }
    
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundColor(.orange)
            Text(msg).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button(isGlobalEnglishMode ? "Retry" : "重试") {
                Task { await dataManager.loadVideos() }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color.blue).foregroundColor(.white).cornerRadius(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 瀑布流 (两列, Lazy 懒加载)
struct WaterfallGridView: View {
    let items: [OVideoItem]
    
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    var body: some View {
        if items.isEmpty {
            Text("暂无内容")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(destination: VideoDetailView(item: item)) {
                        VideoCardView(item: item)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - 卡片 (关键修复:固定2:3比例,防止溢出/重叠)
struct VideoCardView: View {
    let item: OVideoItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 使用 Color.clear + aspectRatio(.fit) + overlay,保证卡片宽度等于列宽
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomTrailing) {
                        coverImage
                        if let info = item.info, !info.isEmpty {
                            Text(info)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .padding(6)
                        }
                        // 评分小角标
                        if item.bestRating > 0 {
                            VStack {
                                HStack {
                                    Text(String(format: "%.1f", item.bestRating))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                                        .padding(6)
                                    Spacer()
                                }
                                Spacer()
                            }
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if let date = item.date, !date.isEmpty {
                Text(date.split(separator: "(").first.map(String.init) ?? date)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let types = item.types, !types.isEmpty {
                Text(types.joined(separator: " / "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 2)
    }
    
    @ViewBuilder
    private var coverImage: some View {
        if let imageName = item.image, !imageName.isEmpty,
           let url = OVideoAPI.coverURL(for: imageName) {
            CachedAsyncImage(url: url) { phase in
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
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            // 关键: 先裁剪再 clipped 防止溢出到兄弟卡片
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Image(systemName: "film").foregroundColor(.secondary).font(.title2)
            }
        }
    }
}

// MARK: - 分类检索页
struct VideoFilterView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var selectedType: String? = nil
    @State private var selectedYear: Int? = nil
    @State private var selectedRegion: String? = nil
    
    private var allTypes: [String] {
        let set = Set(dataManager.allItems.flatMap { $0.types ?? [] })
        return set.sorted()
    }
    private var allYears: [Int] {
        let set = Set(dataManager.allItems.compactMap { $0.releaseYear })
        return set.sorted(by: >)
    }
    private var allRegions: [String] {
        let set = Set(dataManager.allItems.compactMap { $0.region }).filter { !$0.isEmpty }
        return set.sorted()
    }
    
    private var filteredItems: [OVideoItem] {
        dataManager.allItems.filter { item in
            if let t = selectedType, !(item.types?.contains(t) ?? false) { return false }
            if let y = selectedYear, item.releaseYear != y { return false }
            if let r = selectedRegion, item.region != r { return false }
            return true
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filterRow(title: isGlobalEnglishMode ? "Genre" : "类型",
                              options: ["All"] + allTypes,
                              selected: selectedType ?? "All") { v in
                        selectedType = (v == "All") ? nil : v
                    }
                    filterRow(title: isGlobalEnglishMode ? "Year" : "年份",
                              options: ["All"] + allYears.map { String($0) },
                              selected: selectedYear.map { String($0) } ?? "All") { v in
                        selectedYear = (v == "All") ? nil : Int(v)
                    }
                    filterRow(title: isGlobalEnglishMode ? "Region" : "地区",
                              options: ["All"] + allRegions,
                              selected: selectedRegion ?? "All") { v in
                        selectedRegion = (v == "All") ? nil : v
                    }
                    
                    Divider().padding(.horizontal, 16)
                    
                    HStack {
                        Text(isGlobalEnglishMode
                             ? "\(filteredItems.count) result(s)"
                             : "共 \(filteredItems.count) 个结果")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        if selectedType != nil || selectedYear != nil || selectedRegion != nil {
                            Button {
                                selectedType = nil; selectedYear = nil; selectedRegion = nil
                            } label: {
                                Label(isGlobalEnglishMode ? "Reset" : "重置",
                                      systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    WaterfallGridView(items: filteredItems)
                        .padding(.top, 4)
                }
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(isGlobalEnglishMode ? "Filter" : "分类检索")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func filterRow(title: String, options: [String],
                           selected: String,
                           onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { opt in
                        let isSelected = opt == selected
                        Button {
                            onSelect(opt)
                        } label: {
                            Text(opt == "All" ? (isGlobalEnglishMode ? "All" : "全部") : opt)
                                .font(.system(size: 13,
                                              weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : .primary)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(
                                    Capsule().fill(isSelected
                                                   ? Color.accentColor
                                                   : Color.secondary.opacity(0.12))
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - 搜索 Tab
struct VideoSearchTabView: View {
    @ObservedObject var dataManager: OVideoDataManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var keyword: String = ""
    @FocusState private var focused: Bool
    
    private var results: [OVideoItem] { dataManager.search(keyword: keyword) }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(isGlobalEnglishMode
                          ? "Search name / director / cast..."
                          : "搜索视频名称 / 导演 / 演员",
                          text: $keyword)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintView(icon: "magnifyingglass",
                         text: isGlobalEnglishMode ? "Type to search" : "输入关键词开始搜索")
            } else if results.isEmpty {
                hintView(icon: "tray",
                         text: isGlobalEnglishMode ? "No results" : "暂无搜索结果")
            } else {
                ScrollView {
                    WaterfallGridView(items: results)
                        .padding(.top, 10)
                        .padding(.bottom, 20)
                }
                .background(Color(UIColor.systemGroupedBackground))
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Search" : "搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }
    
    private func hintView(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.5))
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 缓存管理
struct VideoCacheView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    private var cachedItems: [(url: String, meta: VideoCacheMetadata)] {
        downloadManager.localBookmarks.keys.compactMap { url in
            if let m = downloadManager.cacheMetadata[url] {
                return (url, m)
            } else {
                // 兼容老数据:没有 metadata 的也显示
                return (url, VideoCacheMetadata(title: url, coverImage: nil, savedAt: Date()))
            }
        }.sorted { $0.meta.savedAt > $1.meta.savedAt }
    }
    
    private var downloadingItems: [(url: String, progress: Double, title: String)] {
        downloadManager.downloadProgress.compactMap { key, value in
            let title = downloadManager.cacheMetadata[key]?.title ?? key
            return (key, value, title)
        }.sorted { $0.title < $1.title }
    }
    
    var body: some View {
        Group {
            if cachedItems.isEmpty && downloadingItems.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 54))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(isGlobalEnglishMode ? "No cached videos yet" : "还没有缓存的视频")
                        .foregroundColor(.secondary)
                    Text(isGlobalEnglishMode
                         ? "Cached videos can be played offline"
                         : "缓存后即可离线播放")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !downloadingItems.isEmpty {
                        Section(header: Text(isGlobalEnglishMode ? "Downloading" : "下载中")) {
                            ForEach(downloadingItems, id: \.url) { row in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                    HStack {
                                        ProgressView(value: row.progress)
                                        Text("\(Int(row.progress * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    
                    if !cachedItems.isEmpty {
                        Section(header: Text(isGlobalEnglishMode
                                             ? "Cached (\(cachedItems.count))"
                                             : "已缓存 (\(cachedItems.count))")) {
                            ForEach(cachedItems, id: \.url) { row in
                                NavigationLink(destination:
                                    CachedVideoPlayerView(realURL: row.url, title: row.meta.title)
                                ) {
                                    HStack(spacing: 12) {
                                        coverThumb(name: row.meta.coverImage)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.meta.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .lineLimit(2)
                                            Text(formattedDate(row.meta.savedAt))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Label(isGlobalEnglishMode ? "Offline" : "已缓存",
                                                  systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        downloadManager.deleteDownload(urlString: row.url)
                                    } label: {
                                        Label(isGlobalEnglishMode ? "Delete" : "删除",
                                              systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Offline Cache" : "离线缓存")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private func coverThumb(name: String?) -> some View {
        if let name = name, !name.isEmpty, let url = OVideoAPI.coverURL(for: name) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 54, height: 80)
            .clipped()
            .cornerRadius(6)
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "film").foregroundColor(.secondary)
            }
            .frame(width: 54, height: 80)
            .cornerRadius(6)
        }
    }
    
    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - 离线缓存播放器(直接使用本地 URL)
struct CachedVideoPlayerView: View {
    let realURL: String
    let title: String
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let local = downloadManager.getLocalURL(for: realURL) {
                    VideoPlayerView(videoURL: local)
                } else if let url = URL(string: realURL) {
                    VideoPlayerView(videoURL: url)
                } else {
                    Text(isGlobalEnglishMode ? "Unable to play" : "无法播放")
                        .foregroundColor(.white)
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 16, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text(isGlobalEnglishMode
                         ? "Playing from local cache"
                         : "当前正在使用本地缓存播放")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button(role: .destructive) {
                    downloadManager.deleteDownload(urlString: realURL)
                } label: {
                    Label(isGlobalEnglishMode ? "Delete Cache" : "删除缓存",
                          systemImage: "trash")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(16)
            
            Spacer()
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
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
    
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let imageName = item.image, !imageName.isEmpty,
                   let url = OVideoAPI.coverURL(for: imageName) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Rectangle().fill(Color.secondary.opacity(0.15))
                        }
                    }
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 120, height: 170).clipped().cornerRadius(10)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary).lineLimit(2)
                
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
        .padding(.horizontal, 16).padding(.top, 12)
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
    
    private var playlistSection: some View {
        Group {
            if item.playlist.isEmpty {
                Text(isGlobalEnglishMode ? "No sources" : "暂无可用资源")
                    .foregroundColor(.secondary).padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isGlobalEnglishMode ? "Sources" : "播放列表")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 16)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(item.playlist.enumerated()), id: \.offset) { idx, ch in
                                Button {
                                    withAnimation { selectedChannelIndex = idx }
                                } label: {
                                    Text(ch.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(selectedChannelIndex == idx ? .white : .primary)
                                        .padding(.horizontal, 14).padding(.vertical, 7)
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
                    
                    if selectedChannelIndex < item.playlist.count {
                        let channel = item.playlist[selectedChannelIndex]
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)],
                                  spacing: 10) {
                            ForEach(Array(channel.episodes.enumerated()), id: \.offset) { epIdx, epURL in
                                NavigationLink(destination:
                                    VideoPlayerPageView(
                                        episodeURL: epURL,
                                        videoTitle: "\(item.name) · \(episodeLabel(index: epIdx, channel: channel))",
                                        coverImage: item.image
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
    
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):").font(.system(size: 12)).foregroundColor(.secondary)
            Text(value).font(.system(size: 12)).foregroundColor(.primary).lineLimit(2)
        }
    }
    
    private func sectionBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(.secondary)
            Text(content).font(.system(size: 13)).foregroundColor(.primary).lineSpacing(2)
        }
        .padding(.horizontal, 16)
    }
    
    private func episodeLabel(index: Int, channel: OVideoChannel) -> String {
        if channel.episodes.count == 1 { return item.info ?? "HD" }
        return isGlobalEnglishMode ? "EP \(index + 1)" : "第\(index + 1)集"
    }
}

// MARK: - 播放页 (加了 coverImage 传递给下载管理器)
struct VideoPlayerPageView: View {
    let episodeURL: String
    let videoTitle: String
    let coverImage: String?
    
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    @State private var realURL: String? = nil
    @State private var isResolving = true
    @State private var resolveError: String? = nil
    
    var body: some View {
        VStack(spacing: 0) {
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
                            .font(.system(size: 36)).foregroundColor(.orange)
                        Text(error).foregroundColor(.white).font(.subheadline)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        Button(isGlobalEnglishMode ? "Retry" : "重试") {
                            Task { await resolve() }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.white.opacity(0.9))
                        .foregroundColor(.black).cornerRadius(16)
                    }
                } else if let real = realURL {
                    let playURL = downloadManager.getLocalURL(for: real) ?? URL(string: real)!
                    VideoPlayerView(videoURL: playURL)
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(videoTitle)
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 16).padding(.top, 16)
                    
                    if let real = realURL {
                        cacheSection(realURL: real)
                    }
                    
                    if let real = realURL, downloadManager.localBookmarks[real] != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.slash").foregroundColor(.green)
                            Text(isGlobalEnglishMode
                                 ? "Playing from local cache"
                                 : "当前正在使用本地缓存播放")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                    Spacer(minLength: 30)
                }
            }
        }
        .navigationTitle(isGlobalEnglishMode ? "Player" : "播放")
        .navigationBarTitleDisplayMode(.inline)
        .task { if realURL == nil { await resolve() } }
    }
    
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
                            .background(Color.red.opacity(0.12)).cornerRadius(16)
                    }
                } else if progress != nil {
                    Text("\(Int((progress ?? 0) * 100))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                } else {
                    Button {
                        downloadManager.startDownload(urlString: realURL,
                                                      title: videoTitle,
                                                      coverImage: coverImage)
                    } label: {
                        Label(isGlobalEnglishMode ? "Download" : "缓存到本地",
                              systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12)).cornerRadius(16)
                    }
                }
            }
            
            if isDownloaded {
                Label(isGlobalEnglishMode ? "Cached, available offline" : "已缓存,可离线播放",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundColor(.green)
            } else if let p = progress {
                ProgressView(value: p)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
            } else {
                Text(isGlobalEnglishMode
                     ? "Cache this video for offline playback later."
                     : "缓存后可离线播放,建议在 Wi-Fi 环境下操作。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
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

// MARK: - 简易图片内存缓存
final class OImageCache {
    static let shared = OImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {
        cache.countLimit = 300          // 最多缓存 300 张
        cache.totalCostLimit = 200 * 1024 * 1024  // 约 200MB
    }
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL,
                        cost: Int(image.size.width * image.size.height * 4))
    }
}

// MARK: - 带缓存的异步图片
struct CachedAsyncImage<Content: View>: View {
    let url: URL
    let content: (AsyncImagePhase) -> Content
    
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    
    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }
    
    var body: some View {
        // 使用 Group 或其他容器包裹，确保 .task 作用在整个视图上
        Group {
            if let img = uiImage {
                content(.success(Image(uiImage: img)))
            } else if isLoading {
                content(.empty)
            } else {
                content(.empty)
            }
        }
        // 将 .task 放在 Group 上，或者放在 Group 内部的具体视图上
        .task(id: url) { 
            await load() 
        }
    }
    
    private func load() async {
        // 如果已经有图，直接返回
        if uiImage != nil { return }
        
        if let cached = OImageCache.shared.image(for: url) {
            self.uiImage = cached
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                OImageCache.shared.set(img, for: url)
                self.uiImage = img
            }
        } catch { 
            // 加载失败，可以根据需要处理
        }
    }
}