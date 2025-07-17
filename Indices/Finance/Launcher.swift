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
                                    dataService.loadData()
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
            .onAppear {
                // 先检查本地是否已有 description.json
                let hasLocalDescription = FileManagerHelper.getLatestFileUrl(for: "description") != nil

                if !hasLocalDescription {
                    // 首次启动，Documents 里没有任何数据文件
                    // 先执行一次「同步」更新
                    Task {
                        let updated = await updateManager.checkForUpdates(isManual: false)
                        if updated {
                            DatabaseManager.shared.reconnectToLatestDatabase()
                        }
                        // 不管更新是否成功，都尝试加载（如果更新失败，则可能依然无本地数据，界面会报错）
                        dataService.loadData()
                        isDataReady = true
                    }
                } else {
                    // 已经有本地数据，立即加载并展示
                    dataService.loadData()
                    isDataReady = true

                    // 后台异步发起一次更新
                    Task {
                        if await updateManager.checkForUpdates(isManual: false) {
                            // 如果更新成功，重新打开 DB，reload 本地数据
                            DatabaseManager.shared.reconnectToLatestDatabase()
                            dataService.loadData()
                        }
                    }
                }
            }

            // 更新状态浮层
            UpdateOverlayView(updateManager: updateManager)
        }
    }
}
