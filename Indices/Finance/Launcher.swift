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

    // MARK: - 此处为核心修改
    private var isUpdateInProgress: Bool {
        // 只要更新管理器的状态不是“空闲”，就认为更新流程正在进行中。
        // 这会确保按钮在检查、下载、显示结果（成功/失败）的整个过程中都保持禁用，
        // 直到状态被重置回 .idle 为止。
        return updateManager.updateState != .idle
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
                                // 手动刷新时，等待检查更新流程完成
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
                    // 立即加载数据并准备UI，让用户能立刻看到主界面
                    dataService.loadData()
                    isDataReady = true

                    // 将检查更新放入一个独立的后台任务，不阻塞UI
                    Task {
                        if await updateManager.checkForUpdates(isManual: false) {
                            // 如果后台检查发现并成功下载了更新，则刷新数据
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
