import Foundation

/// LaTeX 原始碼的「作用中」掃描。頁碼還原（PsychQuant/macdoc#9）與圖片寬度還原
/// （PsychQuant/macdoc#10）共用同一份判定，確保兩者對「哪裡是真正會被執行的 LaTeX」看法一致。
///
/// 每個 UTF-16 單位分成三類：
///
/// - **comment**：未跳脫的 `%` 到行尾（`\%` 是字元，不是註解）。
/// - **verbatim**（封閉列舉，只有這些）：`verbatim`、`verbatim*`、`Verbatim`、`Verbatim*`、
///   `lstlisting`、`minted`、`comment` 環境的內容（結束規則因環境而異，見 `VerbatimTermination`；
///   開始那一行 `\begin{env}` 之後的文字一律不會被執行），以及 inline `\verb`／`\verb*`
///   （分隔字元規則見 `verbEnd`）。
/// - **code**：其餘。
///
/// 環境名稱與 document 邊界的參數用同一個讀取器（`readGroupArgument`）：`\begin`／`\end` 與
/// `{name}` 之間可以有空白、換行與註解（pdflatex 實測 `\begin% c⏎{verbatim}` 會開始 verbatim）。
///
/// 程式碼視圖（`texCodeText`）依 TeX 的註解語意：`%` 到行尾，連同換行與下一行開頭的空白一起
/// 消失（pdflatex 實測 `[wid%⏎    th=3cm]` 的 key 是 width）；沒有註解的換行是一個空白。
///
/// 巨集定義內的內容不會在定義處執行。定義指令（封閉列舉）：`\newcommand`、`\renewcommand`、
/// `\providecommand`、`\DeclareRobustCommand`、`\def`、`\gdef`、`\edef`、`\xdef`、`\let`、
/// `\NewDocumentCommand`、`\RenewDocumentCommand`、`\ProvideDocumentCommand`、
/// `\DeclareDocumentCommand`、`\newenvironment`、`\renewenvironment`。定義範圍涵蓋到該指令
/// 最後一個參數的閉合大括號（`\let` 則是被指派的那個 token）；參數不平衡時只涵蓋指令本身。
///
/// **作用中** = code、不在巨集定義內、位於 document body（`\begin{document}` 之後到
/// `\end{document}` 之前；沒有 `\begin{document}` 時整份都是 body）。
///
/// **page marker 行** = 整行恰好是 `%% === Page N ===`（前後只允許空格／tab，CRLF 的 `\r` 亦可），
/// 且那個 `%` 是註解起點、不在巨集定義內。後面接其他文字（`%% === Page 12 === 說明`）或位於其他
/// 註解中間（`% 例：%% === Page 12 ===`）都不是 marker。`pageMarkers` 只收 body 內的；
/// `markerLines` 不限 body，供移除 marker 用。
struct LaTeXSourceScan {
    enum Kind: UInt8 {
        case code
        case comment
        case verbatim
    }

    struct ControlWord {
        let name: String
        /// `\` 的 offset。
        let start: Int
        /// 名稱之後的 offset。
        let end: Int
    }

    struct PageMarker {
        let offset: Int
        /// 0 起算的行號。
        let line: Int
        let page: Int
    }

    /// verbatim 類環境怎麼結束。全部以 pdflatex（TeX Live 2025；fancyvrb 4.5c、listings 1.10c、
    /// comment、minted 3.6.0）實測決定。`\end {env}`（中間有空白）與 `\end%⏎{env}` 在所有環境都
    /// 不會結束。
    enum VerbatimTermination {
        /// 第一個字面 `\end{env}`（行中也算）結束；同一行其後的文字照常執行。
        /// kernel `verbatim`、`verbatim*`，listings `lstlisting`。
        case literalAnywhereRestOfLineExecuted
        /// 第一個字面 `\end{env}`（行中也算）結束；同一行其後的文字被丟棄（FancyVerb Error），不執行。
        /// fancyvrb `Verbatim`、`Verbatim*`，minted `minted`。
        case literalAnywhereRestOfLineDropped
        /// 只有「整行恰好是 `\end{env}`」才結束（行首不可有空白；行尾空格被 TeX 去掉所以可以，
        /// tab 不行；CRLF 可以）。comment 套件的 `comment`。
        case wholeLineOnly
    }

    static let verbatimEnvironments: [String: VerbatimTermination] = [
        "verbatim": .literalAnywhereRestOfLineExecuted,
        "verbatim*": .literalAnywhereRestOfLineExecuted,
        "lstlisting": .literalAnywhereRestOfLineExecuted,
        "Verbatim": .literalAnywhereRestOfLineDropped,
        "Verbatim*": .literalAnywhereRestOfLineDropped,
        "minted": .literalAnywhereRestOfLineDropped,
        "comment": .wholeLineOnly,
    ]

    let units: [UInt16]
    let kinds: [Kind]
    let lineStarts: [Int]
    /// code 中的控制字（依出現順序；verbatim 與註解內的不在此列）。
    let controlWords: [ControlWord]
    let body: Range<Int>
    /// body 內的 page marker（依 offset 排序）。
    let pageMarkers: [PageMarker]
    /// 所有 page marker 行（0 起算，不限 body），供移除 marker 用。
    let markerLines: [Int]
    private let definitionMask: [Bool]

    init(_ source: String) {
        let units = Array(source.utf16)
        let (kinds, words) = Self.classify(units)
        var starts = [0]
        for (offset, unit) in units.enumerated() where unit == U.newline {
            starts.append(offset + 1)
        }
        let mask = Self.computeDefinitionMask(units: units, kinds: kinds, words: words)
        let body = Self.documentBody(units: units, words: words, mask: mask)

        var markers: [PageMarker] = []
        var markerLines: [Int] = []
        let regex = try! NSRegularExpression(
            pattern: #"^[ \t]*%%[ \t]*===[ \t]*Page[ \t]+(\d+)[ \t]*===[ \t]*\r?$"#
        )
        for (line, start) in starts.enumerated() {
            var p = start
            while p < units.count && (units[p] == U.space || units[p] == U.tab) { p += 1 }
            guard p < units.count, units[p] == U.percent, kinds[p] == .comment, !mask[p] else { continue }
            var end = p
            while end < units.count && units[end] != U.newline { end += 1 }
            let text = String(decoding: units[start..<end], as: UTF16.self)
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  let page = Int(ns.substring(with: match.range(at: 1))) else { continue }
            markerLines.append(line)
            if body.contains(p) {
                markers.append(PageMarker(offset: p, line: line, page: page))
            }
        }

        self.units = units
        self.kinds = kinds
        self.controlWords = words
        self.lineStarts = starts
        self.definitionMask = mask
        self.body = body
        self.pageMarkers = markers
        self.markerLines = markerLines
    }

    // MARK: - Queries

    func isActive(_ offset: Int) -> Bool {
        offset >= 0 && offset < units.count
            && kinds[offset] == .code && !definitionMask[offset] && body.contains(offset)
    }

    /// code 且位於 document body（巨集定義內也算）。轉寫當下改寫圖片路徑用：定義內的路徑在
    /// 巨集被呼叫時才會用到，檔名改了它也要跟著改。
    func isCodeInBody(_ offset: Int) -> Bool {
        offset >= 0 && offset < units.count && kinds[offset] == .code && body.contains(offset)
    }

    func isExecuted(_ offset: Int) -> Bool {
        offset >= 0 && offset < units.count && kinds[offset] == .code && !definitionMask[offset]
    }

    /// 0 起算的行號。
    func line(of offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func lineRange(_ line: Int) -> Range<Int> {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : units.count
        return start..<end
    }

    /// 這一行、它結尾的換行、或它前面的換行是否有 verbatim 單位（PsychQuant/macdoc#215）。
    ///
    /// 為真時，刪除這一行或在它之後插入文字都可能改到 verbatim：`\begin{verbatim}` 那一行（行尾換行
    /// 已是內容）、verbatim 內容、`\end{verbatim}` 那一行（前面的換行是內容）、含 `\verb` 的行。
    func lineTouchesVerbatim(_ line: Int) -> Bool {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : units.count
        return (max(0, start - 1)..<end).contains { kinds[$0] == .verbatim }
    }

    /// 每一段連續 verbatim 的內容（依出現順序）。以行為單位的編輯用它確認 verbatim 完全沒變：
    /// 編輯前後的值相同，才表示沒有刪到、插進、或改變任何 verbatim 範圍。
    var verbatimSegments: [String] {
        var segments: [String] = []
        var k = 0
        while k < units.count {
            guard kinds[k] == .verbatim else {
                k += 1
                continue
            }
            let start = k
            while k < units.count && kinds[k] == .verbatim { k += 1 }
            segments.append(text(start..<k))
        }
        return segments
    }

    /// 這一行結尾的換行是否為 verbatim（在它之後插入一行會插進 verbatim 內容）。沒有換行時為 false。
    func lineEndIsVerbatim(_ line: Int) -> Bool {
        guard line + 1 < lineStarts.count else { return false }
        return kinds[lineStarts[line + 1] - 1] == .verbatim
    }

    /// 行內第一個非空白（空格／tab）的 offset。
    func firstNonBlank(line: Int) -> Int? {
        let range = lineRange(line)
        var p = range.lowerBound
        while p < range.upperBound && (units[p] == U.space || units[p] == U.tab) { p += 1 }
        return p < range.upperBound ? p : nil
    }

    /// 範圍內只保留 code 的文字（去掉註解與 verbatim）。
    func codeText(_ range: Range<Int>) -> String {
        String(decoding: range.filter { kinds[$0] == .code }.map { units[$0] }, as: UTF16.self)
    }

    /// 依 TeX 語意的程式碼文字：去掉 verbatim；註解（`%` 到行尾）連同換行與下一行開頭的
    /// 空格／tab 一起消失；其他換行（含 CRLF）變成一個空白並略過下一行開頭的空格／tab。
    func texCodeText(_ range: Range<Int>) -> String {
        var out: [UInt16] = []
        var k = range.lowerBound
        let upper = range.upperBound
        func skipLeadingBlanks() {
            while k < upper && (units[k] == U.space || units[k] == U.tab) { k += 1 }
        }
        while k < upper {
            switch kinds[k] {
            case .verbatim:
                k += 1
            case .comment:
                while k < upper && kinds[k] == .comment { k += 1 }
                if k < upper && units[k] == U.newline {
                    k += 1
                    skipLeadingBlanks()
                }
            case .code:
                let unit = units[k]
                if unit == U.carriageReturn && k + 1 < upper && units[k + 1] == U.newline {
                    k += 1
                } else if unit == U.newline {
                    out.append(U.space)
                    k += 1
                    skipLeadingBlanks()
                } else {
                    out.append(unit)
                    k += 1
                }
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// 檔案使用的換行：第一個換行前是 `\r` 就是 CRLF，否則 LF。
    var lineEnding: String {
        guard let first = units.firstIndex(of: U.newline) else { return "\n" }
        return (first > 0 && units[first - 1] == U.carriageReturn) ? "\r\n" : "\n"
    }

    func readGroupArgument(from offset: Int) -> GroupArgument? {
        Self.readGroupArgument(units, from: offset)
    }

    func text(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    // MARK: - Argument parsing (comments and whitespace are skipped)

    /// 略過空白（含換行）與註解。
    func skipIgnorable(from offset: Int) -> Int {
        var k = offset
        while k < units.count && (kinds[k] == .comment || U.isWhitespace(units[k])) { k += 1 }
        return k
    }

    /// `offset` 指向 code 的 `{`；回傳對應 `}` 之後的 offset。不平衡時回傳 nil。
    func groupEnd(from offset: Int) -> Int? {
        guard offset < units.count, units[offset] == U.openBrace, kinds[offset] == .code else { return nil }
        var depth = 0
        var k = offset
        while k < units.count {
            guard kinds[k] == .code else {
                k += 1
                continue
            }
            switch units[k] {
            case U.backslash:
                k += 2
                continue
            case U.openBrace:
                depth += 1
            case U.closeBrace:
                depth -= 1
                if depth == 0 { return k + 1 }
            default:
                break
            }
            k += 1
        }
        return nil
    }

    /// `offset` 指向 code 的 `[`；回傳大括號外第一個 `]` 之後的 offset。不平衡時回傳 nil。
    func optionalEnd(from offset: Int) -> Int? {
        guard offset < units.count, units[offset] == U.openBracket, kinds[offset] == .code else { return nil }
        var depth = 0
        var k = offset + 1
        while k < units.count {
            guard kinds[k] == .code else {
                k += 1
                continue
            }
            switch units[k] {
            case U.backslash:
                k += 2
                continue
            case U.openBrace:
                depth += 1
            case U.closeBrace:
                depth -= 1
            case U.closeBracket where depth == 0:
                return k + 1
            default:
                break
            }
            k += 1
        }
        return nil
    }

    /// 一個 token：控制序列、`{…}` 群組或單一字元。
    func tokenEnd(from offset: Int) -> Int? {
        guard offset < units.count else { return nil }
        if units[offset] == U.backslash {
            var k = offset + 1
            guard k < units.count else { return nil }
            if U.isLetter(units[k]) {
                while k < units.count && U.isLetter(units[k]) { k += 1 }
                return k
            }
            return k + 1
        }
        if units[offset] == U.openBrace { return groupEnd(from: offset) }
        return offset + 1
    }

    // MARK: - Classification

    private static func classify(_ units: [UInt16]) -> ([Kind], [ControlWord]) {
        var kinds = [Kind](repeating: .code, count: units.count)
        var words: [ControlWord] = []
        let n = units.count
        var i = 0
        while i < n {
            let unit = units[i]
            if unit == U.percent {
                while i < n && units[i] != U.newline {
                    kinds[i] = .comment
                    i += 1
                }
                continue
            }
            guard unit == U.backslash else {
                i += 1
                continue
            }
            guard i + 1 < n, U.isLetter(units[i + 1]) else {
                i += 2  // 控制符號（\%、\\、\{ …）整組跳過
                continue
            }
            var j = i + 1
            while j < n && U.isLetter(units[j]) { j += 1 }
            let name = String(decoding: units[(i + 1)..<j], as: UTF16.self)

            if name == "verb", let end = verbEnd(units, after: j) {
                for k in j..<end { kinds[k] = .verbatim }
                i = end
                continue
            }
            words.append(ControlWord(name: name, start: i, end: j))

            if name == "begin", let argument = readGroupArgument(units, from: j),
               let termination = verbatimEnvironments[argument.text] {
                for comment in argument.comments {
                    for k in comment { kinds[k] = .comment }
                }
                let contentStart = argument.range.upperBound
                let terminator = Array("\\end{\(argument.text)}".utf16)
                let close: Int
                switch termination {
                case .literalAnywhereRestOfLineExecuted, .literalAnywhereRestOfLineDropped:
                    close = find(terminator, in: units, from: contentStart) ?? n
                case .wholeLineOnly:
                    close = findWholeLine(terminator, in: units, after: contentStart) ?? n
                }
                for k in contentStart..<close { kinds[k] = .verbatim }
                i = close
                if termination == .literalAnywhereRestOfLineDropped && close < n {
                    // \end{env} 本身是程式碼，同一行其後的文字被丟棄：標成 verbatim 並跳過。
                    var lineEnd = close + terminator.count
                    while lineEnd < n && units[lineEnd] != U.newline { lineEnd += 1 }
                    for k in (close + terminator.count)..<lineEnd { kinds[k] = .verbatim }
                    i = lineEnd
                }
                continue
            }
            i = j
        }
        return (kinds, words)
    }

    /// `\verb` 名稱之後的 verbatim 範圍結尾。規則以 pdflatex（TeX Live 2025）實測決定，對應
    /// kernel 的 `\verb`／`\@sverb`（`\dospecials` 先把空格改成 other，再用 `\@ifstar` 看星號；
    /// `\@sverb` 略過字元碼 32 的 token；`\obeylines` 讓行尾也能當分隔字元）：
    ///
    /// 1. 名稱之後的 tab 被略過；接著緊鄰的 `*` 才是星號形式。空格之後的 `*` 不是星號形式，
    ///    而是分隔字元（`\verb *x*` 的內容是 `x`）。
    /// 2. 再略過任意空格與 tab。
    /// 3. 下一個字元若是行尾（LF 或 CRLF），分隔字元就是行尾：內容是下一整行（含開頭空白）。
    /// 4. 否則下一個字元（字母、`%`、`{`、`\\` 都可以）就是分隔字元，內容到同一行的下一個相同
    ///    字元；行尾先到時 LaTeX 報「\verb ended by end of line」並在行尾結束，這裡也到行尾為止。
    ///
    /// 名稱之後緊接字母的情形（`\verbX`）在讀控制字時就成了另一個控制字，不會進到這裡。
    private static func verbEnd(_ units: [UInt16], after offset: Int) -> Int? {
        let n = units.count
        func isLineEnd(_ k: Int) -> Bool {
            units[k] == U.newline || (units[k] == U.carriageReturn && k + 1 < n && units[k + 1] == U.newline)
        }
        var k = offset
        while k < n && units[k] == U.tab { k += 1 }
        if k < n && units[k] == U.star { k += 1 }
        while k < n && (units[k] == U.space || units[k] == U.tab) { k += 1 }
        guard k < n else { return nil }

        if isLineEnd(k) {
            var next = k
            while next < n && units[next] != U.newline { next += 1 }
            next += 1
            guard next < n else { return n }
            var end = next
            while end < n && units[end] != U.newline { end += 1 }
            return end
        }

        let delimiter = units[k]
        var m = k + 1
        while m < n && units[m] != delimiter && !isLineEnd(m) { m += 1 }
        return (m < n && units[m] == delimiter) ? m + 1 : m
    }

    /// 一個大括號參數的讀取結果。
    struct GroupArgument {
        /// 含大括號的範圍。
        let range: Range<Int>
        /// 內容的 TeX 文字（註解與其後的換行、下一行開頭空白已移除；其他換行變成空白）。
        let text: String
        /// 沿途的註解（`%` 到行尾，不含換行）。
        let comments: [Range<Int>]
    }

    /// 依 TeX 讀取未定界參數的方式：略過空白（含換行）與註解，期望 `{`，讀到平衡的 `}`。
    /// 環境名稱（`\begin`／`\end`）、document 邊界與 `\pagenumbering` 的參數都用它。
    static func readGroupArgument(_ units: [UInt16], from offset: Int) -> GroupArgument? {
        let n = units.count
        var comments: [Range<Int>] = []
        var k = offset

        func skipComment() {
            let start = k
            while k < n && units[k] != U.newline { k += 1 }
            comments.append(start..<k)
        }

        while k < n {
            if U.isWhitespace(units[k]) {
                k += 1
            } else if units[k] == U.percent {
                skipComment()
            } else {
                break
            }
        }
        guard k < n, units[k] == U.openBrace else { return nil }

        let open = k
        var depth = 0
        var text: [UInt16] = []
        while k < n {
            let unit = units[k]
            switch unit {
            case U.backslash:
                text.append(unit)
                if k + 1 < n { text.append(units[k + 1]) }
                k += 2
                continue
            case U.percent:
                skipComment()
                if k < n { k += 1 }
                while k < n && (units[k] == U.space || units[k] == U.tab) { k += 1 }
                continue
            case U.openBrace:
                depth += 1
                if depth > 1 { text.append(unit) }
            case U.closeBrace:
                depth -= 1
                if depth == 0 {
                    return GroupArgument(
                        range: open..<(k + 1), text: String(decoding: text, as: UTF16.self), comments: comments
                    )
                }
                text.append(unit)
            case U.carriageReturn where k + 1 < n && units[k + 1] == U.newline:
                break
            case U.newline:
                text.append(U.space)
                k += 1
                while k < n && (units[k] == U.space || units[k] == U.tab) { k += 1 }
                continue
            default:
                text.append(unit)
            }
            k += 1
        }
        return nil
    }

    /// `offset` 所在行之後，第一個「整行恰好是 `needle`」的行首 offset（行尾空格與 CRLF 的 `\r` 忽略）。
    private static func findWholeLine(_ needle: [UInt16], in units: [UInt16], after offset: Int) -> Int? {
        var lineStart = offset
        while lineStart < units.count && units[lineStart] != U.newline { lineStart += 1 }
        lineStart += 1
        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count && units[lineEnd] != U.newline { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > lineStart && units[contentEnd - 1] == U.carriageReturn { contentEnd -= 1 }
            while contentEnd > lineStart && units[contentEnd - 1] == U.space { contentEnd -= 1 }
            if Array(units[lineStart..<contentEnd]) == needle { return lineStart }
            lineStart = lineEnd + 1
        }
        return nil
    }

    private static func find(_ needle: [UInt16], in units: [UInt16], from offset: Int) -> Int? {
        guard !needle.isEmpty, units.count >= needle.count else { return nil }
        var k = offset
        while k + needle.count <= units.count {
            if units[k] == needle[0] && Array(units[k..<(k + needle.count)]) == needle { return k }
            k += 1
        }
        return nil
    }

    // MARK: - Macro definitions

    private enum DefinitionShape {
        /// `\newcommand*{\name}[n][default]{body}`
        case latexCommand
        /// `\def\name<parameter text>{body}`
        case texDef
        /// `\let\name=<token>`（右側 token 的讀法見 `letAssignmentEnd`）
        case letAssignment
        /// `\NewDocumentCommand{\name}{argspec}{body}`
        case documentCommand
        /// `\newenvironment*{name}[n][default]{begin}{end}`
        case environment
    }

    private static let definitionShapes: [String: DefinitionShape] = [
        "newcommand": .latexCommand, "renewcommand": .latexCommand,
        "providecommand": .latexCommand, "DeclareRobustCommand": .latexCommand,
        "def": .texDef, "gdef": .texDef, "edef": .texDef, "xdef": .texDef,
        "let": .letAssignment,
        "NewDocumentCommand": .documentCommand, "RenewDocumentCommand": .documentCommand,
        "ProvideDocumentCommand": .documentCommand, "DeclareDocumentCommand": .documentCommand,
        "newenvironment": .environment, "renewenvironment": .environment,
    ]

    private static func computeDefinitionMask(units: [UInt16], kinds: [Kind], words: [ControlWord]) -> [Bool] {
        var mask = [Bool](repeating: false, count: units.count)
        // 用一份暫時的 scan 取得參數解析工具（此時 mask 尚未決定，解析不依賴它）。
        let parser = LaTeXSourceScan(units: units, kinds: kinds)
        var coveredUntil = 0
        for word in words where word.start >= coveredUntil {
            guard let shape = definitionShapes[word.name] else { continue }
            let end = parser.definitionEnd(shape: shape, after: word.end) ?? word.end
            for k in word.start..<end { mask[k] = true }
            coveredUntil = end
        }
        return mask
    }

    /// 只供定義範圍解析使用的精簡 scan。
    private init(units: [UInt16], kinds: [Kind]) {
        self.units = units
        self.kinds = kinds
        self.lineStarts = [0]
        self.controlWords = []
        self.body = 0..<units.count
        self.pageMarkers = []
        self.markerLines = []
        self.definitionMask = [Bool](repeating: false, count: units.count)
    }

    private func definitionEnd(shape: DefinitionShape, after offset: Int) -> Int? {
        func optionalStar(_ k: Int) -> Int {
            let s = skipIgnorable(from: k)
            return (s < units.count && units[s] == U.star) ? s + 1 : k
        }
        func optionals(_ k: Int, max count: Int) -> Int? {
            var k = skipIgnorable(from: k)
            for _ in 0..<count {
                guard k < units.count, units[k] == U.openBracket else { break }
                guard let end = optionalEnd(from: k) else { return nil }
                k = skipIgnorable(from: end)
            }
            return k
        }
        func group(_ k: Int) -> Int? {
            groupEnd(from: skipIgnorable(from: k))
        }

        switch shape {
        case .latexCommand:
            guard let name = tokenEnd(from: skipIgnorable(from: optionalStar(offset))),
                  let afterOptionals = optionals(name, max: 2) else { return nil }
            return groupEnd(from: afterOptionals)
        case .texDef:
            guard let name = tokenEnd(from: skipIgnorable(from: offset)) else { return nil }
            var k = name
            while k < units.count {
                if kinds[k] == .code && units[k] == U.openBrace { break }
                k += (kinds[k] == .code && units[k] == U.backslash) ? 2 : 1
            }
            return groupEnd(from: k)
        case .letAssignment:
            return letAssignmentEnd(after: offset)
        case .documentCommand:
            guard let name = tokenEnd(from: skipIgnorable(from: offset)),
                  let spec = group(name) else { return nil }
            return group(spec)
        case .environment:
            guard let name = group(optionalStar(offset)),
                  let afterOptionals = optionals(name, max: 2),
                  let begin = groupEnd(from: afterOptionals) else { return nil }
            return group(begin)
        }
    }

    /// `\let` 的兩個 token（名稱、右側）讀到哪裡。依 TeX 的語法 `\let⟨cs⟩⟨equals⟩⟨one optional space⟩⟨token⟩`，
    /// 以 pdflatex 實測（\let\saved 之後接 \frontmatter，看 \frontmatter 有沒有被執行）：
    ///
    /// - 空格、tab、單一換行、註解（連同其換行）都會被略過：`\let\saved% c⏎\frontmatter`、
    ///   `\let\saved⏎\frontmatter`、`\let\saved=\frontmatter`、`\let\saved = \frontmatter`、
    ///   `\let\saved =⏎   \frontmatter`、`\let\saved = % c⏎   \frontmatter` 都把 `\frontmatter`
    ///   指派給 `\saved`，不執行。
    /// - 空行（行首狀態下的行尾）產生 `\par`：`\let\saved⏎⏎\frontmatter` 指派的是 `\par`，
    ///   `\frontmatter` 會被執行。
    /// - 右側是單一 token：控制序列或單一字元（`{` 也只是一個字元）。
    private func letAssignmentEnd(after offset: Int) -> Int? {
        /// 略過 TeX 的空白；遇到空行時回傳 `\par` 的結尾。
        func skipSpaces(from start: Int) -> (next: Int, parEnd: Int?) {
            var k = start
            var atLineStart = false
            while k < units.count {
                let unit = units[k]
                if unit == U.space || unit == U.tab {
                    k += 1
                } else if unit == U.carriageReturn && k + 1 < units.count && units[k + 1] == U.newline {
                    k += 1
                } else if unit == U.newline {
                    if atLineStart { return (k, k + 1) }
                    atLineStart = true
                    k += 1
                } else if unit == U.percent && kinds[k] == .comment {
                    while k < units.count && units[k] != U.newline { k += 1 }
                    if k < units.count { k += 1 }
                    atLineStart = true
                } else {
                    break
                }
            }
            return (k, nil)
        }
        func singleTokenEnd(_ k: Int) -> Int? {
            guard k < units.count else { return nil }
            guard units[k] == U.backslash else { return k + 1 }
            var end = k + 1
            guard end < units.count else { return nil }
            if U.isLetter(units[end]) {
                while end < units.count && U.isLetter(units[end]) { end += 1 }
                return end
            }
            return end + 1
        }

        let beforeName = skipSpaces(from: offset)
        if let parEnd = beforeName.parEnd { return parEnd }
        guard let nameEnd = singleTokenEnd(beforeName.next) else { return nil }

        var right = skipSpaces(from: nameEnd)
        if let parEnd = right.parEnd { return parEnd }
        if right.next < units.count && units[right.next] == U.equals && kinds[right.next] == .code {
            right = skipSpaces(from: right.next + 1)
            if let parEnd = right.parEnd { return parEnd }
        }
        return singleTokenEnd(right.next)
    }

    // MARK: - Document body

    private static func documentBody(units: [UInt16], words: [ControlWord], mask: [Bool]) -> Range<Int> {
        func isDocumentBoundary(_ word: ControlWord, _ name: String) -> GroupArgument? {
            guard word.name == name, !mask[word.start],
                  let argument = readGroupArgument(units, from: word.end), argument.text == "document" else {
                return nil
            }
            return argument
        }
        guard let bodyStart = words.lazy.compactMap({ isDocumentBoundary($0, "begin") }).first?.range.upperBound else {
            return 0..<units.count
        }
        let end = words.first { $0.start >= bodyStart && isDocumentBoundary($0, "end") != nil }
        return bodyStart..<(end?.start ?? units.count)
    }
}

/// ASCII 單位常數。
enum U {
    static let backslash: UInt16 = 0x5C
    static let percent: UInt16 = 0x25
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let openBrace: UInt16 = 0x7B
    static let closeBrace: UInt16 = 0x7D
    static let openBracket: UInt16 = 0x5B
    static let closeBracket: UInt16 = 0x5D
    static let star: UInt16 = 0x2A
    static let equals: UInt16 = 0x3D
    static let comma: UInt16 = 0x2C

    static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == newline || unit == carriageReturn
    }
}
