import Foundation

public enum PDFToLaTeXError: LocalizedError {
    case validation(String)
    case pdfOpenFailed(URL)
    case pageUnavailable(Int)
    case bitmapCreationFailed(Int)
    case imageCreationFailed(Int)
    case imageCannotOpen(URL)
    case imageCannotDecode(URL)
    case imageCannotCreateDestination(URL)
    case imageFinalizeFailed(URL)
    case invalidImageSize
    case invalidCrop(BoundingBox)
    case cropFailed(URL)
    case cliNotFound(String)
    case cliFailed(String, Int32, String)
    case cliInvalidResponse(String, String)
    case cliTimedOut(String, Double)
    case latexmkFailed(Int32, String)
    case missingPageRanges
    case missingChapterConfig
    case invalidRangeToken(String)
    case invalidRange(Int, Int)
    case invalidCustomConfig(String)

    public var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        case .pdfOpenFailed(let url):
            return "無法開啟 PDF: \(url.path)"
        case .pageUnavailable(let index):
            return "無法讀取 PDF 第 \(index + 1) 頁。"
        case .bitmapCreationFailed(let page):
            return "無法建立第 \(page) 頁的點陣畫布。"
        case .imageCreationFailed(let page):
            return "無法建立第 \(page) 頁的影像。"
        case .imageCannotOpen(let url):
            return "無法開啟圖片檔: \(url.path)"
        case .imageCannotDecode(let url):
            return "無法解碼圖片檔: \(url.path)"
        case .imageCannotCreateDestination(let url):
            return "無法建立圖片輸出: \(url.path)"
        case .imageFinalizeFailed(let url):
            return "無法完成圖片輸出: \(url.path)"
        case .invalidImageSize:
            return "頁面圖片尺寸無效，無法做區塊切分。"
        case .invalidCrop(let bbox):
            return "block bbox 無效: x=\(bbox.x) y=\(bbox.y) w=\(bbox.width) h=\(bbox.height)"
        case .cropFailed(let url):
            return "無法從頁面圖片裁出 block: \(url.path)"
        case .cliNotFound(let cli):
            return "找不到 \(cli) CLI。請先確認 `\(cli)` 已安裝且可在 PATH 中使用。"
        case .cliFailed(let cli, let code, let output):
            return "\(cli) 失敗，exit code \(code): \(output)"
        case .cliInvalidResponse(let cli, let output):
            return "\(cli) 回傳內容無法解析: \(output)"
        case .cliTimedOut(let cli, let seconds):
            return "\(cli) 超時，超過 \(Int(seconds)) 秒仍未完成。"
        case .latexmkFailed(let code, let output):
            return "latexmk 編譯失敗，exit code \(code): \(output)"
        case .missingPageRanges:
            return "`pages` 策略需要提供 --page-ranges。"
        case .missingChapterConfig:
            return "`custom` 策略需要提供 --chapter-config。"
        case .invalidRangeToken(let token):
            return "無法解析頁碼區間: \(token)"
        case .invalidRange(let start, let end):
            return "頁碼區間無效: \(start)-\(end)"
        case .invalidCustomConfig(let reason):
            return "chapter config 無效: \(reason)"
        }
    }

    /// 是否為 timeout 錯誤
    public var isTimeout: Bool {
        if case .cliTimedOut = self { return true }
        return false
    }
}
