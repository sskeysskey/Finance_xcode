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

struct MainContentView: View {
    @StateObject private var dataService = DataService()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 1. 上部：扇区展示
                IndicesContentView()
                    .frame(maxHeight: .infinity, alignment: .top)
                
                Divider()
                
                // 2. 中部：搜索框
                SearchContentView()
                    .frame(height: 100)
                    .padding(.vertical, 10)
                
                Divider()
                
                // 3. 下部：自定义标签栏
                TopContentView()
                    .frame(height: 60)
                    .background(Color(.systemBackground))
            }
            .navigationBarTitle("经济数据与搜索", displayMode: .inline)
        }
        .environmentObject(dataService) // 移到这里，确保 NavigationStack 内的所有视图都能访问
        .onAppear {
            dataService.loadData()
        }
    }
}
