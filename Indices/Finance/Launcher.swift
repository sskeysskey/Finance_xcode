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

// MARK: - 新增：更新状态视图
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
    }
}


struct MainContentView: View {
    // MARK: - 修改
    @StateObject private var dataService = DataService.shared
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isDataReady = false

    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    if isDataReady {
                        // 1. 上部：Sectors 展示
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
                        // 在数据加载完成前显示一个加载指示器
                        VStack {
                            Spacer()
                            ProgressView("正在准备数据...")
                            Spacer()
                        }
                    }
                }
                .navigationBarTitle("经济数据与搜索", displayMode: .inline)
            }
            .environmentObject(dataService)
            .onAppear {
                // 仅在首次出现时执行更新和加载
                if !isDataReady {
                    Task {
                        // 1. 检查并执行更新
                        _ = await updateManager.checkForUpdates()
                        
                        // 2. 更新完成后，加载所有数据到内存
                        dataService.loadData()
                        
                        // 3. 更新UI，显示主内容
                        withAnimation {
                            isDataReady = true
                        }
                    }
                }
            }
            
            // 更新状态的浮层
            UpdateOverlayView(updateManager: updateManager)
        }
    }
}
