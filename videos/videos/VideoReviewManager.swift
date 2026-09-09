import SwiftUI
import StoreKit

final class ReviewManager {
    static let shared = ReviewManager()

    @AppStorage("userVideoInteractionCount") private var videoInteractionCount: Int = 0
    private let thresholds: Set<Int> = [8, 20, 50, 100]

    private init() {}

    func recordVideoInteraction() {
        videoInteractionCount += 1
        if thresholds.contains(videoInteractionCount) { requestReview() }
    }

    private func requestReview() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
            if #available(iOS 16.0, *) { AppStore.requestReview(in: scene) }
            else { SKStoreReviewController.requestReview(in: scene) }
        }
    }
}
