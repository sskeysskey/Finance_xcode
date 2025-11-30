import SwiftUI
import Foundation

// 文件名: Source_Add.swift
// 职责: 提供一个列表，让用户能够添加或移除新闻源订阅（已取消搜索功能）。
// 职责: 集中管理用户的新闻源订阅列表，使用 UserDefaults 进行持久化存储。

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager() // 使用单例模式，方便全局访问

    // 【修改】Key 改名，明确存储的是 ID
    private let subscribedSourceIDsKey = "subscribedNewsSourceIDs"
    // 【兼容】保留旧 Key 用于迁移检查
    let oldSubscribedSourcesKey = "subscribedNewsSources"
    
    @Published var subscribedSourceIDs: Set<String> { // 【改为ID集合】
        didSet {
            saveSubscribedIDs()
            // print("订阅列表(ID)已更新并保存: \(subscribedSourceIDs)")
        }
    }

    private init() {
        let savedIDs = UserDefaults.standard.stringArray(forKey: subscribedSourceIDsKey) ?? []
        self.subscribedSourceIDs = Set(savedIDs)
    }

    private func saveSubscribedIDs() {
        UserDefaults.standard.set(Array(subscribedSourceIDs), forKey: subscribedSourceIDsKey)
    }

    // MARK: - 公共方法

    /// 根据 source_id 判断是否订阅
    func isSubscribed(sourceId: String) -> Bool {
        return subscribedSourceIDs.contains(sourceId)
    }

    func addSubscription(sourceId: String) {
        subscribedSourceIDs.insert(sourceId)
    }

    func removeSubscription(sourceId: String) {
        subscribedSourceIDs.remove(sourceId)
    }
    
    func subscribeToAll(_ sourceIds: [String]) {
        subscribedSourceIDs.formUnion(sourceIds)
    }
    
    /// 【新增】供外部调用的迁移方法：将旧的名称订阅转换为 ID 订阅
    func migrateOldSubscription(name: String, id: String) {
        // 读取旧的名称列表
        let oldNames = UserDefaults.standard.stringArray(forKey: oldSubscribedSourcesKey) ?? []
        if oldNames.contains(name) {
            print("迁移订阅: 发现旧名称订阅 [\(name)]，自动映射为 ID [\(id)]")
            addSubscription(sourceId: id)
        }
    }
}

struct AddSourceView: View {
    // 状态：存储 (ID, Name) 元组
    @State private var allAvailableSources: [(id: String, name: String)] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // 订阅管理器
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    // 【新增】接收 ResourceManager 以获取 mappings
    @EnvironmentObject var resourceManager: ResourceManager 
    
    // 用于判断显示逻辑（首次设置 vs. 后续添加）
    let isFirstTimeSetup: Bool
    var onComplete: (() -> Void)? // 仅在首次设置时使用
    var onConfirm: (() -> Void)?  // 非首次场景点击“确定”的回调（默认关闭页面）

    @Environment(\.presentationMode) var presentationMode

    // MARK: - 新增计算属性
    /// 计算是否所有可用源都已被订阅，用于禁用“一键添加”按钮
    private var areAllSourcesSubscribed: Bool {
        let allIDs = Set(allAvailableSources.map { $0.id })
        return subscriptionManager.subscribedSourceIDs.isSuperset(of: allIDs)
    }

    var body: some View {
        ZStack {
            // 背景图与遮罩，和 WelcomeView 风格一致
            Image("welcome_background")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.4).ignoresSafeArea())

            // 主内容：当加载或出错时，展示覆盖层；正常时展示列表
            Group {
                if isLoading {
                    ProgressView("正在加载新闻源...")
                        .tint(.white)
                        .foregroundColor(.white)
                } else if let error = errorMessage {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .padding()
                            .foregroundColor(.white)
                    }
                } else {
                    // 使用 List 承载所有行，并把“确定”按钮放到列表底部的 Section 页脚
                    List {
                        // MARK: - [修改点 1] 将“一键添加”按钮移动到列表顶部
                        Section {
                            Button(action: {
                                let allIDs = allAvailableSources.map { $0.id }
                                subscriptionManager.subscribeToAll(allIDs)
                                handleConfirm()
                            }) {
                                // MARK: - [修改点 3] 优化按钮文本，使其更清晰地反映其行为
                                Text("一键添加所有新闻源")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(height: 50)
                                    .frame(maxWidth: .infinity)
                                    .background(areAllSourcesSubscribed ? Color.gray : Color.green)
                                    .cornerRadius(10)
                            }
                            .disabled(areAllSourcesSubscribed)
                            .animation(.easeInOut, value: areAllSourcesSubscribed)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 8) // 为按钮部分添加一些垂直间距

                        // 遍历源列表
                        ForEach(allAvailableSources, id: \.id) { source in
                            HStack {
                                Text(source.name) // 显示名称（如“华尔街日报”）
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Spacer()
                                
                                // 使用 ID 判断订阅状态
                                if subscriptionManager.isSubscribed(sourceId: source.id) {
                                    Text("已添加")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.trailing, 8)
                                    
                                    Button(action: {
                                        subscriptionManager.removeSubscription(sourceId: source.id)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.title2)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())

                                } else {
                                    Button(action: {
                                        subscriptionManager.addSubscription(sourceId: source.id)
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.title2)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                            }
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        
                        // 底部确定按钮：放在列表末尾
                        Section(footer:
                            VStack(spacing: 12) { // MARK: - 修改部分
                                // MARK: - 新增“一键添加所有来源”按钮
                                Button(action: {
                                    let allIDs = allAvailableSources.map { $0.id }
                                    subscriptionManager.subscribeToAll(allIDs)
                                    handleConfirm()
                                }) {
                                    Text("一键添加所有新闻源")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .frame(height: 50)
                                        .frame(maxWidth: .infinity)
                                        // 如果所有源都已添加，按钮变灰，否则为绿色
                                        .background(areAllSourcesSubscribed ? Color.gray : Color.green)
                                        .cornerRadius(10)
                                }
                                .disabled(areAllSourcesSubscribed) // 当所有源都已添加时禁用按钮
                                .animation(.easeInOut, value: areAllSourcesSubscribed) // 添加动画效果

                                // MARK: - 原有的“确定”按钮
                                Button(action: {
                                    handleConfirm()
                                }) {
                                    Text("确定")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .frame(height: 50)
                                        .frame(maxWidth: .infinity)
                                        .background(subscriptionManager.subscribedSourceIDs.isEmpty ? Color.gray : Color.blue)
                                        .cornerRadius(10)
                                }
                                .disabled(subscriptionManager.subscribedSourceIDs.isEmpty)
                                .animation(.easeInOut, value: subscriptionManager.subscribedSourceIDs.isEmpty)
                            }
                            .padding(.vertical, 16)
                        ) {
                            EmptyView()
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("添加新闻源")
        .navigationBarTitleDisplayMode(.inline)
        // 移除右上角“完成”按钮，保留默认返回按钮
        .onAppear(perform: loadAvailableSources)
    }
    
    private func handleConfirm() {
        if isFirstTimeSetup {
            onComplete?()
        } else {
            if let onConfirm {
                onConfirm()
            } else {
                presentationMode.wrappedValue.dismiss()
            }
        }
    }

    /// 从 Documents 中所有 onews_*.json 文件合并所有分组名（去重、排序）
    private func loadAvailableSources() {
        isLoading = true
        errorMessage = nil
        
        // 【修复】在进入后台线程前，先从 ResourceManager 获取映射表
        // 这样 mappings 变量就在闭包的作用域内了
        let mappings = resourceManager.sourceMappings
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let allFiles = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)

                // 找到所有 onews_*.json 文件
                let newsJSONURLs = allFiles
                    .filter { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
                
                guard !newsJSONURLs.isEmpty else {
                    throw NSError(domain: "AppError", code: 1, userInfo: [NSLocalizedDescriptionKey: "在 Documents 目录中没有找到任何 'onews_*.json' 文件。\n请先返回主页同步资源。"])
                }

                // 使用字典去重：Key 是 ID，Value 是 Name
                // 如果同一个 ID 对应多个 Name (比如不同日期的文件改名了)，我们取最新的那个（这里简化为取扫描到的最后一个）
                var sourceMap = [String: String]()
                let decoder = JSONDecoder()
                
                for url in newsJSONURLs {
                    guard let data = try? Data(contentsOf: url),
                          let decoded = try? decoder.decode([String: [Article]].self, from: data) else {
                        continue
                    }
                    
                    for (fileKeyName, articles) in decoded {
                        if let firstArticle = articles.first, let sourceId = firstArticle.source_id, !sourceId.isEmpty {
                            // 【核心修改】如果有映射，使用映射名；否则使用文件里的 Key
                            // 现在 mappings 变量已经存在了，不会报错
                            let displayName = mappings[sourceId] ?? fileKeyName
                            sourceMap[sourceId] = displayName
                        }
                    }
                }

                // 转换为数组并按名称排序
                let sortedSources = sourceMap.map { (id: $0.key, name: $0.value) }
                    .sorted { $0.name < $1.name }

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