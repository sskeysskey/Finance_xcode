// /Users/yanzhang/Documents/Xcode/Indices/Finance/Launcher.swift

import SwiftUI
import Foundation

@main
struct Finance: App {
    var body: some Scene {
        WindowGroup {
            MainContentView()
        }
    }
}

// MARK: - 更新状态视图 (无修改)
struct UpdateOverlayView: View {
    @ObservedObject var updateManager: UpdateManager

    // 用于格式化字节数的工具
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Group {
            switch updateManager.updateState {
            case .idle:
                EmptyView()
                
            case .checking:
                StatusView(icon: nil, message: "正在检查更新...")
            
            // --- 修改：处理新的 downloadingFile case ---
            case .downloadingFile(let name, let progress, let downloaded, let total):
                VStack(spacing: 12) {
                    Text("正在下载 \(name)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    // --- 修改：只显示 已下载 / 总大小 ---
                    Text("\(byteFormatter.string(fromByteCount: downloaded)) / \(byteFormatter.string(fromByteCount: total))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 300)
                .background(Color(.systemBackground).opacity(0.9))
                .cornerRadius(15)
                .shadow(radius: 10)

            // 旧的下载视图，用于显示文件总数进度
            case .downloading(let progress, let total):
                 VStack(spacing: 12) {
                    Text("正在处理文件...")
                         .font(.headline)
                    ProgressView(value: progress)
                    Text("已完成 \(Int(progress * Double(total)))/\(total)")
                         .font(.caption)
                         .foregroundColor(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 300)
                .background(Color(.systemBackground).opacity(0.9))
                .cornerRadius(15)
                .shadow(radius: 10)
                
            case .alreadyUpToDate:
                StatusView(icon: "checkmark.circle.fill", iconColor: .green, message: "当前已是最新版本")

            case .updateCompleted:
                StatusView(icon: "arrow.down.circle.fill", iconColor: .blue, message: "更新完成")

            case .error(let message):
                VStack {
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text("更新失败")
                    Text(message).font(.caption).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(10)
                .shadow(radius: 10)
            }
        }
        .animation(.easeInOut, value: updateManager.updateState)
    }
}

// MARK: - 可重用的状态提示视图 (无修改)
struct StatusView: View {
    let icon: String?
    var iconColor: Color = .secondary
    let message: String
    
    var body: some View {
        VStack(spacing: 8) {
            if let iconName = icon {
                Image(systemName: iconName)
                    .font(.largeTitle)
                    .foregroundColor(iconColor)
            } else {
                ProgressView()
            }
            Text(message)
                .font(.headline)
        }
        .padding(20)
        .background(Color(.systemBackground).opacity(0.85))
        .cornerRadius(15)
        .shadow(radius: 10)
    }
}


struct MainContentView: View {
    @StateObject private var dataService = DataService.shared
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isDataReady = false

    // 【新增】第 1 步：引入 scenePhase 来监控 App 的生命周期状态
    @Environment(\.scenePhase) private var scenePhase

    // 判断更新流程是否在进行中，用来 disable 刷新按钮
    private var isUpdateInProgress: Bool {
        updateManager.updateState != .idle
    }

    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    if isDataReady {
                        IndicesContentView()
                            .frame(maxHeight: .infinity, alignment: .top)
                        Divider()
                        SearchContentView()
                            .frame(height: 60)
                            .padding(.vertical, 10)
                        Divider()
                        TopContentView()
                            .frame(height: 60)
                            .background(Color(.systemBackground))
                    } else {
                        VStack {
                            Spacer()
                            ProgressView("正在准备数据…")
                            Spacer()
                        }
                    }
                }
                .navigationBarTitle("经济数据与搜索", displayMode: .inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            Task {
                                // 手动检查更新时，要等整个流程完成才重新 loadData
                                if await updateManager.checkForUpdates(isManual: true) {
                                    DatabaseManager.shared.reconnectToLatestDatabase()
                                    // MARK: - 修改：调用新的强制刷新方法
                                    dataService.forceReloadData()
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isUpdateInProgress)
                    }
                }
            }
            .environmentObject(dataService)
            // 【移除】第 2 步：移除旧的 .onAppear 修饰符，它的逻辑将被新的 scenePhase 处理器取代
            /*
            .onAppear {
                // ... 所有旧逻辑都将被移动和改进 ...
            }
            */
            // 【新增】第 3 步：使用 onChange 监听 scenePhase 的变化
            .onChange(of: scenePhase) { oldPhase, newPhase in
                // 当 App 变为活跃状态时（例如首次启动，或从后台返回，或关闭系统弹窗后）
                if newPhase == .active {
                    print("App is now active. Handling initial data load.")
                    Task {
                        await handleInitialDataLoad()
                    }
                }
            }

            // 更新状态浮层
            UpdateOverlayView(updateManager: updateManager)
        }
    }

    // 【新增】第 4 步：创建一个集中的、可重入的初始数据加载函数
    private func handleInitialDataLoad() async {
        // 守卫条件：如果数据已经准备好，则直接退出，防止重复加载。
        // 这是实现“仅首次成功加载”的关键。
        guard !isDataReady else {
            print("Data is already ready. Skipping initial load.")
            return
        }
        
        // 检查本地是否已有关键数据文件
        let hasLocalDescription = FileManagerHelper.getLatestFileUrl(for: "description") != nil

        if !hasLocalDescription {
            // 情况一：首次启动，或本地数据被清除，Documents 里没有任何数据文件。
            // 执行前台更新流程，UI会显示“正在准备数据...”。
            print("No local data found. Starting initial sync...")
            // isManual: false 表示这是自动流程
            let updated = await updateManager.checkForUpdates(isManual: false)
            if updated {
                // 更新成功后，重新连接数据库并强制加载所有数据到内存
                DatabaseManager.shared.reconnectToLatestDatabase()
                dataService.forceReloadData()
                // 设置数据就绪状态，UI将切换到主界面
                isDataReady = true
                print("Initial sync successful. Data is now ready.")
            } else {
                // 如果更新失败（例如网络问题），isDataReady 保持 false。
                // 当用户解决问题后（例如开启网络），App再次变为 active，此函数会重试。
                print("Initial sync failed.")
            }
        } else {
            // 情况二：本地已存在数据。
            // 这是常规启动流程。
            print("Local data found. Loading existing data and checking for updates in background.")
            
            // 1. 立即加载本地数据并展示UI，提供快速启动体验。
            dataService.loadData()
            isDataReady = true

            // 2. 在后台异步发起一次静默更新检查。
            Task {
                if await updateManager.checkForUpdates(isManual: false) {
                    // 如果后台检查发现并成功下载了更新
                    DatabaseManager.shared.reconnectToLatestDatabase()
                    dataService.forceReloadData()
                    print("Background update successful. Data reloaded.")
                } else {
                    print("Background check: No new updates or check failed silently.")
                }
            }
        }
    }
}