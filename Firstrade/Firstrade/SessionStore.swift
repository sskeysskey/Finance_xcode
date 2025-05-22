import SwiftUI
import Combine

final class SessionStore: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var username: String = ""
}
