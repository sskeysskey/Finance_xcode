import SwiftUI
import UserNotifications
import Combine

// 文件名: WelcomeView.swift
// 职责: 作为应用的首次启动欢迎界面，引导用户添加新闻源。

struct WelcomeView: View {
    // 当用户完成操作后，调用此闭包通知父视图
    var onComplete: () -> Void
    
    // ==================== 核心修改: 引入状态和管理器 ====================
    @StateObject private var resourceManager = ResourceManager()
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    // ===============================================================
    
    @State private var showAddSourceView = false
    @State private var ripple = false

    var body: some View {
        // ==================== 核心修改: 添加顶层 ZStack 以便显示覆盖层 ====================
        ZStack {
            NavigationView {
                ZStack {
                    // 背景图
                    Image("welcome_background")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(Color.black.opacity(0.4))

                    VStack {
                        Spacer()
                        
                        Text("欢迎使用 ONews")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.bottom, 20)

                        Text("点击下方按钮，开始添加您感兴趣的新闻源")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))

                        Spacer()
                        
                        VStack(spacing: 8) {
                            Text("点击这里开始")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue)
                                .cornerRadius(8)
                            
                            Image(systemName: "arrow.down")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        .offset(y: -20)
                        
                        Button(action: {
                            showAddSourceView = true
                        }) {
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(ripple ? 0 : 0.8), lineWidth: 2)
                                    .scaleEffect(ripple ? 1.8 : 1.0)
                                    .opacity(ripple ? 0 : 1)
                                
                                Image(systemName: "plus")
                                    .font(.system(size: 44, weight: .light))
                                    .foregroundColor(.white)
                                    .padding(30)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .shadow(radius: 10)
                            }
                        }
                        .onAppear {
                            withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                                ripple.toggle()
                            }
                        }
                        .padding(.bottom, 60)
                    }
                    
                    NavigationLink(
                        destination: AddSourceView(isFirstTimeSetup: true, onComplete: onComplete),
                        isActive: $showAddSourceView
                    ) {
                        EmptyView()
                    }
                }
                .navigationBarHidden(true)
            }
            .accentColor(.white)
            .onAppear {
                // ==================== 核心修改: 自动触发轻量级同步 ====================
                Task {
                    await syncInitialResources()
                }
                // =====================================================================
            }
            .alert("", isPresented: $showErrorAlert, actions: {
                Button("好的", role: .cancel) { }
            }, message: {
                Text(errorMessage)
            })

            // ==================== 核心修改: 添加手动刷新按钮 ====================
            if !resourceManager.isSyncing && !showAddSourceView {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            Task {
                                await syncInitialResources()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.3))
                                .clipShape(Circle())
                        }
                        .padding(.top, 50)
                        .padding(.trailing, 20)
                    }
                    Spacer()
                }
            }
            // =====================================================================

            // ==================== 核心修改: 添加同步加载覆盖层 ====================
            if resourceManager.isSyncing {
                VStack(spacing: 15) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    
                    Text(resourceManager.syncMessage)
                        .padding(.top, 10)
                        .foregroundColor(.white)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.7))
                .edgesIgnoringSafeArea(.all)
                .contentShape(Rectangle()) // 阻止底层交互
            }
            // =====================================================================
        }
    }
    
    // ==================== 核心修改: 封装同步逻辑 ====================
    private func syncInitialResources() async {
        do {
            // 调用我们新增的轻量级同步方法
            try await resourceManager.checkAndDownloadLatestNewsManifest()
        } catch {
            // 处理网络错误等，并显示弹窗
            self.errorMessage = "下载新闻数据失败，请点击右上角刷新↻按钮。"
//            self.errorMessage = "下载新闻数据失败，请点击右上角刷新↻按钮\n(\(error.localizedDescription))"
            self.showErrorAlert = true
            print("WelcomeView 同步失败: \(error)")
        }
    }
    // ===============================================================
}


extension Color {
    static let viewBackground = Color(red: 28/255, green: 28/255, blue: 30/255)
}

@main
struct NewsReaderAppApp: App {
    var body: some Scene {
        WindowGroup {
            MainAppView()
        }
    }
}

struct MainAppView: View {
    @AppStorage("hasCompletedInitialSetup") private var hasCompletedInitialSetup = false
    
    @State private var isAuthenticated = false

    var body: some View {
        if hasCompletedInitialSetup {
            if isAuthenticated {
                SourceListView(isAuthenticated: $isAuthenticated)
            } else {
                 SourceListView(isAuthenticated: $isAuthenticated)
            }
        } else {
            WelcomeView {
                self.hasCompletedInitialSetup = true
            }
        }
    }
}


class NewsViewModel: ObservableObject {
    @Published var sources: [NewsSource] = []

    private let subscriptionManager = SubscriptionManager.shared
    
    private let readKey = "readTopics"
    private var readRecords: [String: Date] = [:]

    var badgeUpdater: ((Int) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var allArticlesSortedForDisplay: [(article: Article, sourceName: String)] {
        let flatList = self.sources.flatMap { source in
            source.articles.map { (article: $0, sourceName: source.name) }
        }
        
        return flatList.sorted { item1, item2 in
            if item1.article.timestamp != item2.article.timestamp {
                return item1.article.timestamp < item2.article.timestamp
            }
            return item1.article.topic < item2.article.topic
        }
    }

    init() {
        loadReadRecords()
        $sources
            .map { sources in
                sources.flatMap { $0.articles }.filter { !$0.isRead }.count
            }
            .removeDuplicates()
            .sink { [weak self] unreadCount in
                print("检测到未读数变化，准备更新角标: \(unreadCount)")
                self?.badgeUpdater?(unreadCount)
            }
            .store(in: &cancellables)
    }

    private func loadReadRecords() {
        self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }

    func loadNews() {
        let subscribed = subscriptionManager.subscribedSources
        if subscribed.isEmpty {
            print("没有订阅任何新闻源。列表将为空。")
            DispatchQueue.main.async {
                self.sources = []
            }
            return
        }
        print("开始加载新闻，订阅源为: \(subscribed)")
        
        guard let allFileURLs = try? FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil) else {
            print("无法读取 Documents 目录。")
            return
        }
        
        let newsJSONURLs = allFileURLs.filter {
            $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json"
        }
        
        guard !newsJSONURLs.isEmpty else {
            print("错误：在 Documents 目录中没有找到任何 'onews_*.json' 文件。请先同步资源。")
            return
        }

        var allArticlesBySource = [String: [Article]]()
        let decoder = JSONDecoder()

        for url in newsJSONURLs {
            let fileName = url.deletingPathExtension().lastPathComponent
            guard let timestamp = fileName.components(separatedBy: "_").last, !timestamp.isEmpty else {
                continue
            }
            
            guard let data = try? Data(contentsOf: url) else {
                continue
            }
            
            guard let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                continue
            }
            
            for (sourceName, articles) in decoded {
                guard subscribed.contains(sourceName) else { continue }
                
                let articlesWithTimestamp = articles.map { article -> Article in
                    var mutableArticle = article
                    mutableArticle.timestamp = timestamp
                    return mutableArticle
                }
                allArticlesBySource[sourceName, default: []].append(contentsOf: articlesWithTimestamp)
            }
        }
        
        var tempSources = allArticlesBySource.map { sourceName, articles -> NewsSource in
            let sortedArticles = articles.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.topic < $1.topic
            }
            return NewsSource(name: sourceName, articles: sortedArticles)
        }
        .sorted { $0.name < $1.name }

        for i in tempSources.indices {
            for j in tempSources[i].articles.indices {
                let article = tempSources[i].articles[j]
                if readRecords.keys.contains(article.topic) {
                    tempSources[i].articles[j].isRead = true
                }
            }
        }

        DispatchQueue.main.async {
            self.sources = tempSources
            print("新闻数据加载/刷新完成！共 \(self.sources.count) 个已订阅来源。")
        }
    }

    func markAsRead(articleID: UUID) {
        DispatchQueue.main.async {
            for i in self.sources.indices {
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    if !self.sources[i].articles[j].isRead {
                        self.sources[i].articles[j].isRead = true
                        let topic = self.sources[i].articles[j].topic
                        self.readRecords[topic] = Date()
                        self.saveReadRecords()
                    }
                    return
                }
            }
        }
    }

    func markAsUnread(articleID: UUID) {
        DispatchQueue.main.async {
            for i in self.sources.indices {
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    if self.sources[i].articles[j].isRead {
                        self.sources[i].articles[j].isRead = false
                        let topic = self.sources[i].articles[j].topic
                        self.readRecords.removeValue(forKey: topic)
                        self.saveReadRecords()
                    }
                    return
                }
            }
        }
    }

    func markAllAboveAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        DispatchQueue.main.async {
            guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
            guard pivotIndex > 0 else { return }
            let articlesAbove = visibleArticles[0..<pivotIndex]
            for article in articlesAbove where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }

    func markAllBelowAsRead(articleID: UUID, inVisibleList visibleArticles: [Article]) {
        DispatchQueue.main.async {
            guard let pivotIndex = visibleArticles.firstIndex(where: { $0.id == articleID }) else { return }
            guard pivotIndex < visibleArticles.count - 1 else { return }
            let articlesBelow = visibleArticles[(pivotIndex + 1)...]
            for article in articlesBelow where !article.isRead {
                self.markAsRead(articleID: article.id)
            }
        }
    }

    private func getArticleList(for sourceName: String?) -> [Article] {
        if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
            return source.articles
        } else {
            return self.allArticlesSortedForDisplay.map { $0.article }
        }
    }

    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }

    func findNextUnread(after id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        let list: [(article: Article, sourceName: String)]
        
        if let name = sourceName, let source = self.sources.first(where: { $0.name == name }) {
            list = source.articles
                .filter { !$0.isRead }
                .map { (article: $0, sourceName: name) }
        } else {
            list = self.allArticlesSortedForDisplay.filter { !$0.article.isRead }
        }
        
        guard !list.isEmpty else { return nil }
        
        guard let currentIndex = list.firstIndex(where: { $0.article.id == id }) else {
            return list.first
        }
        
        let nextIndex = (currentIndex + 1) % list.count
        return list[nextIndex]
    }

    func findPreviousUnread(before id: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        let list: [(article: Article, sourceName: String)]
        
        if let name = sourceName, let source = sources.first(where: { $0.name == name }) {
            list = source.articles
                .filter { !$0.isRead }
                .map { (article: $0, sourceName: name) }
        } else {
            list = self.allArticlesSortedForDisplay.filter { !$0.article.isRead }
        }
        
        guard !list.isEmpty else { return nil }
        
        if let currentIndex = list.firstIndex(where: { $0.article.id == id }), currentIndex > 0 {
            return list[currentIndex - 1]
        }
        
        return nil
    }
}


struct NewsSource: Identifiable {
    let id = UUID()
    let name: String
    var articles: [Article]

    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }
}

struct Article: Identifiable, Codable {
    var id = UUID()
    let topic: String
    let article: String
    let images: [String]

    var isRead: Bool = false
    var timestamp: String = ""

    enum CodingKeys: String, CodingKey {
        case topic, article, images
    }
}

@MainActor
class AppBadgeManager {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            if granted {
                print("用户已授予角标权限。")
            } else {
                print("用户未授予角标权限。")
            }
        }
    }

    func updateBadge(count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error = error {
                print("更新角标失败: \(error.localizedDescription)")
            } else {
                print("应用角标已更新为: \(count)")
            }
        }
    }
}
