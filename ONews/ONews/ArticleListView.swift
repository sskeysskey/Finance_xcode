import SwiftUI
import UIKit

// MARK: - 触感反馈
enum ONewsHaptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

enum ArticleFilterMode: String, CaseIterable {
    case unread
    case read

    var localizedName: String {
        switch self {
        case .unread: return Localized.unread
        case .read: return Localized.read
        }
    }
}

// ==================== 免费标识判定 ====================
@MainActor
enum NewsFreeBadge {
    static func isFree(timestamp: String, auth: AuthManager, viewModel: NewsViewModel) -> Bool {
        if auth.isSubscribed || auth.isPermanentVIP { return false }
        return !viewModel.isTimestampLocked(timestamp: timestamp)
    }
}

@MainActor
enum AnonFreeReadTracker {
    static func note(_ article: Article, auth: AuthManager, viewModel: NewsViewModel) {
        guard !auth.isLoggedIn, !auth.isSubscribed else { return }
        guard !viewModel.isTimestampLocked(timestamp: article.timestamp) else { return }
        AnonymousSubscribePromptManager.shared.noteFreeArticleRead()
    }
}

struct FreeTagView: View {
    var compact: Bool = false
    var body: some View {
        HStack(spacing: 3) {
            Text(Localized.isEnglish ? "FREE" : "免费")
                .font(.system(size: compact ? 14 : 16, weight: .heavy, design: .rounded))
        }
        .foregroundColor(Color(red: 0.08, green: 0.68, blue: 0.28))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(Capsule().fill(Color(red:0.18, green:0.82, blue:0.38).opacity(0.12)))
        .overlay(Capsule().stroke(Color(red:0.18, green:0.82, blue:0.38).opacity(0.38), lineWidth: 0.6))
    }
}

// ==================== 公共协议和模型 ====================
protocol ArticleListDataSource {
    var baseFilteredArticles: [ArticleItem] { get }
    var filterMode: ArticleFilterMode { get }
}

struct ArticleItem: Identifiable {
    let id: UUID
    let article: Article
    let sourceName: String?
    let sourceNameEN: String?
    var isContentMatch: Bool = false

    init(article: Article, sourceName: String? = nil, sourceNameEN: String? = nil, isContentMatch: Bool = false) {
        self.id = article.id
        self.article = article
        self.sourceName = sourceName
        self.sourceNameEN = sourceNameEN
        self.isContentMatch = isContentMatch
    }
}

/// 预分组模型，减轻 body 渲染期压力
struct ArticleDateGroup: Identifiable {
    var id: String { timestamp }
    let timestamp: String
    let items: [ArticleItem]
}

// ==================== 撤销条（Gmail 式 Undo Snackbar） ====================
@MainActor
final class ArticleUndoCenter: ObservableObject {
    @Published private(set) var message: String = ""
    @Published private(set) var isVisible: Bool = false
    private var undoAction: (() -> Void)?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, undo: @escaping () -> Void) {
        hideTask?.cancel()
        self.message = message
        self.undoAction = undo
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isVisible = true }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func performUndo() {
        let action = undoAction
        undoAction = nil
        hide()
        action?()
        ONewsHaptics.light()
    }

    func hide() {
        hideTask?.cancel(); hideTask = nil
        undoAction = nil
        withAnimation(.easeInOut(duration: 0.2)) { isVisible = false }
    }
}

struct UndoSnackBar: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onUndo) {
                Text(Localized.isEnglish ? "UNDO" : "撤销")
                    .font(.subheadline.weight(.heavy))
                    .foregroundColor(Color(red: 0.52, green: 0.80, blue: 1.0))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
    }
}

// ==================== 多选模式模型 ====================
enum GroupSelectionState { case none, partial, all }

@MainActor
final class ArticleSelectionModel: ObservableObject {
    @Published var isActive: Bool = false
    @Published var selected: Set<UUID> = []

    func enter(preselect: UUID? = nil) {
        guard !isActive else {
            if let p = preselect { selected.insert(p) }
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            isActive = true
            if let p = preselect { selected = [p] } else { selected = [] }
        }
        ONewsHaptics.rigid()
    }

    func exit() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isActive = false
            selected.removeAll()
        }
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        ONewsHaptics.selection()
    }

    func toggleGroup(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if ids.allSatisfy({ selected.contains($0) }) {
            ids.forEach { selected.remove($0) }
        } else {
            ids.forEach { selected.insert($0) }
        }
        ONewsHaptics.selection()
    }

    func groupState(_ ids: [UUID]) -> GroupSelectionState {
        guard !ids.isEmpty else { return .none }
        let hit = ids.filter { selected.contains($0) }.count
        if hit == 0 { return .none }
        return hit == ids.count ? .all : .partial
    }
}

// ==================== 底部多选工具条 ====================
private struct SelectionChipButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(prominent ? Color.blue : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minWidth: 96, minHeight: 44)
            .background(
                Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06))
            )
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SelectionActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let filterMode: ArticleFilterMode
    let onSelectAll: () -> Void
    let onClearAll: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onCancel: () -> Void

    private var isEn: Bool { Localized.isEnglish }
    private var allSelected: Bool { totalCount > 0 && selectedCount == totalCount }
    private var isMarkRead: Bool { filterMode == .unread }

    private var selectAllTitle: String {
        allSelected ? (isEn ? "Deselect All" : "取消全选") : (isEn ? "Select All" : "全选")
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button(action: { allSelected ? onClearAll() : onSelectAll() }) {
                    Text(selectAllTitle)
                }
                .buttonStyle(SelectionChipButtonStyle(prominent: true))
                .disabled(totalCount == 0)

                Spacer(minLength: 4)

                Text(isEn ? "\(selectedCount) selected" : "已选 \(selectedCount) 篇")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                Button(action: onCancel) {
                    Text(isEn ? "Cancel" : "取消")
                }
                .buttonStyle(SelectionChipButtonStyle())
            }

            Button(action: { isMarkRead ? onMarkRead() : onMarkUnread() }) {
                Label(isMarkRead ? (isEn ? "Mark as Read" : "标记已读")
                                 : (isEn ? "Mark as Unread" : "标记未读"),
                      systemImage: isMarkRead ? "checkmark.circle.fill" : "envelope.badge.fill")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selectedCount == 0 ? Color.gray.opacity(0.25)
                                                     : (isMarkRead ? Color.blue : Color.orange))
                    )
                    .foregroundColor(.white)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// ==================== 卡片 ====================
struct ArticleRowCardView: View {
    let article: Article
    let sourceName: String?
    let sourceNameEN: String?
    let isReadEffective: Bool
    let isContentMatch: Bool
    let isLocked: Bool
    let isFree: Bool
    let showEnglish: Bool

    init(article: Article, sourceName: String?, sourceNameEN: String? = nil, isReadEffective: Bool,
         isContentMatch: Bool = false, isLocked: Bool = false, isFree: Bool = false,
         showEnglish: Bool = false) {
        self.article = article
        self.sourceName = sourceName
        self.sourceNameEN = sourceNameEN
        self.isReadEffective = isReadEffective
        self.isContentMatch = isContentMatch
        self.isLocked = isLocked
        self.isFree = isFree
        self.showEnglish = showEnglish
    }

    var displayTopic: String {
        if showEnglish, let engTitle = article.topic_eng, !engTitle.isEmpty { return engTitle }
        return article.topic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let name = sourceName {
                    let finalName = (showEnglish && sourceNameEN != nil && !sourceNameEN!.isEmpty) ? sourceNameEN! : name
                    Text(finalName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(isReadEffective ? .secondary.opacity(0.7) : .blue.opacity(0.8))
                        .animation(.none, value: showEnglish)
                }
                Spacer()
                if isLocked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 14))
                        Text(Localized.needSubscription).font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
                }
            }

            HStack(alignment: .top) {
                Text(displayTopic)
                    .font(.system(size: 19, weight: isReadEffective ? .regular : .bold, design: .serif))
                    .foregroundColor(isReadEffective ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .opacity(isReadEffective ? 0.8 : 1.0)
                    .animation(.none, value: showEnglish)
                Spacer(minLength: 0)
            }

            if isContentMatch {
                HStack {
                    Label(Localized.contentMatch, systemImage: "text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color.black.opacity(isReadEffective ? 0.02 : 0.06), radius: 8, x: 0, y: 4)
        )
        .opacity(isLocked ? 0.7 : 1.0)
    }
}

// ==================== 列表内容 ====================
struct ArticleListContent: View {
    let groups: [ArticleDateGroup]
    let allVisibleArticles: [ArticleItem]
    let filterMode: ArticleFilterMode
    let expandedTimestamps: Set<String>
    let viewModel: NewsViewModel
    let authManager: AuthManager
    let showEnglish: Bool
    let isSelectionMode: Bool
    let selectedIDs: Set<UUID>
    let onToggleTimestamp: (String) -> Void
    let onPlayTimestamp: (String) -> Void
    let onArticleTap: (ArticleItem) async -> Void
    let onToggleSelect: (ArticleItem) -> Void
    let onToggleGroupSelect: ([ArticleItem]) -> Void
    let onEnterSelection: (ArticleItem) -> Void
    let onMarkRead: (ArticleItem) -> Void
    let onMarkUnread: (ArticleItem) -> Void

    private func isGroupLocked(_ group: [ArticleItem], timestamp: String) -> Bool {
        guard NewsPointsCoordinator.shouldShowLock(timestamp: timestamp,
                                                  auth: authManager,
                                                  viewModel: viewModel) else { return false }
        if group.isEmpty { return true }
        return group.contains { !NewsPointsCoordinator.canAccess($0.article,
                                                                auth: authManager,
                                                                viewModel: viewModel) }
    }

    private func groupState(_ group: [ArticleItem]) -> GroupSelectionState {
        guard !group.isEmpty else { return .none }
        let hit = group.filter { selectedIDs.contains($0.id) }.count
        if hit == 0 { return .none }
        return hit == group.count ? .all : .partial
    }

    var body: some View {
        ForEach(groups) { group in
            let timestamp = group.timestamp
            let list = group.items

            Section {
                if expandedTimestamps.contains(timestamp) {
                    ForEach(list) { item in
                        ArticleRowButton(
                            item: item,
                            filterMode: filterMode,
                            viewModel: viewModel,
                            authManager: authManager,
                            filteredArticles: allVisibleArticles,
                            onTap: { await onArticleTap(item) },
                            showEnglish: showEnglish,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedIDs.contains(item.id),
                            onToggleSelect: { onToggleSelect(item) },
                            onEnterSelection: { onEnterSelection(item) },
                            onMarkRead: { onMarkRead(item) },
                            onMarkUnread: { onMarkUnread(item) }
                        )
                    }
                }
            } header: {
                TimestampHeader(
                    timestamp: timestamp,
                    count: list.count,
                    isExpanded: expandedTimestamps.contains(timestamp),
                    isLocked: isGroupLocked(list, timestamp: timestamp),
                    isFree: NewsFreeBadge.isFree(timestamp: timestamp,
                                                 auth: authManager,
                                                 viewModel: viewModel),
                    isSelectionMode: isSelectionMode,
                    groupState: groupState(list),
                    onToggle: { onToggleTimestamp(timestamp) },
                    onPlay: { onPlayTimestamp(timestamp) },
                    onToggleGroupSelect: { onToggleGroupSelect(list) }
                )
            }
        }
    }
}

// ==================== 搜索结果 ====================
struct SearchResultsList: View {
    let results: [ArticleItem]
    let viewModel: NewsViewModel
    let authManager: AuthManager
    let showEnglish: Bool
    let onArticleTap: (ArticleItem) async -> Void
    let onMarkRead: (ArticleItem) -> Void
    let onMarkUnread: (ArticleItem) -> Void

    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"; return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Localized.currentLocale
        f.dateFormat = Localized.dateFormatFull
        return f
    }()

    private func isGroupLocked(_ group: [ArticleItem], timestamp: String) -> Bool {
        guard NewsPointsCoordinator.shouldShowLock(timestamp: timestamp,
                                                  auth: authManager,
                                                  viewModel: viewModel) else { return false }
        if group.isEmpty { return true }
        return group.contains { !NewsPointsCoordinator.canAccess($0.article,
                                                                auth: authManager,
                                                                viewModel: viewModel) }
    }

    var body: some View {
        if results.isEmpty {
            Section {
                Text(Localized.noMatch)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            } header: {
                Text(Localized.searchResults)
                    .font(.headline)
                    .foregroundColor(.blue.opacity(0.7))
                    .padding(.vertical, 4)
            }
        } else {
            let grouped = Dictionary(grouping: results, by: { $0.article.timestamp })
                .mapValues { Array($0.reversed()) }
            let timestamps = grouped.keys.sorted(by: >)

            ForEach(timestamps, id: \.self) { timestamp in
                let list = grouped[timestamp] ?? []
                Section(header:
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Localized.searchResults)
                            .font(.subheadline)
                            .foregroundColor(.blue.opacity(0.7))
                        HStack(spacing: 6) {
                            Text("\(formatTimestamp(timestamp)) (\(list.count))")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.85))
                            if isGroupLocked(list, timestamp: timestamp) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.yellow.opacity(0.8))
                                    .font(.footnote)
                            } else if NewsFreeBadge.isFree(timestamp: timestamp,
                                                           auth: authManager,
                                                           viewModel: viewModel) {
                                FreeTagView(compact: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                ) {
                    ForEach(list) { item in
                        ArticleRowButton(
                            item: item,
                            filterMode: .unread,
                            viewModel: viewModel,
                            authManager: authManager,
                            filteredArticles: results,
                            onTap: { await onArticleTap(item) },
                            showEnglish: showEnglish,
                            onMarkRead: { onMarkRead(item) },
                            onMarkUnread: { onMarkUnread(item) }
                        )
                    }
                }
            }
        }
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp }
        return Self.displayFormatter.string(from: date)
    }
}

// ==================== 行（原生 swipeActions：左滑到底松手即执行，丝滑零冲突） ====================
struct ArticleRowButton: View {
    let item: ArticleItem
    let filterMode: ArticleFilterMode
    let viewModel: NewsViewModel
    let authManager: AuthManager
    let filteredArticles: [ArticleItem]
    let onTap: () async -> Void
    let showEnglish: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onEnterSelection: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void

    init(item: ArticleItem,
         filterMode: ArticleFilterMode,
         viewModel: NewsViewModel,
         authManager: AuthManager,
         filteredArticles: [ArticleItem],
         onTap: @escaping () async -> Void,
         showEnglish: Bool,
         isSelectionMode: Bool = false,
         isSelected: Bool = false,
         onToggleSelect: @escaping () -> Void = {},
         onEnterSelection: @escaping () -> Void = {},
         onMarkRead: @escaping () -> Void = {},
         onMarkUnread: @escaping () -> Void = {}) {
        self.item = item
        self.filterMode = filterMode
        self.viewModel = viewModel
        self.authManager = authManager
        self.filteredArticles = filteredArticles
        self.onTap = onTap
        self.showEnglish = showEnglish
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onToggleSelect = onToggleSelect
        self.onEnterSelection = onEnterSelection
        self.onMarkRead = onMarkRead
        self.onMarkUnread = onMarkUnread
    }

    private var isReadEffective: Bool { viewModel.isArticleEffectivelyRead(item.article) }

    var body: some View {
        let isLocked = NewsPointsCoordinator.shouldShowLock(timestamp: item.article.timestamp,
                                                           auth: authManager,
                                                           viewModel: viewModel)
            && !NewsPointsCoordinator.canAccess(item.article,
                                                auth: authManager,
                                                viewModel: viewModel)
        let isFree = !isLocked && NewsFreeBadge.isFree(timestamp: item.article.timestamp,
                                                      auth: authManager,
                                                      viewModel: viewModel)

        HStack(spacing: 10) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.45))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ArticleRowCardView(
                article: item.article,
                sourceName: item.sourceName,
                sourceNameEN: item.sourceNameEN,
                isReadEffective: isReadEffective,
                isContentMatch: item.isContentMatch,
                isLocked: isLocked,
                isFree: isFree,
                showEnglish: showEnglish
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode { onToggleSelect() } else { Task { await onTap() } }
        }
        // ★ 原生系统滑动：allowsFullSwipe = true 支持滑动到底直接松手执行，无任何阻断
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSelectionMode {
                Button {
                    if isReadEffective { onMarkUnread() } else { onMarkRead() }
                } label: {
                    Label(
                        isReadEffective ? Localized.markAsUnread_text : Localized.markAsRead_text,
                        systemImage: isReadEffective ? "envelope.badge.fill" : "checkmark.circle.fill"
                    )
                }
                .tint(isReadEffective ? .orange : .blue)
            }
        }
        .id(item.article.id)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAction(named: Text(isReadEffective ? Localized.markAsUnread_text
                                                         : Localized.markAsRead_text)) {
            if isReadEffective { onMarkUnread() } else { onMarkRead() }
        }
        .contextMenu {
            if !isSelectionMode {
                ArticleContextMenu(
                    article: item.article,
                    filterMode: filterMode,
                    viewModel: viewModel,
                    filteredArticles: filteredArticles.map { $0.article },
                    onMarkRead: onMarkRead,
                    onMarkUnread: onMarkUnread,
                    onEnterSelection: onEnterSelection
                )
            }
        }
    }
}

// ==================== 长按菜单 ====================
struct ArticleContextMenu: View {
    let article: Article
    let filterMode: ArticleFilterMode
    let viewModel: NewsViewModel
    let filteredArticles: [Article]
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onEnterSelection: () -> Void

    var body: some View {
        if viewModel.isArticleEffectivelyRead(article) {
            Button(action: onMarkUnread) {
                Label(Localized.markAsUnread_text, systemImage: "circle")
            }
        } else {
            Button(action: onMarkRead) {
                Label(Localized.markAsRead_text, systemImage: "checkmark.circle")
            }

            if filterMode == .unread && !filteredArticles.isEmpty {
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.markAllAboveAsRead(articleID: article.id, inVisibleList: filteredArticles)
                    }
                } label: { Label(Localized.readAbove, systemImage: "arrow.up.to.line.compact") }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.markAllBelowAsRead(articleID: article.id, inVisibleList: filteredArticles)
                    }
                } label: { Label(Localized.readBelow, systemImage: "arrow.down.to.line.compact") }
            }
        }

        Divider()
        Button(action: onEnterSelection) {
            Label(Localized.isEnglish ? "Select Articles…" : "选择文章…",
                  systemImage: "checkmark.circle.badge.questionmark")
        }
    }
}

// ==================== 日期分组头 ====================
struct TimestampHeader: View {
    let timestamp: String
    let count: Int
    let isExpanded: Bool
    let isLocked: Bool
    let isFree: Bool
    let isSelectionMode: Bool
    let groupState: GroupSelectionState
    let onToggle: () -> Void
    let onPlay: () -> Void
    let onToggleGroupSelect: () -> Void

    private static let parsingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"; return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = Localized.dateFormatShort
        f.locale = Localized.currentLocale
        return f
    }()

    private var groupIcon: String {
        switch groupState {
        case .none: return "circle"
        case .partial: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSelectionMode {
                Button(action: onToggleGroupSelect) {
                    Image(systemName: groupIcon)
                        .font(.system(size: 20))
                        .foregroundColor(groupState == .none ? .secondary.opacity(0.5) : .blue)
                        .padding(.leading, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Capsule()
                    .fill(isExpanded ? Color.blue : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: 24)
                    .padding(.leading, 12)
            }

            Text(formatTimestamp(timestamp))
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(isExpanded ? .blue : .primary.opacity(0.85))
                .padding(.leading, 12)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            if isFree && !isLocked {
                FreeTagView(compact: true).padding(.leading, 8)
            }

            Spacer()

            if count > 0 && !isSelectionMode {
                Button(action: { onPlay() }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isExpanded ? .blue : .gray)
                        .padding(8)
                        .background(Circle().fill(isExpanded ? Color.blue.opacity(0.18) : Color.gray.opacity(0.15)))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 20)
            }

            HStack(spacing: 8) {
                if isLocked {
                    Image(systemName: "lock.fill").font(.caption2).foregroundColor(.orange)
                }
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(isExpanded ? .white : .secondary)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(Capsule().fill(isExpanded ? Color.blue.opacity(0.8)
                                                          : Color.secondary.opacity(0.15)))

                if isSelectionMode {
                    Button(action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { onToggle() } }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.6))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleGroupSelect()
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { onToggle() }
            }
        }
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        guard let date = Self.parsingFormatter.date(from: timestamp) else { return timestamp }
        return Self.displayFormatter.string(from: date)
    }
}

// ==================== 空态 ====================
struct EmptyStateView: View {
    var filterMode: ArticleFilterMode = .unread
    @AppStorage("isGlobalEnglishMode") private var isEnglish = false

    private var icon: String { filterMode == .unread ? "checkmark.circle" : "tray" }

    private var title: String {
        switch filterMode {
        case .unread: return isEnglish ? "You're all caught up" : "当前无未读文章"
        case .read:   return isEnglish ? "No read articles yet" : "暂无已读文章"
        }
    }

    private var subtitle: String {
        switch filterMode {
        case .unread: return isEnglish ? "New stories will appear here." : "有新内容时会出现在这里"
        case .read:   return isEnglish ? "Articles you read will show up here." : "读过的文章会出现在这里"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.3))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.footnote)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.viewBackground)
    }
}

// ==================== 单一来源列表 ====================
struct ArticleListView: View {
    let sourceName: String
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false

    @Environment(\.appNavPath) var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""

    @State private var showProfileSheet = false
    @State private var hasPerformedAutoExpansion = false

    @StateObject private var selection = ArticleSelectionModel()
    @StateObject private var undo = ArticleUndoCenter()

    private var displayTitle: String {
        guard let source = source else { return sourceName }
        return isGlobalEnglishMode ? source.name_en : source.name
    }

    private var source: NewsSource? {
        viewModel.sources.first(where: { $0.name == sourceName })
    }

    private func getCount(for mode: ArticleFilterMode) -> Int {
        mode == .unread ? unreadCount : readCount
    }

    private var baseFilteredArticles: [ArticleItem] {
        guard let source = source else { return [] }
        return source.articles
            .filter { article in
                let isReadEff = viewModel.isArticleEffectivelyRead(article)
                return (filterMode == .unread) ? !isReadEff : isReadEff
            }
            .map { ArticleItem(article: $0, sourceName: nil) }
    }

    private var groupedArticles: [ArticleDateGroup] {
        let items = baseFilteredArticles
        let dict = Dictionary(grouping: items, by: { $0.article.timestamp })
        let orderedKeys = dict.keys.sorted(by: >)
        return orderedKeys.map { key in
            let raw = dict[key] ?? []
            let finalItems = (filterMode == .read) ? Array(raw.reversed()) : raw
            return ArticleDateGroup(timestamp: key, items: finalItems)
        }
    }

    private var searchResults: [ArticleItem] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let source = source else { return [] }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source.articles.compactMap { article -> ArticleItem? in
            if article.topic.lowercased().contains(keyword) {
                return ArticleItem(article: article, sourceName: nil, isContentMatch: false)
            }
            if article.article.lowercased().contains(keyword) {
                return ArticleItem(article: article, sourceName: nil, isContentMatch: true)
            }
            return nil
        }
    }

    private var unreadCount: Int {
        source?.articles.filter { !viewModel.isArticleEffectivelyRead($0) }.count ?? 0
    }
    private var readCount: Int {
        source?.articles.filter { viewModel.isArticleEffectivelyRead($0) }.count ?? 0
    }

    var body: some View {
        if source == nil {
            VStack { Text(Localized.sourceUnavailable).foregroundColor(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.viewBackground.ignoresSafeArea())
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isSearching && !selection.isActive {
                    SearchBarInline(
                        text: $searchText,
                        placeholder: Localized.searchPlaceholder,
                        onCommit: {
                            isSearchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        },
                        onCancel: {
                            withAnimation { isSearching = false; isSearchActive = false; searchText = "" }
                        }
                    )
                }

                if let message = resourceManager.activeNotification {
                    NotificationBannerView(message: message) {
                        resourceManager.dismissNotification()
                    }
                    .background(Color.viewBackground)
                }

                listArea

                bottomBar
            }
            .background(Color.viewBackground.ignoresSafeArea())

            if undo.isVisible {
                UndoSnackBar(message: undo.message, onUndo: { undo.performUndo() })
                    .padding(.bottom, selection.isActive ? 130 : 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(60)
            }
        }
        .onAppear {
            viewModel.finishReadingIfNeeded()
            if !hasPerformedAutoExpansion {
                autoExpandGroups(); hasPerformedAutoExpansion = true
            }
            Task { await resourceManager.silentRefresh(minInterval: 60, reason: "source-list-appear") }
        }
        .navigationTitle(displayTitle.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                UserStatusToolbarItem(showProfileSheet: $showProfileSheet)
            }
            ToolbarItem(placement: .principal) {
                if !selection.isActive && authManager.isLoggedIn && !authManager.isSubscribed {
                    NewsPointsPill()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !selection.isActive {
                    ArticleListToolbarActions(
                        isGlobalEnglishMode: $isGlobalEnglishMode,
                        onEnterSelection: { enterSelection(preselect: nil) },
                        onToggleSearch: {
                            withAnimation {
                                isSearching.toggle()
                                if !isSearching { isSearchActive = false; searchText = "" }
                            }
                        }
                    )
                }
            }
        }
        .overlay(
            DownloadOverlay(isDownloading: isDownloadingImages,
                            progress: downloadProgress,
                            progressText: downloadProgressText)
        )
        .alert("", isPresented: $showErrorAlert,
               actions: { Button(Localized.confirm, role: .cancel) { } },
               message: { Text(errorMessage) })
        .sheet(isPresented: $showProfileSheet) { UserProfileView() }
        .onChange(of: authManager.isLoggedIn) { newValue in
            if newValue {
                Task {
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager))
                }
            }
        }
    }

    @ViewBuilder
    private var listArea: some View {
        if !isSearchActive && baseFilteredArticles.isEmpty {
            EmptyStateView(filterMode: filterMode)
        } else {
            List {
                if isSearchActive {
                    SearchResultsList(
                        results: searchResults,
                        viewModel: viewModel,
                        authManager: authManager,
                        showEnglish: isGlobalEnglishMode,
                        onArticleTap: { item in await handleArticleTap(item, autoPlay: false) },
                        onMarkRead: { markOne($0, asRead: true) },
                        onMarkUnread: { markOne($0, asRead: false) }
                    )
                } else {
                    ArticleListContent(
                        groups: groupedArticles,
                        allVisibleArticles: baseFilteredArticles,
                        filterMode: filterMode,
                        expandedTimestamps: viewModel.expandedTimestampsBySource[sourceName, default: Set<String>()],
                        viewModel: viewModel,
                        authManager: authManager,
                        showEnglish: isGlobalEnglishMode,
                        isSelectionMode: selection.isActive,
                        selectedIDs: selection.selected,
                        onToggleTimestamp: { timestamp in
                            viewModel.toggleTimestampExpansion(for: sourceName, timestamp: timestamp)
                        },
                        onPlayTimestamp: { timestamp in
                            if let firstItem = baseFilteredArticles.first(where: { $0.article.timestamp == timestamp }) {
                                Task { await handleArticleTap(firstItem, autoPlay: true) }
                            }
                        },
                        onArticleTap: { item in await handleArticleTap(item, autoPlay: false) },
                        onToggleSelect: { selection.toggle($0.id) },
                        onToggleGroupSelect: { group in selection.toggleGroup(group.map { $0.id }) },
                        onEnterSelection: { item in enterSelection(preselect: item.id) },
                        onMarkRead: { markOne($0, asRead: true) },
                        onMarkUnread: { markOne($0, asRead: false) }
                    )
                }
            }
            .listStyle(PlainListStyle())
            .environment(\.defaultMinListRowHeight, 0)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if selection.isActive {
            SelectionActionBar(
                selectedCount: selection.selected.count,
                totalCount: baseFilteredArticles.count,
                filterMode: filterMode,
                onSelectAll: { selection.selected = Set(baseFilteredArticles.map { $0.id }) },
                onClearAll: { selection.selected.removeAll() },
                onMarkRead: { applySelection(asRead: true) },
                onMarkUnread: { applySelection(asRead: false) },
                onCancel: { exitSelection() }
            )
        } else if !isSearchActive {
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    Text("\(mode.localizedName) (\(self.getCount(for: mode)))").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .onChange(of: filterMode) { _ in
                ONewsHaptics.selection()
                autoExpandGroups()
            }
        }
    }

    // MARK: - 多选处理
    private func enterSelection(preselect: UUID?) {
        undo.hide()
        selection.enter(preselect: preselect)
    }

    private func exitSelection() {
        selection.exit()
    }

    private func applySelection(asRead: Bool) {
        let ids = selection.selected
        guard !ids.isEmpty else { exitSelection(); return }
        let articles = baseFilteredArticles.filter { ids.contains($0.id) }.map { $0.article }
        guard !articles.isEmpty else { exitSelection(); return }

        ONewsHaptics.success()
        withAnimation(.easeInOut(duration: 0.28)) { viewModel.markArticles(articles, asRead: asRead) }
        exitSelection()

        let n = articles.count
        let msg = isGlobalEnglishMode
            ? "\(n) marked as \(asRead ? "read" : "unread")"
            : "已将 \(n) 篇标记为\(asRead ? "已读" : "未读")"
        undo.show(msg) {
            withAnimation(.easeInOut(duration: 0.28)) { viewModel.markArticles(articles, asRead: !asRead) }
        }
    }

    // MARK: - 单篇标记（带撤销，滑动 / 长按菜单 / VoiceOver 共用）
    private func markOne(_ item: ArticleItem, asRead: Bool) {
        ONewsHaptics.light()
        let a = item.article
        // 直接更新状态，无需 withAnimation，原生 swipeActions 会平滑收起此行
        viewModel.markArticles([a], asRead: asRead)
        let msg = isGlobalEnglishMode
            ? (asRead ? "Marked as read" : "Marked as unread")
            : (asRead ? "已标记为已读" : "已标记为未读")
        undo.show(msg) {
            withAnimation(.easeInOut(duration: 0.25)) { viewModel.markArticles([a], asRead: !asRead) }
        }
    }

    private func handleArticleTap(_ item: ArticleItem, autoPlay: Bool = false) async {
        let article = item.article

        if !NewsPointsCoordinator.canAccess(article, auth: authManager, viewModel: viewModel) {
            NewsPointsCoordinator.shared.attemptUnlockArticle(article, auth: authManager, viewModel: viewModel) {
                Task { await self.handleArticleTap(item, autoPlay: autoPlay) }
            }
            return
        }

        AnonFreeReadTracker.note(article, auth: authManager, viewModel: viewModel)
        undo.hide()

        if !article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp,
                                                  imageNames: article.images,
                                                  priority: true)
        }
        // ★★★ 新增：点击瞬间就在后台把正文排版算好，push 动画结束时内容已就位（无占位、无跳版）
        ArticleBodyCache.shared.prefetch(article: article)

        await MainActor.run {
            appNavPath?.wrappedValue.append(
                NavigationTarget.articleDetail(article, self.sourceName, "source", autoPlay))
        }
    }

    private func autoExpandGroups() {
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        let sortedTimestamps = groupedArticles.keys.sorted(by: >)
        if authManager.isSubscribed {
            viewModel.expandedTimestampsBySource[sourceName] =
                sortedTimestamps.first.map { [$0] } ?? []
        } else {
            if sortedTimestamps.count == 1, let s = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[sourceName] = [s]
            } else {
                viewModel.expandedTimestampsBySource[sourceName] = []
            }
        }
    }
}

// ==================== 顶部工具栏按钮组 ====================
struct ArticleListToolbarActions: View {
    @Binding var isGlobalEnglishMode: Bool
    let onEnterSelection: () -> Void
    let onToggleSearch: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: { withAnimation(.spring()) { isGlobalEnglishMode.toggle() } }) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                        .background(!isGlobalEnglishMode ? Color.primary : Color.clear)
                        .clipShape(Circle())
                    Text(isGlobalEnglishMode ? "中" : "英")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(!isGlobalEnglishMode ? Color.viewBackground : Color.primary)
                }
                .frame(width: 24, height: 24)
            }
            .accessibilityLabel(isGlobalEnglishMode ? "Chinese" : "English")

            Button(action: onEnterSelection) {
                Image(systemName: "checklist")
            }
            .accessibilityLabel(isGlobalEnglishMode ? "Select" : "选择文章")

            Button(action: onToggleSearch) {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel(Localized.search)
        }
        .foregroundColor(.primary)
    }
}

// ==================== 全部文章列表 ====================
struct AllArticlesListView: View {
    @ObservedObject var viewModel: NewsViewModel
    @ObservedObject var resourceManager: ResourceManager
    @EnvironmentObject var authManager: AuthManager

    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @Environment(\.appNavPath) var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var isDownloadingImages = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadProgressText = ""
    @State private var showProfileSheet = false
    @State private var hasPerformedAutoExpansion = false

    @StateObject private var selection = ArticleSelectionModel()
    @StateObject private var undo = ArticleUndoCenter()

    private var baseFilteredArticles: [ArticleItem] {
        viewModel.allArticlesSortedForDisplay
            .filter { item in
                let isReadEff = viewModel.isArticleEffectivelyRead(item.article)
                return (filterMode == .unread) ? !isReadEff : isReadEff
            }
            .map { ArticleItem(article: $0.article, sourceName: $0.sourceName, sourceNameEN: $0.sourceNameEN) }
    }

    private var groupedArticles: [ArticleDateGroup] {
        let items = baseFilteredArticles
        let dict = Dictionary(grouping: items, by: { $0.article.timestamp })
        let orderedKeys = dict.keys.sorted(by: >)
        return orderedKeys.map { key in
            let raw = dict[key] ?? []
            let finalItems = (filterMode == .read) ? Array(raw.reversed()) : raw
            return ArticleDateGroup(timestamp: key, items: finalItems)
        }
    }

    private var totalUnreadCount: Int {
        viewModel.allArticlesSortedForDisplay.filter { !viewModel.isArticleEffectivelyRead($0.article) }.count
    }
    private var totalReadCount: Int {
        viewModel.allArticlesSortedForDisplay.filter { viewModel.isArticleEffectivelyRead($0.article) }.count
    }

    private var searchResults: [ArticleItem] {
        guard isSearchActive, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.allArticlesSortedForDisplay.compactMap { item -> ArticleItem? in
            if item.article.topic.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName,
                                   sourceNameEN: item.sourceNameEN, isContentMatch: false)
            }
            if item.article.article.lowercased().contains(keyword) {
                return ArticleItem(article: item.article, sourceName: item.sourceName,
                                   sourceNameEN: item.sourceNameEN, isContentMatch: true)
            }
            return nil
        }
    }

    private func getCount(for mode: ArticleFilterMode) -> Int {
        mode == .unread ? totalUnreadCount : totalReadCount
    }

    private func getFilterTitle(for mode: ArticleFilterMode) -> String {
        "\(mode.localizedName) (\(getCount(for: mode)))"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isSearching && !selection.isActive {
                    SearchBarInline(
                        text: $searchText,
                        placeholder: Localized.searchPlaceholder,
                        onCommit: {
                            isSearchActive = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        },
                        onCancel: {
                            withAnimation { isSearching = false; isSearchActive = false; searchText = "" }
                        }
                    )
                }

                if let message = resourceManager.activeNotification {
                    NotificationBannerView(message: message) {
                        resourceManager.dismissNotification()
                    }
                    .background(Color.viewBackground)
                }

                listArea

                bottomBar
            }
            .background(Color.viewBackground.ignoresSafeArea())

            if undo.isVisible {
                UndoSnackBar(message: undo.message, onUndo: { undo.performUndo() })
                    .padding(.bottom, selection.isActive ? 130 : 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(60)
            }
        }
        .onAppear {
            viewModel.finishReadingIfNeeded()
            if !hasPerformedAutoExpansion {
                autoExpandGroups(); hasPerformedAutoExpansion = true
            }
            Task { await resourceManager.silentRefresh(minInterval: 60, reason: "all-list-appear") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                UserStatusToolbarItem(showProfileSheet: $showProfileSheet)
            }
            ToolbarItem(placement: .principal) {
                if !selection.isActive && authManager.isLoggedIn && !authManager.isSubscribed {
                    NewsPointsPill()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !selection.isActive {
                    ArticleListToolbarActions(
                        isGlobalEnglishMode: $isGlobalEnglishMode,
                        onEnterSelection: { enterSelection(preselect: nil) },
                        onToggleSearch: {
                            withAnimation {
                                isSearching.toggle()
                                if !isSearching { isSearchActive = false; searchText = "" }
                            }
                        }
                    )
                }
            }
        }
        .overlay(
            DownloadOverlay(isDownloading: isDownloadingImages,
                            progress: downloadProgress,
                            progressText: downloadProgressText)
        )
        .alert("", isPresented: $showErrorAlert,
               actions: { Button(Localized.confirm, role: .cancel) { } },
               message: { Text(errorMessage) })
        .sheet(isPresented: $showProfileSheet) { UserProfileView() }
        .onChange(of: authManager.isLoggedIn) { newValue in
            if newValue {
                Task {
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager))
                }
            }
        }
    }

    @ViewBuilder
    private var listArea: some View {
        if !isSearchActive && baseFilteredArticles.isEmpty {
            EmptyStateView(filterMode: filterMode)
        } else {
            List {
                if isSearchActive {
                    SearchResultsList(
                        results: searchResults,
                        viewModel: viewModel,
                        authManager: authManager,
                        showEnglish: isGlobalEnglishMode,
                        onArticleTap: { item in await handleArticleTap(item, autoPlay: false) },
                        onMarkRead: { markOne($0, asRead: true) },
                        onMarkUnread: { markOne($0, asRead: false) }
                    )
                } else {
                    ArticleListContent(
                        groups: groupedArticles,
                        allVisibleArticles: baseFilteredArticles,
                        filterMode: filterMode,
                        expandedTimestamps: viewModel.expandedTimestampsBySource[viewModel.allArticlesKey, default: Set<String>()],
                        viewModel: viewModel,
                        authManager: authManager,
                        showEnglish: isGlobalEnglishMode,
                        isSelectionMode: selection.isActive,
                        selectedIDs: selection.selected,
                        onToggleTimestamp: { timestamp in
                            viewModel.toggleTimestampExpansion(for: viewModel.allArticlesKey, timestamp: timestamp)
                        },
                        onPlayTimestamp: { timestamp in
                            if let firstItem = baseFilteredArticles.first(where: { $0.article.timestamp == timestamp }) {
                                Task { await handleArticleTap(firstItem, autoPlay: true) }
                            }
                        },
                        onArticleTap: { item in await handleArticleTap(item, autoPlay: false) },
                        onToggleSelect: { selection.toggle($0.id) },
                        onToggleGroupSelect: { group in selection.toggleGroup(group.map { $0.id }) },
                        onEnterSelection: { item in enterSelection(preselect: item.id) },
                        onMarkRead: { markOne($0, asRead: true) },
                        onMarkUnread: { markOne($0, asRead: false) }
                    )
                }
            }
            .listStyle(PlainListStyle())
            .environment(\.defaultMinListRowHeight, 0)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if selection.isActive {
            SelectionActionBar(
                selectedCount: selection.selected.count,
                totalCount: baseFilteredArticles.count,
                filterMode: filterMode,
                onSelectAll: { selection.selected = Set(baseFilteredArticles.map { $0.id }) },
                onClearAll: { selection.selected.removeAll() },
                onMarkRead: { applySelection(asRead: true) },
                onMarkUnread: { applySelection(asRead: false) },
                onCancel: { exitSelection() }
            )
        } else if !isSearchActive {
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    Text(getFilterTitle(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .onChange(of: filterMode) { _ in
                ONewsHaptics.selection()
                autoExpandGroups()
            }
        }
    }

    // MARK: - 多选处理
    private func enterSelection(preselect: UUID?) {
        undo.hide()
        selection.enter(preselect: preselect)
    }

    private func exitSelection() {
        selection.exit()
    }

    private func applySelection(asRead: Bool) {
        let ids = selection.selected
        guard !ids.isEmpty else { exitSelection(); return }
        let articles = baseFilteredArticles.filter { ids.contains($0.id) }.map { $0.article }
        guard !articles.isEmpty else { exitSelection(); return }

        ONewsHaptics.success()
        withAnimation(.easeInOut(duration: 0.28)) { viewModel.markArticles(articles, asRead: asRead) }
        exitSelection()

        let n = articles.count
        let msg = isGlobalEnglishMode
            ? "\(n) marked as \(asRead ? "read" : "unread")"
            : "已将 \(n) 篇标记为\(asRead ? "已读" : "未读")"
        undo.show(msg) {
            withAnimation(.easeInOut(duration: 0.28)) { viewModel.markArticles(articles, asRead: !asRead) }
        }
    }

    private func markOne(_ item: ArticleItem, asRead: Bool) {
        ONewsHaptics.light()
        let a = item.article
        // 直接更新状态，无需 withAnimation，原生 swipeActions 会平滑收起此行
        viewModel.markArticles([a], asRead: asRead)
        let msg = isGlobalEnglishMode
            ? (asRead ? "Marked as read" : "Marked as unread")
            : (asRead ? "已标记为已读" : "已标记为未读")
        undo.show(msg) {
            withAnimation(.easeInOut(duration: 0.25)) { viewModel.markArticles([a], asRead: !asRead) }
        }
    }

    private func handleArticleTap(_ item: ArticleItem, autoPlay: Bool = false) async {
        let article = item.article
        guard let sourceName = item.sourceName else { return }

        if !NewsPointsCoordinator.canAccess(article, auth: authManager, viewModel: viewModel) {
            NewsPointsCoordinator.shared.attemptUnlockArticle(article, auth: authManager, viewModel: viewModel) {
                Task { await self.handleArticleTap(item, autoPlay: autoPlay) }
            }
            return
        }

        AnonFreeReadTracker.note(article, auth: authManager, viewModel: viewModel)
        undo.hide()

        if !article.images.isEmpty {
            resourceManager.enqueueImageDownloads(timestamp: article.timestamp,
                                                  imageNames: article.images,
                                                  priority: true)
        }
        ArticleBodyCache.shared.prefetch(article: article)   // ★★★ 新增

        await MainActor.run {
            appNavPath?.wrappedValue.append(
                NavigationTarget.articleDetail(article, sourceName, "all", autoPlay))
        }
    }

    private func autoExpandGroups() {
        let key = viewModel.allArticlesKey
        let groupedArticles = Dictionary(grouping: baseFilteredArticles, by: { $0.article.timestamp })
        let sortedTimestamps = groupedArticles.keys.sorted(by: >)
        if authManager.isSubscribed {
            viewModel.expandedTimestampsBySource[key] = sortedTimestamps.first.map { [$0] } ?? []
        } else {
            if sortedTimestamps.count == 1, let s = sortedTimestamps.first {
                viewModel.expandedTimestampsBySource[key] = [s]
            } else {
                viewModel.expandedTimestampsBySource[key] = []
            }
        }
    }
}