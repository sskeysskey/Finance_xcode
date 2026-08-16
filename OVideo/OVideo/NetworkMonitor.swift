import Foundation
import Network
import Combine

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    @Published var isConnected = true
    @Published var isWiFi = true          // Mac 上有线/Wi-Fi 都视为"不限流"
    @Published var isExpensive = false    // 手机热点等

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected  = path.status == .satisfied
                self?.isExpensive  = path.isExpensive
                self?.isWiFi       = !path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "gw.net"))
    }
}