import Foundation

// MARK: - Page Counter Insertion

extension LaTeXNormalizer {

    /// 在 \chapter 前根據最近的 %% === Page N === 標記插入 \setcounter{page}{N}。
    /// 也處理 \begin{document} 後的第一個頁面標記。
    /// 冪等：已有 \setcounter{page} 則不重複插入。
    public static func insertPageCounters(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let pagePattern = #"%%\s*===\s*Page\s+(\d+)\s*==="#
        guard let pageRegex = try? NSRegularExpression(pattern: pagePattern) else { return source }

        // 找出每個 page marker 的行號和頁碼
        struct PageMarker {
            let lineIndex: Int
            let pageNumber: Int
        }

        var markers: [PageMarker] = []
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = pageRegex.firstMatch(in: line, range: range) {
                let numStr = ns.substring(with: match.range(at: 1))
                if let num = Int(numStr) {
                    markers.append(PageMarker(lineIndex: i, pageNumber: num))
                }
            }
        }

        guard !markers.isEmpty else { return source }

        // 找出需要插入 \setcounter 的位置
        var insertions: [(lineIndex: Int, pageNumber: Int)] = []

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 在 \chapter 或 \chapter* 前插入
            if trimmed.hasPrefix("\\chapter") {
                // 找最近的前方 page marker
                if let marker = markers.last(where: { $0.lineIndex < i }) {
                    // 檢查此 chapter 前是否已有 \setcounter{page}
                    let prevLine = i > 0 ? lines[i - 1].trimmingCharacters(in: .whitespaces) : ""
                    if !prevLine.hasPrefix("\\setcounter{page}") {
                        insertions.append((i, marker.pageNumber))
                    }
                }
            }
        }

        guard !insertions.isEmpty else { return source }

        // 從後往前插入以避免索引偏移
        var resultLines = lines
        for insertion in insertions.reversed() {
            resultLines.insert("\\setcounter{page}{\(insertion.pageNumber)}", at: insertion.lineIndex)
        }

        return resultLines.joined(separator: "\n")
    }
}
