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
        ZStack(alignment: .bottom) {
            Color.viewBackground.ignoresSafeArea()
            
            if isLoading {
                VStack {
                    ProgressView()
                    Text("正在获取最新源...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(allAvailableSources, id: \.id) { source in
                            HStack {
                                Text(source.name) // 显示名称（如“华尔街日报”）
                                    .fontWeight(.medium)
                                    // 【修改】文字颜色自适应
                                    .foregroundColor(.primary)

                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.spring()) {
                                        if subscriptionManager.isSubscribed(sourceId: source.id) {
                                            subscriptionManager.removeSubscription(sourceId: source.id)
                                        } else {
                                            subscriptionManager.addSubscription(sourceId: source.id)
                                        }
                                    }
                                }) {
                                    Image(systemName: subscriptionManager.isSubscribed(sourceId: source.id) ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.system(size: 22))
                                        .foregroundColor(subscriptionManager.isSubscribed(sourceId: source.id) ? .green : .blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("可用新闻源")
                    } footer: {
                        // 底部占位，防止列表被悬浮按钮遮挡
                        Spacer().frame(height: 100)
                    }
                }
                .listStyle(.insetGrouped)
            }
            
            // 悬浮底部 Action Bar
            if !isLoading && errorMessage == nil {
                VStack(spacing: 0) {
                    // 顶部添加一根微弱的分割线
                    Divider()
                    
                    VStack(spacing: 12) {
                        
                        // 【修改】让一键全选按钮变得非常醒目
                        if !areAllSourcesSubscribed {
                            Button(action: {
                                let allIDs = allAvailableSources.map { $0.id }
                                // 使用震动反馈增加交互感
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                
                                withAnimation(.spring()) {
                                    subscriptionManager.subscribeToAll(allIDs)
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.rectangle.stack.fill")
                                        .font(.system(size: 18))
                                    Text("一键添加所有 (\(allAvailableSources.count))")
                                        .fontWeight(.bold)
                                }
                                .font(.headline)
                                .foregroundColor(.white) // 白色文字
                                .frame(maxWidth: .infinity)
                                .frame(height: 54) // 稍微加高一点
                                .background(
                                    // 使用鲜艳的绿色渐变
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.green, Color.mint]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(16) // 更圆润的角
                                .shadow(color: Color.green.opacity(0.4), radius: 8, x: 0, y: 4) // 漂亮的绿色光晕阴影
                            }
                            .transition(.scale.combined(with: .opacity)) // 添加出现/消失动画
                        }
                        
                        // 完成设置按钮
                        Button(action: handleConfirm) {
                            Text(subscriptionManager.subscribedSourceIDs.isEmpty ? "请至少选择一个" : "完成设置")
                                .font(.headline)
                                .foregroundColor(subscriptionManager.subscribedSourceIDs.isEmpty ? .secondary : .white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(
                                    subscriptionManager.subscribedSourceIDs.isEmpty 
                                    ? Color.secondary.opacity(0.2) // 禁用状态
                                    : Color.blue // 启用状态
                                )
                                .cornerRadius(16)
                        }
                        .disabled(subscriptionManager.subscribedSourceIDs.isEmpty)
                    }
                    .padding(16)
                    .padding(.bottom, 10) // 适配全面屏底部
                    .background(
                        Material.regular // 使用更通透的毛玻璃背景
                    )
                }
                // 确保 Action Bar 始终在最上层
                .zIndex(2)
            }
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
