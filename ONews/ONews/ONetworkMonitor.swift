// ONetworkMonitor.swift
// 监听网络状态：是否联网、是否 Wi-Fi

import Foundation
import Network
import Combine

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ONews.NetworkMonitor")

    @Published var isConnected: Bool = true
    @Published var isWiFi: Bool = true
    @Published var isCellular: Bool = false

    /// 上一次状态，用来识别"切换"事件
    private var lastIsWiFi: Bool = true
    /// Wi-Fi → 蜂窝的切换回调（可被 HLSDownloadManager 订阅）
    var onSwitchedToCellular: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)

            DispatchQueue.main.async {
                self.isConnected = connected
                self.isWiFi = wifi
                self.isCellular = cellular

                // Wi-Fi → 蜂窝
                if self.lastIsWiFi && !wifi && cellular {
                    self.onSwitchedToCellular?()
                }
                self.lastIsWiFi = wifi
            }
        }
        monitor.start(queue: queue)
    }
}
