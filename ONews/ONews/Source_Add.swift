import SwiftUI
import Foundation

// 文件名: Source_Add.swift
// 职责: 提供一个列表，让用户能够添加或移除新闻源订阅（已取消搜索功能）。
// 职责: 集中管理用户的新闻源订阅列表，使用 UserDefaults 进行持久化存储。

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager() // 使用单例模式，方便全局访问

    private let subscribedSourcesKey = "subscribedNewsSources"
    
    @Published var subscribedSources: Set<String> {
        didSet {
            // 当订阅列表变化时，自动保存到 UserDefaults
            saveSubscribedSources()
            print("订阅列表已更新并保存: \(subscribedSources)")
        }
    }

    private init() {
        // 初始化时从 UserDefaults 加载已保存的订阅列表
        let savedSources = UserDefaults.standard.stringArray(forKey: subscribedSourcesKey) ?? []
        self.subscribedSources = Set(savedSources)
        print("SubscriptionManager 初始化，加载的订阅源: \(self.subscribedSources)")
    }

    /// 将当前的订阅列表（Set）转换为数组并保存到 UserDefaults
    private func saveSubscribedSources() {
        UserDefaults.standard.set(Array(self.subscribedSources), forKey: subscribedSourcesKey)
    }

    /// 检查某个新闻源是否已被订阅
    func isSubscribed(to sourceName: String) -> Bool {
        return subscribedSources.contains(sourceName)
    }

    /// 添加一个新闻源到订阅列表
    func addSubscription(_ sourceName: String) {
        subscribedSources.insert(sourceName)
    }

    /// 从订阅列表移除一个新闻源
    func removeSubscription(_ sourceName: String) {
        subscribedSources.remove(sourceName)
    }
    
    /// 切换某个新闻源的订阅状态
    func toggleSubscription(for sourceName: String) {
        if isSubscribed(to: sourceName) {
            removeSubscription(sourceName)
        } else {
            addSubscription(sourceName)
        }
    }
}

struct AddSourceView: View {
    // 状态
    @State private var allAvailableSources: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // 订阅管理器
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    
    // 用于判断显示逻辑（首次设置 vs. 后续添加）
    let isFirstTimeSetup: Bool
    var onComplete: (() -> Void)? // 仅在首次设置时使用
    var onConfirm: (() -> Void)?  // 非首次场景点击“确定”的回调（默认关闭页面）

    @Environment(\.presentationMode) var presentationMode

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
                        ForEach(allAvailableSources, id: \.self) { sourceName in
                            HStack {
                                Text(sourceName)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Spacer()
                                
                                if subscriptionManager.isSubscribed(to: sourceName) {
                                    Text("已添加")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.trailing, 8)
                                    
                                    Button(action: {
                                        subscriptionManager.removeSubscription(sourceName)
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.title2)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())

                                } else {
                                    Button(action: {
                                        subscriptionManager.addSubscription(sourceName)
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
                            VStack {
                                Button(action: {
                                    handleConfirm()
                                }) {
                                    Text("确定")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .frame(height: 50)
                                        .frame(maxWidth: .infinity)
                                        .background(subscriptionManager.subscribedSources.isEmpty ? Color.gray : Color.blue)
                                        .cornerRadius(10)
                                }
                                .disabled(subscriptionManager.subscribedSources.isEmpty)
                                .padding(.top, 8)
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

                var union = Set<String>()
                let decoder = JSONDecoder()
                
                for url in newsJSONURLs {
                    do {
                        let data = try Data(contentsOf: url)
                        // 只需要键，解码为 [String: [Article]]；若无 Article 类型，请替换为通用结构
                        let decoded = try decoder.decode([String: [Article]].self, from: data)
                        union.formUnion(decoded.keys)
                    } catch {
                        // 某个文件坏了不应影响整体，记录日志后继续
                        print("解析 \(url.lastPathComponent) 失败: \(error.localizedDescription)")
                        continue
                    }
                }

                let sources = union.sorted()

                DispatchQueue.main.async {
                    self.allAvailableSources = sources
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
