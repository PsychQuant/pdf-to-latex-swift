import Foundation

// MARK: - Page Counter Insertion (PsychQuant/macdoc#9)

/// 頁碼樣式區段。只由來源中明確寫出的指令決定（見 `insertPageCounters` 的 Roman 契約）。
enum PageNumberingStyle: Equatable {
    case arabic
    case roman
    /// `\pagenumbering{alph}` 等本函式不管理的樣式。
    case unmanaged
}

extension LaTeXNormalizer {

    /// 依 `%% === Page N ===` 標記還原原書頁碼：在「錨點」之後插入 `\setcounter{page}{N}`。
    ///
    /// ## N 的來源
    ///
    /// N 取自錨點之前（第一個 marker 則是它自己）最近的一個 body 內 page marker。marker 是
    /// 轉寫流程寫入的頁序（`PageResult.page`），本函式把它當成要顯示的頁碼。
    /// `\begin{document}` 之前與 `\end{document}` 之後的內容不參與。
    ///
    /// ## 錨點（封閉列舉，只有這三類）
    ///
    /// 1. **第一個 page marker**：body 內第一個 marker 行。counter 插在 marker 行之後。
    /// 2. **章節邊界**：去掉行首空白後以 `\chapter{`、`\chapter*{`、`\chapter[` 開頭的行
    ///    （`\chapterauthor` 之類不算，註解掉的不算）。counter 插在 `\chapter` 指令
    ///    **閉合大括號所在行之後**，標題跨行也一樣。理由：`\chapter` 會先
    ///    `\clearpage`／`\cleardoublepage`，counter 若放在它之前，會被記在前一頁、章首頁變成
    ///    N+1（以 pdflatex 實測：放前面 → 目錄記 19；放後面 → 目錄記 18）。
    /// 3. **切回阿拉伯數字**：`\mainmatter` 或 `\pagenumbering{arabic}`。兩者都會把 counter
    ///    重設為 1，所以 counter 插在該行之後。
    ///
    /// 錨點 1 與 3 若下一個有內容的行（略過空行與 `%` 註解行，含 page marker）本身是章節或
    /// 頁碼切換指令，就省略，交給後者處理，避免冗餘的 counter。沒有前置 marker 的錨點一律不動。
    ///
    /// ## Roman numerals：保守契約
    ///
    /// 頁碼樣式只由來源中**明確寫出**的指令決定。以下是封閉列舉，不得依性質相似類推其他訊號：
    ///
    /// - `\frontmatter`、`\pagenumbering{roman}`、`\pagenumbering{Roman}` → roman 區段
    /// - `\mainmatter`、`\pagenumbering{arabic}` → arabic 區段
    /// - 其他 `\pagenumbering{…}`（如 `alph`）→ 不受管理的區段
    /// - 出現任何上述指令之前 → arabic（LaTeX 預設）
    ///
    /// 特別是：頁碼數字小、位在第一個 `\chapter` 之前、`\chapter*{Preface}`、
    /// `\tableofcontents`，**都不是** front-matter 證據，不會觸發 roman。
    ///
    /// roman 與不受管理的區段內不插入任何 counter：marker 是實體頁序，不是該區段的頁標籤，
    /// 寫進去等於捏造頁碼。本函式也不輸出 `\pagenumbering{roman}`／`{arabic}`：目前承認的
    /// front-matter 證據就是上列指令本身，它們已經完成樣式切換；本函式的責任是在切回
    /// arabic 之後，把被重設為 1 的 counter 還原成原書頁碼。PDF page labels 之類的外部
    /// 頁標籤來源尚未納入此契約。
    ///
    /// ## 冪等
    ///
    /// 錨點之後那一行若已是 `\setcounter{page}{…}`（不論數值），視為已處理或使用者自訂，
    /// 不再插入；章節錨點之前那一行若是 `\setcounter{page}{…}`，同樣尊重、不重複插入。
    /// 因此重跑不會改變輸出。
    public static func insertPageCounters(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let body = documentBodyRange(of: lines)
        let markers = pageMarkers(in: lines, within: body)
        guard let firstMarker = markers.first else { return source }

        func nearestMarkerPage(atOrBefore line: Int) -> Int? {
            markers.last(where: { $0.line <= line })?.page
        }

        var style: PageNumberingStyle = .arabic
        var insertions: [(afterLine: Int, page: Int)] = []
        var i = 0

        while i < lines.count {
            let code = codePortion(of: lines[i])
            let inBody = body.contains(i)

            if let switched = numberingSwitch(in: code) {
                style = switched
                if inBody, switched == .arabic,
                   !nextContentLineTakesOver(lines, after: i, within: body),
                   !hasPageCounter(lines, at: i + 1),
                   let page = nearestMarkerPage(atOrBefore: i - 1) {
                    insertions.append((i, page))
                }
                i += 1
                continue
            }

            guard inBody else {
                i += 1
                continue
            }

            if i == firstMarker.line {
                if style == .arabic,
                   !nextContentLineTakesOver(lines, after: i, within: body),
                   !hasPageCounter(lines, at: i + 1) {
                    insertions.append((i, firstMarker.page))
                }
                i += 1
                continue
            }

            if isChapterStart(code) {
                guard let end = chapterCommandEndLine(lines, start: i, limit: body.upperBound) else {
                    i += 1
                    continue
                }
                if style == .arabic,
                   !hasPageCounter(lines, at: end + 1),
                   !hasPageCounter(lines, at: i - 1),
                   let page = nearestMarkerPage(atOrBefore: i - 1) {
                    insertions.append((end, page))
                }
                i = end + 1
                continue
            }

            i += 1
        }

        guard !insertions.isEmpty else { return source }

        var resultLines = lines
        for insertion in insertions.sorted(by: { $0.afterLine > $1.afterLine }) {
            resultLines.insert("\\setcounter{page}{\(insertion.page)}", at: insertion.afterLine + 1)
        }
        return resultLines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// body 的行範圍：`\begin{document}` 的下一行到 `\end{document}`（不含）。
    /// 沒有 `\begin{document}` 時整份 source 視為 body。
    static func documentBodyRange(of lines: [String]) -> Range<Int> {
        guard let begin = lines.firstIndex(where: { codePortion(of: $0).contains("\\begin{document}") }) else {
            return 0..<lines.count
        }
        let end = lines[(begin + 1)...].firstIndex(where: {
            codePortion(of: $0).contains("\\end{document}")
        }) ?? lines.count
        return (begin + 1)..<end
    }

    /// body 內的 `%% === Page N ===` 標記（行號與頁碼），依行號排序。
    static func pageMarkers(in lines: [String], within body: Range<Int>) -> [(line: Int, page: Int)] {
        let pattern = #"^\s*%%\s*===\s*Page\s+(\d+)\s*==="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var markers: [(line: Int, page: Int)] = []
        for i in body {
            let ns = lines[i] as NSString
            guard let match = regex.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)),
                  let page = Int(ns.substring(with: match.range(at: 1))) else { continue }
            markers.append((i, page))
        }
        return markers
    }

    /// 一行中註解（未跳脫的 `%`）之前的部分。
    static func codePortion(of line: String) -> String {
        var backslashes = 0
        for index in line.indices {
            let ch = line[index]
            if ch == "%" && backslashes % 2 == 0 {
                return String(line[..<index])
            }
            backslashes = (ch == "\\") ? backslashes + 1 : 0
        }
        return line
    }

    private static let chapterStartRegex = try! NSRegularExpression(pattern: #"^\s*\\chapter\*?\s*[\[{]"#)

    static func isChapterStart(_ code: String) -> Bool {
        let range = NSRange(location: 0, length: (code as NSString).length)
        return chapterStartRegex.firstMatch(in: code, range: range) != nil
    }

    private static let numberingSwitchRegex = try! NSRegularExpression(
        pattern: #"\\(frontmatter|mainmatter)(?![A-Za-z])|\\pagenumbering\s*\{\s*([A-Za-z]+)\s*\}"#
    )

    /// 行內最後一個頁碼樣式切換指令（封閉列舉）；沒有則回傳 nil。
    static func numberingSwitch(in code: String) -> PageNumberingStyle? {
        let ns = code as NSString
        guard let match = numberingSwitchRegex.matches(
            in: code, range: NSRange(location: 0, length: ns.length)
        ).last else { return nil }

        if match.range(at: 1).location != NSNotFound {
            return ns.substring(with: match.range(at: 1)) == "frontmatter" ? .roman : .arabic
        }
        switch ns.substring(with: match.range(at: 2)) {
        case "arabic": return .arabic
        case "roman", "Roman": return .roman
        default: return .unmanaged
        }
    }

    private static func hasPageCounter(_ lines: [String], at index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        return lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("\\setcounter{page}")
    }

    /// 下一個有內容的行（略過空行與註解行）是否為章節或頁碼切換指令。
    private static func nextContentLineTakesOver(_ lines: [String], after index: Int, within body: Range<Int>) -> Bool {
        var j = index + 1
        while j < body.upperBound {
            let code = codePortion(of: lines[j]).trimmingCharacters(in: .whitespaces)
            if code.isEmpty {
                j += 1
                continue
            }
            return isChapterStart(code) || numberingSwitch(in: code) != nil
        }
        return false
    }

    /// `\chapter` 指令（可選 `*`、可選 `[短標題]`、必要 `{標題}`）結束於哪一行。
    /// 大括號不平衡或超過 20 行仍未閉合時回傳 nil（保守：不插入）。
    static func chapterCommandEndLine(_ lines: [String], start: Int, limit: Int) -> Int? {
        enum Phase { case name, optional, mandatory }
        var phase = Phase.name
        var depth = 0
        var starAllowed = true
        let lastLine = min(limit, start + 20)

        var j = start
        while j < lastLine {
            let code = codePortion(of: lines[j])
            let chars = Array(code)
            var k = 0
            if j == start {
                guard let range = code.range(of: "\\chapter") else { return nil }
                k = code.distance(from: code.startIndex, to: range.upperBound)
            }
            while k < chars.count {
                let ch = chars[k]
                switch phase {
                case .name:
                    if ch == "*" && starAllowed {
                        starAllowed = false
                    } else if ch == "[" {
                        phase = .optional
                        depth = 0
                    } else if ch == "{" {
                        phase = .mandatory
                        depth = 1
                    } else if !ch.isWhitespace {
                        return nil
                    }
                case .optional:
                    if ch == "\\" {
                        k += 1
                    } else if ch == "{" {
                        depth += 1
                    } else if ch == "}" {
                        depth -= 1
                    } else if ch == "]" && depth == 0 {
                        phase = .name
                        starAllowed = false
                    }
                case .mandatory:
                    if ch == "\\" {
                        k += 1
                    } else if ch == "{" {
                        depth += 1
                    } else if ch == "}" {
                        depth -= 1
                        if depth == 0 { return j }
                    }
                }
                k += 1
            }
            j += 1
        }
        return nil
    }
}
