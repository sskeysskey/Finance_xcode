import SwiftUI
import UIKit

enum ReaderPalette {
    /// 详情页背景：暗色 RGB(30,30,30)，亮色保持系统背景
    static let background = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
            : .systemBackground
    }

    /// 详情页正文/标题：暗色 RGB(214,214,214)，亮色保持系统 label
    static let text = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 214/255, green: 214/255, blue: 214/255, alpha: 1)
            : .label
    }

    static var backgroundColor: Color { Color(uiColor: background) }
    static var textColor: Color { Color(uiColor: text) }
}
