import SwiftUI

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var selectedChannelIndex = 0
    
    // 【新增】对 playlist 进行排序的计算属性
    private var sortedPlaylist: [OVideoChannel] {
        // 1. 获取当前下载/映射管理器中的所有有效 URL 集合 (请根据你项目实际的单例和属性名修改)
        // 假设你的 HLSDownloadManager 存在，且里面有 url_mapping 字典
        // 如果你的 url_mapping 结构不同，请将此处替换为获取有效 URL 集合的逻辑
        // 比如：let validURLs = Set(HLSDownloadManager.shared.urlMapping.keys)
        // 这里做一个安全的兜底：如果获取不到，则不进行过滤，全部视为有效
        let validURLs: Set<String> = {
            // TODO: 请在此处替换为你的 url_mapping 数据源
            // 例如：return Set(HLSDownloadManager.shared.urlMapping.keys)
            // 下面是示意代码（如果你的 HLSDownloadManager 叫别的名字，请对应修改）：
            // return Set(HLSDownloadManager.shared.url_mapping.keys)
            return Set<String>() 
        }()
        
        // 2. 将 playlist 转换为带排序权重的元组
        let indexedChannels = item.playlist.enumerated().map { (index, channel) -> (index: Int, channel: OVideoChannel, validCount: Int, qualityScore: Int) in
            
            // A. 计算当前 channel 中有效 url 的数量
            let validCount = channel.episodes.values.filter { url in
                // 判断 url 是否在有效映射中
                // 如果 validURLs 为空（比如还没加载完），我们默认所有 url 都有效，或者你可以根据业务调整
                validURLs.isEmpty ? true : validURLs.contains(url)
            }.count
            
            // B. 计算画质/版本权重分数 (qualityScore)
            // 规则：
            // - 包含 "HD" 或 "正片" -> 记为 2 分 (优先显示)
            // - 包含 "TC", "TS", "抢先", "HC" -> 记为 0 分 (靠后显示)
            // - 其他情况 -> 记为 1 分 (默认)
            var qualityScore = 1 
            
            let episodeKeys = channel.episodes.keys
            
            // 判断是否包含降级关键字
            let hasLowQuality = episodeKeys.contains { key in
                let k = key.uppercased()
                return k.contains("TC") || k.contains("TS") || k.contains("HC") || k.contains("抢先")
            }
            
            // 判断是否包含升级关键字
            let hasHighQuality = episodeKeys.contains { key in
                let k = key.uppercased()
                return k.contains("HD") || k.contains("正片")
            }
            
            if hasLowQuality {
                qualityScore = 0 // 包含抢先、TC等，降级
            } else if hasHighQuality {
                qualityScore = 2 // 不含低画质，且含有HD、正片等，升级
            }
            
            return (index, channel, validCount, qualityScore)
        }
        
        // 3. 综合排序规则：
        //   - 优先按有效数量（validCount）降序排列
        //   - 其次按画质分数（qualityScore）降序排列（HD/正片在前，TC/抢先在后）
        //   - 如果前两者都相同，按原始索引（index）升序排列（即保持默认顺序）
        let sortedIndexed = indexedChannels.sorted { a, b in
            // 1. 比较有效 URL 数量
            if a.validCount != b.validCount {
                return a.validCount > b.validCount
            }
            // 2. 比较画质分数
            if a.qualityScore != b.qualityScore {
                return a.qualityScore > b.qualityScore
            }
            // 3. 保持原序
            return a.index < b.index
        }
        
        // 4. 还原为 [OVideoChannel] 数组
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
                // 【新增】别名显示逻辑
                if let alias = item.alias, !alias.isEmpty {
                    infoRow(label: isGlobalEnglishMode ? "Alias" : "又名", value: alias)
                }

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
    
    private var playlistSection: some View {
        Group {
            // 【修改】这里使用排序后的 sortedPlaylist 判断是否为空
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
                            // 【修改】这里遍历已排序的 sortedPlaylist
                            ForEach(Array(sortedPlaylist.enumerated()), id: \.offset) { idx, ch in
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
                    
                    // 【修改】这里使用 sortedPlaylist 获取选中的 channel
                    if selectedChannelIndex < sortedPlaylist.count {
                        let channel = sortedPlaylist[selectedChannelIndex]
                        let sortedEps = channel.sortedEpisodes
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)],
                                  spacing: 10) {
                            ForEach(sortedEps, id: \.url) { episode in
                                NavigationLink(destination:
                                    VideoPlayerPageView(
                                        episodeURL: episode.url,
                                        videoTitle: "\(item.name) · \(episode.name)",
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