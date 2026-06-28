import SwiftUI
import Foundation

// 文件名: Source_Add.swift
// 职责: 提供列表让用户添加/移除视频订阅与新闻源订阅，并集中管理新闻订阅持久化。

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager() // 单例

    private let subscribedSourceIDsKey = "subscribedNewsSourceIDs"
    let oldSubscribedSourcesKey = "subscribedNewsSources"

    @Published var subscribedSourceIDs: Set<String> {
        didSet { saveSubscribedIDs() }
    }

    private init() {
        let savedIDs = UserDefaults.standard.stringArray(forKey: subscribedSourceIDsKey) ?? []
        self.subscribedSourceIDs = Set(savedIDs)
    }

    private func saveSubscribedIDs() {
        UserDefaults.standard.set(Array(subscribedSourceIDs), forKey: subscribedSourceIDsKey)
    }

    // MARK: - 公共方法
    func isSubscribed(sourceId: String) -> Bool { subscribedSourceIDs.contains(sourceId) }
    func addSubscription(sourceId: String) { subscribedSourceIDs.insert(sourceId) }
    func removeSubscription(sourceId: String) { subscribedSourceIDs.remove(sourceId) }
    func subscribeToAll(_ sourceIds: [String]) { subscribedSourceIDs.formUnion(sourceIds) }
    func removeAll(_ sourceIds: [String]) { sourceIds.forEach { subscribedSourceIDs.remove($0) } }

    func migrateOldSubscription(name: String, id: String) {
        let oldNames = UserDefaults.standard.stringArray(forKey: oldSubscribedSourcesKey) ?? []
        if oldNames.contains(name) {
            print("迁移订阅: 发现旧名称订阅 [\(name)]，自动映射为 ID [\(id)]")
            addSubscription(sourceId: id)
        }
    }
}

struct AddSourceView: View {
    // 新闻源 (ID, Name)
    @State private var allAvailableSources: [(id: String, name: String)] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // 视频订阅选择
    @State private var selectedVideoKeys: Set<String> = []

    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @EnvironmentObject var resourceManager: ResourceManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage("prefersVideoHome") private var prefersVideoHome = false

    let isFirstTimeSetup: Bool
    var onComplete: (() -> Void)?
    var onConfirm: (() -> Void)?

    @Environment(\.presentationMode) var presentationMode

    private let selectedVideoStorageKey = "selectedVideoCategories"
    private let videoKeyOrder = ["vid_movie", "vid_west_drama", "vid_asia_drama", "vid_anime", "vid_show"]

    // 两列网格
    private let twoColumns = [GridItem(.flexible(), spacing: 12),
                              GridItem(.flexible(), spacing: 12)]

    // MARK: - 计算属性
    private var videoCategories: [(key: String, name: String)] {
        guard resourceManager.showVideoModule else { return [] }
        let mappings = resourceManager.videoCategoryMappings
        return videoKeyOrder.compactMap { key in
            guard let raw = mappings[key] else { return nil }
            let parts = raw.components(separatedBy: "|")
            let name = isGlobalEnglishMode
                ? (parts.count > 1 ? parts[1] : (parts.first ?? raw))
                : (parts.first ?? raw)
            return (key, name)
        }
    }

    private var hasAnySelection: Bool {
        !subscriptionManager.subscribedSourceIDs.isEmpty || !selectedVideoKeys.isEmpty
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // 上部：视频订阅（仅在应显示视频内容时出现）
                        if !videoCategories.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                moduleHeader(
                                    title: isGlobalEnglishMode ? "Video Sources" : "视频订阅源",
                                    accent: .purple,
                                    onAll: selectAllVideos,
                                    onNone: selectNoneVideos
                                )
                                LazyVGrid(columns: twoColumns, spacing: 12) {
                                    ForEach(videoCategories, id: \.key) { cat in
                                        selectCard(
                                            name: cat.name,
                                            isSelected: selectedVideoKeys.contains(cat.key),
                                            accent: .purple
                                        ) { toggleVideo(cat.key) }
                                    }
                                }
                            }
                        }

                        // 下部：新闻来源
                        VStack(alignment: .leading, spacing: 14) {
                            moduleHeader(
                                title: isGlobalEnglishMode ? "News Sources" : "新闻订阅源",
                                accent: .blue,
                                onAll: selectAllNews,
                                onNone: selectNoneNews
                            )
                            LazyVGrid(columns: twoColumns, spacing: 12) {
                                ForEach(allAvailableSources, id: \.id) { source in
                                    selectCard(
                                        name: source.name,
                                        isSelected: subscriptionManager.isSubscribed(sourceId: source.id),
                                        accent: .blue
                                    ) { toggleNews(source.id) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
                .background(Color.viewBackground)
                .safeAreaInset(edge: .bottom) { bottomBar }
            }
        }
        .navigationTitle(Localized.addSourceTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSelectedVideoKeys()
            loadAvailableSources()
        }
    }

    // MARK: - 模块标题 + 全选/全不选
    private func moduleHeader(title: String, accent: Color,
                              onAll: @escaping () -> Void,
                              onNone: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 4, height: 18)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
            Spacer()
            Button(action: onAll) {
                Text(isGlobalEnglishMode ? "All" : "全选")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(PlainButtonStyle())
            Button(action: onNone) {
                Text(isGlobalEnglishMode ? "None" : "全不选")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - 通用选择卡片
    private func selectCard(name: String, isSelected: Bool,
                            accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundColor(isSelected ? accent : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.55) : Color.secondary.opacity(0.12),
                            lineWidth: isSelected ? 1.5 : 1)
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.05 : 0.02),
                    radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 底部栏（只保留"完成"）
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: handleConfirm) {
                Text(hasAnySelection ? Localized.finishSetup : Localized.selectAtLeastOne)
                    .font(.headline)
                    .foregroundColor(hasAnySelection ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(hasAnySelection ? Color.blue : Color.secondary.opacity(0.2))
                    .cornerRadius(16)
            }
            .disabled(!hasAnySelection)
            .padding(16)
            .background(Material.regular)
        }
    }

    // MARK: - 交互
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.impactOccurred()
    }

    private func toggleVideo(_ key: String) {
        haptic()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if selectedVideoKeys.contains(key) { selectedVideoKeys.remove(key) }
            else { selectedVideoKeys.insert(key) }
        }
        saveSelectedVideoKeys()
    }

    private func toggleNews(_ id: String) {
        haptic()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if subscriptionManager.isSubscribed(sourceId: id) {
                subscriptionManager.removeSubscription(sourceId: id)
            } else {
                subscriptionManager.addSubscription(sourceId: id)
            }
        }
    }

    private func selectAllVideos() {
        haptic(.medium)
        withAnimation(.spring()) { selectedVideoKeys.formUnion(videoCategories.map { $0.key }) }
        saveSelectedVideoKeys()
    }
    private func selectNoneVideos() {
        haptic()
        withAnimation(.spring()) { videoCategories.forEach { selectedVideoKeys.remove($0.key) } }
        saveSelectedVideoKeys()
    }
    private func selectAllNews() {
        haptic(.medium)
        withAnimation(.spring()) { subscriptionManager.subscribeToAll(allAvailableSources.map { $0.id }) }
    }
    private func selectNoneNews() {
        haptic()
        withAnimation(.spring()) { subscriptionManager.removeAll(allAvailableSources.map { $0.id }) }
    }

    // MARK: - 子视图：加载 / 错误
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text(Localized.fetchingSources)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
        .background(Color.viewBackground)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(error)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.secondary)
            Button(Localized.refresh) { syncThenLoadSources() }
                .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
        .background(Color.viewBackground)
    }

    // MARK: - 确认逻辑
    private func handleConfirm() {
        saveSelectedVideoKeys()

        if isFirstTimeSetup {
            let hasNews = !subscriptionManager.subscribedSourceIDs.isEmpty
            let hasVideo = !selectedVideoKeys.isEmpty

            if resourceManager.serverReviewMode {
                // 审核模式：永远进入新闻列表；兜底确保新闻可审
                prefersVideoHome = false
                if subscriptionManager.subscribedSourceIDs.isEmpty {
                    subscriptionManager.subscribeToAll(allAvailableSources.map { $0.id })
                }
            } else {
                // 非审核：只选了视频（没选新闻）→ 直接进视频首页
                prefersVideoHome = hasVideo && !hasNews
            }

            onComplete?()
        } else {
            if let onConfirm {
                onConfirm()
            } else {
                presentationMode.wrappedValue.dismiss()
            }
        }
    }

    // MARK: - 视频订阅本地持久化
    private func loadSelectedVideoKeys() {
        let arr = UserDefaults.standard.stringArray(forKey: selectedVideoStorageKey) ?? []
        selectedVideoKeys = Set(arr)
    }

    private func saveSelectedVideoKeys() {
        UserDefaults.standard.set(Array(selectedVideoKeys), forKey: selectedVideoStorageKey)
    }

    // MARK: - 先同步服务器资源，成功后再加载本地新闻源列表
    private func syncThenLoadSources() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await resourceManager.checkAndDownloadAllNewsManifests(isManual: true)
                resourceManager.showAlreadyUpToDateAlert = false
            } catch {
                await MainActor.run {
                    self.errorMessage = Localized.networkError
                    self.isLoading = false
                }
                return
            }
            loadAvailableSources()
        }
    }

    private func loadAvailableSources() {
        isLoading = true
        errorMessage = nil

        let mappings = resourceManager.sourceMappings
        let useEnglish = self.isGlobalEnglishMode

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let allFiles = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)

                let newsJSONURLs = allFiles
                    .filter { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }

                guard !newsJSONURLs.isEmpty else {
                    let errorMsg = useEnglish
                        ? "No news data found in local storage.\nPlease go back and sync resources first."
                        : "本地未发现新闻数据。\n请先返回主页同步资源。"
                    throw NSError(domain: "AppError", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }

                var sourceMap = [String: String]()
                let decoder = JSONDecoder()

                for url in newsJSONURLs {
                    guard let data = try? Data(contentsOf: url),
                          let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                        continue
                    }

                    for (fileKeyName, articles) in decoded {
                        if let firstArticle = articles.first, let sourceId = firstArticle.source_id, !sourceId.isEmpty {
                            let rawDisplayName = mappings[sourceId] ?? fileKeyName
                            let parts = rawDisplayName.components(separatedBy: "|")
                            let finalName: String
                            if useEnglish {
                                finalName = parts.count > 1 ? parts[1] : (parts.first ?? rawDisplayName)
                            } else {
                                finalName = parts.first ?? rawDisplayName
                            }
                            sourceMap[sourceId] = finalName
                        }
                    }
                }

                let preferredOrder = NewsViewModel.preferredSourceOrder
                let sortedSources = sourceMap.map { (id: $0.key, name: $0.value) }
                    .sorted { source1, source2 in
                        let index1 = preferredOrder.firstIndex(of: source1.id) ?? Int.max
                        let index2 = preferredOrder.firstIndex(of: source2.id) ?? Int.max
                        if index1 != index2 { return index1 < index2 }
                        return source1.name < source2.name
                    }

                DispatchQueue.main.async {
                    self.allAvailableSources = sortedSources
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}