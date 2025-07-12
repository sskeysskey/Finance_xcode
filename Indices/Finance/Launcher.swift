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

    var body: some View {
        Group {
            switch updateManager.updateState {
            case .idle, .finished:
                EmptyView()
            case .checking:
                VStack {
                    ProgressView()
                    Text("正在检查更新...")
                }
                .padding()
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(10)
                .shadow(radius: 10)
            case .downloading(let progress, let total):
                VStack {
                    ProgressView(value: progress)
                    Text("正在下载 \(Int(progress * Double(total)))/\(total)...")
                }
                .padding()
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(10)
                .shadow(radius: 10)
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
        // MARK: 新增 - 添加动画，使提示出现和消失更平滑
        .animation(.easeInOut, value: updateManager.updateState)
    }
}


// ... Launcher.swift 的其他部分 ...

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
                    // ... 内部视图 ...
                    if isDataReady {
                        // 内容视图
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
                        // 加载视图
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
                                // MARK: - 修改点在这里
                                // 1. 检查更新，如果返回 true，说明有新文件下载
                                if await updateManager.checkForUpdates() {
                                    
                                    // 2. 关键步骤：强制数据库管理器重新连接
                                    DatabaseManager.shared.reconnectToLatestDatabase()
                                    
                                    // 3. 现在，从新的数据库连接中加载数据
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
                    Task {
                        if await updateManager.checkForUpdates() {
                            // 如果首次启动就有更新，也需要重新连接
                            // 虽然在这种情况下 init 应该就找到了最新的，但为了逻辑一致性加上也无妨
                            DatabaseManager.shared.reconnectToLatestDatabase()
                        }
                        
                        dataService.loadData()
                        
                        withAnimation {
                            isDataReady = true
                        }
                    }
                }
            }
            
            UpdateOverlayView(updateManager: updateManager)
        }
    }
}
