import Cocoa
import HotKey
import Carbon

// 定义常用的路径常量，方便后续调用
let PYTHON_PATH = "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
let HOME_DIR = FileManager.default.homeDirectoryForCurrentUser.path
// 注意：你的脚本里是 "/Users/yanzhang"，这里动态获取或者硬编码都可以
let USER_HOME = "/Users/yanzhang"

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
        
        // 初始化快捷键
        setupHotKeys()
    }
    
    // MARK: - 新增：状态栏设置
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
        
        // 添加退出按钮
        menu.addItem(NSMenuItem(title: "退出 (Quit)", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 快捷键注册中心
    func setupHotKeys() {
        
        // --- 1. App 启动类 ---
        
        // Ctrl + \ : Stickies
        bind(key: .backslash, modifiers: [.control]) {
            self.launchApp("Stickies")
            self.notify("Stickies 已启动")
        }
        
        // Ctrl + Alt + D : Reminders
        bind(key: .d, modifiers: [.control, .option]) {
            self.launchApp("Reminders")
            self.notify("提醒事项 (Reminders) 已启动")
        }
        
        // Ctrl + Alt + S : Notes
        bind(key: .s, modifiers: [.control, .option]) {
            self.launchApp("Notes")
            self.notify("备忘录 (Notes) 已启动")
        }

        // --- 2. Python 后台运行类 (hs.task) ---
        
        // Ctrl + / : Split2DB
        bind(key: .slash, modifiers: [.control]) {
            self.notify("正在执行 Split2DB...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Update_Split2DB.py")
        }
        
        // Ctrl + J : Show_Earning_History
        bind(key: .j, modifiers: [.control]) {
            self.notify("正在执行 Split2DB (History)...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Show_Earning_History.py")
        }

        // Ctrl + Cmd + 7 : Analyse_Options
        bind(key: .seven, modifiers: [.control, .command]) {
            self.notify("正在执行 Analyse_Options...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Analyse_Options.py")
        }

        // Ctrl + Cmd + 8 : Check_yesterday
        bind(key: .eight, modifiers: [.control, .command]) {
            self.notify("正在执行 Check_yesterday...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Check_yesterday.py")
        }

        // Ctrl + Alt + \ : Imigrate_new_exist
        bind(key: .backslash, modifiers: [.control, .option]) {
            self.notify("正在执行 Imigrate_new_exist.py...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Imigrate_new_exist.py")
        }

        // Ctrl + Cmd + 9 : Insert_History_Data
        bind(key: .nine, modifiers: [.control, .command]) {
            self.notify("正在执行 Insert_History_Data.py...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/JavaScript/HistoryData/Insert_History_Data.py")
        }

        // Ctrl + Alt + 7 : Check_Earning_dup
        bind(key: .seven, modifiers: [.control, .option]) {
            self.notify("正在执行 Check_Earning_dup...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Check_Earning_dup.py")
        }

        // Ctrl + Shift + Q : Search_Similar_Tag
        bind(key: .q, modifiers: [.control, .shift]) {
            self.notify("正在执行 search similar tag...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Search_Similar_Tag.py")
        }

        // Ctrl + Cmd + Z : Insert_Panel
        bind(key: .z, modifiers: [.control, .command]) {
            self.notify("正在执行 Insert panel.json")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Panel.py")
        }

        // Ctrl + L : Prompt_Creator
        bind(key: .l, modifiers: [.control]) {
            self.notify("正在执行 Prompt_Creator...")
            self.runPythonBackground("\(USER_HOME)/Coding/python_code/Prompt_Creator.py")
        }

        // Ctrl + G : split_TXT
        bind(key: .g, modifiers: [.control]) {
            self.notify("正在执行 split_TXT...")
            self.runPythonBackground("\(USER_HOME)/Coding/python_code/split_TXT.py")
        }

        // Ctrl + Alt + K : Insert_Desc_Manual
        bind(key: .k, modifiers: [.control, .option]) {
            self.notify("正在执行 Insert_Desc_Manual.py...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Desc_Manual.py")
        }

        // Ctrl + Cmd + K : Insert_Desc_null_Stock
        bind(key: .k, modifiers: [.control, .command]) {
            self.notify("正在执行 Insert_Desc_null_Stock...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Desc_null_Stock.py")
        }

        // Ctrl + Alt + 3 : Fix_MarketcapPEPB
        bind(key: .three, modifiers: [.control, .option]) {
            self.notify("正在执行 Fix_MarketcapPEPB...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Fix_MarketcapPEPB.py")
        }

        // Ctrl + V : Insert_Desc_Stock
        bind(key: .v, modifiers: [.control]) {
            self.notify("正在执行 Insert_Desc_Stock...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Desc_Stock.py")
        }

        // Ctrl + Alt + V : Insert_Desc_ETFs
        bind(key: .v, modifiers: [.control, .option]) {
            self.notify("正在执行 Insert_Desc_ETFs...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Desc_ETFs.py")
        }

        // Ctrl + Alt + Z : Editor_Tags
        bind(key: .z, modifiers: [.control, .option]) {
            self.notify("正在执行 Editor_Tags...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Editor_Tags.py")
        }

        // Alt + Cmd + Z : Check_Earning_Similar
        bind(key: .z, modifiers: [.option, .command]) {
            self.notify("正在打开 Earning_Similar...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Check_Earning_Similar.py")
        }

        // Ctrl + Alt + A : Editor_tags_weight
        bind(key: .a, modifiers: [.control, .option]) {
            self.notify("正在打开 tags_weights...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Editor_tags_weight.py")
        }

        // Ctrl + 1 : Volume_Monitor
        bind(key: .one, modifiers: [.control]) {
            self.notify("正在 执行volume监控程序...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Volume_Monitor.py")
        }

        // Ctrl + Cmd + 2 : Insert_Blacklist (带参数 etf)
        bind(key: .two, modifiers: [.control, .command]) {
            self.notify("正在 Insert_Blacklist (ETF模式)...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Blacklist.py", args: ["etf"])
        }

        // Ctrl + ' : Mouse_move
        bind(key: .quote, modifiers: [.control]) {
            self.notify("正在 移动鼠标...")
            self.runPythonBackground("\(USER_HOME)/Coding/python_code/Mouse_move.py")
        }

        // Ctrl + E : Check_Options
        bind(key: .e, modifiers: [.control]) {
            self.notify("正在执行 Options_Monitor...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Check_Options.py")
        }

        // Ctrl + Alt + E : Editor_Blacklist
        bind(key: .e, modifiers: [.control, .option]) {
            self.notify("正在执行 Editor_Blacklist...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Editor_Blacklist.py")
        }

        // Ctrl + D : Insert_Earning_auto
        bind(key: .d, modifiers: [.control]) {
            self.notify("正在打开财报编辑界面...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Operations/Insert_Earning_auto.py")
        }

        // Ctrl + I : Chart_Earning
        bind(key: .i, modifiers: [.control]) {
            self.notify("正在打开Chart_Earning界面...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Chart_Earning.py")
        }

        // Ctrl + K : Check_HighLow
        bind(key: .k, modifiers: [.control]) {
            self.notify("正在打开highlow.txt...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Check_HighLow.py")
        }

        // Ctrl + W : Panel.py
        bind(key: .w, modifiers: [.control]) {
            self.notify("正在运行 Panel.py...")
            self.runPythonBackground("\(USER_HOME)/Coding/Financial_System/Query/Panel.py")
        }

        // --- 3. 运行 AppleScript 文件 (带参数/不带参数) ---
        
        // Ctrl + S : Insert_PythonFile.scpt -> Insert_Events.py
        bind(key: .s, modifiers: [.control]) {
            self.notify("正在执行 Insert_PythonFile 脚本...")
            self.runOsascript(
                scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Insert_PythonFile.scpt",
                args: ["\(USER_HOME)/Coding/Financial_System/Operations/Insert_Events.py"]
            )
        }

        // Ctrl + Alt + W : Insert_PythonFile.scpt -> Editor_Earning_DB.py
        bind(key: .w, modifiers: [.control, .option]) {
            self.notify("正在执行 Editor_Earning_DB 脚本...")
            self.runOsascript(
                scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Insert_PythonFile.scpt",
                args: ["\(USER_HOME)/Coding/Financial_System/Operations/Editor_Earning_DB.py"]
            )
        }

        // Ctrl + Cmd + D : Insert_PythonFile.scpt -> Insert_Earning_Manual.py
        bind(key: .d, modifiers: [.control, .command]) {
            self.notify("正在执行 Insert_Earning_Manual 脚本...")
            self.runOsascript(
                scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Insert_PythonFile.scpt",
                args: ["\(USER_HOME)/Coding/Financial_System/Operations/Insert_Earning_Manual.py"]
            )
        }

        // Ctrl + Alt + Q : Insert_PythonFile.scpt -> Editor_Events.py
        bind(key: .q, modifiers: [.control, .option]) {
            self.notify("正在执行 Editor_Events 脚本...")
            self.runOsascript(
                scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Insert_PythonFile.scpt",
                args: ["\(USER_HOME)/Coding/Financial_System/Operations/Editor_Events.py"]
            )
        }

        // --- 纯 AppleScript 运行 ---
        
        // Ctrl + Alt + O
        bind(key: .o, modifiers: [.control, .option]) {
            self.notify("正在执行 API_Trans.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/API_Trans_small.scpt")
        }
        
        // Ctrl + Alt + P
        bind(key: .p, modifiers: [.control, .option]) {
            self.notify("正在执行 Doubao_small.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Doubao_small.scpt")
        }
        
        // Alt + Cmd + P
        bind(key: .p, modifiers: [.option, .command]) {
            self.notify("正在执行 Trans_doubao.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Trans_doubao.scpt")
        }
        
        // Ctrl + Alt + U
        bind(key: .u, modifiers: [.control, .option]) {
            self.notify("正在执行 Check_Earning.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Check_Earning.scpt")
        }
        
        // Ctrl + F
        bind(key: .f, modifiers: [.control]) {
            self.notify("正在执行 Insert_Sector.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Insert_Sector.scpt")
        }
        
        // Ctrl + Alt + F
        bind(key: .f, modifiers: [.control, .option]) {
            self.notify("正在执行 Delete_name.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Delete_name.scpt")
        }
        
        // Ctrl + ;
        bind(key: .semicolon, modifiers: [.control]) {
            self.notify("正在执行 karing 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Karing1.scpt")
        }
        
        // Ctrl + Alt + ;
        bind(key: .semicolon, modifiers: [.control, .option]) {
            self.notify("正在执行 singbox 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/singbox.scpt")
        }
        
        // Ctrl + M
        bind(key: .m, modifiers: [.control]) {
            self.notify("正在执行 Googlemap_input 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Googlemap_input.scpt")
        }
        
        // Shift + Cmd + 0
        bind(key: .zero, modifiers: [.shift, .command]) {
            self.notify("正在执行 Trans_Title.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/API_Trans_Title.scpt")
        }
        
        // Ctrl + Cmd + S
        bind(key: .s, modifiers: [.control, .command]) {
            self.notify("正在执行 Show_Description.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Show_Description.scpt")
        }
        
        // Ctrl + Alt + 0
        bind(key: .zero, modifiers: [.control, .option]) {
            self.notify("正在执行 Doubao_Title.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Doubao_Title.scpt")
        }
        
        // Ctrl + -
        bind(key: .minus, modifiers: [.control]) {
            self.notify("正在执行 Trans_SRT_Sonnet.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Trans_SRT_Sonnet.scpt")
        }
        
        // Ctrl + Alt + -
        bind(key: .minus, modifiers: [.control, .option]) {
            self.notify("正在执行 Trans_SRT_Sonnet_Auto.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Trans_SRT_Sonnet_Auto.scpt")
        }
        
        // Ctrl + =
        bind(key: .equal, modifiers: [.control]) {
            self.notify("正在执行 Doubao_SRT.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Doubao_SRT.scpt")
        }
        
        // Ctrl + Alt + =
        bind(key: .equal, modifiers: [.control, .option]) {
            self.notify("正在执行 Doubao_SRT_Auto.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Doubao_SRT_Auto.scpt")
        }
        
        // Ctrl + Cmd + A
        bind(key: .a, modifiers: [.control, .command]) {
            self.notify("正在执行 Stock_DB.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Stock_DB.scpt")
        }
        
        // Ctrl + Alt + 1
        bind(key: .one, modifiers: [.control, .option]) {
            self.notify("正在执行 Ask_Stock_info.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Ask_Stock_info.scpt")
        }
        
        // Ctrl + Alt + 2
        bind(key: .two, modifiers: [.control, .option]) {
            self.notify("正在执行 Ask_ETF_info.scpt...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Ask_ETF_info.scpt")
        }
        
        // Alt + Cmd + [
        bind(key: .leftBracket, modifiers: [.option, .command]) {
            self.notify("正在执行 Restore270 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Restore270.scpt")
        }
        
        // Alt + Cmd + ]
        bind(key: .rightBracket, modifiers: [.option, .command]) {
            self.notify("正在执行 Restore90 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Restore90.scpt")
        }
        
        // Ctrl + Cmd + [
        bind(key: .leftBracket, modifiers: [.control, .command]) {
            self.notify("正在执行 270_90 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/270_90.scpt")
        }
        
        // Alt + Cmd + X
        bind(key: .x, modifiers: [.option, .command]) {
            self.notify("正在执行 Baiducall 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Baidu_Call.scpt")
        }
        
        // Alt + Cmd + S
        bind(key: .s, modifiers: [.option, .command]) {
            self.notify("正在执行 Doubaocall 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Doubao_Call.scpt")
        }
        
        // Alt + Ctrl + L
        bind(key: .l, modifiers: [.control, .option]) {
            self.notify("正在执行Find Code...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Find_Code.scpt")
        }
        
        // Ctrl + Z
        bind(key: .z, modifiers: [.control]) {
            self.notify("正在执行查询富途...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Stock_CheckFutu.scpt")
        }
        
        // Ctrl + Shift + Z
        bind(key: .z, modifiers: [.control, .shift]) {
            self.notify("正在执行有道翻译脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Youdao.scpt")
        }
        
        // Ctrl + U
        bind(key: .u, modifiers: [.control]) {
            self.notify("正在执行查询富途(Clipboard)...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Clipboard_count.scpt")
        }
        
        // Ctrl + O
        bind(key: .o, modifiers: [.control]) {
            self.notify("正在执行查询Seeking Alpha...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Stock_seekingalpha.scpt")
        }
        
        // Ctrl + A
        bind(key: .a, modifiers: [.control]) {
            self.notify("正在执行 Stock_Chart 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Stock_Chart.scpt")
        }
        
        // Ctrl + Q
        bind(key: .q, modifiers: [.control]) {
            self.notify("正在执行搜索脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Search.scpt")
        }
        
        // Ctrl + [
        bind(key: .leftBracket, modifiers: [.control]) {
            self.notify("正在执行 MemoryClearner 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/MemoryClearner.scpt")
        }
        
        // Ctrl + Shift + W
        bind(key: .w, modifiers: [.control, .shift]) {
            self.notify("正在执行 Bob 脚本...")
            self.runOsascript(scriptPath: "\(USER_HOME)/Coding/ScriptEditor/Bob.scpt")
        }

        // --- 4. 动态 AppleScript (run script with parameters) ---
        
        // Ctrl + H
        bind(key: .h, modifiers: [.control]) {
            self.notify("正在执行 API_News_Sonnet...")
            let cmd = "run script (POSIX file \"\(USER_HOME)/Coding/ScriptEditor/API_News_Sonnet.scpt\") with parameters {\"\", \"normal\", false}"
            self.runOsascriptDirect(command: cmd)
        }
        
        // Ctrl + Alt + H
        bind(key: .h, modifiers: [.control, .option]) {
            self.notify("正在执行 API_News_Sonnet (Force)...")
            let cmd = "run script (POSIX file \"\(USER_HOME)/Coding/ScriptEditor/API_News_Sonnet.scpt\") with parameters {\"\", \"normal\", true}"
            self.runOsascriptDirect(command: cmd)
        }
        
        // Ctrl + N
        bind(key: .n, modifiers: [.control]) {
            self.notify("正在执行 Doubao_News...")
            let cmd = "run script (POSIX file \"\(USER_HOME)/Coding/ScriptEditor/Doubao_News.scpt\") with parameters {\"\", \"normal\", false}"
            self.runOsascriptDirect(command: cmd)
        }
        
        // Ctrl + Alt + N
        bind(key: .n, modifiers: [.control, .option]) {
            self.notify("正在执行 Doubao_News (Force)...")
            let cmd = "run script (POSIX file \"\(USER_HOME)/Coding/ScriptEditor/Doubao_News.scpt\") with parameters {\"\", \"normal\", true}"
            self.runOsascriptDirect(command: cmd)
        }

        // --- 5. Terminal 交互类 (最复杂的部分) ---
        // 这些任务会在 Terminal 中打开新标签或窗口执行
        
        // Ctrl + 3
        bind(key: .three, modifiers: [.control]) {
            self.notify("正在执行 YF_MarketCapPEShare 脚本…")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_MarketCapPEShare.py"
            let cmd = "\(PYTHON_PATH) '\(script)' --mode normal"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Cmd + 3
        bind(key: .three, modifiers: [.control, .command]) {
            self.notify("正在执行 YF_MarketCapPEShare (Empty/Clear)…")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_MarketCapPEShare.py"
            let cmd = "\(PYTHON_PATH) '\(script)' --mode empty --clear"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Alt + 9
        bind(key: .nine, modifiers: [.control, .option]) {
            self.notify("正在执行 YF_MarketCapPEShare (Empty/Clear)…")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_MarketCapPEShare.py"
            let cmd = "\(PYTHON_PATH) '\(script)' --mode empty --clear"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Alt + 8
        bind(key: .eight, modifiers: [.control, .option]) {
            self.notify("正在执行 YF_PriceVolume.py ...")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_PriceVolume.py"
            let cmd = "\(PYTHON_PATH) '\(script)' --mode empty"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Cmd + 0
        bind(key: .zero, modifiers: [.control, .command]) {
            self.notify("正在执行 YF_Options 脚本…")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_Options.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + 9
        bind(key: .nine, modifiers: [.control]) {
            self.notify("正在执行 Filter 脚本…")
            let script = "\(USER_HOME)/Coding/Financial_System/JavaScript/Screener/Filter.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + 8
        bind(key: .eight, modifiers: [.control]) {
            self.notify("正在执行 TE_Merged 脚本…")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/TE_Merged.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + ,
        bind(key: .comma, modifiers: [.control]) {
            self.notify("正在执行 AppServer.py 脚本…")
            let script = "\(USER_HOME)/Coding/LocalServer/AppServer.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + 0
        bind(key: .zero, modifiers: [.control]) {
            self.notify("正在执行 Selenium_Combined.py 脚本…")
            let script = "\(USER_HOME)/Coding/python_code/Selenium_News/Selenium_Combined.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Alt + 5
        bind(key: .five, modifiers: [.control, .option]) {
            self.notify("正在执行 txt2json.py…")
            let script = "\(USER_HOME)/Coding/python_code/txt2json.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + 7
        bind(key: .seven, modifiers: [.control]) {
            self.notify("正在执行 YF_Earnings_Combined 脚本…")
            let script = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_Earnings_Combined.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Cmd + 6
        bind(key: .six, modifiers: [.control, .command]) {
            self.notify("正在执行 Backup_Syncing 脚本…")
            let script = "\(USER_HOME)/Coding/Financial_System/Operations/Backup_Syncing.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // --- 6. 组合命令 (Chained Commands) ---
        
        // Ctrl + 6 : Analyse_Compare (Sequence)
        bind(key: .six, modifiers: [.control]) {
            self.notify("正在启动 Analyse_Compare 序列...")
            let s1 = "\(USER_HOME)/Coding/Financial_System/Operations/Insert_Earning_auto.py"
            let s2 = "\(USER_HOME)/Coding/Financial_System/Query/Analyse_Compare.py"
            let cmd = "\(PYTHON_PATH) '\(s1)' && \(PYTHON_PATH) '\(s2)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Alt + 6 : Analyse_season (Sequence)
        bind(key: .six, modifiers: [.control, .option]) {
            self.notify("正在启动 Analyse_season 序列...")
            let scripts = [
                "\(USER_HOME)/Coding/Financial_System/Query/Analyse_OverBuy.py",
                "\(USER_HOME)/Coding/Financial_System/Query/Analyse_Earning_Season.py",
                "\(USER_HOME)/Coding/Financial_System/Query/Analyse_Earning_no_Season.py",
                "\(USER_HOME)/Coding/Financial_System/Query/Analyse_Earning_Volume.py"
            ]
            // 拼接命令
            let cmd = scripts.map { "\(PYTHON_PATH) '\($0)'" }.joined(separator: " && ")
            self.runInTerminal(cmd)
        }
        
        // Cmd + Alt + 8 : Holiday_Insert (Sequence)
        bind(key: .eight, modifiers: [.command, .option]) {
            self.notify("正在启动 Holiday_Insert 序列...")
            let scripts = [
                "\(USER_HOME)/Coding/Financial_System/Selenium/TE_Merged.py",
                "\(USER_HOME)/Coding/Financial_System/Operations/Insert_Holiday.py"
            ]
            let cmd = scripts.map { "\(PYTHON_PATH) '\($0)'" }.joined(separator: " && ")
            self.runInTerminal(cmd)
        }
        
        // Shift + Cmd + 8 : Weekend Processing
        bind(key: .eight, modifiers: [.shift, .command]) {
            self.notify("正在启动周末数据处理序列...")
            let s1 = "\(USER_HOME)/Coding/Financial_System/Operations/Insert_Weekend.py"
            let s2 = "\(USER_HOME)/Coding/Financial_System/Selenium/YF_PriceVolume.py"
            let cmd = "\(PYTHON_PATH) '\(s1)' && \(PYTHON_PATH) '\(s2)' --mode empty --weekend"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + 4 : Sync to server (Shell script)
        bind(key: .four, modifiers: [.control]) {
            self.notify("正在执行同步脚本...")
            let script = "\(USER_HOME)/Coding/sh/sync_to_server.sh"
            // bash -lc 确保加载环境变量
            let cmd = "bash -lc '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + 5 : GitHub Sync All
        bind(key: .five, modifiers: [.control]) {
            self.notify("正在执行 GitHub 全量同步...")
            let scripts = [
                "github_sync_pythoncode.sh", "github_sync_finance.sh", "github_sync_xcode.sh",
                "github_sync_HammerSpoon.sh", "github_sync_scripteditor.sh", "github_sync_shell.sh",
                "github_sync_xcode.sh", "github_sync_website.sh", "github_sync_android.sh",
                "github_sync_LocalServer.sh"
            ]
            let cmd = scripts.map { "bash -lc '\(USER_HOME)/Coding/sh/\($0)'" }.joined(separator: " && ")
            self.runInTerminal(cmd)
        }
        
        // Ctrl + ] : whisper_mlx_auto
        bind(key: .rightBracket, modifiers: [.control]) {
            self.notify("正在执行 whisper_mlx_auto...")
            let script = "\(USER_HOME)/Coding/python_code/Video/whisper_mlx_auto.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
        }
        
        // Ctrl + Alt + ] : whisper_mlx_manual
        bind(key: .rightBracket, modifiers: [.control, .option]) {
            self.notify("正在执行 whisper_mlx_manual...")
            let script = "\(USER_HOME)/Coding/python_code/Video/whisper_mlx_manual.py"
            let cmd = "\(PYTHON_PATH) '\(script)'"
            self.runInTerminal(cmd)
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
        
        DispatchQueue.global().async {
            do {
                try task.run()
            } catch {
                print("无法执行 osascript: \(error)")
            }
        }
    }
}