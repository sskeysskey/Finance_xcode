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
        .background(Capsule().fill(Color(red: 0.18, green: 0.82, blue: 0.38).opacity(0.12)))
        .overlay(Capsule().stroke(Color(red: 0.18, green: 0.82, blue: 0.38).opacity(0.38), lineWidth: 0.6))
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

struct ArticleDateGroup: Identifiable {
    var id: String { timestamp }
    let timestamp: String
    let items: [ArticleItem]
}

// ==================== 日期格式化（按语言缓存，切换中英即时生效） ====================
@MainActor
enum ONewsDateText {
    private static var cache: [String: DateFormatter] = [:]
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd"
        return f
    }()

    static func string(_ timestamp: String, format: String, locale: Locale) -> String {
        guard let date = parser.date(from: timestamp) else { return timestamp }
        let key = format + "|" + locale.identifier
        let f: DateFormatter
        if let hit = cache[key] {
            f = hit
        } else {
            f = DateFormatter()
            f.locale = locale
            f.dateFormat = format
            cache[key] = f
        }
        return f.string(from: date)
    }
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
        guard isVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isVisible = false }
    }
}

/// 永不 publish 的持有者（同 ReaderAudioHolder 思路）：列表不因撤销条显隐而整页重算
@MainActor
final class ArticleUndoHolder: ObservableObject {
    let center = ArticleUndoCenter()
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

/// 只有这棵小子树观察撤销状态
private struct UndoSnackOverlay: View {
    @ObservedObject var center: ArticleUndoCenter
    let raised: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if center.isVisible {
                UndoSnackBar(message: center.message, onUndo: { center.performUndo() })
                    .padding(.bottom, raised ? 130 : 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// 只有这棵小子树观察 ResourceManager（它在图片下载期间高频 publish）
private struct NotificationBannerHost: View {
    @ObservedObject var resourceManager: ResourceManager

    var body: some View {
        if let message = resourceManager.activeNotification {
            NotificationBannerView(message: message) {
                resourceManager.dismissNotification()
            }
            .background(Color.viewBackground)
        }
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
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
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

                Button(action: onCancel) { Text(isEn ? "Cancel" : "取消") }
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

    private var displaySourceName: String? {
        guard let name = sourceName else { return nil }
        if showEnglish, let en = sourceNameEN, !en.isEmpty { return en }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let finalName = displaySourceName {
                    Text(finalName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(isReadEffective ? .secondary.opacity(0.7) : .blue.opacity(0.8))
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
        .transaction { $0.animation = nil }   // 中英切换时标题不做跨行插值动画
    }
}

// ==================== 行（Equatable：输入不变就跳过重算） ====================
private struct ArticleRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ArticleRowView: View, Equatable {
    let item: ArticleItem
    let isRead: Bool
    let isLocked: Bool
    let isFree: Bool
    let showEnglish: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let allowBulkMarks: Bool
    /// 批量标记可用性（列表按"显示顺序"算好；没有可标记目标时菜单项直接隐藏）
    let canMarkAbove: Bool
    let canMarkBelow: Bool
    let canMarkAboveInGroup: Bool
    let canMarkBelowInGroup: Bool

    let onTap: () -> Void
    let onToggleSelect: () -> Void
    let onEnterSelection: () -> Void
    let onToggleRead: () -> Void
    let onMarkAbove: () -> Void
    let onMarkBelow: () -> Void
    let onMarkAboveInGroup: () -> Void
    let onMarkBelowInGroup: () -> Void

    static func == (l: ArticleRowView, r: ArticleRowView) -> Bool {
        l.item.id == r.item.id
            && l.item.isContentMatch == r.item.isContentMatch
            && l.item.sourceName == r.item.sourceName
            && l.isRead == r.isRead
            && l.isLocked == r.isLocked
            && l.isFree == r.isFree
            && l.showEnglish == r.showEnglish
            && l.isSelectionMode == r.isSelectionMode
            && l.isSelected == r.isSelected
            && l.allowBulkMarks == r.allowBulkMarks
            && l.canMarkAbove == r.canMarkAbove
            && l.canMarkBelow == r.canMarkBelow
            && l.canMarkAboveInGroup == r.canMarkAboveInGroup
            && l.canMarkBelowInGroup == r.canMarkBelowInGroup
    }

    private var isEn: Bool { Localized.isEnglish }
    private var toggleTitle: String { isRead ? Localized.markAsUnread_text : Localized.markAsRead_text }

    var body: some View {
        Button(action: { isSelectionMode ? onToggleSelect() : onTap() }) {
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
                    isReadEffective: isRead,
                    isContentMatch: item.isContentMatch,
                    isLocked: isLocked,
                    isFree: isFree,
                    showEnglish: showEnglish
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ArticleRowPressStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSelectionMode {
                Button(action: onToggleRead) {
                    Label(toggleTitle, systemImage: isRead ? "envelope.badge.fill" : "checkmark.circle.fill")
                }
                .tint(isRead ? .orange : .blue)
            }
        }
        .contextMenu {
            if !isSelectionMode {
                Button(action: onToggleRead) {
                    Label(toggleTitle, systemImage: isRead ? "circle" : "checkmark.circle")
                }
                if !isRead && allowBulkMarks {
                    if canMarkAboveInGroup || canMarkBelowInGroup {
                        Section(isEn ? "This Day Only" : "仅本日分组") {
                            if canMarkAboveInGroup {
                                Button(action: onMarkAboveInGroup) {
                                    Label(isEn ? "Mark Above in This Day as Read" : "本日以上全部已读",
                                          systemImage: "arrow.up.to.line")
                                }
                            }
                            if canMarkBelowInGroup {
                                Button(action: onMarkBelowInGroup) {
                                    Label(isEn ? "Mark Below in This Day as Read" : "本日以下全部已读",
                                          systemImage: "arrow.down.to.line")
                                }
                            }
                        }
                    }
                    if canMarkAbove || canMarkBelow {
                        Section(isEn ? "Across All Days" : "跨日期分组") {
                            if canMarkAbove {
                                Button(action: onMarkAbove) {
                                    Label(Localized.readAbove, systemImage: "arrow.up.to.line.compact")
                                }
                            }
                            if canMarkBelow {
                                Button(action: onMarkBelow) {
                                    Label(Localized.readBelow, systemImage: "arrow.down.to.line.compact")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(action: onEnterSelection) {
                    Label(isEn ? "Select Articles…" : "选择文章…",
                          systemImage: "checkmark.circle.badge.questionmark")
                }
            }
        }
        .accessibilityAction(named: Text(toggleTitle), onToggleRead)
    }
}

// ==================== 日期分组头（★ 恢复为吸顶 Section header，带防"文字消失"保护） ====================
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

    private var groupIcon: String {
        switch groupState {
        case .none: return "circle"
        case .partial: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }

    private var toggleAnimation: Animation { .easeInOut(duration: 0.25) }

    var body: some View {
        card
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            // ★ 吸顶时遮住下方滚动内容；纯色而非毛玻璃（实时模糊每帧都很贵）
            .background(Color.viewBackground)
            // ★ plain List 的 header 默认会把文字转大写（英文日期会变 "JAN 5"）
            .textCase(nil)
            // ★ 核心防护：header 内任何文字 / 颜色变化都不做插值动画。
            //   复用的 header 视图若在淡入淡出途中被回收，文字会卡在 opacity 0 → "标题消失"。
            .transaction { $0.animation = nil }
    }

    private var card: some View {
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

            Text(ONewsDateText.string(timestamp, format: Localized.dateFormatShort, locale: Localized.currentLocale))
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(isExpanded ? .blue : .primary.opacity(0.85))
                .padding(.leading, 12)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            if isFree && !isLocked {
                FreeTagView(compact: true).padding(.leading, 8)
            }

            Spacer(minLength: 8)

            if count > 0 && !isSelectionMode {
                Button(action: onPlay) {
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
                    Button(action: { withAnimation(toggleAnimation) { onToggle() } }) {
                        chevron(opacity: 0.6).padding(4).contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    chevron(opacity: 0.5)
                }
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleGroupSelect()
            } else {
                withAnimation(toggleAnimation) { onToggle() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// ★ 只有箭头旋转保留动画（纯几何变换，无文字淡入淡出风险）
    private func chevron(opacity: Double) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.secondary.opacity(opacity))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(toggleAnimation, value: isExpanded)
    }
}

// ==================== 搜索分组头（★ 同样吸顶 + 同样防护） ====================
struct SearchGroupHeader: View {
    let timestamp: String
    let count: Int
    let isLocked: Bool
    let isFree: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Localized.searchResults)
                .font(.subheadline)
                .foregroundColor(.blue.opacity(0.7))
            HStack(spacing: 6) {
                Text("\(ONewsDateText.string(timestamp, format: Localized.dateFormatFull, locale: Localized.currentLocale)) (\(count))")
                    .font(.headline)
                    .foregroundColor(.blue.opacity(0.85))
                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.yellow.opacity(0.8))
                        .font(.footnote)
                } else if isFree {
                    FreeTagView(compact: true)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.viewBackground)
        .textCase(nil)
        .transaction { $0.animation = nil }
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

// ============================================================================
// MARK: - 统一列表页（单源 / 全部 共用）
// ============================================================================
enum ArticleListScope: Equatable {
    case source(String)
    case all
}

struct ArticleListScreen: View {
    let scope: ArticleListScope
    @ObservedObject var viewModel: NewsViewModel
    /// ★ 不观察：只用来调方法 / 交给 NotificationBannerHost 局部观察
    let resourceManager: ResourceManager

    @EnvironmentObject var authManager: AuthManager
    @AppStorage("isGlobalEnglishMode") private var isGlobalEnglishMode = false
    @AppStorage(ArticleSortPrefs.groupNewestFirstKey) private var groupNewestFirst = true
    @AppStorage(ArticleSortPrefs.itemNewestFirstKey) private var itemNewestFirst = true
    @Environment(\.appNavPath) private var appNavPath

    @State private var filterMode: ArticleFilterMode = .unread
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var searchHits: [ArticleItem] = []
    @State private var showProfileSheet = false
    @State private var hasPerformedAutoExpansion = false

    /// ★ 吸顶 header 的"自愈纪元"
    @State private var headerEpoch = 0

    @StateObject private var selection = ArticleSelectionModel()
    @StateObject private var undoHolder = ArticleUndoHolder()
    private var undo: ArticleUndoCenter { undoHolder.center }

    // MARK: 一次成型的数据快照
    private struct Snapshot {
        var sourceAvailable = true
        /// 基础顺序（日期降序 + 发布时间降序）的可见文章
        var visible: [ArticleItem] = []
        /// 按用户偏好排列的分组
        var groups: [ArticleDateGroup] = []
        /// ★ 显示顺序（groups 拍平）——"以上 / 以下"按它计算
        var ordered: [ArticleItem] = []
        var unreadCount = 0
        var readCount = 0

        var groupSignature: String {
            groups.map { "\($0.timestamp):\($0.items.count)" }.joined(separator: ",")
        }
    }

    private struct RowMarks {
        var above = false
        var below = false
        var aboveInGroup = false
        var belowInGroup = false
        static let none = RowMarks()
    }

    private var expansionKey: String {
        switch scope {
        case .source(let n): return n
        case .all: return viewModel.allArticlesKey
        }
    }

    private var currentSource: NewsSource? {
        guard case .source(let n) = scope else { return nil }
        return viewModel.sources.first { $0.name == n }
    }

    private var navTitle: String {
        switch scope {
        case .all: return ""
        case .source(let n):
            guard let s = currentSource else { return n.replacingOccurrences(of: "_", with: " ") }
            return (isGlobalEnglishMode ? s.name_en : s.name).replacingOccurrences(of: "_", with: " ")
        }
    }

    private func makeGroups(_ items: [ArticleItem]) -> [ArticleDateGroup] {
        ArticleSortPrefs.group(items, day: { $0.article.timestamp },
                               groupNewestFirst: groupNewestFirst,
                               itemNewestFirst: itemNewestFirst)
            .map { ArticleDateGroup(timestamp: $0.day, items: $0.items) }
    }

    private func makeSnapshot() -> Snapshot {
        var snap = Snapshot()
        let wantRead = (filterMode == .read)

        switch scope {
        case .source:
            guard let s = currentSource else { snap.sourceAvailable = false; return snap }
            snap.visible.reserveCapacity(s.articles.count)
            for a in s.articles {
                let r = viewModel.isArticleEffectivelyRead(a)
                if r { snap.readCount += 1 } else { snap.unreadCount += 1 }
                if r == wantRead { snap.visible.append(ArticleItem(article: a)) }
            }
        case .all:
            let all = viewModel.allArticlesSortedForDisplay
            snap.visible.reserveCapacity(all.count)
            for it in all {
                let r = viewModel.isArticleEffectivelyRead(it.article)
                if r { snap.readCount += 1 } else { snap.unreadCount += 1 }
                if r == wantRead {
                    snap.visible.append(ArticleItem(article: it.article,
                                                    sourceName: it.sourceName,
                                                    sourceNameEN: it.sourceNameEN))
                }
            }
        }

        // ★ 已读 / 未读统一规则（不再对已读列表做组内反转）
        snap.groups = makeGroups(snap.visible)
        snap.ordered = snap.groups.flatMap(\.items)
        return snap
    }

    // MARK: Body
    var body: some View {
        let snap = makeSnapshot()

        Group {
            if snap.sourceAvailable {
                mainContent(snap)
            } else {
                VStack { Text(Localized.sourceUnavailable).foregroundColor(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.viewBackground.ignoresSafeArea())
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showProfileSheet) { UserProfileView() }
        .onAppear {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { viewModel.finishReadingIfNeeded() }

            if !hasPerformedAutoExpansion {
                autoExpandGroups(); hasPerformedAutoExpansion = true
            }
            scheduleHeaderRefresh(after: 0.45)

            let reason = (scope == .all) ? "all-list-appear" : "source-list-appear"
            Task { await resourceManager.silentRefresh(minInterval: 60, reason: reason) }
        }
        .onChange(of: snap.groupSignature) { _, _ in
            scheduleHeaderRefresh(after: 0.4)
        }
        .onChange(of: filterMode) { _, _ in
            ONewsHaptics.selection()
            autoExpandGroups()
        }
        .onChange(of: groupNewestFirst) { _, _ in
            autoExpandGroups()            // 顶部分组变了 → 重新决定默认展开
            scheduleHeaderRefresh(after: 0.1)
        }
        .onChange(of: itemNewestFirst) { _, _ in
            scheduleHeaderRefresh(after: 0.1)
        }
        .onChange(of: viewModel.allArticlesSortedForDisplay.count) { _, _ in
            if isSearchActive { runSearch() }
        }
        .onChange(of: authManager.isLoggedIn) { _, newValue in
            if newValue {
                Task {
                    await NewsQuotaManager.shared.refresh(
                        userId: NewsQuotaManager.currentUserId(auth: authManager))
                }
            }
        }
    }

    private func mainContent(_ snap: Snapshot) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isSearching && !selection.isActive {
                    SearchBarInline(
                        text: $searchText,
                        placeholder: Localized.searchPlaceholder,
                        onCommit: { runSearch() },
                        onCancel: { withAnimation { closeSearch() } }
                    )
                }

                NotificationBannerHost(resourceManager: resourceManager)

                listArea(snap)

                bottomBar(snap)
            }
            .background(Color.viewBackground.ignoresSafeArea())

            UndoSnackOverlay(center: undo, raised: selection.isActive)
                .zIndex(60)
        }
    }

    // MARK: 列表
    @ViewBuilder
    private func listArea(_ snap: Snapshot) -> some View {
        if isSearchActive {
            List { searchRows }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .environment(\.defaultMinListHeaderHeight, 0)
        } else if snap.visible.isEmpty {
            EmptyStateView(filterMode: filterMode)
        } else {
            List { groupRows(snap) }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .environment(\.defaultMinListHeaderHeight, 0)
        }
    }

    @ViewBuilder
    private func groupRows(_ snap: Snapshot) -> some View {
        let expanded = viewModel.expandedTimestampsBySource[expansionKey, default: Set<String>()]
        let inSelection = selection.isActive
        let selected = selection.selected
        let isReadList = (filterMode == .read)
        let epoch = headerEpoch
        let firstID = snap.ordered.first?.id
        let lastID = snap.ordered.last?.id

        ForEach(snap.groups) { group in
            let ts = group.timestamp
            let isExpanded = expanded.contains(ts)
            let ids = group.items.map(\.id)
            let gFirst = group.items.first?.id
            let gLast = group.items.last?.id
            let showLock = NewsPointsCoordinator.shouldShowLock(timestamp: ts, auth: authManager, viewModel: viewModel)
            let groupFree = NewsFreeBadge.isFree(timestamp: ts, auth: authManager, viewModel: viewModel)
            let groupLocked = showLock && (group.items.isEmpty || group.items.contains {
                !NewsPointsCoordinator.canAccess($0.article, auth: authManager, viewModel: viewModel)
            })

            Section {
                if isExpanded {
                    ForEach(group.items) { item in
                        let locked = showLock && !NewsPointsCoordinator.canAccess(item.article, auth: authManager, viewModel: viewModel)
                        row(item,
                            isRead: isReadList,
                            isLocked: locked,
                            isFree: !locked && groupFree,
                            inSelection: inSelection,
                            isSelected: selected.contains(item.id),
                            allowBulk: !isReadList,
                            marks: RowMarks(above: item.id != firstID,
                                            below: item.id != lastID,
                                            aboveInGroup: item.id != gFirst,
                                            belowInGroup: item.id != gLast))
                    }
                }
            } header: {
                TimestampHeader(
                    timestamp: ts,
                    count: group.items.count,
                    isExpanded: isExpanded,
                    isLocked: groupLocked,
                    isFree: groupFree,
                    isSelectionMode: inSelection,
                    groupState: selection.groupState(ids),
                    onToggle: { viewModel.toggleTimestampExpansion(for: expansionKey, timestamp: ts) },
                    onPlay: { playGroup(ts) },
                    onToggleGroupSelect: { selection.toggleGroup(ids) }
                )
                .id("\(ts)#\(epoch)")
                .listRowInsets(EdgeInsets())
            }
            .listSectionSeparator(.hidden)
        }
    }

    private var searchGroups: [ArticleDateGroup] { makeGroups(searchHits) }

    @ViewBuilder
    private var searchRows: some View {
        if searchHits.isEmpty {
            Text(Localized.noMatch)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            let epoch = headerEpoch
            ForEach(searchGroups) { group in
                let ts = group.timestamp
                let showLock = NewsPointsCoordinator.shouldShowLock(timestamp: ts, auth: authManager, viewModel: viewModel)
                let groupFree = NewsFreeBadge.isFree(timestamp: ts, auth: authManager, viewModel: viewModel)
                let groupLocked = showLock && group.items.contains {
                    !NewsPointsCoordinator.canAccess($0.article, auth: authManager, viewModel: viewModel)
                }

                Section {
                    ForEach(group.items) { item in
                        let locked = showLock && !NewsPointsCoordinator.canAccess(item.article, auth: authManager, viewModel: viewModel)
                        row(item,
                            isRead: viewModel.isArticleEffectivelyRead(item.article),
                            isLocked: locked,
                            isFree: !locked && groupFree,
                            inSelection: false,
                            isSelected: false,
                            allowBulk: false)
                    }
                } header: {
                    SearchGroupHeader(timestamp: ts, count: group.items.count,
                                      isLocked: groupLocked, isFree: groupFree)
                        .id("search-\(ts)#\(epoch)")
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSeparator(.hidden)
            }
        }
    }

    private func row(_ item: ArticleItem, isRead: Bool, isLocked: Bool, isFree: Bool,
                     inSelection: Bool, isSelected: Bool, allowBulk: Bool,
                     marks: RowMarks = .none) -> some View {
        ArticleRowView(
            item: item,
            isRead: isRead,
            isLocked: isLocked,
            isFree: isFree,
            showEnglish: isGlobalEnglishMode,
            isSelectionMode: inSelection,
            isSelected: isSelected,
            allowBulkMarks: allowBulk,
            canMarkAbove: marks.above,
            canMarkBelow: marks.below,
            canMarkAboveInGroup: marks.aboveInGroup,
            canMarkBelowInGroup: marks.belowInGroup,
            onTap: { openArticle(item, autoPlay: false) },
            onToggleSelect: { selection.toggle(item.id) },
            onEnterSelection: { enterSelection(preselect: item.id) },
            onToggleRead: { markOne(item, asRead: !isRead) },
            onMarkAbove: { markAround(item, above: true, inGroup: false) },
            onMarkBelow: { markAround(item, above: false, inGroup: false) },
            onMarkAboveInGroup: { markAround(item, above: true, inGroup: true) },
            onMarkBelowInGroup: { markAround(item, above: false, inGroup: true) }
        )
        .equatable()
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: ★ header 自愈
    private func scheduleHeaderRefresh(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { headerEpoch &+= 1 }
        }
    }

    // MARK: 底部
    @ViewBuilder
    private func bottomBar(_ snap: Snapshot) -> some View {
        if selection.isActive {
            SelectionActionBar(
                selectedCount: selection.selected.count,
                totalCount: snap.visible.count,
                filterMode: filterMode,
                onSelectAll: { selection.selected = Set(snap.visible.map(\.id)) },
                onClearAll: { selection.selected.removeAll() },
                onMarkRead: { applySelection(asRead: true) },
                onMarkUnread: { applySelection(asRead: false) },
                onCancel: { selection.exit() }
            )
        } else if !isSearchActive {
            Picker("Filter", selection: $filterMode) {
                ForEach(ArticleFilterMode.allCases, id: \.self) { mode in
                    Text("\(mode.localizedName) (\(mode == .unread ? snap.unreadCount : snap.readCount))").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    // MARK: 工具栏
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                            if isSearching { closeSearch() } else { isSearching = true }
                        }
                    }
                )
            }
        }
    }

    // MARK: 搜索
    private func runSearch() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { isSearchActive = false; searchHits = []; return }

        let pool: [ArticleItem]
        switch scope {
        case .source:
            pool = (currentSource?.articles ?? []).map { ArticleItem(article: $0) }
        case .all:
            pool = viewModel.allArticlesSortedForDisplay.map {
                ArticleItem(article: $0.article, sourceName: $0.sourceName, sourceNameEN: $0.sourceNameEN)
            }
        }

        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func hit(_ s: String?) -> Bool {
            guard let s = s, !s.isEmpty else { return false }
            return s.range(of: kw, options: opts) != nil
        }

        searchHits = pool.compactMap { item in
            let a = item.article
            if hit(a.topic) || hit(a.topic_eng) {
                return ArticleItem(article: a, sourceName: item.sourceName,
                                   sourceNameEN: item.sourceNameEN, isContentMatch: false)
            }
            if hit(a.article) || hit(a.article_eng) {
                return ArticleItem(article: a, sourceName: item.sourceName,
                                   sourceNameEN: item.sourceNameEN, isContentMatch: true)
            }
            return nil
        }
        isSearchActive = true
    }

    private func closeSearch() {
        isSearching = false
        isSearchActive = false
        searchText = ""
        searchHits = []
    }

    // MARK: 多选
    private func enterSelection(preselect: UUID?) {
        undo.hide()
        selection.enter(preselect: preselect)
    }

    private func applySelection(asRead: Bool) {
        let ids = selection.selected
        guard !ids.isEmpty else { selection.exit(); return }
        let articles = makeSnapshot().visible.filter { ids.contains($0.id) }.map(\.article)
        guard !articles.isEmpty else { selection.exit(); return }

        ONewsHaptics.success()
        withAnimation(.easeInOut(duration: 0.28)) { viewModel.markArticles(articles, asRead: asRead) }
        selection.exit()

        let n = articles.count
        let msg = isGlobalEnglishMode
            ? "\(n) marked as \(asRead ? "read" : "unread")"
            : "已将 \(n) 篇标记为\(asRead ? "已读" : "未读")"
        undo.show(msg) { [viewModel] in
            withAnimation(.easeInOut(duration: 0.28)) { viewModel.markArticles(articles, asRead: !asRead) }
        }
    }

    // MARK: 单篇 / 以上 / 以下
    private func markOne(_ item: ArticleItem, asRead: Bool) {
        ONewsHaptics.light()
        let a = item.article
        viewModel.markArticles([a], asRead: asRead)
        let msg = isGlobalEnglishMode
            ? (asRead ? "Marked as read" : "Marked as unread")
            : (asRead ? "已标记为已读" : "已标记为未读")
        undo.show(msg) { [viewModel] in
            withAnimation(.easeInOut(duration: 0.25)) { viewModel.markArticles([a], asRead: !asRead) }
        }
    }

    /// 调用时才读取最新快照；"以上 / 以下"严格按屏幕显示顺序
    /// - inGroup: true = 只在当前日期分组内；false = 跨所有日期分组（原功能）
    private func markAround(_ item: ArticleItem, above: Bool, inGroup: Bool) {
        let snap = makeSnapshot()
        let pool: [ArticleItem] = inGroup
            ? (snap.groups.first(where: { $0.timestamp == item.article.timestamp })?.items ?? [])
            : snap.ordered
        let list = pool.map(\.article)
        guard let pivot = list.firstIndex(where: { $0.id == item.id }) else { return }
        let targets: [Article] = above
            ? Array(list[..<pivot])
            : (pivot + 1 < list.count ? Array(list[(pivot + 1)...]) : [])
        guard !targets.isEmpty else { return }

        ONewsHaptics.success()
        withAnimation(.easeInOut(duration: 0.25)) { viewModel.markArticles(targets, asRead: true) }
        let n = targets.count
        let msg: String
        if inGroup {
            msg = isGlobalEnglishMode ? "\(n) in this day marked as read" : "已将本日 \(n) 篇标记为已读"
        } else {
            msg = isGlobalEnglishMode ? "\(n) marked as read" : "已将 \(n) 篇标记为已读"
        }
        undo.show(msg) { [viewModel] in
            withAnimation(.easeInOut(duration: 0.25)) { viewModel.markArticles(targets, asRead: false) }
        }
    }

    // MARK: 打开文章
    private func playGroup(_ timestamp: String) {
        // 按显示顺序取该组第一篇
        if let first = makeSnapshot().groups.first(where: { $0.timestamp == timestamp })?.items.first {
            openArticle(first, autoPlay: true)
        }
    }

    private func openArticle(_ item: ArticleItem, autoPlay: Bool) {
        let article = item.article
        let srcName: String
        let ctx: String
        switch scope {
        case .source(let n):
            srcName = n; ctx = "source"
        case .all:
            guard let n = item.sourceName else { return }
            srcName = n; ctx = "all"
        }

        if !NewsPointsCoordinator.canAccess(article, auth: authManager, viewModel: viewModel) {
            NewsPointsCoordinator.shared.attemptUnlockArticle(article, auth: authManager, viewModel: viewModel) {
                Task { @MainActor in self.openArticle(item, autoPlay: autoPlay) }
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
        ArticleBodyCache.shared.prefetch(article: article)

        appNavPath?.wrappedValue.append(NavigationTarget.articleDetail(article, srcName, ctx, autoPlay))
    }

    // MARK: 自动展开（展开"屏幕最上方"的分组；值不变不写）
    private func autoExpandGroups() {
        let ts = makeSnapshot().groups.map(\.timestamp)
        let value: Set<String>
        if authManager.isSubscribed {
            value = ts.first.map { [$0] } ?? []
        } else {
            value = ts.count == 1 ? [ts[0]] : []
        }
        if viewModel.expandedTimestampsBySource[expansionKey] != value {
            viewModel.expandedTimestampsBySource[expansionKey] = value
        }
    }
}

// ==================== 对外入口（签名保持不变，Source_List 无需改动） ====================
struct ArticleListView: View {
    let sourceName: String
    let viewModel: NewsViewModel
    let resourceManager: ResourceManager

    var body: some View {
        ArticleListScreen(scope: .source(sourceName), viewModel: viewModel, resourceManager: resourceManager)
    }
}

struct AllArticlesListView: View {
    let viewModel: NewsViewModel
    let resourceManager: ResourceManager

    var body: some View {
        ArticleListScreen(scope: .all, viewModel: viewModel, resourceManager: resourceManager)
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

            Button(action: onEnterSelection) { Image(systemName: "checklist") }
                .accessibilityLabel(isGlobalEnglishMode ? "Select" : "选择文章")

            Button(action: onToggleSearch) { Image(systemName: "magnifyingglass") }
                .accessibilityLabel(Localized.search)
        }
        .foregroundColor(.primary)
    }
}