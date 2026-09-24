import Foundation

/// LaTeX 原始碼的「作用中」掃描。頁碼還原（PsychQuant/macdoc#9）與圖片寬度還原
/// （PsychQuant/macdoc#10）共用同一份判定，確保兩者對「哪裡是真正會被執行的 LaTeX」看法一致。
///
/// 每個 UTF-16 單位分成三類：
///
/// - **comment**：未跳脫的 `%` 到行尾（`\%` 是字元，不是註解）。
/// - **verbatim**（封閉列舉，只有這些）：`verbatim`、`verbatim*`、`Verbatim`、`Verbatim*`、
///   `lstlisting`、`minted`、`comment` 環境的內容（到字面上的 `\end{<env>}` 為止；找不到則到檔尾），
///   以及 inline `\verb<d>…<d>`、`\verb*<d>…<d>`（到同一行的下一個分隔字元；找不到則到行尾）。
/// - **code**：其餘。
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
/// **page marker** = 位於 body、不在巨集定義內的一行，其第一個非空白字元（空格／tab 之後）是 comment 的起點，
/// 且符合 `%% === Page N ===`。verbatim 內長得像 marker 的文字不算。
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

    static let verbatimEnvironments: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "Verbatim*", "lstlisting", "minted", "comment",
    ]

    let units: [UInt16]
    let kinds: [Kind]
    let lineStarts: [Int]
    /// code 中的控制字（依出現順序；verbatim 與註解內的不在此列）。
    let controlWords: [ControlWord]
    let body: Range<Int>
    /// 所有作用中的 page marker（依 offset 排序）。
    let pageMarkers: [PageMarker]
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
        let regex = try! NSRegularExpression(pattern: #"^%%[ \t]*===[ \t]*Page[ \t]+(\d+)[ \t]*==="#)
        for (line, start) in starts.enumerated() {
            var p = start
            while p < units.count && (units[p] == U.space || units[p] == U.tab) { p += 1 }
            guard p < units.count, units[p] == U.percent, kinds[p] == .comment, !mask[p], body.contains(p) else {
                continue
            }
            var end = p
            while end < units.count && units[end] != U.newline { end += 1 }
            let text = String(decoding: units[p..<end], as: UTF16.self)
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  let page = Int(ns.substring(with: match.range(at: 1))) else { continue }
            markers.append(PageMarker(offset: p, line: line, page: page))
        }

        self.units = units
        self.kinds = kinds
        self.controlWords = words
        self.lineStarts = starts
        self.definitionMask = mask
        self.body = body
        self.pageMarkers = markers
    }

    // MARK: - Queries

    func isActive(_ offset: Int) -> Bool {
        offset >= 0 && offset < units.count
            && kinds[offset] == .code && !definitionMask[offset] && body.contains(offset)
    }

    /// 註解（非 verbatim）且不在巨集定義內。
    func isComment(_ offset: Int) -> Bool {
        offset >= 0 && offset < units.count && kinds[offset] == .comment && !definitionMask[offset]
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

            if name == "begin", let (argEnd, env) = environmentName(units, after: j),
               verbatimEnvironments.contains(env) {
                let terminator = Array("\\end{\(env)}".utf16)
                let close = find(terminator, in: units, from: argEnd) ?? n
                for k in argEnd..<close { kinds[k] = .verbatim }
                i = close
                continue
            }
            i = j
        }
        return (kinds, words)
    }

    /// `\verb` 名稱之後：可選 `*`、分隔字元、內容、同一個分隔字元。回傳結尾 offset。
    private static func verbEnd(_ units: [UInt16], after offset: Int) -> Int? {
        var k = offset
        if k < units.count && units[k] == U.star { k += 1 }
        while k < units.count && (units[k] == U.space || units[k] == U.tab) { k += 1 }
        guard k < units.count, !U.isLetter(units[k]), units[k] != U.newline else { return nil }
        let delimiter = units[k]
        k += 1
        while k < units.count && units[k] != delimiter && units[k] != U.newline { k += 1 }
        return (k < units.count && units[k] == delimiter) ? k + 1 : k
    }

    /// `\begin` 之後的 `{name}`（允許中間有空白）。
    private static func environmentName(_ units: [UInt16], after offset: Int) -> (Int, String)? {
        var k = offset
        while k < units.count && U.isWhitespace(units[k]) { k += 1 }
        guard k < units.count, units[k] == U.openBrace else { return nil }
        let nameStart = k + 1
        var end = nameStart
        while end < units.count && units[end] != U.closeBrace && units[end] != U.newline { end += 1 }
        guard end < units.count, units[end] == U.closeBrace else { return nil }
        return (end + 1, String(decoding: units[nameStart..<end], as: UTF16.self))
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
        /// `\let\name=<token>`
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
            guard let name = tokenEnd(from: skipIgnorable(from: offset)) else { return nil }
            var k = name
            while k < units.count && (units[k] == U.space || units[k] == U.tab) { k += 1 }
            if k < units.count && units[k] == U.equals {
                k += 1
                if k < units.count && units[k] == U.space { k += 1 }
            }
            return tokenEnd(from: k)
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

    // MARK: - Document body

    private static func documentBody(units: [UInt16], words: [ControlWord], mask: [Bool]) -> Range<Int> {
        func environmentArgument(_ word: ControlWord) -> (end: Int, name: String)? {
            var k = word.end
            while k < units.count && U.isWhitespace(units[k]) { k += 1 }
            guard k < units.count, units[k] == U.openBrace else { return nil }
            var end = k + 1
            while end < units.count && units[end] != U.closeBrace && units[end] != U.newline { end += 1 }
            guard end < units.count, units[end] == U.closeBrace else { return nil }
            return (end + 1, String(decoding: units[(k + 1)..<end], as: UTF16.self))
        }

        guard let begin = words.first(where: {
            $0.name == "begin" && !mask[$0.start] && environmentArgument($0)?.name == "document"
        }), let bodyStart = environmentArgument(begin)?.end else {
            return 0..<units.count
        }
        let end = words.first(where: {
            $0.start >= bodyStart && $0.name == "end" && !mask[$0.start]
                && environmentArgument($0)?.name == "document"
        })
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
