import Foundation

// MARK: - Page Counter Insertion (PsychQuant/macdoc#9, #211)

/// 頁碼還原過程中的一筆紀錄。
public struct PageCounterNote: Sendable, Equatable {
    /// 紀錄類別（封閉列舉）。
    public enum Kind: Sendable, Equatable {
        /// 在錨點之後插入了 `\setcounter{page}{page}`。有 page labels 時 `page` 是 label 的值
        /// （羅馬數字也以整數表示）。
        case counterInserted(page: Int)
        /// `\chapter` 前一行、值與目標頁碼相同的 counter（舊版的放法）已移到章名之後。
        case legacyCounterMoved(page: Int)
        /// `\chapter` 前一行的 counter 值與目標頁碼不同：原樣保留，該章不插入。
        case conflictingCounterBeforeChapter(existing: Int, expected: Int)
        /// 找不到 `\chapter` 章名的閉合大括號：整份原始碼不動。
        case chapterTitleNotFound
        /// 在錨點之後插入了 `\pagenumbering{style}`：page label 的樣式與當時的頁碼樣式不同
        /// （PsychQuant/macdoc#211）。
        case numberingInserted(style: PageNumberStyle)
        /// 錨點所在頁的 page label 不是阿拉伯數字或標準羅馬數字（例如 `A-1`、`a`、空字串）：
        /// 該錨點不插入（PsychQuant/macdoc#211）。
        case pageLabelUnsupported(page: Int, label: String)
        /// 有 page labels，但錨點所在頁（marker 的頁號）沒有 label：該錨點不插入（PsychQuant/macdoc#211）。
        case pageLabelMissing(page: Int)
    }

    /// 錨點在輸入原始碼中的行號（1 起算）：marker 行、切換指令所在行、`\chapter` 起始行。
    public let line: Int
    public let kind: Kind

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// page label 能還原的頁碼樣式（PsychQuant/macdoc#211）。raw value 是 `\pagenumbering` 的參數。
public enum PageNumberStyle: String, Sendable, Equatable {
    case arabic
    case roman
    case romanUpper = "Roman"
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

/// 頁碼樣式區段。只由來源中明確寫出、且在該處被執行的指令決定（label 模式下另含本函式插入的
/// `\pagenumbering`）。
enum PageNumberingStyle: Equatable {
    case arabic
    case roman
    /// `\pagenumbering{Roman}`（大寫羅馬數字）。
    case romanUpper
    /// `\pagenumbering{alph}` 等本函式不管理的樣式。
    case unmanaged

    init(_ style: PageNumberStyle) {
        switch style {
        case .arabic: self = .arabic
        case .roman: self = .roman
        case .romanUpper: self = .romanUpper
        }
    }
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
    /// - `\frontmatter`、`\pagenumbering{roman}` → roman 區段；`\pagenumbering{Roman}` → Roman 區段
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
    /// 沒有 page labels 時本函式不輸出 `\pagenumbering`：承認的證據就是上列指令本身，它們已完成
    /// 切換；本函式只在切回 arabic 後把被重設為 1 的 counter 還原成原書頁碼。有 page labels 時見下節。
    ///
    /// ## PDF page labels（PsychQuant/macdoc#211）
    ///
    /// `pageLabels`（實體頁號 → PDF 的 page label，通常來自 manifest）不是空的時候進入 label 模式（例外見
    /// 本節最後）。
    /// marker 的 N 是實體頁序，label 才是書上印的頁碼，所以錨點的目標（樣式、值）改由 N 那一頁的 label
    /// 決定（封閉列舉，只有這四種情形）：
    ///
    /// 1. label 非空且全為 ASCII 數字 → arabic，值為該數字；
    /// 2. label 是標準寫法的小寫或大寫羅馬數字（`iv`、`XIV`）→ `roman`／`Roman`，值為其數值；
    /// 3. 其他 label（`A-1`、`a`、空字串、`iiii`）→ 該錨點不插入，回報 `pageLabelUnsupported`；
    /// 4. N 沒有 label → 該錨點不插入，回報 `pageLabelMissing`。`/PageLabels` 對每一頁都有定義，缺 label
    ///    表示 marker 與 manifest 對不上；退回實體頁序等於用猜的。
    ///
    /// 錨點仍是上列三類，另加 roman 與不受管理的切換指令（它們把 counter 重設為 1，需要以 label 還原）。
    /// 錨點的目標樣式與當時的頁碼樣式（LaTeX 預設 arabic，之後由被執行的切換指令與本函式插入的
    /// `\pagenumbering` 決定）不同時，先插入 `\pagenumbering{樣式}` 再插入 counter；label 與原始碼的
    /// 切換指令不一致時以 label 為準。roman 區段也插入 counter。
    ///
    /// 已處理的判定多一種：錨點之後的下一個 token 是 `\pagenumbering{目標樣式}`，它之後是
    /// `\setcounter{page}`。錨點之後已有 counter 時沿用它的值（與沒有 label 時相同），只在樣式不同時
    /// 補上 `\pagenumbering`。
    ///
    /// 以下情形不進入 label 模式，維持上述行為、輸出一字不差（封閉列舉）：
    /// - `pageLabels` 是空的（PDF 沒有 `/PageLabels`、或舊 manifest）；
    /// - 每一頁的 label 都等於它的實體頁號（`/PageLabels` 只是 1、2、3…），而且每個 page marker 的頁號
    ///   都有 label：它沒有 marker 以外的資訊，當成 label 只會推翻原始碼明寫的 `\frontmatter` 等切換指令。
    ///   有 marker 的頁號沒有 label 時仍是 label 模式，該頁照常回報 `pageLabelMissing`。
    ///
    /// ## 冪等
    ///
    /// 已處理過的錨點後面都跟著 counter，重跑不再插入；舊版 counter 移過之後不再位於章前。
    public static func applyPageCounters(_ source: String, pageLabels: [Int: String] = [:]) -> PageCounterReport {
        let scan = LaTeXSourceScan(source)
        guard let firstMarker = scan.pageMarkers.first else {
            return PageCounterReport(result: source, notes: [])
        }
        // label 模式的啟用條件見「PDF page labels」一節：labels 與實體頁號相同、且涵蓋每個 marker 的頁號時不啟用。
        let labelMode = !pageLabels.isEmpty && (
            pageLabels.contains { $0.value != String($0.key) }
                || scan.pageMarkers.contains { pageLabels[$0.page] == nil }
        )

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

        /// label 模式：錨點所在頁（marker 的頁號）的目標；不可用時回傳原因。
        func lookup(page: Int) -> LabelLookup {
            guard let label = pageLabels[page] else { return .problem(.pageLabelMissing(page: page)) }
            guard let parsed = parsePageLabel(label) else {
                return .problem(.pageLabelUnsupported(page: page, label: label))
            }
            return .target(PageTarget(style: parsed.style, value: parsed.value))
        }

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
            guard let page = context.nearestPage(before: chapter.offset) else { continue }
            let value: Int
            if labelMode {
                guard case .target(let target) = lookup(page: page),
                      !context.counterFollows(chapter.end, throughNumbering: true) else { continue }
                value = target.value
            } else {
                guard styleAtChapter[chapter.offset] == .arabic, !context.pageCounterFollows(chapter.end) else { continue }
                value = page
            }
            let previous = chapter.startLine - 1
            if chapter.firstOnLine, !context.chapterEndLines.contains(previous - 1),
               context.pageCounterValue(line: previous) == value {
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

        /// label 模式：取得錨點頁的目標；不可用時記下原因並回傳 nil。
        func resolveTarget(page: Int, anchorLine: Int) -> PageTarget? {
            switch lookup(page: page) {
            case .target(let target):
                return target
            case .problem(let kind):
                notes.append(PageCounterNote(line: anchorLine + 1, kind: kind))
                return nil
            }
        }

        /// label 模式：在錨點結尾之後套用目標樣式與值（見「PDF page labels」一節），之後的樣式即為目標樣式。
        func applyTarget(_ target: PageTarget, after end: Int, anchorLine: Int) {
            let targetStyle = PageNumberingStyle(target.style)
            defer { style = targetStyle }
            let numbering = "\\pagenumbering{\(target.style.rawValue)}"
            if context.pageCounterFollows(end) {
                guard targetStyle != style else { return }
                edits.append(context.insertion(after: end, text: numbering))
                notes.append(PageCounterNote(line: anchorLine + 1, kind: .numberingInserted(style: target.style)))
                return
            }
            if context.numberingThenCounterFollows(end, style: targetStyle) { return }
            var text = "\\setcounter{page}{\(target.value)}"
            if targetStyle != style {
                text = numbering + scan.lineEnding + text
                notes.append(PageCounterNote(line: anchorLine + 1, kind: .numberingInserted(style: target.style)))
            }
            edits.append(context.insertion(after: end, text: text))
            notes.append(PageCounterNote(line: anchorLine + 1, kind: .counterInserted(page: target.value)))
        }

        for event in events {
            switch event {
            case .numberingSwitch(let change):
                style = change.style
                guard scan.body.contains(change.offset), change.end <= scan.body.upperBound,
                      !context.nextTokenTakesOver(after: change.end),
                      let page = context.nearestPage(before: change.offset) else { continue }
                if labelMode {
                    guard let target = resolveTarget(page: page, anchorLine: change.line) else { continue }
                    applyTarget(target, after: change.end, anchorLine: change.line)
                } else {
                    guard change.style == .arabic, !context.pageCounterFollows(change.end) else { continue }
                    insertCounter(page: page, after: change.end, anchorLine: change.line)
                }

            case .firstMarker(let marker):
                let end = scan.lineRange(marker.line).upperBound
                guard !context.nextTokenTakesOver(after: end) else { continue }
                if labelMode {
                    guard let target = resolveTarget(page: marker.page, anchorLine: marker.line) else { continue }
                    applyTarget(target, after: end, anchorLine: marker.line)
                } else {
                    guard style == .arabic, !context.pageCounterFollows(end) else { continue }
                    insertCounter(page: marker.page, after: end, anchorLine: marker.line)
                }

            case .chapter(let chapter):
                guard labelMode || style == .arabic,
                      let page = context.nearestPage(before: chapter.offset) else { continue }
                let previous = chapter.startLine - 1
                let target: PageTarget
                if labelMode {
                    guard let resolved = resolveTarget(page: page, anchorLine: chapter.startLine) else { continue }
                    target = resolved
                } else {
                    target = PageTarget(style: .arabic, value: page)
                }
                if context.ownedLegacyLines[previous] == chapter.offset {
                    var text = context.lineContent(previous)
                    let targetStyle = PageNumberingStyle(target.style)
                    if targetStyle != style {
                        text = "\\pagenumbering{\(target.style.rawValue)}" + scan.lineEnding + text
                        notes.append(PageCounterNote(
                            line: chapter.startLine + 1, kind: .numberingInserted(style: target.style)
                        ))
                    }
                    edits.append((context.wholeLine(previous), ""))
                    edits.append(context.insertion(after: chapter.end, text: text))
                    notes.append(PageCounterNote(
                        line: chapter.startLine + 1, kind: .legacyCounterMoved(page: target.value)
                    ))
                    style = targetStyle
                    continue
                }
                if !context.counterFollows(chapter.end, throughNumbering: labelMode), chapter.firstOnLine,
                   !context.chapterEndLines.contains(previous - 1),
                   let existing = context.pageCounterValue(line: previous) {
                    notes.append(PageCounterNote(
                        line: chapter.startLine + 1,
                        kind: .conflictingCounterBeforeChapter(existing: existing, expected: target.value)
                    ))
                    continue
                }
                if labelMode {
                    applyTarget(target, after: chapter.end, anchorLine: chapter.startLine)
                } else {
                    guard !context.pageCounterFollows(chapter.end) else { continue }
                    insertCounter(page: page, after: chapter.end, anchorLine: chapter.startLine)
                }
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

    /// 相容 API：回傳 `applyPageCounters(_:pageLabels:)` 的改寫結果。
    public static func insertPageCounters(_ source: String, pageLabels: [Int: String] = [:]) -> String {
        applyPageCounters(source, pageLabels: pageLabels).result
    }

    // MARK: - Page labels (PsychQuant/macdoc#211)

    /// 解析 PDF page label。只有兩種會被採用（封閉列舉，不得依性質相似類推第三種）：
    ///
    /// 1. 非空、全為 ASCII 數字 → arabic，值為該數字；
    /// 2. 全為小寫、或全為大寫的羅馬數字字母（i v x l c d m），且恰好是其數值的標準寫法
    ///    （即 `romanNumeral` 的輸出：`iv` 可、`iiii` 不可）→ roman／Roman。
    ///
    /// 兩者的值都必須在 TeX 整數範圍內（`texMaxCount`；pdflatex 實測 `\setcounter{page}{2147483648}`
    /// 是 `! Number too big.`）。其他（空字串、帶前綴的 `A-1`、字母編號 `a`、大小寫混用 `Iv`、非 ASCII
    /// 數字、超出範圍的值）都回傳 nil。
    static func parsePageLabel(_ label: String) -> (style: PageNumberStyle, value: Int)? {
        guard !label.isEmpty else { return nil }
        if label.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) {
            guard let value = Int(label), value <= texMaxCount else { return nil }
            return (.arabic, value)
        }
        let lower = label.lowercased()
        let style: PageNumberStyle
        if label == lower {
            style = .roman
        } else if label == label.uppercased() {
            style = .romanUpper
        } else {
            return nil
        }
        let digits: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var values: [Int] = []
        for character in lower {
            guard let digit = digits[character] else { return nil }
            values.append(digit)
        }
        var total = 0
        for (index, digit) in values.enumerated() {
            if index + 1 < values.count && digit < values[index + 1] {
                total -= digit
            } else {
                total += digit
            }
        }
        guard total > 0, total <= texMaxCount, romanNumeral(total) == lower else { return nil }
        return (style, total)
    }

    /// TeX 整數（counter）的上限。
    static let texMaxCount = 2_147_483_647

    /// 正整數的標準小寫羅馬數字，與 TeX `\romannumeral`（LaTeX `\roman`）相同：千位以 m 重複。
    /// 0 以下回傳空字串。
    static func romanNumeral(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let table: [(amount: Int, numeral: String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = value
        var result = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }

    /// manifest.json 記錄的 page labels（實體頁號 → label；PsychQuant/macdoc#211）。沒有 manifest、
    /// 無法解析、或沒有任何一頁有 label 時為空，頁碼還原即維持沒有 label 的行為（manifest 無法解析時，
    /// 圖片寬度步驟會回報原因）。
    static func manifestPageLabels(projectDir: URL) -> [Int: String] {
        let url = ProjectLayout.manifestURL(for: projectDir)
        guard FileManager.default.fileExists(atPath: url.path),
              let manifest = try? ManifestStore().load(from: url) else { return [:] }
        var labels: [Int: String] = [:]
        for page in manifest.pages {
            if let label = page.label, labels[page.number] == nil {
                labels[page.number] = label
            }
        }
        return labels
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
    fileprivate static func numberingSwitch(
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
            case "roman": return (.roman, argument.range.upperBound)
            case "Roman": return (.romanUpper, argument.range.upperBound)
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

/// label 模式下一個錨點的目標（PsychQuant/macdoc#211）。
private struct PageTarget {
    let style: PageNumberStyle
    let value: Int
}

private enum LabelLookup {
    case target(PageTarget)
    case problem(PageCounterNote.Kind)
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

    /// 結尾之後的下一個 token（不跨過 page marker）若是作用中的 `\pagenumbering{…}`，回傳其樣式與結尾。
    func pagenumberingFollows(_ end: Int) -> (style: PageNumberingStyle, end: Int)? {
        guard let next = nextToken(after: end, stopAtMarker: true),
              next < scan.body.upperBound, scan.isActive(next),
              let word = scan.controlWords.first(where: { $0.start == next }), word.name == "pagenumbering",
              let (style, switchEnd) = LaTeXNormalizer.numberingSwitch(word, in: scan) else { return nil }
        return (style, switchEnd)
    }

    /// 結尾之後是 `\pagenumbering{style}`，它之後是 `\setcounter{page}`（label 模式插入的形式）。
    func numberingThenCounterFollows(_ end: Int, style: PageNumberingStyle) -> Bool {
        guard let following = pagenumberingFollows(end), following.style == style else { return false }
        return pageCounterFollows(following.end)
    }

    /// 結尾之後已有 counter：直接是 `\setcounter{page}`，或（`throughNumbering`）是任一
    /// `\pagenumbering{…}` 之後的 `\setcounter{page}`。
    func counterFollows(_ end: Int, throughNumbering: Bool) -> Bool {
        if pageCounterFollows(end) { return true }
        guard throughNumbering, let following = pagenumberingFollows(end) else { return false }
        return pageCounterFollows(following.end)
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
