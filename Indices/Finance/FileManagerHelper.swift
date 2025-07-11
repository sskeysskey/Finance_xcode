import Foundation

class FileManagerHelper {
    
    // 获取应用的 Documents 目录 URL
    static var documentsDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    /**
     在 Documents 目录中查找具有最新时间戳的文件。
     例如，对于 baseName="HighLow"，它会查找 "HighLow_250710.txt", "HighLow_250709.txt" 等，并返回最新的一个。
     
     - Parameters:
       - baseName: 文件名的基础部分 (例如, "HighLow")
     - Returns: 最新文件的 URL，如果找不到则返回 nil。
     */
    static func getLatestFileUrl(for baseName: String) -> URL? {
        let fileManager = FileManager.default
        let documentsURL = self.documentsDirectory
        
        do {
            // 获取 Documents 目录下的所有文件
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            
            var latestFile: (url: URL, timestamp: String)? = nil
            
            // 正则表达式，用于匹配 "baseName_YYMMDD.extension" 格式
            // 例如: "HighLow_250710.json" -> 匹配 "HighLow", "250710", ".json"
            let regex = try NSRegularExpression(pattern: "^\(baseName)_(\\d{6})\\..+$")

            for url in fileURLs {
                let filename = url.lastPathComponent
                let range = NSRange(location: 0, length: filename.utf16.count)
                
                if let match = regex.firstMatch(in: filename, options: [], range: range) {
                    // 提取时间戳 (YYMMDD)
                    if let timestampRange = Range(match.range(at: 1), in: filename) {
                        let timestamp = String(filename[timestampRange])
                        
                        // 如果是第一个匹配的文件，或者当前文件的时间戳更新
                        if latestFile == nil || timestamp > latestFile!.timestamp {
                            latestFile = (url, timestamp)
                        }
                    }
                }
            }
            
            // 如果找到了文件，返回其 URL
            if let file = latestFile {
                print("找到最新文件 for '\(baseName)': \(file.url.lastPathComponent)")
                return file.url
            } else {
                print("警告: 未能在 Documents 中找到 for '\(baseName)' 的任何版本文件。")
                return nil
            }
            
        } catch {
            print("错误: 无法列出 Documents 目录中的文件: \(error)")
            return nil
        }
    }
}
