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

// MARK: - 修改：更新状态视图以处理新状态
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
                
            // MARK: 新增 - 处理“已是最新”状态
            case .alreadyUpToDate:
                StatusView(icon: "checkmark.circle.fill", iconColor: .green, message: "当前已是最新版本")

            // MARK: 新增 - 处理“更新完成”状态
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

// MARK: - 新增：可重用的状态提示视图
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
                        // ... 内容视图 (无修改) ...
                        IndicesContentView()
                            .frame(maxHeight: .infinity, alignment: .top)
                        
                        Divider()
                        
                        // 2. 中部：搜索框
                        SearchContentView()
                            .frame(height: 60)
                            .padding(.vertical, 10)
                        
                        Divider()
                        
                        // 3. 下部：自定义标签栏
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
                                if await updateManager.checkForUpdates() {
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
                    Task {
                        if await updateManager.checkForUpdates() {
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
