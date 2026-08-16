import SwiftUI

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 500; cache.totalCostLimit = 300 * 1024 * 1024 }
    func get(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func set(_ img: NSImage, _ url: URL) {
        cache.setObject(img, forKey: url as NSURL,
                        cost: Int(img.size.width * img.size.height * 4))
    }
    func clear() { cache.removeAllObjects() }
}

struct CachedImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12))
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let c = ImageCache.shared.get(url) { image = c; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        ImageCache.shared.set(img, url)
        image = img
    }
}