import SwiftUI
import AppKit

private struct RatingChip: Identifiable, Hashable {
    var id: String { source }
    let source: String
    let value: String
}

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
    @State private var showShare = false          // ⭐ 新增分享

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
            // ⭐ 右上角只保留「分享」
            ToolbarItem {
                Button { showShare = true } label: {
                    Label(lang.t("分享", "Share"), systemImage: "square.and.arrow.up")
                }
                .help(lang.t("分享这部影片", "Share this title"))
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
        }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            CachedImage(url: VideoAPI.coverURL(item.image), contentMode: .fill)
                .frame(width: 190, height: 285)                 // 严格 2:3
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

    /// ⭐ 可点击的人名：蓝色更亮、更明显
    private func nameRow(_ l: String, _ names: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(l):").font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            WrapHStack(names, spacing: 6) { n in
                Button {
                    SearchView.pendingKeyword = n
                    app.go(.search)
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

    // MARK: 线路 + 选集（⭐ 去掉 "播放列表/Episodes" 标题；线路行左对齐；排序按钮移到线路行右侧）
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

    /// 线路选择条：淡蓝选中态 + 右侧正序/倒序
    private var lineBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(sortedLines.indices, id: \.self) { i in
                Button { lineIndex = i } label: {
                    Text(lang.t("线路 \(i + 1)", "Line \(i + 1)"))
                        .font(.system(size: 12, weight: i == lineIndex ? .semibold : .regular))
                        .foregroundStyle(i == lineIndex ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background(i == lineIndex
                                    ? Color.accentColor.opacity(0.14)      // ⭐ 淡蓝
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
                    Button { SearchView.pendingKeyword = n; app.go(.search) } label: {
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

    // MARK: 行为
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

// MARK: - ⭐ 分享（设计说明见正文）
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

// MARK: - 批量下载（未变动逻辑）
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

/// 简易自动换行容器
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