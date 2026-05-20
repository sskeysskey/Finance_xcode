import SwiftUI

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @State private var selectedChannelIndex = 0
    
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