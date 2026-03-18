import Cocoa
import HotKey
import Carbon

// 定义常用的路径常量
let PYTHON_PATH = "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
let HOME_DIR = FileManager.default.homeDirectoryForCurrentUser.path
let USER_HOME = "/Users/yanzhang"
let CONFIG_PATH = "/Users/yanzhang/Coding/Financial_System/Modules/config.json"

// 定义 JSON 配置的数据结构
struct ShortcutConfig: Codable {
    let key: String
    let modifiers: [String]
    let actionType: String
    let target: String
    let args: [String]?
    let message: String?
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // 保持对 HotKey 对象的引用，否则它们会被释放导致快捷键失效
    var hotKeys: [HotKey] = []
    
    // --- 新增：状态栏图标对象 ---
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("MyHammerspoon Started")
        
        // --- 新增：初始化状态栏图标 ---
        setupMenuBar()
        loadHotKeysConfig()
    }
    
    // MARK: - 状态栏设置
    func setupMenuBar() {
        // 创建一个定长的状态栏项目
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // 设置图标 (这里用了系统自带的闪电图标，你可以换成其他的)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Shortcut")
        }
        
        // 创建下拉菜单
        let menu = NSMenu()
        
        // 添加一个标题项（不可点击）
        let titleItem = NSMenuItem(title: "Shortcut 工具箱", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator()) // 分割线
        
        // 新增：加载配置按钮
        menu.addItem(NSMenuItem(title: "重载配置 (Load Config)", action: #selector(loadHotKeysConfig), keyEquivalent: "r"))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "退出 (Quit)", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 动态加载配置
    @objc func loadHotKeysConfig() {
        // 清空旧的快捷键绑定
        hotKeys.removeAll()
        
        let fileURL = URL(fileURLWithPath: CONFIG_PATH)
        
        do {
            let data = try Data(contentsOf: fileURL)
            let configs = try JSONDecoder().decode([ShortcutConfig].self, from: data)
            
            for config in configs {
                guard let key = mapKey(config.key) else {
                    print("未知的按键: \(config.key)")
                    continue
                }
                let modifiers = mapModifiers(config.modifiers)
                
                bind(key: key, modifiers: modifiers) {
                    if let msg = config.message {
                        self.notify(msg)
                    }
                    
                    switch config.actionType {
                    case "launchApp":
                        self.launchApp(config.target)
                    case "runPythonBackground":
                        self.runPythonBackground(config.target, args: config.args ?? [])
                    case "runOsascript":
                        self.runOsascript(scriptPath: config.target, args: config.args ?? [])
                    case "runOsascriptDirect":
                        self.runOsascriptDirect(command: config.target)
                    case "runInTerminal":
                        self.runInTerminal(config.target)
                    default:
                        print("未知的 actionType: \(config.actionType)")
                    }
                }
            }
            self.notify("快捷键配置已成功加载！", title: "配置更新")
            print("Successfully loaded \(configs.count) shortcuts.")
            
        } catch {
            self.notify("加载配置失败，请检查 JSON 格式", title: "配置错误")
            print("Failed to load config: \(error)")
        }
    }

    // MARK: - 辅助函数 Helper Functions

    // 绑定快捷键的通用方法
    func bind(key: Key, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        let hotKey = HotKey(key: key, modifiers: modifiers)
        hotKey.keyDownHandler = handler
        hotKeys.append(hotKey)
    }

    // 启动普通 App
    func launchApp(_ name: String) {
        let workspace = NSWorkspace.shared
        
        // 1. 尝试在系统中寻找应用的 URL
        // 先检查 /System/Applications (系统自带)，再检查 /Applications (用户安装)
        let appPaths = [
            "/System/Applications/\(name).app",
            "/Applications/\(name).app",
            "/System/Applications/Utilities/\(name).app"
        ]
        
        var appUrl: URL?
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                appUrl = URL(fileURLWithPath: path)
                break
            }
        }
        
        // 2. 如果找到了 URL，则使用现代 API 启动
        if let url = appUrl {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true // 相当于原来的 launchOrFocus，启动并带到前台
            
            workspace.openApplication(at: url, configuration: config) { (app, error) in
                if let error = error {
                    print("启动 \(name) 失败: \(error.localizedDescription)")
                } else {
                    print("\(name) 已成功启动或聚焦")
                }
            }
        } else {
            // 3. 如果通过路径没找到，尝试最后的兜底方案（通过 Bundle Identifier，如果知道的话）
            // 或者直接打印错误
            print("错误: 找不到应用 \(name) 的路径")
        }
    }

    // 发送通知 (使用 osascript 最简单，不需要处理复杂的代理)
    func notify(_ text: String, title: String = "SwiftManager") {
        // 异步发送，不阻塞
        DispatchQueue.global().async {
            let script = "display notification \"\(text)\" with title \"\(title)\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            try? task.run()
        }
    }

    // 后台运行 Python 脚本 (对应 hs.task)
    func runPythonBackground(_ scriptPath: String, args: [String] = []) {
        let task = Process()
        task.launchPath = PYTHON_PATH
        var allArgs = [scriptPath]
        allArgs.append(contentsOf: args)
        task.arguments = allArgs
        
        // 异步运行，忽略输出
        DispatchQueue.global().async {
            try? task.run()
        }
    }

    // 运行 .scpt 文件 (对应 hs.task 调用 osascript)
    func runOsascript(scriptPath: String, args: [String] = []) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        var allArgs = [scriptPath]
        allArgs.append(contentsOf: args)
        task.arguments = allArgs
        
        DispatchQueue.global().async {
            try? task.run()
        }
    }

    // 直接运行 AppleScript 代码字符串 (对应 run script ... with parameters)
    func runOsascriptDirect(command: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", command]
        
        DispatchQueue.global().async {
            try? task.run()
        }
    }

    // 在 Terminal 中运行命令 (修复版：使用 Process/osascript 替代 NSAppleScript)
    func runInTerminal(_ command: String) {
        // 1. 转义处理
        // 我们需要把 command 嵌入到 AppleScript 的字符串中 (do script "...")
        // 所以需要转义 command 内部的反斜杠和双引号
        let safeCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")

        // 2. 构建 AppleScript 源码
        let appleScriptSource = """
        tell application "System Events"
            set isRunning to exists (process "Terminal")
        end tell
        if isRunning then
            tell application "Terminal"
                activate
                try
                    do script "\(safeCommand)"
                on error errMsg
                    display dialog "Error: " & errMsg
                end try
            end tell
        else
            tell application "Terminal"
                activate
                try
                    -- 第一次启动时，Terminal 会自动创建一个窗口，所以直接在 window 1 执行
                    do script "\(safeCommand)" in window 1
                on error errMsg
                    display dialog "Error: " & errMsg
                end try
            end tell
        end if
        """

        // 3. 使用 Process 调用 /usr/bin/osascript 执行
        // 这样即使在后台线程 (DispatchQueue.global) 运行也没问题
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScriptSource]
        DispatchQueue.global().async { try? task.run() }
    }
    
    // MARK: - 映射函数
    
    func mapModifiers(_ mods: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for mod in mods {
            switch mod.lowercased() {
            case "control", "ctrl": flags.insert(.control)
            case "option", "alt": flags.insert(.option)
            case "command", "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }
    
    func mapKey(_ keyString: String) -> Key? {
        switch keyString.lowercased() {
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        case "0", "zero": return .zero
        case "1", "one": return .one
        case "2", "two": return .two
        case "3", "three": return .three
        case "4", "four": return .four
        case "5", "five": return .five
        case "6", "six": return .six
        case "7", "seven": return .seven
        case "8", "eight": return .eight
        case "9", "nine": return .nine
        case "backslash", "\\": return .backslash
        case "slash", "/": return .slash
        case "comma", ",": return .comma
        case "quote", "'": return .quote
        case "semicolon", ";": return .semicolon
        case "minus", "-": return .minus
        case "equal", "=": return .equal
        case "leftbracket", "[": return .leftBracket
        case "rightbracket", "]": return .rightBracket
        default: return nil
        }
    }
}