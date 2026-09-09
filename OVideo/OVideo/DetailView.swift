import SwiftUI
import AppKit

// MARK: - 季度解析辅助（用于同系列多季联想）
private func chineseNumeralToInt(_ raw: String) -> Int? {
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

private func romanNumeralToInt(_ raw: String) -> Int? {
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

/// 从片名解析 (基础名, 季号)
private func videoSeasonInfo(from name: String) -> (base: String, season: Int)? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if let r = seasonByExplicitMarker(trimmed) { return r }   // 1. 第X季
    if let r = seasonByRomanSuffix(trimmed)    { return r }   // 2. 冲上云霄II
    if let r = seasonByArabicSuffix(trimmed)   { return r }   // 3. 洛奇2 / 洛奇4：xxx
    if let r = seasonByChineseSuffix(trimmed)  { return r }   // 4. 绝望一
    return (trimmed, 1)                                       // 5. 无标记 → 默认为第1部
}

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

private func seasonByRomanSuffix(_ name: String) -> (base: String, season: Int)? {
    let pattern = "^(.*?)\\s*([IVXL]{1,7})$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(name.startIndex..., in: name)
    guard let match = regex.firstMatch(in: name, range: full),
          let baseRange = Range(match.range(at: 1), in: name),
          let romanRange = Range(match.range(at: 2), in: name) else { return nil }
    let base = String(name[baseRange]).trimmingCharacters(in: .whitespaces)
    guard !base.isEmpty else { return nil }
    if let last = base.last, last.isLetter, last.isASCII { return nil }
    guard let season = romanNumeralToInt(String(name[romanRange])),
          season >= 1, season <= 39 else { return nil }
    return (base, season)
}

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

private struct RatingChip: Identifiable, Hashable {
    var id: String { source }
    let source: String
    let value: String
}

// MARK: - 主详情视图
struct DetailView: View {
    let item: VideoItem
    @EnvironmentObject var data: VideoDataManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var quota = QuotaManager.shared
    @ObservedObject var dm = HLSDownloadManager.shared
    @ObservedObject var app = AppState.shared
    @Environment(\.openWindow) private var openWindow

    @AppStorage("GW_EpAsc") private var ascending = true
    @State private var channels: [VideoChannel] = []
    @State private var loading = true
    @State private var lineIndex = 0
    @State private var showBatch = false
    @State private var showSubscribe = false
    @State private var pendingEp: EpisodeItem?
    @State private var showConsume = false
    @State private var showLogin = false
    @State private var showBonus = false
    @State private var showShare = false

    // ⭐ 同系列其它季状态
    @State private var seasonSiblings: [VideoItem] = []
    @State private var selectedSeasonItem: VideoItem? = nil
    @State private var navigateToSeason = false

    private var sortedLines: [VideoChannel] { optimalChannels(channels) }
    private var currentEpisodes: [EpisodeItem] {
        guard lineIndex < sortedLines.count else { return [] }
        return sortedLines[lineIndex].episodeItems(ascending: ascending)
    }
    private var isMulti: Bool { (sortedLines.first?.episodes.count ?? 0) > 1 }
    private var cachedKeys: Set<String> { dm.completedKeys }

    private var ratingChips: [RatingChip] {
        (item.ratings ?? [:])
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { RatingChip(source: $0.key, value: $0.value) }
            .sorted { $0.source < $1.source }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if seasonSiblings.count > 1 {
                    Divider()
                    seasonSection
                }
                Divider()
                episodeSection
                if !item.otherCast.isEmpty || (item.intro?.isEmpty == false) {
                    Divider()
                    extraSection
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.winBG)
        .navigationTitle(item.name)
        .navigationSubtitle(item.info ?? "")
        .toolbar {
            ToolbarItem {
                Button { showShare = true } label: {
                    Label(lang.t("分享", "Share"), systemImage: "square.and.arrow.up")
                }
                .help(lang.t("分享这部影片", "Share this title"))
            }
        }
        // ⭐ 切换到其它季的详情页
        .navigationDestination(isPresented: $navigateToSeason) {
            if let s = selectedSeasonItem {
                DetailView(item: s)
            }
        }
        .sheet(isPresented: $showBatch) {
            if lineIndex < sortedLines.count {
                BatchDownloadSheet(item: item, channel: sortedLines[lineIndex],
                                   lineName: lang.t("线路 \(lineIndex + 1)", "Line \(lineIndex + 1)"),
                                   ascending: ascending)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareTitleSheet(item: item,
                            lineName: lineIndex < sortedLines.count
                                ? lang.t("线路 \(lineIndex + 1)", "Line \(lineIndex + 1)") : nil,
                            episodeCount: currentEpisodes.count)
        }
        .sheet(isPresented: $showSubscribe) { SubscriptionView() }
        .alert(lang.t("使用免费点数", "Use 1 Free Pass"), isPresented: $showConsume) {
            Button(lang.t("取消", "Cancel"), role: .cancel) { pendingEp = nil }
            Button(lang.t("确认使用", "Confirm")) { Task { await consumeAndPlay() } }
        } message: {
            Text(quota.consumeNote(lang.isEnglish) + "\n" + quota.remainingSummary(lang.isEnglish))
        }
        .alert(lang.t("登录后免费观看", "Sign in to watch free"), isPresented: $showLogin) {
            Button(lang.t("取消", "Cancel"), role: .cancel) {}
            Button(lang.t("使用 Apple 登录", "Sign in with Apple")) { auth.signInWithApple() }
        } message: {
            Text(lang.t("登录即可领取新人礼包与每日免费点数，登录无需付费。",
                        "Sign in (free) to get welcome + daily free passes."))
        }
        .alert(lang.t("新人礼包 🎉", "Welcome Gift 🎉"), isPresented: $showBonus) {
            Button(lang.t("好的", "Great")) { quota.clearBonusWelcome() }
        } message: {
            Text(lang.t("已赠送 \(quota.pendingBonusWelcome) 个免费点数，每天还可再领 \(quota.dailyQuota) 点。",
                        "You received \(quota.pendingBonusWelcome) passes, plus \(quota.dailyQuota) daily."))
        }
        .task {
            await quota.refresh(userId: QuotaManager.currentUserId(auth: auth))
            if quota.pendingBonusWelcome > 0 {
                if auth.isSubscribed { quota.clearBonusWelcome() } else { showBonus = true }
            }
            if channels.isEmpty {
                channels = await data.playlist(item.url)
                loading = false
            }
            await loadSeasonSiblingsIfNeeded()
        }
    }

    // MARK: - 同系列其它季加载
    private func loadSeasonSiblingsIfNeeded() async {
        guard seasonSiblings.isEmpty,
              let info = videoSeasonInfo(from: item.name),
              !info.base.isEmpty else { return }

        let uid = QuotaManager.currentUserId(auth: auth)
        let results = await data.search(info.base, userId: uid)

        let sameSeries = results.filter { cand in
            guard let ci = videoSeasonInfo(from: cand.name) else { return false }
            return ci.base == info.base
        }

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

    // MARK: - 各季展示区域
    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text(lang.t("选择季", "All Seasons"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(seasonSiblings.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }

            FlowLayout(spacing: 12) {
                ForEach(seasonSiblings) { s in
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
        }
    }

    private func seasonLabel(for s: VideoItem) -> String {
        if let info = videoSeasonInfo(from: s.name) {
            return lang.isEnglish ? "S\(info.season)" : "第\(info.season)季"
        }
        return s.name
    }

    private func seasonChip(for s: VideoItem, isCurrent: Bool) -> some View {
        VStack(spacing: 6) {
            CachedImage(url: VideoAPI.coverURL(s.image), contentMode: .fill)
                .frame(width: 76, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCurrent ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isCurrent ? 2 : 1)
                )
                .overlay(alignment: .bottomLeading) {
                    if isCurrent {
                        Text(lang.t("当前", "Now"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                            .padding(4)
                    }
                }
                .shadow(color: isCurrent ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.15),
                        radius: 4, y: 2)

            Text(seasonLabel(for: s))
                .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .lineLimit(1)
        }
        .frame(width: 76)
        .contentShape(Rectangle())
    }

    // MARK: - Header
    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            CachedImage(url: VideoAPI.coverURL(item.image), contentMode: .fill)
                .frame(width: 190, height: 285)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.title2.bold())
                if let alias = item.alias, !alias.isEmpty { infoRow(lang.t("又名", "Alias"), alias) }
                if let d = item.director, !d.isEmpty {
                    nameRow(lang.t("导演", "Director"),
                            d.split(separator: "、").map { cleanName(String($0)) })
                }
                if !item.starringCast.isEmpty {
                    nameRow(lang.t("主演", "Starring"), item.starringCast.map(cleanName))
                }
                if let t = item.types, !t.isEmpty { infoRow(lang.t("类型", "Genre"), t.joined(separator: "、")) }
                if let r = item.region, !r.isEmpty { infoRow(lang.t("地区", "Region"), r) }
                if let d = item.date, !d.isEmpty { infoRow(lang.t("上映", "Release"), d) }

                if !ratingChips.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(ratingChips) { r in
                            HStack(spacing: 4) {
                                Text(r.source).font(.caption2)
                                Text(r.value).font(.caption.bold())
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if let first = currentEpisodes.first { attemptPlay(first) }
                    } label: {
                        Label(lang.t("播放", "Play"), systemImage: "play.fill").frame(width: 90)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(currentEpisodes.isEmpty)

                    Button { handleDownloadTapped() } label: {
                        Label(isMulti ? lang.t("批量下载", "Batch") : lang.t("下载", "Download"),
                              systemImage: "arrow.down.circle")
                    }
                    .controlSize(.large).disabled(sortedLines.isEmpty)
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private func infoRow(_ l: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(l):").font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(v).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nameRow(_ l: String, _ names: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(l):").font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            WrapHStack(names, spacing: 6) { n in
                Button {
                    app.path.append(Route.search(n))
                } label: {
                    Text(n)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.accentColor.opacity(0.45), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 线路 + 选集
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if sortedLines.isEmpty {
                ContentUnavailableViewCompat(
                    title: lang.t("暂无可播放资源", "No playable source"),
                    message: lang.t("资源正在接入中，请稍后再试。", "Source is being added, please try later."),
                    systemImage: "hourglass").frame(height: 160)
            } else {
                lineBar
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(currentEpisodes) { ep in
                        Button { attemptPlay(ep) } label: {
                            Text(ep.name).font(.system(size: 12, weight: .semibold))
                                .lineLimit(2).minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity).frame(height: 42)
                                .background(LinearGradient(colors: [Color(nsColor: .systemIndigo),
                                                                    Color(nsColor: .systemPurple)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                                .overlay(alignment: .topTrailing) { badge(ep) }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(lang.t("下载这一集", "Download this episode")) { downloadSingle(ep) }
                        }
                    }
                }
            }
        }
    }

    private var lineBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(sortedLines.indices, id: \.self) { i in
                Button { lineIndex = i } label: {
                    Text(lang.t("线路 \(i + 1)", "Line \(i + 1)"))
                        .font(.system(size: 12, weight: i == lineIndex ? .semibold : .regular))
                        .foregroundStyle(i == lineIndex ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background(i == lineIndex
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.secondary.opacity(0.10),
                                    in: Capsule())
                        .overlay(Capsule().stroke(
                            i == lineIndex ? Color.accentColor.opacity(0.40) : Color.clear,
                            lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            if isMulti {
                Button { ascending.toggle() } label: {
                    Label(ascending ? lang.t("倒序", "Desc") : lang.t("正序", "Asc"),
                          systemImage: ascending ? "arrow.down" : "arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func badge(_ ep: EpisodeItem) -> some View {
        if cachedKeys.contains(ep.url) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 10))
                .foregroundStyle(.white).padding(3).background(Circle().fill(.blue)).offset(x: 3, y: -3)
        } else if !auth.isSubscribed {
            if quota.isUnlocked(ep.url) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                    .foregroundStyle(.white).padding(3).background(Circle().fill(.green)).offset(x: 3, y: -3)
            } else if quota.remaining <= 0 {
                Image(systemName: "lock.fill").font(.system(size: 9))
                    .foregroundStyle(.white).padding(3).background(Circle().fill(.orange)).offset(x: 3, y: -3)
            }
        }
    }

    private var extraSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !item.otherCast.isEmpty {
                Text(lang.t("其他演员", "Other Cast")).font(.headline)
                WrapHStack(item.otherCast.map(cleanName), spacing: 6) { n in
                    Button { 
                        app.path.append(Route.search(n))
                    } label: {
                        Text(n)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
            }
            if let intro = item.intro, !intro.isEmpty {
                Text(lang.t("剧情简介", "Synopsis")).font(.headline)
                Text(intro).font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 播放与下载行为
    private func attemptPlay(_ ep: EpisodeItem) {
        switch decideAccess(episodeKey: ep.url, auth: auth, quota: quota) {
        case .allowed:      openPlayer(ep)
        case .needLogin:    showLogin = true
        case .needConsume:  pendingEp = ep; showConsume = true
        case .exhausted:    showSubscribe = true
        }
    }

    private func consumeAndPlay() async {
        guard let ep = pendingEp else { return }
        let uid = QuotaManager.currentUserId(auth: auth)
        switch await quota.unlock(userId: uid, episodeKey: ep.url,
                                  title: "\(item.name) · \(ep.name)") {
        case .success, .alreadyUnlocked: openPlayer(ep)
        default: showSubscribe = true
        }
        pendingEp = nil
    }

    private func openPlayer(_ ep: EpisodeItem) {
        guard lineIndex < sortedLines.count else { return }
        let ch = sortedLines[lineIndex]
        openWindow(id: "player", value: PlayPayload(
            seriesTitle: item.name, episodeName: ep.name, episodeKey: ep.url,
            sourceURL: item.url, cover: item.image, channelName: ch.name,
            episodes: ch.episodeItems(ascending: ascending), playSource: "home"))
    }

    private func handleDownloadTapped() {
        guard lineIndex < sortedLines.count else { return }
        let eps = currentEpisodes.filter { !dm.isQueuedOrDone($0.url) }
        if currentEpisodes.count == 1, let only = eps.first { downloadSingle(only) }
        else { showBatch = true }
    }

    private func downloadSingle(_ ep: EpisodeItem) {
        Task {
            switch decideAccess(episodeKey: ep.url, auth: auth, quota: quota) {
            case .allowed: break
            case .needLogin: showLogin = true; return
            case .needConsume:
                let uid = QuotaManager.currentUserId(auth: auth)
                let r = await quota.unlock(userId: uid, episodeKey: ep.url,
                                          title: "\(item.name) · \(ep.name)")
                switch r {
                case .success, .alreadyUnlocked: break
                default: showSubscribe = true; return
                }
            case .exhausted: showSubscribe = true; return
            }
            guard let real = try? await VideoAPI.resolveRealURL(episodeURL: ep.url) else { return }
            dm.start(episodeKey: ep.url, mediaURL: real, title: "\(item.name) · \(ep.name)",
                     seriesTitle: item.name, episodeName: ep.name,
                     cover: item.image, sourceURL: item.url)
            app.go(.downloads)
        }
    }
}

// MARK: - 分享
struct ShareTitleSheet: View {
    let item: VideoItem
    var lineName: String? = nil
    var episodeCount: Int = 0

    @EnvironmentObject var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var includeIntro = true
    @State private var copiedTip: String?

    private var defaultText: String {
        var lines: [String] = []
        lines.append(lang.t("🎬 推荐：《\(item.name)》", "🎬 Check out: \(item.name)"))
        var meta: [String] = []
        if let d = item.date, !d.isEmpty { meta.append(d.split(separator: "(").first.map(String.init) ?? d) }
        if let r = item.region, !r.isEmpty { meta.append(r) }
        if let t = item.types, !t.isEmpty { meta.append(t.joined(separator: "/")) }
        if item.bestRating > 0 { meta.append("★ " + String(format: "%.1f", item.bestRating)) }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
        if let info = item.info, !info.isEmpty { lines.append(info) }
        if episodeCount > 1 { lines.append(lang.t("共 \(episodeCount) 集可看", "\(episodeCount) episodes")) }
        if includeIntro, let intro = item.intro, !intro.isEmpty {
            lines.append("")
            lines.append(String(intro.prefix(160)) + (intro.count > 160 ? "…" : ""))
        }
        lines.append("")
        lines.append(lang.t("— 来自 OVideo for Mac", "— via OVideo for Mac"))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(lang.t("分享", "Share")).font(.headline)

            HStack(alignment: .top, spacing: 12) {
                CachedImage(url: VideoAPI.coverURL(item.image), contentMode: .fill)
                    .frame(width: 62, height: 93)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.callout.bold()).lineLimit(2)
                    if let info = item.info, !info.isEmpty {
                        Text(info).font(.caption).foregroundStyle(.secondary)
                    }
                    if let l = lineName {
                        Text(l).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            Toggle(lang.t("附带剧情简介", "Include synopsis"), isOn: $includeIntro)
                .toggleStyle(.checkbox).font(.caption)

            Text(lang.t("分享文案（可直接编辑）", "Message (editable)"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout)
                .frame(height: 130)
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1))

            if let t = copiedTip {
                Label(t, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            HStack(spacing: 10) {
                Button { copy(text, tip: lang.t("文案已复制", "Text copied")) } label: {
                    Label(lang.t("复制文案", "Copy text"), systemImage: "doc.on.doc")
                }
                Button { copy(item.url, tip: lang.t("原始页面链接已复制", "Link copied")) } label: {
                    Label(lang.t("复制来源链接", "Copy link"), systemImage: "link")
                }
                ShareLink(item: text) {
                    Label(lang.t("系统分享…", "Share…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button(lang.t("关闭", "Close")) { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear { text = defaultText }
        .onChangeCompat(of: includeIntro) { _ in text = defaultText }
    }

    private func copy(_ s: String, tip: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copiedTip = tip
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copiedTip = nil }
    }
}

// MARK: - 批量下载
struct BatchDownloadSheet: View {
    let item: VideoItem
    let channel: VideoChannel
    let lineName: String
    let ascending: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var dm = HLSDownloadManager.shared
    @ObservedObject var quota = QuotaManager.shared
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var progress = 0
    @State private var showSubscribe = false

    private var episodes: [EpisodeItem] { channel.episodeItems(ascending: ascending) }
    private var selectable: [EpisodeItem] { episodes.filter { !dm.isQueuedOrDone($0.url) } }
    private var newCount: Int { selected.filter { !quota.isUnlocked($0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline)
                    Text("\(lineName) · " + lang.t("可下载 \(selectable.count) 集", "\(selectable.count) available"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(selected.count == selectable.count
                       ? lang.t("取消全选", "Deselect All") : lang.t("全选", "Select All")) {
                    if selected.count == selectable.count { selected = [] }
                    else { selected = Set(selectable.map(\.url)) }
                }
            }
            .padding(16)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(episodes) { ep in
                        let taken = dm.isQueuedOrDone(ep.url)
                        Toggle(isOn: Binding(
                            get: { selected.contains(ep.url) },
                            set: { isOn in
                                if isOn { selected.insert(ep.url) } else { selected.remove(ep.url) }
                            })) {
                            HStack {
                                Text(ep.name).lineLimit(1)
                                if taken {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(taken)
                        .toggleStyle(.checkbox)
                    }
                }.padding(16)
            }

            Divider()
            HStack {
                if working {
                    ProgressView()
                    Text("\(progress)/\(selected.count)").font(.caption)
                } else {
                    Text(lang.t("已选 \(selected.count) 集", "\(selected.count) selected")).font(.callout)
                    if !auth.isSubscribed, newCount > 0 {
                        Text(lang.t("将消耗 \(newCount) 点 · \(quota.remainingSummary(false))",
                                    "Uses \(newCount) pts · \(quota.remainingSummary(true))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(lang.t("取消", "Cancel")) { dismiss() }
                Button(lang.t("开始下载", "Download")) { Task { await start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || working)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .sheet(isPresented: $showSubscribe) { SubscriptionView() }
    }

    private func start() async {
        let list = episodes.filter { selected.contains($0.url) && !dm.isQueuedOrDone($0.url) }
        guard !list.isEmpty else { return }
        if !auth.isSubscribed {
            let need = list.filter { !quota.isUnlocked($0.url) }
            if quota.remaining < need.count { showSubscribe = true; return }
            let uid = QuotaManager.currentUserId(auth: auth)
            for ep in need {
                _ = await quota.unlock(userId: uid, episodeKey: ep.url,
                                       title: "\(item.name) · \(ep.name)")
            }
        }
        working = true; progress = 0
        for ep in list {
            if let real = try? await VideoAPI.resolveRealURL(episodeURL: ep.url) {
                dm.start(episodeKey: ep.url, mediaURL: real, title: "\(item.name) · \(ep.name)",
                         seriesTitle: item.name, episodeName: ep.name,
                         cover: item.image, sourceURL: item.url)
            }
            progress += 1
        }
        working = false
        dismiss()
        AppState.shared.go(.downloads)
    }
}

// MARK: - 布局辅助
struct WrapHStack<T: Hashable, V: View>: View {
    let items: [T]; let spacing: CGFloat; let content: (T) -> V
    init(_ items: [T], spacing: CGFloat = 6, @ViewBuilder content: @escaping (T) -> V) {
        self.items = items; self.spacing = spacing; self.content = content
    }
    var body: some View {
        FlowLayout(spacing: spacing) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}