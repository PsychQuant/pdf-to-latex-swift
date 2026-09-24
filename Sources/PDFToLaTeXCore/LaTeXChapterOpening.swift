import Foundation

// MARK: - Chapter Opening (PsychQuant/macdoc#210)

/// `ensureOpenAny` 與 `normalizeProject` 對章節起始頁的處理結果（封閉列舉，只有這六種）。
public enum ChapterOpeningOutcome: Sendable, Equatable {
    /// 沒有任何章節頁的頁碼是偶數（或沒有章節頁碼可判斷）：不需要 `openany`，不看 `\documentclass`。
    case notNeeded
    /// 在 `\documentclass` 的選項加上了 `openany`。
    case openAnyAdded
    /// `\documentclass` 已有 `openany`：不動。
    case alreadyOpenAny
    /// `\documentclass` 明確寫了 `openright`：尊重這個明確的選擇，不動（偶數頁起始的章節前仍會
    /// 補一張同頁碼的空白頁）。
    case explicitOpenRightKept
    /// `\documentclass` 有 `oneside`：單面時 `\cleardoublepage` 不補空白頁，不需要 `openany`。
    case oneSide
    /// 找不到被執行的 `\documentclass`，或類別不是 `book`（`report` 預設就是 openany；`article`
    /// 沒有 `\chapter`；其他類別的選項名稱不一定相同）：不動。
    case notBookClass
}

extension LaTeXNormalizer {

    /// 每個作用中的 `\chapter` 章首頁會顯示的頁碼：章名之後緊接著的 `\setcounter{page}{N}` 的 N。
    ///
    /// 「緊接著」= 章名閉合大括號之後的下一個 token（略過空白、換行與註解）是作用中的
    /// `\setcounter{page}{N}`，或是 `\pagenumbering{…}` 而它之後的下一個 token 是
    /// `\setcounter{page}{N}`。找下一個 token 時不跨過 page marker（下一頁的 counter 不屬於這一章）。
    /// N 必須是整數字面值；`\setcounter{page}{\value{x}}` 這類無法判斷的不列入。
    ///
    /// 章節前一行的 `\setcounter`（舊版的放法，會被 `\cleardoublepage` 蓋過）、沒有 counter 的章節、
    /// verbatim／註解／巨集定義裡的 `\chapter` 都不列入。依出現順序回傳。
    public static func chapterPageCounterValues(_ source: String) -> [Int] {
        let scan = LaTeXSourceScan(source)
        let markerOffsets = Set(scan.pageMarkers.map(\.offset))
        let wordsByStart = Dictionary(
            scan.controlWords.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first }
        )

        /// 下一個作用中 token 的控制字；遇到 page marker、非控制字或不作用中的位置回傳 nil。
        func nextWord(after end: Int) -> LaTeXSourceScan.ControlWord? {
            var k = end
            while k < scan.units.count {
                if U.isWhitespace(scan.units[k]) {
                    k += 1
                } else if scan.kinds[k] == .comment {
                    if markerOffsets.contains(k) { return nil }
                    while k < scan.units.count && scan.kinds[k] == .comment { k += 1 }
                } else {
                    guard scan.isActive(k) else { return nil }
                    return wordsByStart[k]
                }
            }
            return nil
        }

        /// `\setcounter{page}{N}` 的 N（整數字面值）。
        func pageCounterValue(_ word: LaTeXSourceScan.ControlWord) -> Int? {
            guard word.name == "setcounter",
                  let counter = scan.readGroupArgument(from: word.end),
                  counter.text.trimmingCharacters(in: .whitespaces) == "page",
                  let value = scan.readGroupArgument(from: counter.range.upperBound) else { return nil }
            return Int(value.text.trimmingCharacters(in: .whitespaces))
        }

        var values: [Int] = []
        for word in scan.controlWords where word.name == "chapter" && scan.isActive(word.start) {
            guard let end = chapterCommandEnd(scan, after: word.end), var next = nextWord(after: end) else { continue }
            if next.name == "pagenumbering" {
                guard let argument = scan.readGroupArgument(from: next.end),
                      let afterSwitch = nextWord(after: argument.range.upperBound) else { continue }
                next = afterSwitch
            }
            if let value = pageCounterValue(next) {
                values.append(value)
            }
        }
        return values
    }

    /// 在 `\documentclass[…]{book}` 的選項加上 `openany`（PsychQuant/macdoc#210）。冪等。
    ///
    /// 只看第一個被執行的 `\documentclass`（註解、verbatim、巨集定義裡的不算）。選項清單依 TeX 的讀法
    /// 判斷（註解連同換行消失、以逗號分隔、去掉頭尾空白），結果（封閉列舉，依此順序判定）：
    ///
    /// 1. 找不到、或類別不是 `book` → `.notBookClass`，不動；
    /// 2. 已有 `openany` → `.alreadyOpenAny`，不動；
    /// 3. 明確寫了 `openright` → `.explicitOpenRightKept`，不動。pdflatex 實測兩者並列時不論順序都是
    ///    openany 生效，所以加上去等於推翻作者明寫的選項；這裡選擇尊重，由報告告知；
    /// 4. 有 `oneside` → `.oneSide`，不動（單面不補空白頁，pdflatex 實測）；
    /// 5. 其他 → 加上 `openany`：有 `[…]` 時插在 `]` 之前（選項為空或以逗號結尾時不加逗號），沒有時在
    ///    `\documentclass` 之後插入 `[openany]`。`[11pt,% 註解⏎]`、`[11pt]%⏎{book}`、
    ///    `\documentclass % 註解⏎{book}` 等寫法加上之後，pdflatex 實測 openany 都生效。
    public static func ensureOpenAny(_ source: String) -> (result: String, outcome: ChapterOpeningOutcome) {
        let scan = LaTeXSourceScan(source)
        guard let word = scan.controlWords.first(where: { $0.name == "documentclass" && scan.isExecuted($0.start) }) else {
            return (source, .notBookClass)
        }

        var k = scan.skipIgnorable(from: word.end)
        var options: Range<Int>?
        if k < scan.units.count && scan.units[k] == U.openBracket && scan.kinds[k] == .code {
            guard let end = scan.optionalEnd(from: k) else { return (source, .notBookClass) }
            options = (k + 1)..<(end - 1)
            k = end
        }
        guard let argument = scan.readGroupArgument(from: k),
              argument.text.trimmingCharacters(in: .whitespaces) == "book" else {
            return (source, .notBookClass)
        }

        let optionText = options.map { scan.texCodeText($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let names = Set(optionText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if names.contains("openany") { return (source, .alreadyOpenAny) }
        if names.contains("openright") { return (source, .explicitOpenRightKept) }
        if names.contains("oneside") { return (source, .oneSide) }

        var units = scan.units
        if let options {
            let text = (optionText.isEmpty || optionText.hasSuffix(",")) ? "openany" : ",openany"
            units.insert(contentsOf: Array(text.utf16), at: options.upperBound)
        } else {
            units.insert(contentsOf: Array("[openany]".utf16), at: word.end)
        }
        return (String(decoding: units, as: UTF16.self), .openAnyAdded)
    }
}
