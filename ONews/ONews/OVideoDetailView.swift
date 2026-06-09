import SwiftUI

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @ObservedObject var dataManager: OVideoDataManager   // 新增：需要传入
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    // 记忆用户的正序/倒序偏好，默认正序 (true)
    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true

    @State private var selectedChannelIndex = 0
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @State private var navigateToPlayer = false
    
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var pendingEpisode: (name: String, url: String)? = nil
    // ⭐ 新增：今日额度已用完的中间提示
    @State private var showQuotaExhaustedAlert = false

    // 新增：搜索跳转状态
    @State private var navigateToSearch = false
    @State private var searchKeyword = ""

    // 批量下载相关状态（保留原有）
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
        .navigationDestination(isPresented: $navigateToSearch) {
            VideoSearchTabView(
                dataManager: dataManager,
                initialKeyword: searchKeyword,
                autoFocus: false   // 从人名点进来，不需要再弹键盘
            )
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
                let channel = sortedPlaylist[selectedChannelIndex]   // 先取出当前线路
                VideoPlayerPageView(
                    episodeURL: episode.url,
                    videoTitle: "\(item.name) · \(episode.name)",
                    coverImage: item.image,
                    channelName: channel.name,
                    episodeName: episode.name,
                    sourceURL: item.url,
                    episodes: channel.episodeItems(ascending: isEpisodeAscending)  // ⭐ 新增这一行
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
        .alert(isGlobalEnglishMode ? "Use a Free Pass" : "使用免费次数",
            isPresented: $showConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndPlay() }
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "This will use 1 of today's free passes (\(consumeRemaining) left). After that, you can play / download / watch this episode unlimited times today."
                : "本次将消耗 1 次今日免费次数（剩余 \(consumeRemaining) 次）。确认后，今天内可无限次在线播放 / 缓存下载 / 离线观看本集。")
        }
        // ⭐ 新增：额度用完的中间提示窗
        .alert(isGlobalEnglishMode ? "Free Passes Used Up" : "今日免费额度已用完",
            isPresented: $showQuotaExhaustedAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") {
                // 用户明确点订阅，才弹出订阅页
                showSubscriptionSheet = true
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "You've used all your free passes for today. Come back tomorrow for more, or subscribe now for unlimited access."
                : "您今天的免费额度已用完，明天将会恢复。是否订阅以继续观看？")
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
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
                    // 导演（支持 "、" 分隔的多人）
                    if let director = item.director, !director.isEmpty {
                        let directors = director.split(separator: "、")
                                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                                .filter { !$0.isEmpty }
                        clickableNamesRow(label: isGlobalEnglishMode ? "Director" : "导演", names: directors)
                    }
                    // 主演（前两位）
                    if !item.starringCast.isEmpty {
                        clickableNamesRow(label: isGlobalEnglishMode ? "Starring" : "主演", names: item.starringCast)
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
                
                // 评分标签显示逻辑（弱化颜色纯度，改用更优雅的低饱和度配色）
                if let ratings = item.ratings {
                    // 过滤掉 value 为空的数据
                    let validRatings = ratings.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    
                    if !validRatings.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(validRatings.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                let color = ratingColor(for: key)
                                HStack(spacing: 4) {
                                    Text(key)
                                        .font(.system(size: 9, weight: .medium))
                                    Text(value)
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(color.opacity(0.85)) // 稍微降低饱和度
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(color.opacity(0.06)) // 减弱背景色
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
                // 线路选择 Tab + 排序按钮 + 批量下载按钮
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(sortedPlaylist.enumerated()), id: \.offset) { idx, ch in
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        selectedChannelIndex = idx
                                    }
                                } label: {
                                    let displayName = isGlobalEnglishMode ? "Line \(idx + 1)" : "线路 \(idx + 1)"
                                    
                                    // ⭐ 弱化线路效果：使用更柔和的灰色/浅蓝色，不再使用高饱和度纯色
                                    Text(displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(selectedChannelIndex == idx ? .accentColor : .secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule()
                                                .fill(selectedChannelIndex == idx
                                                      ? Color.accentColor.opacity(0.12)
                                                      : Color.secondary.opacity(0.05))
                                        )
                                        .overlay(
                                            Capsule()
                                                .stroke(selectedChannelIndex == idx ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
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
                                Image(systemName: isEpisodeAscending ? "arrow.up.circle" : "arrow.down.circle")
                                    .font(.system(size: 13))
                                Text(isEpisodeAscending
                                     ? (isGlobalEnglishMode ? "Asc" : "正序")
                                     : (isGlobalEnglishMode ? "Desc" : "倒序"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.accentColor) // ⭐ 调整为蓝色，增强可点击感知
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.08)) // ⭐ 调整为淡蓝色背景
                            )
                        }
                    }

                    // 批量下载按钮（仅多集视频时显示）
                    if isMultiEpisodeVideo {
                        Button {
                            showBatchDownloadSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 13))
                                Text(isGlobalEnglishMode ? "Batch" : "批量缓存")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.accentColor) // ⭐ 调整为蓝色，增强可点击感知
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.08)) // ⭐ 调整为淡蓝色背景
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

                    // ⭐ 调整最小宽度为 75，让网格排布更紧凑，按钮视觉上自然变小
                    // 找到这一段 LazyVGrid，并替换里面的 Button 视图：
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) { // ⭐ 最小宽度微调至 80，更适合双行
                        ForEach(sortedEps, id: \.url) { episode in
                            Button {
                                selectedEpisode = episode
                                attemptPlay(episode: episode)
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    // ⭐ 重塑后的剧集按钮：支持两行、自动缩放字号
                                    Text(episode.name)
                                        .font(.system(size: 12, weight: .bold)) // ⭐ 基础字号微调至 12
                                        .minimumScaleFactor(0.75)               // ⭐ 核心：字号不够时自动缩小，最高缩小至 9pt
                                        .lineLimit(2)                           // ⭐ 核心：允许折行，最多两行
                                        .multilineTextAlignment(.center)        // ⭐ 居中对齐
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 46)                      // ⭐ 固定高度，保证单行和双行的按钮高度一致，视觉更整齐
                                        .padding(.horizontal, 4)                // 左右留出微小边距防止贴边
                                        .background(
                                            LinearGradient(
                                                colors: [
                                                    Color(.systemIndigo),
                                                    Color(.systemPurple)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .cornerRadius(10)
                                        .shadow(color: Color(.systemPurple).opacity(0.35), radius: 5, x: 0, y: 2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                        )
                                    
                                    if !authManager.isSubscribed {
                                        if quotaManager.isUnlocked(episode.url) {
                                            // ⭐ 已解锁：绿色对勾，表示"今天内免费可用"
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 8))
                                                .foregroundColor(.white)
                                                .padding(3)
                                                .background(Circle().fill(Color.green))
                                                .offset(x: 3, y: -3)
                                        } else if quotaManager.remaining <= 0 {
                                            // ⭐ 未解锁且无剩余次数：橙色锁
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 8))
                                                .foregroundColor(.white)
                                                .padding(3)
                                                .background(Circle().fill(Color.orange))
                                                .offset(x: 3, y: -3)
                                        }
                                        // ⭐ 未解锁但有剩余次数：不显示任何图标，暗示可免费点击
                                    }
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }
        }
    }

    private func attemptPlay(episode: (name: String, url: String)) {
        switch decideVideoAccess(episodeKey: episode.url, auth: authManager, quota: quotaManager) {
        case .allowed:
            navigateToPlayer = true
        case .needConsume(let r):
            pendingEpisode = episode
            consumeRemaining = r
            showConsumeConfirm = true
        case .exhausted:
            // ⭐ 修改：先弹"今日额度用完"提示，而不是直接进订阅页
            showQuotaExhaustedAlert = true
        }
    }

    private func consumeAndPlay() async {
        guard let ep = pendingEpisode else { return }
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let result = await quotaManager.unlock(userId: uid, episodeKey: ep.url,
                                            videoTitle: "\(item.name) · \(ep.name)")
        switch result {
        case .success, .alreadyUnlocked:
            navigateToPlayer = true
        case .quotaExceeded:
            showSubscriptionSheet = true
        case .failed:
            showSubscriptionSheet = true   // 网络异常兜底，也可改成 toast 提示
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
            
            // 其他演员 - 使用新的区块样式
            if !item.otherCast.isEmpty {
                clickableNamesBlock(
                    title: isGlobalEnglishMode ? "Other Cast" : "其他演员", 
                    names: item.otherCast
                )
            }
            
            // 剧情简介
            if let intro = item.intro, !intro.isEmpty {
                sectionBlock(title: isGlobalEnglishMode ? "Synopsis" : "剧情简介", content: intro)
            }
        }
    }

    // MARK: - 可点击人名区块（弱化背景与颜色，使其不喧宾夺主）
    private func clickableNamesBlock(title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
            
            // 使用 FlowLayout 来容纳多个标签，允许换行
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let cleaned = cleanName(name)
                    Button {
                        searchKeyword = cleaned
                        navigateToSearch = true
                    } label: {
                        Text(cleaned)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.accentColor) // ⭐ 调整为蓝色，增强可点击感知
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.08)) // ⭐ 调整为淡蓝色背景
                            )
                    }
                    .buttonStyle(.plain) // 确保按钮样式不影响布局
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.03))
        )
        .padding(.horizontal, 16)
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
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
            
            Text(content)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineSpacing(5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.03))
        )
        .padding(.horizontal, 16)
    }
    
    // MARK: - 评分颜色辅助
    private func ratingColor(for key: String) -> Color {
        let k = key.lowercased()
        if k.contains("豆瓣") { return .green }
        if k.contains("imdb") { return .orange }
        return .secondary // 默认使用次要灰色
    }
    
    // MARK: - 可点击人名行（弱化颜色）
    private func clickableNamesRow(label: String, names: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: isGlobalEnglishMode ? 55 : 50, alignment: .leading)
            
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    // ⭐ 修改：对名字进行中英文清洗，提取出最核心的中文或英文
                    let cleaned = cleanName(name)
                    Button {
                        searchKeyword = cleaned
                        navigateToSearch = true
                    } label: {
                        Text(cleaned)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.accentColor) // ⭐ 调整为蓝色，增强可点击感知
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.08)) // ⭐ 调整为淡蓝色背景
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
    @ObservedObject private var quotaManager = FreeQuotaManager.shared   // ⭐ 新增

    @State private var selectedURLs: Set<String> = []
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var showSubscriptionSheet = false

    @State private var pendingBatch: [(name: String, url: String)] = []
    @State private var batchConsumeCount = 0
    @State private var showBatchConsumeConfirm = false

    // ⭐ 剧集状态枚举
    private enum EpisodeStatus {
        case available    // 可下载
        case downloading  // 已在下载队列（含暂停）
        case cached       // 已缓存完成
    }

    private var episodes: [(name: String, url: String)] {
        channel.sortedEpisodes(ascending: isAscending)
    }

    // ⭐ 核心：根据 cacheMetadata.title 反查「已占用」的标题集合
    // key = 标题（"片名 · 集名"），value = 状态
    private var occupiedStatusByTitle: [String: EpisodeStatus] {
        var map: [String: EpisodeStatus] = [:]
        // 1) 下载队列中（含进行中/暂停）
        for url in downloadManager.downloadProgress.keys {
            if let t = downloadManager.cacheMetadata[url]?.title {
                map[t] = .downloading
            }
        }
        // 2) 已缓存完成（优先级更高，覆盖 downloading）
        for url in downloadManager.localBookmarks.keys {
            if let t = downloadManager.cacheMetadata[url]?.title {
                map[t] = .cached
            }
        }
        return map
    }

    // ⭐ 某一集的预期标题（与单集/批量下载写入的标题格式保持一致）
    private func expectedTitle(for ep: (name: String, url: String)) -> String {
        "\(item.name) · \(ep.name)"
    }

    // ⭐ 查询某一集的状态
    private func status(for ep: (name: String, url: String)) -> EpisodeStatus {
        occupiedStatusByTitle[expectedTitle(for: ep)] ?? .available
    }

    // ⭐ 仅「可下载」的剧集
    private var selectableEpisodes: [(name: String, url: String)] {
        episodes.filter { status(for: $0) == .available }
    }

    // ⭐ 全选判断只针对可下载剧集
    private var allSelected: Bool {
        !selectableEpisodes.isEmpty && selectedURLs.count == selectableEpisodes.count
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
                                // ⭐ 只全选「可下载」的剧集
                                selectedURLs = Set(selectableEpisodes.map { $0.url })
                            }
                        }
                    } label: {
                        Text(allSelected
                             ? (isGlobalEnglishMode ? "Deselect All" : "取消全选")
                             : (isGlobalEnglishMode ? "Select All" : "全选"))
                            .font(.system(size: 14, weight: .medium))
                    }
                    // ⭐ 没有任何可下载剧集时禁用全选
                    .disabled(selectableEpisodes.isEmpty)
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

                // ⭐ 文案区分「可缓存」和「已被占用」
                let occupiedCount = episodes.count - selectableEpisodes.count
                if occupiedCount > 0 {
                    Text(isGlobalEnglishMode
                         ? "\(selectableEpisodes.count) selectable · \(occupiedCount) in cache/queue"
                         : "可缓存 \(selectableEpisodes.count) 集 · \(occupiedCount) 集已在缓存/队列")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text(isGlobalEnglishMode
                         ? "\(episodes.count) episodes available"
                         : "共 \(episodes.count) 集可缓存")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
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
        let st = status(for: ep)
        let isOccupied = (st != .available)
        let isSelected = selectedURLs.contains(ep.url)

        return Button {
            guard !isOccupied else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if isSelected { selectedURLs.remove(ep.url) }
                else { selectedURLs.insert(ep.url) }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {   // ⭐ .top 保证图标与文本顶部对齐
                // 左侧图标
                Group {
                    switch st {
                    case .cached:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .downloading:
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.orange)
                    case .available:
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                    }
                }
                .font(.system(size: 18))

                // ⭐ 垂直布局：标题 + 状态标签
                VStack(alignment: .leading, spacing: 4) {
                    Text(ep.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isOccupied ? .secondary : .primary)
                        .lineLimit(2)                    // ⭐ 核心1：允许两行
                        .minimumScaleFactor(0.8)         // ⭐ 核心2：空间不够时自动缩字
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // ⭐ 核心3：状态标签单独放一行，右对齐
                    if st != .available {
                        HStack {
                            Spacer(minLength: 0)
                            if st == .cached {
                                Text(isGlobalEnglishMode ? "Cached" : "已缓存")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.green)
                            } else if st == .downloading {
                                Text(isGlobalEnglishMode ? "In queue" : "队列中")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
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
            .opacity(isOccupied ? 0.5 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isOccupied)
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
        
        let selected = episodes.filter {
            selectedURLs.contains($0.url) && status(for: $0) == .available
        }
        guard !selected.isEmpty else { return }

        if authManager.isSubscribed {
            performDownloads(selected)
            return
        }

        // 需要新消耗次数的集（未解锁的）
        let newOnes = selected.filter { !FreeQuotaManager.shared.isUnlocked($0.url) }
        if newOnes.isEmpty {
            performDownloads(selected)   // 全部已解锁
            return
        }

        if FreeQuotaManager.shared.remaining < newOnes.count {
            showSubscriptionSheet = true   // 次数不足 → 订阅
            return
        }
        
        pendingBatch = selected
        batchConsumeCount = newOnes.count
        showBatchConsumeConfirm = true     // 弹确认，等用户点击
    }

    // ⭐ 新增：用户确认后调用
    private func confirmBatchDownload() async {
        let selected = pendingBatch
        guard !selected.isEmpty else { return }
        
        // 对未解锁的逐个消耗
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let newOnes = selected.filter { !FreeQuotaManager.shared.isUnlocked($0.url) }
        for ep in newOnes {
            _ = await quotaManager.unlock(userId: uid, episodeKey: ep.url,
                                        videoTitle: "\(item.name) · \(ep.name)")
        }
        
        await MainActor.run {
            showBatchConsumeConfirm = false
            performDownloads(selected)
        }
    }

    // ⭐ 把原来的下载逻辑抽成 performDownloads
    private func performDownloads(_ selected: [(name: String, url: String)]) {
        isProcessing = true
        processedCount = 0

        Task {
            for ep in selected {
                do {
                    let realURL = try await OVideoAPI.resolveRealURL(episodeURL: ep.url)
                    await MainActor.run {
                        downloadManager.startDownload(
                            urlString: realURL,
                            title: "\(item.name) · \(ep.name)",
                            coverImage: item.image,
                            seriesTitle: item.name,
                            episodeName: ep.name,
                            episodeKey: ep.url          // 【新增】
                        )
                        processedCount += 1
                    }
                } catch {
                    await MainActor.run { processedCount += 1 }
                }
            }
            await MainActor.run {
                isProcessing = false
                dismiss()
                onStartDownloads()
            }
        }
    }
}