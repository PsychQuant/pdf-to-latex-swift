import Foundation

// MARK: - Page Counter Insertion (PsychQuant/macdoc#9)

/// 頁碼還原過程中的一筆紀錄。
public struct PageCounterNote: Sendable, Equatable {
    /// 紀錄類別（封閉列舉）。
    public enum Kind: Sendable, Equatable {
        /// 在錨點之後插入了 `\setcounter{page}{page}`。
        case counterInserted(page: Int)
        /// `\chapter` 前一行、值與 marker 相同的 counter（舊版的放法）已移到章名之後。
        case legacyCounterMoved(page: Int)
        /// `\chapter` 前一行的 counter 值與 marker 推得的不同：原樣保留，該章不插入。
        case conflictingCounterBeforeChapter(existing: Int, expected: Int)
        /// 找不到 `\chapter` 章名的閉合大括號：整份原始碼不動。
        case chapterTitleNotFound
    }

    /// 錨點在輸入原始碼中的行號（1 起算）：marker 行、切換指令所在行、`\chapter` 起始行。
    public let line: Int
    public let kind: Kind

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// `applyPageCounters` 的結果。
public struct PageCounterReport: Sendable, Equatable {
    public let result: String
    public let notes: [PageCounterNote]

    public init(result: String, notes: [PageCounterNote]) {
        self.result = result
        self.notes = notes
    }
}

/// 頁碼樣式區段。只由來源中明確寫出、且在該處被執行的指令決定。
enum PageNumberingStyle: Equatable {
    case arabic
    case roman
    /// `\pagenumbering{alph}` 等本函式不管理的樣式。
    case unmanaged
}

extension LaTeXNormalizer {

    /// 依 `%% === Page N ===` 標記還原原書頁碼：在「錨點」之後插入 `\setcounter{page}{N}`。
    ///
    /// 只看「作用中」的原始碼（`LaTeXSourceScan`）：註解、verbatim 類環境、`\verb`、巨集定義
    /// 內容、`\begin{document}` 之前與 `\end{document}` 之後都不參與；verbatim 內長得像
    /// marker 的文字不是 marker，裡面的 `\chapter` 也不是章節。
    ///
    /// ## N 的來源
    ///
    /// N 取自錨點之前（第一個 marker 則是它自己）最近的 page marker。marker 是轉寫流程寫入的
    /// 頁序（`PageResult.page`），本函式把它當成要顯示的頁碼。
    ///
    /// ## 錨點（封閉列舉，只有這三類）
    ///
    /// 1. **第一個 page marker**：counter 插在 marker 行之後。
    /// 2. **章節邊界**：一行的第一個非空白 token 是 `\chapter` 控制字（`\chapterauthor` 不算）。
    ///    counter 插在章名閉合大括號所在行之後；`*`、`[短標題]`、`{章名}` 之間可以有空白、換行與
    ///    註解，章名長度不設上限。理由：`\chapter` 會先 `\clearpage`／`\cleardoublepage`，
    ///    counter 放在它之前會被記到前一頁，章首頁變成 N+1（pdflatex 實測：前 → 19、後 → 18）。
    /// 3. **切回阿拉伯數字**：`\mainmatter` 或 `\pagenumbering{arabic}`。兩者把 counter 重設為 1，
    ///    counter 插在該行之後；同一行有多個切換指令時以最後一個為準。
    ///
    /// 錨點 1 與 3 若下一個有內容的行（略過空行與只有註解的行）是章節或切換指令，就省略，
    /// 交給後者處理。沒有前置 marker 的錨點不動。
    ///
    /// ## 章節錨點的既有 counter
    ///
    /// - 章名之後那一行已是 `\setcounter{page}{…}`：視為已處理，不動。
    /// - `\chapter` 前一行是 `\setcounter{page}{M}`（且那一行不是上一章的章後 counter）：
    ///   M 等於 N → 這是舊版的放法，把那一行原樣移到章名之後（`legacyCounterMoved`）；
    ///   M 不等於 N → 原樣保留、該章不插入，回報 `conflictingCounterBeforeChapter`。
    ///
    /// ## 找不到章名
    ///
    /// `\chapter` 之後找不到 `{`、或 `{` 在 `\end{document}` 之前沒有閉合時，整份原始碼不動，
    /// 回報 `chapterTitleNotFound`：大括號結構已經壞了，任何結構性插入都不可靠。
    ///
    /// ## Roman numerals：保守契約
    ///
    /// 頁碼樣式只由**被執行的**切換指令決定。以下是封閉列舉，不得依性質相似類推其他訊號：
    ///
    /// - `\frontmatter`、`\pagenumbering{roman}`、`\pagenumbering{Roman}` → roman 區段
    /// - `\mainmatter`、`\pagenumbering{arabic}` → arabic 區段
    /// - 其他 `\pagenumbering{…}`（如 `alph`）→ 不受管理的區段
    /// - 出現任何上述指令之前 → arabic（LaTeX 預設）
    ///
    /// 「被執行」= 真正的控制字邊界（`\\mainmatter` 是換行加文字，不算），且不在巨集定義內
    /// （`\newcommand{\prefaceMode}{\frontmatter}` 不會切換；之後呼叫 `\prefaceMode` 也不展開追蹤）。
    /// 頁碼數字小、位在第一個 `\chapter` 之前、`\chapter*{Preface}`、`\tableofcontents`
    /// **都不是** front-matter 證據，不會觸發 roman。
    ///
    /// roman 與不受管理的區段內不插入任何 counter：marker 是實體頁序，不是該區段的頁標籤。
    /// 本函式不輸出 `\pagenumbering`：承認的證據就是上列指令本身，它們已完成切換；本函式只在
    /// 切回 arabic 後把被重設為 1 的 counter 還原成原書頁碼。PDF page labels 尚未納入此契約。
    ///
    /// ## 冪等
    ///
    /// 已處理過的錨點後面都有 counter，重跑不再插入；舊版 counter 移過之後不再位於章前。
    public static func applyPageCounters(_ source: String) -> PageCounterReport {
        let scan = LaTeXSourceScan(source)
        guard let firstMarker = scan.pageMarkers.first else {
            return PageCounterReport(result: source, notes: [])
        }

        var chapters: [ChapterCommand] = []
        for word in scan.controlWords where word.name == "chapter" && scan.isActive(word.start) {
            let line = scan.line(of: word.start)
            guard scan.firstNonBlank(line: line) == word.start else { continue }
            guard let end = chapterCommandEnd(scan, after: word.end) else {
                return PageCounterReport(
                    result: source, notes: [PageCounterNote(line: line + 1, kind: .chapterTitleNotFound)]
                )
            }
            chapters.append(ChapterCommand(offset: word.start, startLine: line, endLine: scan.line(of: end - 1)))
        }

        let switches = scan.controlWords.compactMap { word -> NumberingSwitch? in
            guard scan.isExecuted(word.start), let style = numberingStyle(of: word, in: scan) else { return nil }
            return NumberingSwitch(offset: word.start, line: scan.line(of: word.start), style: style)
        }
        let lastSwitchOnLine = Dictionary(switches.map { ($0.line, $0.offset) }, uniquingKeysWith: max)

        var events: [PageCounterEvent] = [.firstMarker(firstMarker)]
        events += switches.map { .numberingSwitch($0) }
        events += chapters.map { .chapter($0) }
        events.sort { $0.offset < $1.offset }

        let lines = source.components(separatedBy: "\n")
        let context = AnchorContext(
            scan: scan,
            chapterStartLines: Set(chapters.map(\.startLine)),
            chapterEndLines: Set(chapters.map(\.endLine)),
            switchLines: Set(switches.map(\.line))
        )

        var style = PageNumberingStyle.arabic
        var insertAfter: [Int: [String]] = [:]
        var removed = Set<Int>()
        var notes: [PageCounterNote] = []

        func insertCounter(page: Int, afterLine line: Int, anchorLine: Int) {
            insertAfter[line, default: []].append("\\setcounter{page}{\(page)}")
            notes.append(PageCounterNote(line: anchorLine + 1, kind: .counterInserted(page: page)))
        }

        for event in events {
            switch event {
            case .numberingSwitch(let change):
                style = change.style
                guard change.style == .arabic, lastSwitchOnLine[change.line] == change.offset,
                      scan.body.contains(change.offset),
                      !context.nextContentLineTakesOver(after: change.line),
                      !context.hasPageCounter(line: change.line + 1),
                      let page = context.nearestPage(before: change.offset) else { continue }
                insertCounter(page: page, afterLine: change.line, anchorLine: change.line)

            case .firstMarker(let marker):
                guard style == .arabic,
                      !context.nextContentLineTakesOver(after: marker.line),
                      !context.hasPageCounter(line: marker.line + 1) else { continue }
                insertCounter(page: marker.page, afterLine: marker.line, anchorLine: marker.line)

            case .chapter(let chapter):
                guard style == .arabic,
                      let page = context.nearestPage(before: chapter.offset),
                      !context.hasPageCounter(line: chapter.endLine + 1) else { continue }
                let previous = chapter.startLine - 1
                if !context.chapterEndLines.contains(previous - 1),
                   let existing = context.pageCounterValue(line: previous) {
                    if existing == page {
                        removed.insert(previous)
                        insertAfter[chapter.endLine, default: []].append(lines[previous])
                        notes.append(PageCounterNote(line: chapter.startLine + 1, kind: .legacyCounterMoved(page: page)))
                    } else {
                        notes.append(PageCounterNote(
                            line: chapter.startLine + 1,
                            kind: .conflictingCounterBeforeChapter(existing: existing, expected: page)
                        ))
                    }
                    continue
                }
                insertCounter(page: page, afterLine: chapter.endLine, anchorLine: chapter.startLine)
            }
        }

        guard !insertAfter.isEmpty || !removed.isEmpty else {
            return PageCounterReport(result: source, notes: notes)
        }
        var output: [String] = []
        output.reserveCapacity(lines.count + insertAfter.count)
        for (index, line) in lines.enumerated() {
            if !removed.contains(index) { output.append(line) }
            if let extra = insertAfter[index] { output.append(contentsOf: extra) }
        }
        return PageCounterReport(result: output.joined(separator: "\n"), notes: notes)
    }

    /// 相容 API：回傳 `applyPageCounters(_:)` 的改寫結果。
    public static func insertPageCounters(_ source: String) -> String {
        applyPageCounters(source).result
    }

    // MARK: - Helpers

    /// `\chapter` 名稱之後：可選 `*`、可選 `[短標題]`、必要 `{章名}`（其間可有空白、換行、註解）。
    /// 回傳章名閉合大括號之後的 offset；找不到或超出 body 時回傳 nil。
    private static func chapterCommandEnd(_ scan: LaTeXSourceScan, after offset: Int) -> Int? {
        var k = scan.skipIgnorable(from: offset)
        if k < scan.units.count && scan.units[k] == U.star && scan.kinds[k] == .code {
            k = scan.skipIgnorable(from: k + 1)
        }
        if k < scan.units.count && scan.units[k] == U.openBracket && scan.kinds[k] == .code {
            guard let end = scan.optionalEnd(from: k) else { return nil }
            k = scan.skipIgnorable(from: end)
        }
        guard let end = scan.groupEnd(from: k), end <= scan.body.upperBound else { return nil }
        return end
    }

    /// 控制字若是頁碼樣式切換指令（封閉列舉），回傳其樣式。
    private static func numberingStyle(of word: LaTeXSourceScan.ControlWord, in scan: LaTeXSourceScan) -> PageNumberingStyle? {
        switch word.name {
        case "frontmatter":
            return .roman
        case "mainmatter":
            return .arabic
        case "pagenumbering":
            let open = scan.skipIgnorable(from: word.end)
            guard let end = scan.groupEnd(from: open) else { return nil }
            switch scan.codeText((open + 1)..<(end - 1)).trimmingCharacters(in: .whitespacesAndNewlines) {
            case "arabic": return .arabic
            case "roman", "Roman": return .roman
            default: return .unmanaged
            }
        default:
            return nil
        }
    }
}

// MARK: - Internal Types

private struct ChapterCommand {
    let offset: Int
    let startLine: Int
    let endLine: Int
}

private struct NumberingSwitch {
    let offset: Int
    let line: Int
    let style: PageNumberingStyle
}

private enum PageCounterEvent {
    case firstMarker(LaTeXSourceScan.PageMarker)
    case numberingSwitch(NumberingSwitch)
    case chapter(ChapterCommand)

    var offset: Int {
        switch self {
        case .firstMarker(let marker): return marker.offset
        case .numberingSwitch(let change): return change.offset
        case .chapter(let chapter): return chapter.offset
        }
    }
}

private struct AnchorContext {
    let scan: LaTeXSourceScan
    let chapterStartLines: Set<Int>
    let chapterEndLines: Set<Int>
    let switchLines: Set<Int>

    private static let counterRegex = try! NSRegularExpression(pattern: #"^\\setcounter\{page\}\{\s*(\d+)\s*\}$"#)

    func nearestPage(before offset: Int) -> Int? {
        scan.pageMarkers.last(where: { $0.offset <= offset })?.page
    }

    /// 該行作用中的程式碼（去掉註解後、去頭尾空白與 CRLF 的 `\r`）；不作用中則為 nil。
    private func activeCode(line: Int) -> String? {
        guard line >= 0, line < scan.lineStarts.count,
              let first = scan.firstNonBlank(line: line), scan.isActive(first) else { return nil }
        return scan.codeText(scan.lineRange(line)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasPageCounter(line: Int) -> Bool {
        activeCode(line: line)?.hasPrefix("\\setcounter{page}") ?? false
    }

    func pageCounterValue(line: Int) -> Int? {
        guard let code = activeCode(line: line) else { return nil }
        let ns = code as NSString
        guard let match = Self.counterRegex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    /// 下一個有內容的行（略過空行與只有註解的行）是否為章節或切換指令。
    func nextContentLineTakesOver(after line: Int) -> Bool {
        var next = line + 1
        while next < scan.lineStarts.count && scan.lineStarts[next] < scan.body.upperBound {
            let code = scan.codeText(scan.lineRange(next)).trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty {
                next += 1
                continue
            }
            return chapterStartLines.contains(next) || switchLines.contains(next)
        }
        return false
    }
}
