import SwiftUI
import Foundation

// 文件名: AddSourceView.swift
// 职责: 提供一个可搜索的列表，让用户能够添加或移除新闻源订阅。
// 文件名: SubscriptionManager.swift
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
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    // 新增：控制是否显示搜索框
    @State private var showSearchBar = false

    // 订阅管理器
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    
    // 用于判断显示逻辑（首次设置 vs. 后续添加）
    let isFirstTimeSetup: Bool
    var onComplete: (() -> Void)? // 仅在首次设置时使用

    @Environment(\.presentationMode) var presentationMode

    // 计算属性，用于显示过滤后的列表
    private var filteredSources: [String] {
        let base = allAvailableSources
        if showSearchBar && !searchText.isEmpty {
            return base.filter { $0.lowercased().contains(searchText.lowercased()) }
        } else {
            return base
        }
    }

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("正在加载新闻源...")
                    .frame(maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxHeight: .infinity)
            } else {
                // 列表本身不变
                let list = List(filteredSources, id: \.self) { sourceName in
                    HStack {
                        Text(sourceName)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        if subscriptionManager.isSubscribed(to: sourceName) {
                            Text("已添加")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                }
                .listStyle(.plain)

                // 仅在 showSearchBar == true 时附加 .searchable
                Group {
                    if showSearchBar {
                        list
                            .searchable(text: $searchText, prompt: "搜索新闻源")
                    } else {
                        list
                    }
                }
            }

            // 仅在首次设置流程中显示“确定”按钮
            if isFirstTimeSetup {
                Button(action: {
                    // 调用闭包，通知父视图完成设置
                    onComplete?()
                }) {
                    Text("确定")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(height: 50)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(10)
                        .padding()
                }
                .disabled(subscriptionManager.subscribedSources.isEmpty) // 如果一个都没选，则禁用按钮
            }
        }
        .navigationTitle("添加新闻源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isFirstTimeSetup {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            // 新增：导航栏右侧放大镜按钮
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearchBar.toggle()
                        if !showSearchBar {
                            // 收起时清空搜索
                            searchText = ""
                        }
                    }
                } label: {
                    Image(systemName: showSearchBar ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .accessibilityLabel("搜索")
            }
        }
        .onAppear(perform: loadAvailableSources)
    }

    /// 从最新的 onews_*.json 文件中加载所有可用的新闻源名称
    private func loadAvailableSources() {
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let allFiles = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)

                // 找到所有 onews_*.json 文件并按名称排序，最新的在最后
                let newsJSONURLs = allFiles
                    .filter { $0.lastPathComponent.starts(with: "onews_") && $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }

                guard let latestNewsURL = newsJSONURLs.last else {
                    throw NSError(domain: "AppError", code: 1, userInfo: [NSLocalizedDescriptionKey: "在 Documents 目录中没有找到任何 'onews_*.json' 文件。\n请先返回主页同步资源。"])
                }

                let data = try Data(contentsOf: latestNewsURL)
                // 我们只需要JSON的键，所以解码为 [String: [Article]]
                let decoded = try JSONDecoder().decode([String: [Article]].self, from: data)
                
                let sources = decoded.keys.sorted()

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
