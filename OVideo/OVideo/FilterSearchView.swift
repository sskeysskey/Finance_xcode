import SwiftUI
import Combine

struct FilterView: View {
    @EnvironmentObject var data: VideoDataManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var config = AppConfigManager.shared

    @State private var category: String?
    @State private var type: String?
    @State private var year: Int?
    @State private var region: String?
    @State private var sort: VideoSortOption = .update
    @State private var results: [VideoItem] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var loadError: String?
    @State private var types: [String] = []
    @State private var years: [Int] = []
    @State private var regions: [String] = []
    /// ⭐ 每次 reload +1；过期请求（旧筛选条件）的结果直接丢弃，避免串数据
    @State private var generation = 0

    private var signature: String {
        "\(category ?? "")|\(type ?? "")|\(year.map(String.init) ?? "")|\(region ?? "")|\(sort.rawValue)|\(config.effectiveMaxYear ?? -1)|\(data.cacheEpoch)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                menu(lang.t("大类", "Category"),
                     options: (["Documentary"] + data.categoryNames.filter { $0 != "Featured" })
                        .map { ($0, config.categoryDisplayName($0, english: lang.isEnglish)) },
                     selected: category) { category = $0 }
                menu(lang.t("子类", "Genre"), options: types.map { ($0, $0) }, selected: type) { type = $0 }
                menu(lang.t("年份", "Year"), options: years.map { (String($0), String($0)) },
                     selected: year.map(String.init)) { year = $0.flatMap(Int.init) }
                menu(lang.t("地区", "Region"), options: regions.map { ($0, $0) }, selected: region) { region = $0 }
                Picker("", selection: $sort) {
                    ForEach(VideoSortOption.allCases, id: \.self) { Text($0.name(lang.isEnglish)).tag($0) }
                }.frame(width: 130).labelsHidden()
                Spacer()
                if !results.isEmpty {
                    Text(lang.t("已加载 \(results.count) 部", "\(results.count) loaded"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(lang.t("重置", "Reset")) {
                    category = nil; type = nil; year = nil; region = nil; sort = .update
                }
            }
            .padding(14)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Divider()
            VideoGrid(items: results,
                      loading: loading,
                      errorText: results.isEmpty ? loadError : nil,
                      hasMore: hasMore,                 // ⭐ 提供「加载更多」兜底按钮
                      onRetry: { Task { await reload() } },
                      onReachEnd: { Task { await more() } })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(lang.t("分类检索", "Filter"))
        .task { await loadOptions() }
        .task(id: signature) { await reload() }
    }

    private func menu(_ title: String, options: [(String, String)],
                      selected: String?, action: @escaping (String?) -> Void) -> some View {
        Menu {
            Button(lang.t("全部", "All")) { action(nil) }
            Divider()
            ForEach(options, id: \.0) { o in Button(o.1) { action(o.0) } }
        } label: {
            HStack(spacing: 4) {
                Text(selected.flatMap { s in options.first { $0.0 == s }?.1 } ?? title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .frame(minWidth: 84)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(selected == nil ? Color.primary : Color.accentColor)
    }

    private func loadOptions() async {
        guard let o = await data.filterOptions(userId: auth.userIdentifier) else { return }
        types = o.types.sorted(); years = o.years.sorted(by: >); regions = o.regions.sorted()
    }

    private func reload() async {
        generation &+= 1
        let gen = generation
        loading = true; loadError = nil
        page = 0; hasMore = true; results = []
        let (i, m, err) = await data.filter(category: category, type: type, year: year, region: region,
                                            sort: sort, page: 0, userId: auth.userIdentifier)
        // ⭐ 已被更新的筛选条件取代 / 任务被取消 → 丢弃结果，不改任何状态
        guard gen == generation, !Task.isCancelled else { return }
        results = i
        hasMore = m
        page = (err == nil) ? 1 : 0          // ⭐ 失败时不跳页，重试仍从第 0 页开始
        loadError = err
        loading = false
    }

    private func more() async {
        guard hasMore, !loading else { return }
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }   // ⭐ 不去改新一轮 reload 的 loading
        var added = 0, tries = 0
        while added == 0, tries < 3, hasMore {
            tries += 1
            let (i, m, err) = await data.filter(category: category, type: type, year: year, region: region,
                                                sort: sort, page: page, userId: auth.userIdentifier)
            guard gen == generation else { return }          // 条件已变，结果作废
            if let err { loadError = err; break }            // 网络错误：保留 hasMore，用户可再点"加载更多"
            loadError = nil
            page += 1
            hasMore = m
            let ex = Set(results.map(\.url))
            let fresh = i.filter { !ex.contains($0.url) }
            results += fresh
            added = fresh.count
            // ⭐ 本页被年份过滤/去重成 0 条但服务器仍 has_more → 继续翻（最多 3 次），不再误判为"到底了"
        }
    }
}

struct SearchView: View {
    var initialKeyword: String? = nil

    @MainActor static var pendingKeyword: String? {
        didSet {
            if let kw = pendingKeyword { pendingKeywordPublisher.send(kw) }
        }
    }
    static let pendingKeywordPublisher = PassthroughSubject<String, Never>()

    @EnvironmentObject var data: VideoDataManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var app = AppState.shared
    @ObservedObject var history = SearchHistoryStore.shared

    @State private var results: [VideoItem] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @State private var showWish = false

    var body: some View {
        contentArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.winBG)
            .navigationTitle(lang.t("搜索", "Search"))
            .onChangeCompat(of: app.keyword) { schedule($0) }
            .onReceive(Self.pendingKeywordPublisher) { newKw in
                app.keyword = newKw
                Self.pendingKeyword = nil
                history.add(newKw)
            }
            .onAppear {
                if let initKw = initialKeyword, !initKw.isEmpty {
                    app.keyword = initKw
                    schedule(initKw)
                    history.add(initKw)
                } else if let k = Self.pendingKeyword {
                    app.keyword = k
                    Self.pendingKeyword = nil
                    schedule(k)
                    history.add(k)
                } else if !app.keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                    // ⭐ 从其他栏目切回来时，沿用已有关键词重新搜索
                    schedule(app.keyword)
                }
            }
            .onDisappear {
                task?.cancel()
                if !results.isEmpty { history.add(app.keyword) }
            }
            .sheet(isPresented: $showWish) {
                WishSheet(initial: app.keyword, userId: auth.userIdentifier,
                          userType: auth.userIdentifier == nil ? "device" : "apple")
            }
    }

    // MARK: 内容区
    @ViewBuilder private var contentArea: some View {
        if app.keyword.trimmingCharacters(in: .whitespaces).isEmpty {
            historyArea
        } else if searching && results.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            wishArea
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(lang.t("找到 \(results.count) 个结果", "\(results.count) results"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(lang.t("没找到？点这里求片", "Not found? Request it")) { showWish = true }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 18)
                .fixedSize(horizontal: false, vertical: true)
                VideoGrid(items: results,
                          onItemTap: { _ in history.add(app.keyword) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var historyArea: some View {
        if history.items.isEmpty {
            ContentUnavailableViewCompat(title: lang.t("输入关键词开始搜索", "Type to search"),
                                         message: "", systemImage: "magnifyingglass")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(lang.t("搜索历史", "Recent Searches")).font(.headline)
                        Spacer()
                        Button(lang.t("清空", "Clear")) { history.clear() }.buttonStyle(.link)
                    }
                    HistoryFlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(history.items, id: \.self) { kw in historyChip(kw) }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func historyChip(_ kw: String) -> some View {
        HStack(spacing: 4) {
            Button { app.keyword = kw } label: {
                Text(kw).font(.callout).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            Button { history.remove(kw) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(lang.t("删除这条历史", "Remove"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private var wishArea: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(lang.t("暂无搜索结果", "No results")).font(.title3.weight(.semibold))
            Button(lang.t("告诉我们你想看什么，我们会全力寻找", "Tell us what you want, we'll find it")) {
                showWish = true
            }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func schedule(_ raw: String) {
        task?.cancel()
        let kw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { results = []; searching = false; return }
        searching = true
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let r = await data.search(kw, userId: auth.userIdentifier)
            if Task.isCancelled { return }
            results = r; searching = false
            if !r.isEmpty {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled,
                   app.keyword.trimmingCharacters(in: .whitespacesAndNewlines) == kw {
                    history.add(kw)
                }
            }
        }
    }
}

// MARK: - 换行布局（Layout 协议，macOS 13+；不依赖 GeometryReader，系统升级不受影响）
private struct HistoryFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, usedW: CGFloat = 0
        for sub in subviews {
            var s = sub.sizeThatFits(.unspecified)
            if s.width > maxWidth {                       // 超长关键词：限制到一行宽度内（文字会截断）
                s = sub.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                s.width = min(s.width, maxWidth)
            }
            if x > 0, x + s.width > maxWidth {            // 换行
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
            usedW = max(usedW, x - spacing)
        }
        return (frames, CGSize(width: usedW, height: frames.isEmpty ? 0 : y + lineH))
    }

    private func usableWidth(_ w: CGFloat?) -> CGFloat {
        guard let w, w.isFinite, w > 0 else { return .greatestFiniteMagnitude }
        return w
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 没有有效宽度时（理想尺寸探测），返回 0，不撑开详情列
        guard let w = proposal.width, w.isFinite, w > 0 else { return .zero }
        let r = arrange(subviews, maxWidth: w)     // 高度与摆放使用同一宽度
        return CGSize(width: w, height: r.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                    subviews: Subviews, cache: inout ()) {
        let r = arrange(subviews, maxWidth: bounds.width)
        for (sub, f) in zip(subviews, r.frames) {
            sub.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

struct WishSheet: View {
    let initial: String
    let userId: String?
    let userType: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var lang: LanguageManager
    @State private var text = ""
    @State private var working = false
    @State private var done = false
    @State private var err: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(lang.t("告诉我们你想看什么", "Request a title")).font(.headline)
            if done {
                Label(lang.t("提交成功，我们会尽快为你寻找", "Submitted! We'll look into it"),
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                TextField(lang.t("例如：想看的剧集名称", "e.g. The Movie Name"), text: $text)
                if let e = err { Text(e).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                if done {
                    Button(lang.t("去看对话", "Open Support")) {
                        AppState.shared.openSupport(type: "wish")
                        dismiss()
                    }
                }
                Button(lang.t("关闭", "Close")) { dismiss() }
                if !done {
                    Button(lang.t("提交", "Submit")) { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { text = initial }
    }

    private func submit() async {
        working = true; err = nil
        do {
            try await VideoAPI.submitWish(content: text, keyword: initial,
                                          userId: userId, userType: userType)
            done = true
            await SupportChatManager.shared.refresh()          // 让客服列表立刻出现这条寻片
        } catch { err = error.localizedDescription }
        working = false
    }
}