import SwiftUI

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var selectedChannelIndex = 0

    // 【新增】
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @State private var navigateToPlayer = false                // 触发跳转
    
    // 【新增】用于记录当前点击并准备播放的剧集
    @State private var selectedEpisode: (name: String, url: String)? = nil
    
    // 【新增】对 playlist 进行排序的计算属性
    private var sortedPlaylist: [OVideoChannel] {
        let validURLs: Set<String> = {
            // 保持你原有的有效 URL 集合逻辑
            return Set<String>() 
        }()
        
        let indexedChannels = item.playlist.enumerated().map { (index, channel) -> (index: Int, channel: OVideoChannel, validCount: Int, qualityScore: Int) in
            let validCount = channel.episodes.values.filter { url in
                validURLs.isEmpty ? true : validURLs.contains(url)
            }.count
            
            var qualityScore = 1 
            let episodeKeys = channel.episodes.keys
            
            let hasLowQuality = episodeKeys.contains { key in
                let k = key.uppercased()
                return k.contains("TC") || k.contains("TS") || k.contains("HC") || k.contains("抢先")
            }
            
            let hasHighQuality = episodeKeys.contains { key in
                let k = key.uppercased()
                return k.contains("HD") || k.contains("正片")
            }
            
            if hasLowQuality {
                qualityScore = 0
            } else if hasHighQuality {
                qualityScore = 2
            }
            
            return (index, channel, validCount, qualityScore)
        }
        
        let sortedIndexed = indexedChannels.sorted { a, b in
            if a.validCount != b.validCount {
                return a.validCount > b.validCount
            }
            if a.qualityScore != b.qualityScore {
                return a.qualityScore > b.qualityScore
            }
            return a.index < b.index
        }
        
        return sortedIndexed.map { $0.channel }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                
                // 播放列表
                playlistSection
                
                // 其他演员
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
        // 【核心修复】：在后台放置一个隐藏的 NavigationLink，用来响应 navigateToPlayer 状态进行跳转
        .navigationDestination(isPresented: $navigateToPlayer) {
            if let episode = selectedEpisode {
                VideoPlayerPageView(
                    episodeURL: episode.url,
                    videoTitle: "\(item.name) · \(episode.name)",
                    coverImage: item.image,
                    channelName: sortedPlaylist[selectedChannelIndex].name, // 传入线路名（如 天堂）
                    episodeName: episode.name,                             // 传入集数名（如 HD国语）
                    sourceURL: item.url                                    // 传入影片详情页唯一键
                )
            }
        }
        // 【新增】订阅页弹窗
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
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
                if let alias = item.alias, !alias.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Alias" : "又名", value: alias)
                }

                if let director = item.director, !director.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Director" : "导演", value: director)
                }
                
                if !item.starringCast.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Starring" : "主演",
                            value: item.starringCast.joined(separator: "、"))
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
                
                if let date = item.date, !date.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Release" : "上映日期", value: date)
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
    
    private var playlistSection: some View {
        Group {
            if sortedPlaylist.isEmpty {
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
                            ForEach(Array(sortedPlaylist.enumerated()), id: \.offset) { idx, ch in
                                Button {
                                    withAnimation { selectedChannelIndex = idx }
                                } label: {
                                    // 【核心修改】：将 ch.name（如 "天堂"）在 UI 上映射为 "线路 1" / "Line 1"
                                    let displayName = isGlobalEnglishMode ? "Line \(idx + 1)" : "线路 \(idx + 1)"
                                    Text(displayName)
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
                    
                    if selectedChannelIndex < sortedPlaylist.count {
                        let channel = sortedPlaylist[selectedChannelIndex]
                        let sortedEps = channel.sortedEpisodes
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)],
                                  spacing: 10) {
                            ForEach(sortedEps, id: \.url) { episode in
                                Button {
                                    // 点击时先记录当前选中的剧集，再判断订阅状态
                                    selectedEpisode = episode
                                    
                                    if authManager.canAccessVideoContent() {
                                        navigateToPlayer = true
                                    } else {
                                        showSubscriptionSheet = true
                                    }
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        Text(episode.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(8)
                                        
                                        if !authManager.isSubscribed {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 9))
                                                .foregroundColor(.orange.opacity(0.85))
                                                .padding(4)
                                        }
                                    }
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