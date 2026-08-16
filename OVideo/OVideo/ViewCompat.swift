import SwiftUI

/// 跨 macOS 13 / 14 / 15 的 onChange 替代品：
/// 不使用 macOS 14 已弃用的 onChange(of:perform:)，也不使用 macOS 14 才有的双参数 onChange。
struct GWChangeObserver<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void
    @State private var last: V?

    func body(content: Content) -> some View {
        content.task(id: value) {
            if let l = last, l != value { action(value) }
            last = value
        }
    }
}

extension View {
    /// 用法与旧的 .onChange(of:) { newValue in } 完全一致
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        modifier(GWChangeObserver(value: value, action: action))
    }
}
