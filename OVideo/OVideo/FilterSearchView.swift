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
            Divider()
            VideoGrid(items: results,
                      loading: loading,
                      errorText: results.isEmpty ? loadError : nil,
                      hasMore: hasMore,                 // ⭐ 提供「加载更多」兜底按钮
                      onRetry: { Task { await reload() } },
                      onReachEnd: { Task { await more() } })
        }
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
        loading = true; loadError = nil
        page = 0; hasMore = true; results = []
        let (i, m, err) = await data.filter(category: category, type: type, year: year, region: region,
                                            sort: sort, page: 0, userId: auth.userIdentifier)
        results = i; hasMore = m; page = 1; loadError = err; loading = false
    }

    /// ⭐ 修复"滑到 8 行就不动"：
    ///   ① 由 VideoGrid 提前 8 个 item 触发；
    ///   ② 若某页全被去重掉（0 条新数据），自动继续翻下一页；
    ///   ③ 请求出错不再把 hasMore 写死为 false。
    private func more() async {
        guard hasMore, !loading else { return }
        loading = true
        defer { loading = false }
        var added = 0, tries = 0
        while added == 0, tries < 3, hasMore {
            tries += 1
            let (i, m, err) = await data.filter(category: category, type: type, year: year, region: region,
                                                sort: sort, page: page, userId: auth.userIdentifier)
            loadError = err
            if err != nil { break }                    // 网络错误：保留 hasMore，用户可再点"加载更多"
            page += 1
            hasMore = m
            let ex = Set(results.map(\.url))
            let fresh = i.filter { !ex.contains($0.url) }
            results += fresh
            added = fresh.count
            if i.isEmpty { hasMore = m && false; break }
        }
    }
}

struct SearchView: View {
    // 1. 使用 Published 包装，或者使用 AppState / ObservableObject 进行通知
    // 这里保留静态形式，但增加 Combine 发布者支持
    @MainActor static var pendingKeyword: String? {
        didSet {
            if let kw = pendingKeyword {
                pendingKeywordPublisher.send(kw)
            }
        }
    }
    static let pendingKeywordPublisher = PassthroughSubject<String, Never>()

    @EnvironmentObject var data: VideoDataManager
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var app = AppState.shared
    @ObservedObject var history = SearchHistoryStore.shared

    @State private var keyword = ""
    @State private var results: [VideoItem] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @State private var showWish = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(lang.t("搜索片名 / 导演 / 演员", "Search title / director / cast"), text: $keyword)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { history.add(keyword) }
                if !keyword.isEmpty {
                    Button { keyword = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(14)

            if keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                historyArea
            } else if searching && results.isEmpty {
                ProgressView().frame(maxHeight: .infinity)
            } else if results.isEmpty {
                wishArea
            } else {
                HStack {
                    Text(lang.t("找到 \(results.count) 个结果", "\(results.count) results"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(lang.t("没找到？点这里求片", "Not found? Request it")) { showWish = true }
                        .buttonStyle(.link)
                }.padding(.horizontal, 18)
                // 点开任意结果 → 记录搜索历史
                VideoGrid(items: results,
                          onItemTap: { _ in history.add(keyword) })
            }
        }
        .navigationTitle(lang.t("搜索", "Search"))
        .onChangeCompat(of: keyword) { schedule($0) }
        .onChangeCompat(of: app.searchFocusToken) { _ in focused = true }
        // ⭐ 关键修复 1：监听来自详情页等外部传入的搜索关键词
        .onReceive(Self.pendingKeywordPublisher) { newKw in
            keyword = newKw
            Self.pendingKeyword = nil
            history.add(newKw)
        }
        .onAppear {
            if let k = Self.pendingKeyword {
                keyword = k
                Self.pendingKeyword = nil
                history.add(k)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
        .onDisappear {
            // 离开搜索页时，把最后一次有结果的关键词落盘
            if !results.isEmpty { history.add(keyword) }
        }
        .sheet(isPresented: $showWish) {
            WishSheet(initial: keyword, userId: auth.userIdentifier,
                      userType: auth.userIdentifier == nil ? "device" : "apple")
        }
    }

    private var historyArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.items.isEmpty {
                ContentUnavailableViewCompat(title: lang.t("输入关键词开始搜索", "Type to search"),
                                             message: "", systemImage: "magnifyingglass")
            } else {
                HStack {
                    Text(lang.t("搜索历史", "Recent Searches")).font(.headline)
                    Spacer()
                    Button(lang.t("清空", "Clear")) { history.clear() }.buttonStyle(.link)
                }
                // ⭐ 每条历史都能单独删除
                WrapHStack(history.items, spacing: 8) { kw in
                    HStack(spacing: 4) {
                        Button { keyword = kw } label: {
                            Text(kw).font(.callout)
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
                Spacer()
            }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // ⭐ 停手 1.2s 且确实搜到内容 → 记入历史（会自动清掉前缀词，不会刷屏）
            if !r.isEmpty {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled, keyword.trimmingCharacters(in: .whitespacesAndNewlines) == kw {
                    history.add(kw)
                }
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
        } catch { err = error.localizedDescription }
        working = false
    }
}