import Foundation
import IOKit

enum DeviceIdentity {
    /// 稳定设备 ID（与服务端 dev_ 前缀约定一致）
    static let deviceId: String = {
        if let hw = hardwareUUID() { return "dev_" + hw }
        let key = "GW_FallbackDeviceUUID"
        if let s = UserDefaults.standard.string(forKey: key) { return "dev_" + s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: key)
        return "dev_" + s
    }()

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                        IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service,
                        "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (cf.takeRetainedValue() as? String)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}