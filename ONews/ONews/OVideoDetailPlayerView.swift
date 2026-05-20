// VideoDetailView、VideoPlayerPageView、VideoCacheView、CachedVideoPlayerView
// 详情、播放、缓存管理

import SwiftUI
import AVKit

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

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var selectedChannelIndex = 0
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                
                // 需求1：将播放列表整块放到图片下方原来'主演'的位置
                playlistSection
                
                // 需求2：其他演员（如果超过3个）
                if !item.otherCast.isEmpty {
                    sectionBlock(title: isGlobalEnglishMode ? "Other Cast" : "其他演员",
                                 content: item.otherCast.joined(separator: " / "))
                }
                
                // 简介
                if let intro = item.intro, !intro.isEmpty {
                    sectionBlock(title: isGlobalEnglishMode ? "Synopsis" : "简介", content: intro)
                }
                
                Spacer(minLength: 30)
            }
        }
        .navigationTitle(
            (item.info != nil && !item.info!.isEmpty) 
            ? "\(item.name) · \(item.info!)" 
            : item.name
        )
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
                // 导演
                if let director = item.director, !director.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Director" : "导演", value: director)
                }
                
                // 需求2：领衔主演 (前3个)
                if !item.starringCast.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Starring" : "主演",
                            value: item.starringCast.joined(separator: "、"))
                }
                
                // 编剧
                if let writers = item.writers, !writers.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Writers" : "编剧",
                            value: writers.joined(separator: "、"))
                }
                
                // 类型
                if let types = item.types, !types.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Genre" : "类型",
                            value: types.joined(separator: "、"))
                }
                
                // 地区
                if let region = item.region, !region.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Region" : "地区", value: region)
                }
                
                // 需求3：上映日期 (放到地区下方，评分上方)
                if let date = item.date, !date.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Release" : "上映日期", value: date)
                }
                
                // 评分
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
                    Divider().padding(.horizontal, 16)
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
                        // 【修改】改用排序后的有序 episodes 数组进行渲染
                        let sortedEps = channel.sortedEpisodes
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)],
                                  spacing: 10) {
                            ForEach(sortedEps, id: \.url) { episode in
                                NavigationLink(destination:
                                    VideoPlayerPageView(
                                        episodeURL: episode.url,
                                        videoTitle: "\(item.name) · \(episode.name)", // 直接使用字典里的 Key 作为集数名
                                        coverImage: item.image
                                    )
                                ) {
                                    Text(episode.name) // 直接显示 "高清" 或 "第1集"
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
            Text(value).font(.system(size: 12)).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func sectionBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(.secondary)
            Text(content).font(.system(size: 13)).foregroundColor(.primary).lineSpacing(2)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 播放页
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

// MARK: - 缓存管理
struct VideoCacheView: View {
    @StateObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    
    private var cachedItems: [(url: String, meta: VideoCacheMetadata)] {
        downloadManager.localBookmarks.keys.compactMap { url in
            if let m = downloadManager.cacheMetadata[url] {
                return (url, m)
            } else {
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

// MARK: - 离线缓存播放器
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