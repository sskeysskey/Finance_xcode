import SwiftUI

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 600; cache.totalCostLimit = 320 * 1024 * 1024 }
    func get(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func set(_ img: NSImage, _ url: URL) {
        cache.setObject(img, forKey: url as NSURL,
                        cost: Int(img.size.width * img.size.height * 4))
    }
    func clear() { cache.removeAllObjects() }
}

/// ⭐ 关键修复：图片始终"填满 + 裁切"到父容器给定的尺寸，绝不会顶出布局
struct CachedImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: min(geo.size.width, geo.size.height) * 0.24))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()                     // ⭐ 就是这一句以前少了
            .contentShape(Rectangle())
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let c = ImageCache.shared.get(url) { image = c; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        ImageCache.shared.set(img, url)
        image = img
    }
}