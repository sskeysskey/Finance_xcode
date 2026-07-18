import SwiftUI

// MARK: - ⭐ 季度解析辅助（全局）
// 中文数字转阿拉伯数字（够用到 99）
func chineseNumeralToInt(_ raw: String) -> Int? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if let n = Int(s) { return n }
    let map: [Character: Int] = ["零":0,"一":1,"二":2,"三":3,"四":4,"五":5,
                                 "六":6,"七":7,"八":8,"九":9,"十":10]
    let chars = Array(s)
    guard !chars.isEmpty else { return nil }
    if s == "十" { return 10 }
    if let idx = chars.firstIndex(of: "十") {
        let before = chars[..<idx]
        let after  = chars[(idx+1)...]
        let tens = before.isEmpty ? 1 : (map[before.first!] ?? 0)
        let ones = after.isEmpty ? 0 : (map[after.first!] ?? 0)
        return tens * 10 + ones
    }
    var val = 0
    for ch in chars {
        guard let d = map[ch] else { return nil }
        val = val * 10 + d
    }
    return val
}

// 罗马数字转整数（I V X L 组合）
func romanNumeralToInt(_ raw: String) -> Int? {
    let map: [Character: Int] = ["I":1,"V":5,"X":10,"L":50,"C":100,"D":500,"M":1000]
    let chars = Array(raw.uppercased())
    guard !chars.isEmpty else { return nil }
    var total = 0, prev = 0
    for ch in chars.reversed() {
        guard let v = map[ch] else { return nil }
        if v < prev { total -= v } else { total += v; prev = v }
    }
    return total > 0 ? total : nil
}

// 从片名解析 (基础名, 季/部号)。支持：
//   第X季 / 洛奇2 / 洛奇4：最后的决战 / 冲上云霄II / 绝望一
//   无任何标记 → 视为第 1 部（base 为整名），以便与后续续集归为同系列
func videoSeasonInfo(from name: String) -> (base: String, season: Int)? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if let r = seasonByExplicitMarker(trimmed) { return r }   // 1. 第X季
    if let r = seasonByRomanSuffix(trimmed)    { return r }   // 2. 冲上云霄II
    if let r = seasonByArabicSuffix(trimmed)   { return r }   // 3. 洛奇2 / 洛奇4：xxx
    if let r = seasonByChineseSuffix(trimmed)  { return r }   // 4. 绝望一
    return (trimmed, 1)                                       // 5. 无标记 → 第1部
}

// 1. 第X季
private func seasonByExplicitMarker(_ name: String) -> (base: String, season: Int)? {
    let pattern = "第\\s*([0-9零一二三四五六七八九十百]+)\\s*季"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(name.startIndex..., in: name)
    guard let match = regex.firstMatch(in: name, range: full),
          let numRange = Range(match.range(at: 1), in: name),
          let matchRange = Range(match.range, in: name),
          let season = chineseNumeralToInt(String(name[numRange])) else { return nil }
    var base = name
    base.removeSubrange(matchRange)
    base = base.trimmingCharacters(in: .whitespaces)
    return (base, season)
}

// 2. 结尾罗马数字：冲上云霄II
private func seasonByRomanSuffix(_ name: String) -> (base: String, season: Int)? {
    let pattern = "^(.*?)\\s*([IVXL]{1,7})$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(name.startIndex..., in: name)
    guard let match = regex.firstMatch(in: name, range: full),
          let baseRange = Range(match.range(at: 1), in: name),
          let romanRange = Range(match.range(at: 2), in: name) else { return nil }
    let base = String(name[baseRange]).trimmingCharacters(in: .whitespaces)
    guard !base.isEmpty else { return nil }
    // base 结尾若是 ASCII 字母，多半是英文单词末尾（如 MIX），放弃
    if let last = base.last, last.isLetter, last.isASCII { return nil }
    guard let season = romanNumeralToInt(String(name[romanRange])),
          season >= 1, season <= 39 else { return nil }
    return (base, season)
}

// 3. 结尾阿拉伯数字（可带副标题）：洛奇2 / 洛奇4：最后的决战
private func seasonByArabicSuffix(_ name: String) -> (base: String, season: Int)? {
    let pattern = "^(\\D+?)([0-9]{1,3})(?:[：:\\s\\-—·].*)?$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(name.startIndex..., in: name)
    guard let match = regex.firstMatch(in: name, range: full),
          let baseRange = Range(match.range(at: 1), in: name),
          let numRange = Range(match.range(at: 2), in: name) else { return nil }
    let base = String(name[baseRange]).trimmingCharacters(in: .whitespaces)
    guard !base.isEmpty, let season = Int(String(name[numRange])),
          season >= 1, season <= 99 else { return nil }
    return (base, season)
}

// 4. 结尾中文数字：绝望一 / 绝望二
private func seasonByChineseSuffix(_ name: String) -> (base: String, season: Int)? {
    let numerals = "零一二三四五六七八九十"
    let pattern = "^(.*?[^\(numerals)])([\(numerals)]{1,3})$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(name.startIndex..., in: name)
    guard let match = regex.firstMatch(in: name, range: full),
          let baseRange = Range(match.range(at: 1), in: name),
          let numRange = Range(match.range(at: 2), in: name) else { return nil }
    let base = String(name[baseRange]).trimmingCharacters(in: .whitespaces)
    guard !base.isEmpty, let season = chineseNumeralToInt(String(name[numRange])),
          season >= 1, season <= 99 else { return nil }
    return (base, season)
}

// MARK: - 视频详情页
struct VideoDetailView: View {
    let item: OVideoItem
    @ObservedObject var dataManager: OVideoDataManager
    var playSource: String = "unknown"
    @ObservedObject private var downloadManager = HLSDownloadManager.shared
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @AppStorage("OVideo_IsEpisodeAscending") private var isEpisodeAscending = true
    @AppStorage("hasSeenPlaylistLineHint") private var hasSeenPlaylistLineHint = false
    @State private var showLineHint = false

    @State private var selectedChannelIndex = 0
    @EnvironmentObject var authManager: AuthManager
    @State private var showSubscriptionSheet = false
    @State private var navigateToPlayer = false
    @State private var showLoginAlert = false
    
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @State private var showConsumeConfirm = false
    @State private var consumeRemaining = 0
    @State private var pendingEpisode: (name: String, url: String)? = nil
    @State private var showQuotaExhaustedAlert = false

    // ⭐ 新人礼包欢迎提示
    @State private var showBonusWelcome = false
    @State private var bonusWelcomeAmount = 0

    // 搜索跳转
    @State private var navigateToSearch = false
    @State private var searchKeyword = ""

    // 批量下载
    @State private var showBatchDownloadSheet = false
    @State private var navigateToCacheView = false

    @State private var selectedEpisode: (name: String, url: String)? = nil
    @State private var loadedChannels: [OVideoChannel] = []
    @State private var isLoadingPlaylist = true

    // ⭐ 同系列其它季
    @State private var seasonSiblings: [OVideoItem] = []
    @State private var selectedSeasonItem: OVideoItem? = nil
    @State private var navigateToSeason = false

    // 计算某线路"去重后的实际集数"：把 粤语01/国语01 之类同集号的语种变体算作 1 集
    private func distinctEpisodeCount(_ channel: OVideoChannel) -> Int {
        var seen = Set<String>()
        for key in channel.episodes.keys {
            let digits = key.filter { $0.isNumber }
            if digits.isEmpty {
                seen.insert(key)                 // 无数字(正片/HD等)按原名去重
            } else if let n = Int(digits) {
                seen.insert("n\(n)")             // "01"/"1" 归一为同一集
            } else {
                seen.insert(digits)
            }
        }
        return seen.count
    }

    private var sortedPlaylist: [OVideoChannel] {
        let indexedChannels = loadedChannels.enumerated().map {
            (index, channel) -> (index: Int, channel: OVideoChannel,
                                distinctCount: Int, totalCount: Int, qualityScore: Int) in
            let distinctCount = distinctEpisodeCount(channel)   // 实际集数（去重语种）
            let totalCount = channel.episodes.count             // 总链接数（作次级依据）

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
            if hasLowQuality { qualityScore = 0 }
            else if hasHighQuality { qualityScore = 2 }

            return (index, channel, distinctCount, totalCount, qualityScore)
        }

        let sortedIndexed = indexedChannels.sorted { a, b in
            if a.distinctCount != b.distinctCount { return a.distinctCount > b.distinctCount } // 1. 实际集数
            if a.totalCount   != b.totalCount     { return a.totalCount   > b.totalCount }     // 2. 总链接数
            if a.qualityScore != b.qualityScore   { return a.qualityScore > b.qualityScore }   // 3. 画质
            return a.index < b.index                                                           // 4. 原始顺序
        }
        return sortedIndexed.map { $0.channel }
    }
    
    private var isMultiEpisodeVideo: Bool {
        if let firstChannel = loadedChannels.first {
            return firstChannel.episodes.count > 1
        }
        return false
    }

    private var cachedOriginalURLs: Set<String> {
        var s = Set<String>()
        for (key, meta) in downloadManager.cacheMetadata where downloadManager.localBookmarks[key] != nil {
            s.insert(key)
            if let orig = meta.originalEpisodeURL, !orig.isEmpty { s.insert(orig) }
        }
        return s
    }
    
    var body: some View {
        ZStack {
            blurBackgroundSection
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    seasonSection            // ⭐ 新增：同系列各季切换
                    playlistSection
                    detailsSection
                    Spacer(minLength: 40)
                }
            }
        }
        .navigationDestination(isPresented: $navigateToSearch) {
            VideoSearchTabView(
                dataManager: dataManager,
                initialKeyword: searchKeyword,
                autoFocus: false
            )
        }
        // ⭐ 切换到其它季的详情页
        .navigationDestination(isPresented: $navigateToSeason) {
            if let s = selectedSeasonItem {
                VideoDetailView(item: s, dataManager: dataManager, playSource: playSource)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navTitleView
            }
        }
        .navigationDestination(isPresented: $navigateToPlayer) {
            if let episode = selectedEpisode {
                let channel = sortedPlaylist[selectedChannelIndex]
                VideoPlayerPageView(
                    episodeURL: episode.url,
                    videoTitle: "\(item.name) · \(episode.name)",
                    coverImage: item.image,
                    channelName: channel.name,
                    episodeName: episode.name,
                    sourceURL: item.url,
                    episodes: channel.episodeItems(ascending: isEpisodeAscending),
                    playSource: playSource
                )
            }
        }
        .navigationDestination(isPresented: $navigateToCacheView) {
            VideoCacheView()
        }
        .sheet(isPresented: $showSubscriptionSheet) {
            SubscriptionView()
        }
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
        // ⭐ 消耗确认：文案更清晰（区分赠送/每日 + 剩余构成）
        .alert(isGlobalEnglishMode ? "Use 1 Free Pass" : "使用免费点数",
            isPresented: $showConsumeConfirm) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                Task { await consumeAndPlay() }
            }
        } message: {
            Text(quotaManager.consumeSourceNote(english: isGlobalEnglishMode)
                 + "\n"
                 + quotaManager.remainingSummary(english: isGlobalEnglishMode))
        }
        .alert(isGlobalEnglishMode
            ? "Free Passes Used Up"
            : "今日免费额度不足",
            isPresented: $showQuotaExhaustedAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Subscribe" : "订阅") {
                showSubscriptionSheet = true
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "You've used all your passes for now. Come back tomorrow for more free daily passes, or subscribe for unlimited access."
                : "您的免费点数已用完，明天可再领取每日免费点数，订阅后即可无限畅享所有视频。")
        }
        // ⭐ 新人礼包欢迎弹窗
        .alert(isGlobalEnglishMode ? "Welcome Gift 🎉" : "新人礼包 🎉",
            isPresented: $showBonusWelcome) {
            Button(isGlobalEnglishMode ? "Awesome" : "好的") {
                quotaManager.clearBonusWelcome()
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "As a new member you've received \(bonusWelcomeAmount) welcome passes, plus \(quotaManager.dailyQuota) free passes every day. Welcome passes are used first!"
                : "欢迎光临！已一次性赠送你 \(bonusWelcomeAmount) 个免费点数，另外每天还可免费领取 \(quotaManager.dailyQuota) 点。")
        }
        .alert(isGlobalEnglishMode ? "Sign in to Watch Free" : "登录后免费观看",
            isPresented: $showLoginAlert) {
            Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
            Button(isGlobalEnglishMode ? "Sign in with Apple" : "登录") {
                authManager.signInWithApple()
            }
        } message: {
            Text(isGlobalEnglishMode
                ? "Sign in (free, no purchase needed) to get a welcome gift plus free daily passes."
                : "登录后即可领取新人礼包和每日免费观看点数，登录无需付费。")
        }
        .onChange(of: authManager.isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager)) }
            }
        }
        // ⭐ 监听礼包发放（会员不弹礼包，直接清除）
        .onChange(of: quotaManager.pendingBonusWelcome) { v in
            guard v > 0 else { return }
            if authManager.isSubscribed {
                quotaManager.clearBonusWelcome()          // 会员随便看，无需礼包
            } else {
                bonusWelcomeAmount = v
                showBonusWelcome = true
            }
        }
        .task {
            await quotaManager.refresh(userId: FreeQuotaManager.currentUserId(auth: authManager))
            if quotaManager.pendingBonusWelcome > 0 {
                if authManager.isSubscribed {
                    quotaManager.clearBonusWelcome()      // ⭐ 会员不弹礼包
                } else {
                    bonusWelcomeAmount = quotaManager.pendingBonusWelcome
                    showBonusWelcome = true
                }
            }
            if loadedChannels.isEmpty {
                let channels = await dataManager.fetchPlaylist(url: item.url)
                await MainActor.run {
                    loadedChannels = channels
                    isLoadingPlaylist = false
                }
            }
            if !hasSeenPlaylistLineHint {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showLineHint = true
                    }
                }
            }
            await loadSeasonSiblingsIfNeeded()
        }
    }

    // MARK: - ⭐ 加载同系列其它季
    private func loadSeasonSiblingsIfNeeded() async {
        guard seasonSiblings.isEmpty,
              let info = videoSeasonInfo(from: item.name),
              !info.base.isEmpty else { return }

        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let results = await dataManager.search(keyword: info.base, userId: uid)

        // 只保留同一基础名且能解析出季号的条目
        let sameSeries = results.filter { cand in
            guard let ci = videoSeasonInfo(from: cand.name) else { return false }
            return ci.base == info.base
        }
        // 去重 + 保证当前季在列表内
        var seen = Set<String>()
        var unique = sameSeries.filter { seen.insert($0.url).inserted }
        if !unique.contains(where: { $0.url == item.url }) {
            unique.append(item)
        }
        let sorted = unique.sorted {
            (videoSeasonInfo(from: $0.name)?.season ?? 0) < (videoSeasonInfo(from: $1.name)?.season ?? 0)
        }
        await MainActor.run {
            seasonSiblings = sorted.count > 1 ? sorted : []
        }
    }

    // MARK: - ⭐ 各季切换区块（改为换行显示，避免横向滑动拦截边缘返回手势）
    @ViewBuilder
    private var seasonSection: some View {
        if seasonSiblings.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    Text(isGlobalEnglishMode ? "All Seasons" : "选择季")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                    Text("\(seasonSiblings.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal, 16)

                // ⭐ 用 FlowLayout 换行：季数少时一行，多时自动换行
                FlowLayout(spacing: 12) {
                    ForEach(seasonSiblings, id: \.url) { s in
                        let isCurrent = (s.url == item.url)
                        Button {
                            if !isCurrent {
                                selectedSeasonItem = s
                                navigateToSeason = true
                            }
                        } label: {
                            seasonChip(for: s, isCurrent: isCurrent)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func seasonLabel(for s: OVideoItem) -> String {
        if let info = videoSeasonInfo(from: s.name) {
            return isGlobalEnglishMode ? "S\(info.season)" : "第\(info.season)季"
        }
        return s.name
    }

    private func seasonChip(for s: OVideoItem, isCurrent: Bool) -> some View {
        VStack(spacing: 6) {
            Group {
                if let name = s.image, !name.isEmpty, let url = OVideoAPI.coverURL(for: name) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color.gray.opacity(0.12)
                                Image(systemName: "film").foregroundColor(.secondary.opacity(0.5))
                            }
                        }
                    }
                } else {
                    ZStack {
                        Color.gray.opacity(0.12)
                        Image(systemName: "film").foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
            .frame(width: 72, height: 100)
            .clipped()
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCurrent ? Color.accentColor : Color.white.opacity(0.15),
                            lineWidth: isCurrent ? 2 : 1)
            )
            .overlay(alignment: .bottomLeading) {
                if isCurrent {
                    Text(isGlobalEnglishMode ? "Now" : "当前")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(4)
                }
            }

            Text(seasonLabel(for: s))
                .font(.system(size: 11, weight: isCurrent ? .bold : .medium))
                .foregroundColor(isCurrent ? .accentColor : .secondary)
                .lineLimit(1)
        }
        .frame(width: 72)
    }

    // MARK: - 导航栏标题
    private var navTitleView: some View {
        let hasInfo = (item.info != nil && !item.info!.isEmpty)
        let combined = hasInfo ? "\(item.name) · \(item.info!)" : item.name
        let isLong = combined.count > 14

        return Group {
            if hasInfo && isLong {
                VStack(spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(item.info!)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: 240)
            } else {
                Text(combined)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
            }
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
            Group {
                if let imageName = item.image, !imageName.isEmpty,
                   let url = OVideoAPI.coverURL(for: imageName) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
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
            
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    if let alias = item.alias, !alias.isEmpty {
                        infoRow(label: isGlobalEnglishMode ? "Alias" : "又名", value: alias)
                    }
                    if let director = item.director, !director.isEmpty {
                        let directors = director.split(separator: "、")
                                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                                .filter { !$0.isEmpty }
                        clickableNamesRow(label: isGlobalEnglishMode ? "Director" : "导演", names: directors)
                    }
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
                
                if let ratings = item.ratings {
                    let validRatings = ratings.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    if !validRatings.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(validRatings.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                let color = ratingColor(for: key)
                                HStack(spacing: 4) {
                                    Text(key).font(.system(size: 9, weight: .medium))
                                    Text(value).font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(color.opacity(0.85))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.06))
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
    
    // MARK: - 3. 播放列表
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .background(Color.secondary.opacity(0.1))
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Text(isGlobalEnglishMode ? "Episodes" : "播放列表")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primary)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showLineHint.toggle()
                    }
                    hasSeenPlaylistLineHint = true
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.orange)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)

                Spacer()

                if !isLoadingPlaylist && !sortedPlaylist.isEmpty {
                    if isMultiEpisodeVideo {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEpisodeAscending.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isEpisodeAscending ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 13))
                                Text(isEpisodeAscending
                                    ? (isGlobalEnglishMode ? "Asc" : "正序")
                                    : (isGlobalEnglishMode ? "Desc" : "倒序"))
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(
                                    LinearGradient(colors: [Color.blue, Color.cyan],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            )
                            .shadow(color: Color.blue.opacity(0.35), radius: 4, x: 0, y: 2)
                        }
                    }

                    Button {
                        showBatchDownloadSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 13))
                            Text(isMultiEpisodeVideo
                                 ? (isGlobalEnglishMode ? "Batch" : "批量下载")
                                 : (isGlobalEnglishMode ? "Cache" : "下载"))
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                LinearGradient(colors: [Color.orange, Color.pink],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        )
                        .shadow(color: Color.orange.opacity(0.35), radius: 4, x: 0, y: 2)
                    }
                }
            }
            .padding(.horizontal, 16)

            if showLineHint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(isGlobalEnglishMode
                         ? "Try switching lines to find the fastest video source."
                         : "尝试切换线路来匹配速度最快的视频源")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        withAnimation { showLineHint = false }
                        hasSeenPlaylistLineHint = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isLoadingPlaylist {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if sortedPlaylist.isEmpty {
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
                    RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.15), lineWidth: 1)
                )
                .padding(.horizontal, 16)

            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(sortedPlaylist.enumerated()), id: \.offset) { idx, ch in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedChannelIndex = idx
                            }
                        } label: {
                            let displayName = isGlobalEnglishMode ? "Line \(idx + 1)" : "线路 \(idx + 1)"
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                if selectedChannelIndex < sortedPlaylist.count {
                    let channel = sortedPlaylist[selectedChannelIndex]
                    let sortedEps = channel.sortedEpisodes(ascending: isEpisodeAscending)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                        ForEach(sortedEps, id: \.url) { episode in
                            Button {
                                selectedEpisode = episode
                                attemptPlay(episode: episode)
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Text(episode.name)
                                        .font(.system(size: 12, weight: .bold))
                                        .minimumScaleFactor(0.75)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 46)
                                        .padding(.horizontal, 4)
                                        .background(
                                            LinearGradient(
                                                colors: [Color(.systemIndigo), Color(.systemPurple)],
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

                                    if cachedOriginalURLs.contains(episode.url) {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 8))
                                            .foregroundColor(.white)
                                            .padding(3)
                                            .background(Circle().fill(Color.blue))
                                            .offset(x: 3, y: -3)
                                    } else if !authManager.isSubscribed {
                                        if quotaManager.isUnlocked(episode.url) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 8))
                                                .foregroundColor(.white)
                                                .padding(3)
                                                .background(Circle().fill(Color.green))
                                                .offset(x: 3, y: -3)
                                        } else if quotaManager.remaining <= 0 {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 8))
                                                .foregroundColor(.white)
                                                .padding(3)
                                                .background(Circle().fill(Color.orange))
                                                .offset(x: 3, y: -3)
                                        }
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
        case .needLogin:
            showLoginAlert = true
        case .needConsume(let r):
            pendingEpisode = episode
            consumeRemaining = r
            showConsumeConfirm = true
        case .exhausted:
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
            showSubscriptionSheet = true
        }
    }
    
    // MARK: - 4. 详情介绍块
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !item.otherCast.isEmpty || (item.intro != nil && !item.intro!.isEmpty) {
                Divider()
                    .background(Color.secondary.opacity(0.1))
                    .padding(.horizontal, 16)
            }
            
            if !item.otherCast.isEmpty {
                clickableNamesBlock(
                    title: isGlobalEnglishMode ? "Other Cast" : "其他演员", 
                    names: item.otherCast
                )
            }
            
            if let intro = item.intro, !intro.isEmpty {
                sectionBlock(title: isGlobalEnglishMode ? "Synopsis" : "剧情简介", content: intro)
            }
        }
    }

    private func clickableNamesBlock(title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
            
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let cleaned = cleanName(name)
                    Button {
                        searchKeyword = cleaned
                        navigateToSearch = true
                    } label: {
                        Text(cleaned)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.03))
        )
        .padding(.horizontal, 16)
    }

    // MARK: - 5. 辅助视图
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
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.03))
        )
        .padding(.horizontal, 16)
    }
    
    private func ratingColor(for key: String) -> Color {
        let k = key.lowercased()
        if k.contains("豆瓣") { return .green }
        if k.contains("imdb") { return .orange }
        return .secondary
    }
    
    private func clickableNamesRow(label: String, names: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: isGlobalEnglishMode ? 55 : 50, alignment: .leading)
            
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    let cleaned = cleanName(name)
                    Button {
                        searchKeyword = cleaned
                        navigateToSearch = true
                    } label: {
                        Text(cleaned)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.08))
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
    let onStartDownloads: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @ObservedObject private var downloadManager = HLSDownloadManager.shared
    @ObservedObject private var quotaManager = FreeQuotaManager.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var showCellularAlert = false
    @State private var pendingCellularBatch: [(name: String, url: String)] = []

    @State private var selectedURLs: Set<String> = []
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var showSubscriptionSheet = false
    @State private var showQuotaExhaustedAlert = false

    @State private var pendingBatch: [(name: String, url: String)] = []
    @State private var batchConsumeCount = 0
    @State private var showBatchConsumeConfirm = false

    private enum EpisodeStatus {
        case available
        case downloading
        case cached
    }

    private var episodes: [(name: String, url: String)] {
        channel.sortedEpisodes(ascending: isAscending)
    }

    private var occupiedStatusByTitle: [String: EpisodeStatus] {
        var map: [String: EpisodeStatus] = [:]
        for url in downloadManager.downloadProgress.keys {
            if let t = downloadManager.cacheMetadata[url]?.title {
                map[t] = .downloading
            }
        }
        for url in downloadManager.localBookmarks.keys {
            if let t = downloadManager.cacheMetadata[url]?.title {
                map[t] = .cached
            }
        }
        return map
    }

    private func expectedTitle(for ep: (name: String, url: String)) -> String {
        "\(item.name) · \(ep.name)"
    }

    private func status(for ep: (name: String, url: String)) -> EpisodeStatus {
        occupiedStatusByTitle[expectedTitle(for: ep)] ?? .available
    }

    private var selectableEpisodes: [(name: String, url: String)] {
        episodes.filter { status(for: $0) == .available }
    }

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
                        Spacer(minLength: 120)
                    }
                    .padding(.top, 12)
                }

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
                                selectedURLs = Set(selectableEpisodes.map { $0.url })
                            }
                        }
                    } label: {
                        Text(allSelected
                             ? (isGlobalEnglishMode ? "Deselect All" : "取消全选")
                             : (isGlobalEnglishMode ? "Select All" : "全选"))
                            .font(.system(size: 14, weight: .medium))
                    }
                    .disabled(selectableEpisodes.isEmpty)
                }
            }
            .sheet(isPresented: $showSubscriptionSheet) {
                SubscriptionView()
            }
            // ⭐ 批量消耗确认（文案更清晰）
            .alert(isGlobalEnglishMode ? "Use Free Passes" : "使用免费点数",
                isPresented: $showBatchConsumeConfirm) {
                Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
                Button(isGlobalEnglishMode ? "Confirm" : "确认使用") {
                    Task { await confirmBatchDownload() }
                }
            } message: {
                Text((isGlobalEnglishMode
                    ? "This will use \(batchConsumeCount) passes (welcome passes used first).\n"
                    : "本次操作将消耗 \(batchConsumeCount) 点\n")
                    + quotaManager.remainingSummary(english: isGlobalEnglishMode))
            }
            // ⭐ 额度不足提示
            .alert(isGlobalEnglishMode ? "Not Enough Passes" : "免费点数不足",
                isPresented: $showQuotaExhaustedAlert) {
                Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {}
                Button(isGlobalEnglishMode ? "Subscribe" : "订阅") {
                    showSubscriptionSheet = true
                }
            } message: {
                Text((isGlobalEnglishMode
                    ? "You need \(batchConsumeCount) passes. \(quotaManager.remainingSummary(english: true)). Subscribe for unlimited access."
                    : "本次操作需消耗 \(batchConsumeCount) 点，当前\(quotaManager.remainingSummary(english: false))。订阅后即可无限畅享所有视频。"))
            }
            .alert(isGlobalEnglishMode ? "Cellular Network Warning" : "蜂窝网络提示",
                isPresented: $showCellularAlert) {
                Button(isGlobalEnglishMode ? "Cancel" : "取消", role: .cancel) {
                    pendingCellularBatch = []
                }
                Button(isGlobalEnglishMode ? "Download Anyway" : "允许并下载") {
                    performDownloads(pendingCellularBatch)
                    pendingCellularBatch = []
                }
            } message: {
                Text(isGlobalEnglishMode
                    ? "You are on a cellular network. Downloading will use mobile data. Continue?"
                    : "当前处于蜂窝网络，批量下载将消耗流量，是否继续？")
            }
        }
    }

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

                let occupiedCount = episodes.count - selectableEpisodes.count
                if occupiedCount > 0 {
                    Text(isGlobalEnglishMode
                         ? "\(selectableEpisodes.count) selectable · \(occupiedCount) in cache/queue"
                         : "可下载 \(selectableEpisodes.count) 集 · \(occupiedCount) 集已在下载/队列")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text(isGlobalEnglishMode
                         ? "\(episodes.count) episodes available"
                         : "共 \(episodes.count) 集可下载")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
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
            HStack(alignment: .top, spacing: 8) {
                Group {
                    switch st {
                    case .cached:
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .downloading:
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(.orange)
                    case .available:
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                    }
                }
                .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Text(ep.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isOccupied ? .secondary : .primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if st != .available {
                        HStack {
                            Spacer(minLength: 0)
                            if st == .cached {
                                Text(isGlobalEnglishMode ? "Cached" : "已下载")
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
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.55))
            )
        }
    }

    private func startBatchDownload() {
        let selected = episodes.filter {
            selectedURLs.contains($0.url) && status(for: $0) == .available
        }
        guard !selected.isEmpty else { return }

        if authManager.isSubscribed {
            performDownloadsWithNetworkCheck(selected)
            return
        }

        let newOnes = selected.filter { !quotaManager.isUnlocked($0.url) }
        if newOnes.isEmpty {
            performDownloadsWithNetworkCheck(selected)
            return
        }

        batchConsumeCount = newOnes.count

        if quotaManager.remaining < newOnes.count {
            showQuotaExhaustedAlert = true
            return
        }

        pendingBatch = selected
        showBatchConsumeConfirm = true
    }

    private func confirmBatchDownload() async {
        let selected = pendingBatch
        guard !selected.isEmpty else { return }
        
        let uid = FreeQuotaManager.currentUserId(auth: authManager)
        let newOnes = selected.filter { !FreeQuotaManager.shared.isUnlocked($0.url) }
        for ep in newOnes {
            _ = await quotaManager.unlock(userId: uid, episodeKey: ep.url,
                                        videoTitle: "\(item.name) · \(ep.name)")
        }
        
        await MainActor.run {
            showBatchConsumeConfirm = false
            performDownloadsWithNetworkCheck(selected)
        }
    }

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
                            episodeKey: ep.url,
                            sourceURL: item.url
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
    
    private func performDownloadsWithNetworkCheck(_ selected: [(name: String, url: String)]) {
        if !network.isWiFi {
            pendingCellularBatch = selected
            showCellularAlert = true
        } else {
            performDownloads(selected)
        }
    }
}