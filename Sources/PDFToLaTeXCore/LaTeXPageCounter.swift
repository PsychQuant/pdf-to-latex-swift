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
    /// ## 錨點（封閉列舉，只有這三類）與其結尾
    ///
    /// 1. **第一個 page marker**：結尾是 marker 行的行尾。
    /// 2. **章節邊界**：每一個作用中的 `\chapter` 控制字（`\chapterauthor` 不算），不論在行首或行中；
    ///    同一行有多個 `\chapter` 時每個都是錨點。（只認行首會不冪等：第一輪在第一個章名之後斷行插入，
    ///    讓第二個 `\chapter` 變成行首，第二輪才被認出。）結尾是章名的閉合大括號；`*`、`[短標題]`、`{章名}` 之間可以有空白、換行與註解，章名長度
    ///    不設上限。理由：`\chapter` 會先 `\clearpage`／`\cleardoublepage`，counter 放在它之前會
    ///    被記到前一頁，章首頁變成 N+1（pdflatex 實測：前 → 19、後 → 18）。
    /// 3. **切回阿拉伯數字**：`\mainmatter`（結尾是指令名稱）或 `\pagenumbering{arabic}`（結尾是
    ///    參數的閉合大括號；指令與參數之間可以有換行與註解）。兩者把 counter 重設為 1。
    ///
    /// ## 插入位置
    ///
    /// 錨點結尾之後、同一行還有程式碼（例如 `\chapter{A}\end{document}`）→ 在結尾處斷行插入，
    /// 所以 counter 永遠在 `\end{document}` 之前；同一行只剩空白或註解 → 插在下一行開頭。插入的
    /// 換行沿用檔案的換行（CRLF 檔案插入 CRLF）。
    ///
    /// 錨點 1 與 3 之後的下一個 token（略過空白、換行與註解）若是章節或切換指令，就省略，交給後者
    /// 處理。沒有前置 marker 的錨點不動。
    ///
    /// ## 章節錨點的既有 counter
    ///
    /// - 章名之後的下一個 token 已是 `\setcounter{page}`：視為已處理，不動（找下一個 token 時不跨過
    ///   page marker：下一頁的 counter 不算這個錨點的）。
    /// - `\chapter` 是該行第一個 token，且前一行是 `\setcounter{page}{M}`（那一行不是緊接上一章之後的
    ///   counter）：
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
    /// 已處理過的錨點後面都跟著 counter，重跑不再插入；舊版 counter 移過之後不再位於章前。
    public static func applyPageCounters(_ source: String) -> PageCounterReport {
        let scan = LaTeXSourceScan(source)
        guard let firstMarker = scan.pageMarkers.first else {
            return PageCounterReport(result: source, notes: [])
        }

        var chapters: [ChapterCommand] = []
        for word in scan.controlWords where word.name == "chapter" && scan.isActive(word.start) {
            let line = scan.line(of: word.start)
            guard let end = chapterCommandEnd(scan, after: word.end) else {
                return PageCounterReport(
                    result: source, notes: [PageCounterNote(line: line + 1, kind: .chapterTitleNotFound)]
                )
            }
            chapters.append(ChapterCommand(
                offset: word.start, end: end, startLine: line, endLine: scan.line(of: end - 1),
                firstOnLine: scan.firstNonBlank(line: line) == word.start
            ))
        }

        let switches = scan.controlWords.compactMap { word -> NumberingSwitch? in
            guard scan.isExecuted(word.start), let (style, end) = numberingSwitch(word, in: scan) else { return nil }
            return NumberingSwitch(offset: word.start, end: end, line: scan.line(of: word.start), style: style)
        }

        var events: [PageCounterEvent] = [.firstMarker(firstMarker)]
        events += switches.map { .numberingSwitch($0) }
        events += chapters.map { .chapter($0) }
        events.sort { $0.offset < $1.offset }

        var context = AnchorContext(
            scan: scan,
            takeoverOffsets: Set(chapters.map(\.offset)).union(switches.map(\.offset)),
            chapterEndLines: Set(chapters.map(\.endLine)),
            markerOffsets: Set(scan.pageMarkers.map(\.offset)),
            ownedLegacyLines: [:]
        )

        // 先決定哪些舊版 counter 會被移走（由最後一章往前：「後面已有 counter」的判定只看後面），
        // 之後所有判定都把這些行當成已經不在，也就是用第二輪會看到的文件來判斷。
        var styleAtChapter: [Int: PageNumberingStyle] = [:]
        var runningStyle = PageNumberingStyle.arabic
        for event in events {
            switch event {
            case .numberingSwitch(let change): runningStyle = change.style
            case .chapter(let chapter): styleAtChapter[chapter.offset] = runningStyle
            case .firstMarker: break
            }
        }
        for chapter in chapters.reversed() {
            guard styleAtChapter[chapter.offset] == .arabic,
                  let page = context.nearestPage(before: chapter.offset),
                  !context.pageCounterFollows(chapter.end) else { continue }
            let previous = chapter.startLine - 1
            if chapter.firstOnLine, !context.chapterEndLines.contains(previous - 1),
               context.pageCounterValue(line: previous) == page {
                context.ownedLegacyLines[previous] = chapter.offset
            }
        }

        var style = PageNumberingStyle.arabic
        var edits: [(range: Range<Int>, text: String)] = []
        var notes: [PageCounterNote] = []

        func insertCounter(page: Int, after end: Int, anchorLine: Int) {
            edits.append(context.insertion(after: end, text: "\\setcounter{page}{\(page)}"))
            notes.append(PageCounterNote(line: anchorLine + 1, kind: .counterInserted(page: page)))
        }

        for event in events {
            switch event {
            case .numberingSwitch(let change):
                style = change.style
                guard change.style == .arabic, scan.body.contains(change.offset),
                      change.end <= scan.body.upperBound,
                      !context.nextTokenTakesOver(after: change.end),
                      !context.pageCounterFollows(change.end),
                      let page = context.nearestPage(before: change.offset) else { continue }
                insertCounter(page: page, after: change.end, anchorLine: change.line)

            case .firstMarker(let marker):
                let end = scan.lineRange(marker.line).upperBound
                guard style == .arabic,
                      !context.nextTokenTakesOver(after: end),
                      !context.pageCounterFollows(end) else { continue }
                insertCounter(page: marker.page, after: end, anchorLine: marker.line)

            case .chapter(let chapter):
                guard style == .arabic, let page = context.nearestPage(before: chapter.offset) else { continue }
                let previous = chapter.startLine - 1
                if context.ownedLegacyLines[previous] == chapter.offset {
                    edits.append((context.wholeLine(previous), ""))
                    edits.append(context.insertion(after: chapter.end, text: context.lineContent(previous)))
                    notes.append(PageCounterNote(line: chapter.startLine + 1, kind: .legacyCounterMoved(page: page)))
                    continue
                }
                guard !context.pageCounterFollows(chapter.end) else { continue }
                if chapter.firstOnLine, !context.chapterEndLines.contains(previous - 1),
                   let existing = context.pageCounterValue(line: previous) {
                    notes.append(PageCounterNote(
                        line: chapter.startLine + 1,
                        kind: .conflictingCounterBeforeChapter(existing: existing, expected: page)
                    ))
                    continue
                }
                insertCounter(page: page, after: chapter.end, anchorLine: chapter.startLine)
            }
        }

        guard !edits.isEmpty else {
            return PageCounterReport(result: source, notes: notes)
        }
        // 由後往前套用；同一個起點時先套用範圍較大的（刪除），再套用插入。
        let ordered = edits.sorted(by: {
            ($0.range.lowerBound, $0.range.upperBound) > ($1.range.lowerBound, $1.range.upperBound)
        })
        // 安全網：編輯不可重疊（插入點可以落在刪除範圍的起點）。重疊代表邏輯錯誤：debug 直接中止，
        // release 則原樣回傳，絕不輸出被弄壞的原文。
        for (later, earlier) in zip(ordered, ordered.dropFirst())
        where earlier.range.upperBound > later.range.lowerBound
            || (earlier.range.lowerBound == later.range.lowerBound && !later.range.isEmpty && !earlier.range.isEmpty) {
            assertionFailure("overlapping page-counter edits: \(earlier.range) / \(later.range)")
            return PageCounterReport(result: source, notes: [])
        }
        var units = scan.units
        for edit in ordered {
            units.replaceSubrange(edit.range, with: Array(edit.text.utf16))
        }
        return PageCounterReport(result: String(decoding: units, as: UTF16.self), notes: notes)
    }

    /// 相容 API：回傳 `applyPageCounters(_:)` 的改寫結果。
    public static func insertPageCounters(_ source: String) -> String {
        applyPageCounters(source).result
    }

    // MARK: - Helpers

    /// `\chapter` 名稱之後：可選 `*`、可選 `[短標題]`、必要 `{章名}`（其間可有空白、換行、註解）。
    /// 回傳章名閉合大括號之後的 offset；找不到或超出 body 時回傳 nil。
    static func chapterCommandEnd(_ scan: LaTeXSourceScan, after offset: Int) -> Int? {
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

    /// 控制字若是頁碼樣式切換指令（封閉列舉），回傳其樣式與整個指令（含參數）的結尾 offset。
    private static func numberingSwitch(
        _ word: LaTeXSourceScan.ControlWord, in scan: LaTeXSourceScan
    ) -> (PageNumberingStyle, Int)? {
        switch word.name {
        case "frontmatter":
            return (.roman, word.end)
        case "mainmatter":
            return (.arabic, word.end)
        case "pagenumbering":
            guard let argument = scan.readGroupArgument(from: word.end) else { return nil }
            switch argument.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "arabic": return (.arabic, argument.range.upperBound)
            case "roman", "Roman": return (.roman, argument.range.upperBound)
            default: return (.unmanaged, argument.range.upperBound)
            }
        default:
            return nil
        }
    }
}

// MARK: - Internal Types

private struct ChapterCommand {
    let offset: Int
    /// 章名閉合大括號之後的 offset。
    let end: Int
    let startLine: Int
    let endLine: Int
    /// `\chapter` 是否為該行第一個 token（舊版 counter 的判定只適用於這種）。
    let firstOnLine: Bool
}

private struct NumberingSwitch {
    let offset: Int
    /// 整個指令（含參數）之後的 offset。
    let end: Int
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
    /// 章節錨點與切換指令的起點：錨點 1、3 之後的下一個 token 若在此，就交給它處理。
    let takeoverOffsets: Set<Int>
    let chapterEndLines: Set<Int>
    let markerOffsets: Set<Int>
    /// 這一輪會被移到章名之後的舊版 counter 行 → 擁有它的章節 offset（只有行首那一章）。
    /// 所有「下一個 token」的判定都當這些行已經不在。
    var ownedLegacyLines: [Int: Int]

    private static let counterRegex = try! NSRegularExpression(pattern: #"^\\setcounter\{page\}\{\s*(\d+)\s*\}$"#)

    func nearestPage(before offset: Int) -> Int? {
        scan.pageMarkers.last(where: { $0.offset <= offset })?.page
    }

    /// 結尾之後的下一個 token：略過空白、換行、註解，以及即將被移走的舊版 counter 行。
    /// `stopAtMarker` 為真時，遇到 page marker 就回傳 nil（下一頁的東西不屬於這個錨點）。
    private func nextToken(after end: Int, stopAtMarker: Bool) -> Int? {
        var k = end
        while k < scan.units.count {
            if U.isWhitespace(scan.units[k]) {
                k += 1
            } else if scan.kinds[k] == .comment {
                if stopAtMarker && markerOffsets.contains(k) { return nil }
                while k < scan.units.count && scan.kinds[k] == .comment { k += 1 }
            } else {
                let line = scan.line(of: k)
                guard ownedLegacyLines[line] != nil, scan.firstNonBlank(line: line) == k else { return k }
                k = scan.lineRange(line).upperBound
            }
        }
        return k
    }

    func nextTokenTakesOver(after end: Int) -> Bool {
        guard let next = nextToken(after: end, stopAtMarker: false) else { return false }
        return next < scan.body.upperBound && takeoverOffsets.contains(next)
    }

    /// 結尾之後的下一個 token（略過空白、換行與註解，但**不跨過 page marker**）是否為作用中的
    /// `\setcounter{page}`。下一個 marker 之後的 counter 屬於後面的頁與錨點（例如下一章的舊版
    /// counter）；若把它算成這個錨點的，第一輪會略過這個錨點、該 counter 被移走後第二輪又替它插入。
    func pageCounterFollows(_ end: Int) -> Bool {
        guard let next = nextToken(after: end, stopAtMarker: true),
              next < scan.body.upperBound, scan.isActive(next),
              let word = scan.controlWords.first(where: { $0.start == next }), word.name == "setcounter",
              let argument = scan.readGroupArgument(from: word.end) else { return false }
        return argument.text.trimmingCharacters(in: .whitespaces) == "page"
    }

    /// 插在錨點結尾之後：同一行還有程式碼就在結尾處斷行，否則插在下一行開頭。
    func insertion(after end: Int, text: String) -> (range: Range<Int>, text: String) {
        let eol = scan.lineEnding
        let lineEnd = scan.lineRange(scan.line(of: end)).upperBound
        let codeFollows = (end..<lineEnd).contains {
            scan.kinds[$0] != .comment && !U.isWhitespace(scan.units[$0])
        }
        if codeFollows {
            return (end..<end, eol + text + eol)
        }
        guard lineEnd < scan.units.count else {
            return (lineEnd..<lineEnd, eol + text)
        }
        return ((lineEnd + 1)..<(lineEnd + 1), text + eol)
    }

    /// 整行（含行尾換行）的範圍。
    func wholeLine(_ line: Int) -> Range<Int> {
        let start = scan.lineStarts[line]
        let end = line + 1 < scan.lineStarts.count ? scan.lineStarts[line + 1] : scan.units.count
        return start..<end
    }

    /// 一行的原文（不含換行與 CRLF 的 `\r`）。
    func lineContent(_ line: Int) -> String {
        var text = scan.text(scan.lineRange(line))
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// 該行作用中的程式碼（去掉註解後、去頭尾空白與 CRLF 的 `\r`）；不作用中則為 nil。
    private func activeCode(line: Int) -> String? {
        guard line >= 0, line < scan.lineStarts.count,
              let first = scan.firstNonBlank(line: line), scan.isActive(first) else { return nil }
        return scan.codeText(scan.lineRange(line)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pageCounterValue(line: Int) -> Int? {
        guard let code = activeCode(line: line) else { return nil }
        let ns = code as NSString
        guard let match = Self.counterRegex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }
}
