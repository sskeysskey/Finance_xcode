import SwiftUI

@main
struct NewsReaderAppApp: App {
    var body: some Scene {
        WindowGroup {
            MainAppView()
        }
    }
}

struct MainAppView: View {
    // 使用 @State 来管理是否已认证的状态
    @State private var isAuthenticated = false

    var body: some View {
        if isAuthenticated {
            // 如果已认证，显示主新闻阅读器界面
            // fullScreenCover 会全屏展示，并允许用户通过下拉手势返回（如果需要）
            SourceListView(isAuthenticated: $isAuthenticated)
        } else {
            // 否则，显示一个简单的登录界面
//            LoginView(isAuthenticated: $isAuthenticated)
            SourceListView(isAuthenticated: $isAuthenticated)
        }
    }
}

// 登录界面
struct LoginView: View {
    // 使用 @Binding 来接收和修改父视图的 isAuthenticated 状态
    @Binding var isAuthenticated: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("登录/验证")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Button(action: {
                // 点击按钮时，将状态设置为 true，从而切换到主界面
                isAuthenticated = true
            }) {
                Text("登录")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(width: 200, height: 50)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
        }
    }
}

// ObservableObject 使得 SwiftUI 视图可以订阅它的变化
class NewsViewModel: ObservableObject {

    // 发布到 UI
    @Published var sources: [NewsSource] = []
    
    // ==================== 新增属性 ====================
    /// 追踪用户在详情页最后看到的那篇文章的ID
//    @Published var lastViewedArticleID: UUID? = nil
    // ===============================================

    // 存已读文章的 key（我们用 topic 作为唯一标识）
    private let readKey = "readTopics"

    // 内存缓存
//    private var readTopics: Set<String> = []
    private var readRecords: [String: Date] = [:] // <- 新代码
    
    init() {
        // 先把上次保存的读过的 topic 读出来
        loadReadRecords() // <- 方法名已更新
        // 然后加载 JSON 并标记已读
        loadNews()
    }

    private func loadReadRecords() {
        // 直接从 UserDefaults 读取字典
        self.readRecords = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Date] ?? [:]
    }

    private func saveReadRecords() {
        // 直接将字典保存到 UserDefaults
        UserDefaults.standard.set(self.readRecords, forKey: readKey)
    }

    func findNextArticle(after currentArticleID: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
            // 如果指定了来源名称，则只在该来源内查找
            if let sourceName = sourceName, let source = sources.first(where: { $0.name == sourceName }) {
                // 找到当前文章在来源文章列表中的索引
                if let currentIndex = source.articles.firstIndex(where: { $0.id == currentArticleID }) {
                    // 计算下一个索引
                    let nextIndex = currentIndex + 1
                    // 检查下一个索引是否有效
                    if nextIndex < source.articles.count {
                        // 返回下一篇文章和它的来源名称
                        return (article: source.articles[nextIndex], sourceName: source.name)
                    }
                }
            } else { // 否则，在所有文章中查找
                // 将所有文章平铺成一个列表，同时保留来源信息
                let allArticlesWithSource = sources.flatMap { source in
                    source.articles.map { article in (article: article, sourceName: source.name) }
                }
                
                // 找到当前文章在总列表中的索引
                if let currentIndex = allArticlesWithSource.firstIndex(where: { $0.article.id == currentArticleID }) {
                    // 计算下一个索引
                    let nextIndex = currentIndex + 1
                    // 检查下一个索引是否有效
                    if nextIndex < allArticlesWithSource.count {
                        // 返回下一篇文章和它的来源名称
                        return allArticlesWithSource[nextIndex]
                    }
                }
            }
            
            // 如果没有找到下一篇文章，返回 nil
            return nil
        }
    
    func findPreviousArticle(before currentArticleID: UUID, inSource sourceName: String?) -> (article: Article, sourceName: String)? {
        // 如果指定了来源名称，则只在该来源内查找
        if let sourceName = sourceName, let source = sources.first(where: { $0.name == sourceName }) {
            // 找到当前文章在来源文章列表中的索引
            if let currentIndex = source.articles.firstIndex(where: { $0.id == currentArticleID }) {
                // 计算上一个索引
                let prevIndex = currentIndex - 1
                // 检查上一个索引是否有效 (必须大于等于0)
                if prevIndex >= 0 {
                    // 返回上一篇文章和它的来源名称
                    return (article: source.articles[prevIndex], sourceName: source.name)
                }
            }
        } else { // 否则，在所有文章中查找
            // 将所有文章平铺成一个列表，同时保留来源信息
            let allArticlesWithSource = sources.flatMap { source in
                source.articles.map { article in (article: article, sourceName: source.name) }
            }
            
            // 找到当前文章在总列表中的索引
            if let currentIndex = allArticlesWithSource.firstIndex(where: { $0.article.id == currentArticleID }) {
                // 计算上一个索引
                let prevIndex = currentIndex - 1
                // 检查上一个索引是否有效
                if prevIndex >= 0 {
                    // 返回上一篇文章和它的来源名称
                    return allArticlesWithSource[prevIndex]
                }
            }
        }
        
        // 如果没有找到上一篇文章，返回 nil
        return nil
    }
    
    func loadNews() {
        // 1. 从 bundle 里读 JSON（和你原来的一样）
        guard let url = Bundle.main.url(forResource: "onews", withExtension: "json") else {
            fatalError("无法在项目包中找到 onews.json")
        }
        guard let data = try? Data(contentsOf: url) else {
            fatalError("无法加载 onews.json")
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
            fatalError("解析 onews.json 失败")
        }

        // 2. 转成数组、排序
        var tmp = decoded.map { NewsSource(name: $0.key, articles: $0.value) }
                            .sorted { $0.name < $1.name }

        // 3. **根据 readTopics 标记 isRead**
        for i in tmp.indices {
            for j in tmp[i].articles.indices {
                let art = tmp[i].articles[j]
                if readRecords.keys.contains(art.topic) {
                   tmp[i].articles[j].isRead = true
               }
            }
        }

        // 4. 发布出去
        DispatchQueue.main.async {
            self.sources = tmp
        }
    }

    /// 用户阅读完文章后调用
    func markAsRead(articleID: UUID) {
        DispatchQueue.main.async {
            for i in self.sources.indices {
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    if !self.sources[i].articles[j].isRead {
                        // 1. 内存里标记
                        self.sources[i].articles[j].isRead = true
                        // 2. 把 topic 存到 Set 并写入 UserDefaults
                        let topic = self.sources[i].articles[j].topic
                        self.readRecords[topic] = Date() // 存入当前时间
                        self.saveReadRecords() // 保存更新后的字典
                    }
                    return
                }
            }
        }
    }

    // ==================== 新增方法 ====================
    /// 将指定文章标记为未读
    func markAsUnread(articleID: UUID) {
        // 确保在主线程上执行，因为这会改变 @Published 属性，从而更新UI
        DispatchQueue.main.async {
            // 遍历所有来源，找到对应的文章
            for i in self.sources.indices {
                if let j = self.sources[i].articles.firstIndex(where: { $0.id == articleID }) {
                    // 只有当文章当前是已读状态时才需要处理
                    if self.sources[i].articles[j].isRead {
                        // 1. 在内存中将文章的 isRead 状态设置为 false
                        self.sources[i].articles[j].isRead = false
                        
                        // 2. 从已读主题集合中移除该文章的 topic
                        let topic = self.sources[i].articles[j].topic
                        self.readRecords.removeValue(forKey: topic)
                        self.saveReadRecords()
                    }
                    // 找到并处理后即可退出循环
                    return
                }
            }
        }
    }
    // =================================================

    /// 计算总未读数
    var totalUnreadCount: Int {
        sources.flatMap { $0.articles }.filter { !$0.isRead }.count
    }
}

// 在 NewsViewModel 扩展中
extension NewsViewModel {

    // ==================== 修改后的函数 ====================
    func findNextUnread(after id: UUID,
                        inSource sourceName: String?)
        -> (article: Article, sourceName: String)?
    {
        // 步骤 1: 根据 sourceName 确定要搜索的范围
        let relevantSources: [NewsSource]
        if let name = sourceName {
            // 如果指定了来源，则只在该来源中查找
            relevantSources = self.sources.filter { $0.name == name }
        } else {
            // 如果未指定来源，则在所有来源中查找
            relevantSources = self.sources
        }

        // 步骤 2: 从相关范围中构建一个平铺的、只包含未读文章的列表
        let unreadArticles = relevantSources.flatMap { source -> [(article: Article, sourceName: String)] in
            source.articles
                .filter { !$0.isRead }
                .map { article in (article: article, sourceName: source.name) }
        }

        // 步骤 3: 处理边界情况和查找当前索引
        // 如果没有未读文章，或者只有一篇（循环无意义但逻辑依然成立），则提前处理
        guard !unreadArticles.isEmpty else {
            return nil
        }
        
        // 找到当前文章在 *未读列表* 中的索引
        guard let currentIndex = unreadArticles.firstIndex(where: { $0.article.id == id }) else {
            // 如果当前文章不在未读列表中（可能刚刚被标记为已读），
            // 作为备用方案，我们可以返回第一篇未读文章。
            return unreadArticles.first
        }

        // 步骤 4: 使用模运算 (%) 实现循环逻辑
        // (currentIndex + 1) 会得到下一个索引。
        // % unreadArticles.count 确保当索引越界时，能回到列表的开头 (例如: 5 % 5 = 0)。
        let nextIndex = (currentIndex + 1) % unreadArticles.count
        
        return unreadArticles[nextIndex]
    }
    // =====================================================

    // findPreviousUnread 函数保持不变，除非您也想让它循环
    func findPreviousUnread(before id: UUID,
                            inSource sourceName: String?)
        -> (article: Article, sourceName: String)?
    {
        // (此函数代码保持不变)
        let list: [(Article, String)]
        if let sourceName = sourceName, let source = sources.first(where: { $0.name == sourceName }) {
            list = source.articles.filter { !$0.isRead }.map { ($0, source.name) }
        } else {
            list = sources.flatMap { src in
                src.articles.filter { !$0.isRead }.map { ($0, src.name) }
            }
        }

        if let idx = list.firstIndex(where: { $0.0.id == id }), idx > 0 {
            return list[idx-1]
        }
        return nil
    }
}

// 用于UI展示的新闻来源结构体
// Identifiable 协议让它可以在 SwiftUI 的 List 中直接使用
struct NewsSource: Identifiable {
    let id = UUID() // 唯一标识符
    let name: String
    var articles: [Article]
    
    // 添加一个计算属性，用于动态计算未读文章的数量
    // 它会过滤出 articles 数组中 isRead 为 false 的文章，并返回其数量
    var unreadCount: Int {
        articles.filter { !$0.isRead }.count
    }
}

// 文章的结构体
// Identifiable 和 Codable 协议
struct Article: Identifiable, Codable {
    var id = UUID() // 为每个文章实例生成唯一ID
    let topic: String
    let article: String
    let images: [String]
    
    // `isRead` 状态不在JSON中，所以我们自定义解码过程
    var isRead: Bool = false

    // 定义JSON中的键，这样解码器就知道要解析哪些字段
    enum CodingKeys: String, CodingKey {
        case topic, article, images
    }
}
