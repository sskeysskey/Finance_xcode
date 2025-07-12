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

// MARK: - 修改：更新状态视图以处理新状态 (无修改)
struct UpdateOverlayView: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        Group {
            switch updateManager.updateState {
            case .idle:
                EmptyView()
                
            case .checking:
                StatusView(icon: nil, message: "正在检查更新...")
                
            case .downloading(let progress, let total):
                VStack {
                    ProgressView(value: progress)
                    Text("正在下载 \(Int(progress * Double(total)))/\(total)...")
                }
                .padding()
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(10)
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

// MARK: - 新增：可重用的状态提示视图 (无修改)
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

    private var isUpdateInProgress: Bool {
        switch updateManager.updateState {
        case .checking, .downloading:
            return true
        default:
            return false
        }
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
                            ProgressView("正在准备数据...")
                            Spacer()
                        }
                    }
                }
                .navigationBarTitle("经济数据与搜索", displayMode: .inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            Task {
                                // 手动刷新时，仍然是阻塞的，这是符合预期的行为
                                if await updateManager.checkForUpdates(isManual: true) {
                                    DatabaseManager.shared.reconnectToLatestDatabase()
                                    dataService.loadData()
                                }
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isUpdateInProgress)
                    }
                }
            }
            .environmentObject(dataService)
            .onAppear {
                if !isDataReady {
                    // MARK: - 此处为核心修改
                    // 1. 立即加载数据并准备UI，让用户能立刻看到主界面
                    dataService.loadData()
                    isDataReady = true // 直接设置为true，让界面立即响应

                    // 2. 将检查更新放入一个独立的后台任务，它将独立运行，不阻塞UI
                    Task {
                        // isManual: false 表示这是后台自动检查
                        if await updateManager.checkForUpdates(isManual: false) {
                            // 如果后台检查发现并成功下载了更新，
                            // 那么需要重新连接数据库并刷新数据。
                            DatabaseManager.shared.reconnectToLatestDatabase()
                            dataService.loadData()
                        }
                    }
                }
            }
            
            UpdateOverlayView(updateManager: updateManager)
        }
    }
}
