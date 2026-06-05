import SwiftUI

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    // 记忆用户的正序/倒序偏好，默认正序 (true)
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true

    @State private var selectedChannelIndex = 0

    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @State private var navigateToPlayer = false

    // ⭐ 新增：批量下载相关状态
    @State private var showBatchDownloadSheet = false
    @State private var navigateToCacheView = false

    // 用于记录当前点击并准备播放的剧集
    @State private var selectedEpisode: (name: String, url: String)? = nil

    // 对 playlist 进行过滤和排序的计算属性
    private var sortedPlaylist: [OVideoChannel] {
        // 这里的有效 URL 集合逻辑保持你原有的映射过滤
        let validURLs: Set<String> = {
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
    
    // ⭐ 辅助计算属性：判断当前影片是否是多集类型（Drama, Show, Anime）
    // 如果影片只有 1 集，或者分类属于 Movie，通常不需要显示排序按钮
    private var isMultiEpisodeVideo: Bool {
        if let firstChannel = item.playlist.first {
            return firstChannel.episodes.count > 1
        }
        return false
    }
    
    var body: some View {
        ZStack {
            // 影院级沉浸式背景：使用海报图的超大高斯模糊作为底色
            blurBackgroundSection
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 头部基本信息（海报 + 元数据）
                    headerSection
                    
                    // 播放列表区域（若无链接则展示“正在洽谈”提示）
                    playlistSection
                    
                    // 详情介绍块（演员、简介等）
                    detailsSection
                    
                    Spacer(minLength: 40)
                }
            }
        }
        .navigationTitle(
            (item.info != nil && !item.info!.isEmpty) 
            ? "\(item.name) · \(item.info!)" 
            : item.name
        )
        .navigationBarTitleDisplayMode(.inline)
        // 隐藏的 NavigationLink，响应播放跳转
        .navigationDestination(isPresented: $navigateToPlayer) {
            if let episode = selectedEpisode {
                VideoPlayerPageView(
                    episodeURL: episode.url,
                    videoTitle: "\(item.name) · \(episode.name)",
                    coverImage: item.image,
                    channelName: sortedPlaylist[selectedChannelIndex].name,
                    episodeName: episode.name,
                    sourceURL: item.url
                )
            }
        }
        // ⭐ 新增：批量下载完成后推入缓存管理页（返回即回到详情页）
        .navigationDestination(isPresented: $navigateToCacheView) {
            VideoCacheView()
        }
        // 订阅页弹窗
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
        // ⭐ 新增：批量下载选择页
        .sheet(isPresented: $showBatchDownloadSheet) {
            if selectedChannelIndex < sortedPlaylist.count {
                BatchDownloadView(
                    item: item,
                    channel: sortedPlaylist[selectedChannelIndex],
                    channelDisplayName: isGlobalEnglishMode
                        ? "Line \(selectedChannelIndex + 1)"
                        : "线路 \(selectedChannelIndex + 1)",
                    isAscending: isEpisodeAscending,
                    onStartDownloads: {
                        // 等 sheet 关闭动画结束后再跳转，避免时序冲突
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            navigateToCacheView = true
                        }
                    }
                )
                .environmentObject(authManager)
            }
        }
        .onDisappear {
            ReviewManager.shared.recordVideoInteraction()
        }
    }
    
    // MARK: - 1. 沉浸式模糊背景
    private var blurBackgroundSection: some View {
        GeometryReader { geo in
            Group {
                if let imageName = item.image, !imageName.isEmpty,
                   let url = OVideoAPI.coverURL(for: imageName) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height * 0.5)
                                .clipped()
                                .blur(radius: 40)
                                .opacity(0.25)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
    
    // MARK: - 2. 头部海报与元数据
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 18) {
            // 3D 质感海报
            Group {
                if let imageName = item.image, !imageName.isEmpty,
                   let url = OVideoAPI.coverURL(for: imageName) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                               .scaledToFill()
                        default:
                            ZStack {
                                Color.gray.opacity(0.1)
                                Image(systemName: "film")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                        }
                    }
                } else {
                    ZStack {
                        Color.gray.opacity(0.1)
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
            .frame(width: 125, height: 175)
            .clipped()
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            
            // 影片元数据
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
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
                    if let types = item.types, !types.isEmpty {
                        infoRow(label: isGlobalEnglishMode ? "Genre" : "类型",
                                value: types.joined(separator: "、"))
                    }
                    if let region = item.region, !region.isEmpty {
                        infoRow(label: isGlobalEnglishMode ? "Region" : "地区", value: region)
                    }
                    if let date = item.date, !date.isEmpty {
                        infoRow(label: isGlobalEnglishMode ? "Release" : "上映", value: date)
                    }
                }
                
                // 【优化】评分标签显示逻辑
                if let ratings = item.ratings {
                    // 过滤掉 value 为空的数据
                    let validRatings = ratings.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    
                    if !validRatings.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(validRatings.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                let color = ratingColor(for: key)
                                HStack(spacing: 4) {
                                    Text(key)
                                        .font(.system(size: 10, weight: .medium))
                                    Text(value)
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(color.opacity(0.12))
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
    
    // MARK: - 3. 播放列表与“洽谈中”无链接提醒
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .background(Color.secondary.opacity(0.1))
                .padding(.horizontal, 16)
            
            Text(isGlobalEnglishMode ? "Episodes" : "播放列表")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 16)
            
            if sortedPlaylist.isEmpty {
                // 🌟 【核心新增】高端大气的“无链接洽谈中”提示卡片
                VStack(spacing: 12) {
                    Image(systemName: "hourglass.badge.plus")
                        .font(.system(size: 36))
                        .foregroundColor(.orange.opacity(0.8))
                        .padding(.top, 8)
                    
                    Text(isGlobalEnglishMode ? "Video is being negotiated, please wait patiently..." : "视频正在洽谈接入中，请耐心等候...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.orange.opacity(0.15), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                
            } else {
                // 线路选择 Tab + 排序按钮 + ⭐批量下载按钮
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(sortedPlaylist.enumerated()), id: \.offset) { idx, ch in
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        selectedChannelIndex = idx
                                    }
                                } label: {
                                    let displayName = isGlobalEnglishMode ? "Line \(idx + 1)" : "线路 \(idx + 1)"
                                    Text(displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(selectedChannelIndex == idx ? .white : .primary)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(
                                            Capsule()
                                                .fill(selectedChannelIndex == idx
                                                      ? Color.accentColor
                                                      : Color.secondary.opacity(0.12))
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // 正序/倒序切换按钮（仅多集视频时显示）
                    if isMultiEpisodeVideo {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEpisodeAscending.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isEpisodeAscending ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 16))
                                Text(isEpisodeAscending
                                     ? (isGlobalEnglishMode ? "Asc" : "正序")
                                     : (isGlobalEnglishMode ? "Desc" : "倒序"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                        }
                    }

                    // ⭐【新增】批量下载按钮（仅多集视频时显示）
                    if isMultiEpisodeVideo {
                        Button {
                            showBatchDownloadSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down.on.square.fill")
                                    .font(.system(size: 14))
                                Text(isGlobalEnglishMode ? "Batch" : "批量下载")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                    startPoint: .leading, endPoint: .trailing))
                            )
                        }
                        .padding(.trailing, 16)
                    }
                }

                // 剧集网格
                if selectedChannelIndex < sortedPlaylist.count {
                    let channel = sortedPlaylist[selectedChannelIndex]
                    // ⭐【修改】根据用户的排序偏好获取排序后的剧集
                    let sortedEps = channel.sortedEpisodes(ascending: isEpisodeAscending)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                        ForEach(sortedEps, id: \.url) { episode in
                            Button {
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
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.secondary.opacity(0.08))
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                                        )
                                    
                                    if !authManager.isSubscribed {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white)
                                            .padding(4)
                                            .background(Circle().fill(Color.orange))
                                            .offset(x: 4, y: -4)
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
    
    // MARK: - 4. 详情介绍块（演员与简介）
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !item.otherCast.isEmpty || (item.intro != nil && !item.intro!.isEmpty) {
                Divider()
                    .background(Color.secondary.opacity(0.1))
                    .padding(.horizontal, 16)
            }
            
            // 其他演员
            if !item.otherCast.isEmpty {
                sectionBlock(title: isGlobalEnglishMode ? "Other Cast" : "其他演员",
                             content: item.otherCast.joined(separator: " / "))
            }
            
            // 剧情简介
            if let intro = item.intro, !intro.isEmpty {
                sectionBlock(title: isGlobalEnglishMode ? "Synopsis" : "剧情简介", content: intro)
            }
        }
    }

    // MARK: - 5. 辅助视图组件
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: isGlobalEnglishMode ? 55 : 50, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func sectionBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.primary)
            
            Text(content)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineSpacing(5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.04))
        )
        .padding(.horizontal, 16)
    }
    
    // MARK: - 评分颜色辅助
    private func ratingColor(for key: String) -> Color {
        let k = key.lowercased()
        if k.contains("豆瓣") { return .green }
        if k.contains("imdb") { return .orange }
        return .accentColor // 默认颜色
    }
}

struct BatchDownloadView: View {
    let item: OVideoItem
    let channel: OVideoChannel
    let channelDisplayName: String
    let isAscending: Bool
    /// 下载成功发起后回调（用于父级跳转到缓存管理页）
    let onStartDownloads: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @ObservedObject private var downloadManager = HLSDownloadManager.shared

    @State private var selectedURLs: Set<String> = []
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var showSubscriptionSheet = false

    private var episodes: [(name: String, url: String)] {
        channel.sortedEpisodes(ascending: isAscending)
    }

    private var allSelected: Bool {
        !episodes.isEmpty && selectedURLs.count == episodes.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground),
                             Color.accentColor.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        episodeGrid
                        Spacer(minLength: 120) // 给底部悬浮栏留空间
                    }
                    .padding(.top, 12)
                }

                // 底部悬浮下载栏
                VStack {
                    Spacer()
                    bottomBar
                }

                if isProcessing {
                    processingOverlay
                }
            }
            .navigationTitle(isGlobalEnglishMode ? "Batch Download" : "批量下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isGlobalEnglishMode ? "Cancel" : "取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if allSelected {
                                selectedURLs.removeAll()
                            } else {
                                selectedURLs = Set(episodes.map { $0.url })
                            }
                        }
                    } label: {
                        Text(allSelected
                             ? (isGlobalEnglishMode ? "Deselect All" : "取消全选")
                             : (isGlobalEnglishMode ? "Select All" : "全选"))
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
            .sheet(isPresented: $showSubscriptionSheet) {
                SubscriptionView()
            }
        }
    }

    // MARK: - 头部信息卡
    private var headerCard: some View {
        HStack(spacing: 14) {
            coverThumb
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(channelDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                Text(isGlobalEnglishMode
                     ? "\(episodes.count) episodes available"
                     : "共 \(episodes.count) 集可缓存")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var coverThumb: some View {
        Group {
            if let name = item.image, !name.isEmpty,
               let url = OVideoAPI.coverURL(for: name) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                }
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Image(systemName: "film").foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 56, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 剧集网格
    private var episodeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            ForEach(episodes, id: \.url) { ep in
                episodeCell(ep)
            }
        }
        .padding(.horizontal, 16)
    }

    private func episodeCell(_ ep: (name: String, url: String)) -> some View {
        let isSelected = selectedURLs.contains(ep.url)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isSelected { selectedURLs.remove(ep.url) }
                else { selectedURLs.insert(ep.url) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                Text(ep.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10)
                                     : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5)
                                       : Color.secondary.opacity(0.12),
                            lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 底部下载栏
    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isGlobalEnglishMode ? "Selected" : "已选择")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("\(selectedURLs.count)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
            }
            Spacer()
            Button {
                startBatchDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(isGlobalEnglishMode ? "Download Selected" : "下载所选")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: selectedURLs.isEmpty
                            ? [Color.secondary.opacity(0.4), Color.secondary.opacity(0.4)]
                            : [Color.accentColor, Color.accentColor.opacity(0.8)],
                        startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: Color.accentColor.opacity(selectedURLs.isEmpty ? 0 : 0.3),
                        radius: 8, y: 3)
            }
            .disabled(selectedURLs.isEmpty || isProcessing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 处理中遮罩
    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(isGlobalEnglishMode
                     ? "Preparing downloads... \(processedCount)/\(selectedURLs.count)"
                     : "正在准备下载… \(processedCount)/\(selectedURLs.count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
        }
    }

    // MARK: - 下载逻辑
    private func startBatchDownload() {
        guard authManager.canAccessVideoContent() else {
            showSubscriptionSheet = true
            return
        }
        let selected = episodes.filter { selectedURLs.contains($0.url) }
        guard !selected.isEmpty else { return }

        isProcessing = true
        processedCount = 0

        Task {
            for ep in selected {
                do {
                    // 与单集播放一致：先解析出真实可下载地址
                    let realURL = try await OVideoAPI.resolveRealURL(episodeURL: ep.url)
                    await MainActor.run {
                        downloadManager.startDownload(
                            urlString: realURL,
                            title: "\(item.name) · \(ep.name)",
                            coverImage: item.image
                        )
                        processedCount += 1
                    }
                } catch {
                    // 单集解析失败不阻断其它集
                    await MainActor.run { processedCount += 1 }
                }
            }
            await MainActor.run {
                isProcessing = false
                dismiss()            // 先关闭批量选择页
                onStartDownloads()   // 通知父级跳转到缓存管理页
            }
        }
    }
}