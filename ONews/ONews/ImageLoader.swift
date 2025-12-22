// ===== 新建文件: ImageLoader.swift =====
// 负责异步图片加载和缓存

import SwiftUI
import UIKit

@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    
    private static var cache = NSCache<NSString, UIImage>()
    
    func load(from path: String) {
        let cacheKey = path as NSString
        
        // 1. 先检查内存缓存
        if let cached = Self.cache.object(forKey: cacheKey) {
            self.image = cached
            return
        }
        
        // 2. 异步加载
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loadedImage = UIImage(contentsOfFile: path)
            
            await MainActor.run {
                self.isLoading = false
                if let img = loadedImage {
                    Self.cache.setObject(img, forKey: cacheKey)
                    self.image = img
                }
            }
        }
    }
    
    static func clearCache() {
        cache.removeAllObjects()
    }
}