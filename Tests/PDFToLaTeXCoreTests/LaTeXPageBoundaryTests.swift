import XCTest
@testable import PDFToLaTeXCore

/// 以 page marker 為分頁邊界的兩個步驟（PsychQuant/macdoc#215）：`removeCrossPageDuplicates` 與
/// `fixSplitListEnvironments`。邊界只認 `LaTeXSourceScan` 的 marker 行；verbatim 類環境與 `\verb`
/// 內長得像 marker 的文字不是邊界，verbatim 的位元組一律不動。
final class LaTeXPageBoundaryTests: XCTestCase {

    // MARK: - removeCrossPageDuplicates

    /// verbatim 內的假 marker 不是分頁：舊版會把它當邊界，刪掉 verbatim 裡「重複」的兩行。
    func testDedup_fakeMarkerInsideVerbatimIsNotABoundary() {
        let input = """
        \\documentclass{book}
        \\begin{document}
        Intro line one.
        Intro line two.
        \\begin{verbatim}
        x = 1
        y = 2
        %% === Page 2 ===
        x = 1
        y = 2
        \\end{verbatim}
        Closing line one.
        Closing line two.
        \\end{document}
        """
        let normalizer = LaTeXNormalizer()
        let result = normalizer.removeCrossPageDuplicates(input)
        XCTAssertEqual(result, input)
        XCTAssertEqual(normalizer.removeCrossPageDuplicates(result), result)
    }

    func testDedup_fakeMarkerInsideCommentEnvironmentAndVerbIsNotABoundary() {
        let input = """
        \\begin{document}
        Alpha.
        Beta.
        \\begin{comment}
        Alpha.
        %% === Page 7 ===
        Alpha.
        \\end{comment}
        Gamma.
        \\verb
        %% === Page 8 ===
        Gamma.
        Delta.
        \\end{document}
        """
        let result = LaTeXNormalizer().removeCrossPageDuplicates(input)
        XCTAssertEqual(result, input)
    }

    /// 真正的 marker 旁邊是 verbatim：碰到 verbatim 的行（`\begin{verbatim}`、內容、`\end{verbatim}`）
    /// 不參與比對、也不刪。舊版會刪掉第二個區塊的 `\begin`／`\end`，讓 `b` 變成一般文字。
    func testDedup_realMarkerNeverDeletesLinesTouchingVerbatim() {
        let input = """
        \\begin{document}
        Opening text.
        \\begin{verbatim}
        a
        \\end{verbatim}
        %% === Page 2 ===
        \\begin{verbatim}
        b
        \\end{verbatim}
        Closing text.
        More closing text.
        \\end{document}
        """
        let result = LaTeXNormalizer().removeCrossPageDuplicates(input)
        XCTAssertEqual(result, input)
    }

    /// CRLF 檔案：marker 行與 verbatim 判定都以 `LaTeXSourceScan` 為準，結果不動。
    func testDedup_fakeMarkerInsideVerbatim_CRLF() {
        let input = """
        \\begin{document}
        Intro line one.
        Intro line two.
        \\begin{verbatim}
        x = 1
        y = 2
        %% === Page 2 ===
        x = 1
        y = 2
        \\end{verbatim}
        Closing line one.
        Closing line two.
        \\end{document}
        """.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 頁尾與頁首的重疊必須是連續的一段：舊版只要頁首某行在頁尾出現過就刪。連續兩個表格時，第二個
    /// 表格的 `\centering`、`\begin{tabular}{c}`、`\end{tabular}` 被刪，表格內容變成一般段落
    /// （pdflatex 實測仍可編譯，但表格被毀）。
    func testDedup_scatteredStructuralMatchesAreNotDeleted() {
        let input = """
        \\begin{document}
        Tail paragraph.
        \\begin{table}[h]
        \\centering
        \\begin{tabular}{c}
        A \\\\
        \\end{tabular}
        \\end{table}
        %% === Page 2 ===
        \\begin{table}[h]
        \\centering
        \\begin{tabular}{c}
        B \\\\
        \\end{tabular}
        \\end{table}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 連續兩個列表：舊版刪掉第二個列表的 `\begin{itemize}` 與 `\end{itemize}`，留下孤立的 `\item`
    /// （pdflatex 實測：`! LaTeX Error: Lonely \item--perhaps a missing list environment.`）。
    func testDedup_consecutiveListsKeepTheirEnvironmentLines() {
        let input = """
        \\begin{document}
        Tail paragraph.
        \\begin{itemize}
        \\item A
        \\end{itemize}
        %% === Page 2 ===
        \\begin{itemize}
        \\item B
        \\end{itemize}
        Closing one.
        Closing two.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 碰到 verbatim 的行是比對的阻隔（Codex R1 HIGH）：頁首遇到 verbatim 就停，不會跳過整個 verbatim
    /// 區塊去刪它後面、只是碰巧與頁尾相同的正文。
    func testDedup_headStopsAtVerbatim() {
        let input = """
        \\documentclass{article}
        \\begin{document}
        Example.
        %% === Page 2 ===
        \\begin{verbatim}
        print("example")
        \\end{verbatim}
        Example.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 同上，頁尾往前遇到 verbatim 就停：頁尾的最後內容是 verbatim 區塊時，不拿更前面的正文來比。
    func testDedup_tailStopsAtVerbatim() {
        let input = """
        \\begin{document}
        Example.
        \\begin{verbatim}
        print("example")
        \\end{verbatim}
        %% === Page 2 ===
        Example.
        More text.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 合法的巢狀列表：內層與外層各一個 `\\end{itemize}` 夾著分頁，文字相同但不是重複（Codex R2 HIGH）。
    /// 舊版的短文件門檻剛好擋住；刪掉外層結尾，pdflatex 實測為
    /// `! LaTeX Error: \\begin{itemize} on input line 3 ended by \\end{document}.`
    func testDedup_nestedListEndsAreNotDuplicates() {
        let input = """
        \\documentclass{article}
        \\begin{document}
        \\begin{itemize}
        \\item Outer
        \\begin{itemize}
        \\item Inner
        \\end{itemize}
        %% === Page 2 ===
        \\end{itemize}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 兩段各自完整的 `$$…$$` 展示數學夾著分頁：頁尾的 `$$` 是結尾、頁首的 `$$` 是開頭（Codex R3 HIGH）。
    /// `$$` 是一個展示數學分隔字元，單獨一行不自成一體；刪掉它，pdflatex 實測為 `! Missing $ inserted.`
    func testDedup_displayMathDelimitersAreNotDuplicates() {
        let input = "\\documentclass{article}\n\\begin{document}\n$$\nx\n$$\n%% === Page 2 ===\n$$\ny\n$$\n\\end{document}"
        let normalizer = LaTeXNormalizer()
        XCTAssertEqual(normalizer.removeCrossPageDuplicates(input), input)
    }

    /// `\ifcase` 的兩個分支分隔 `\or` 夾著分頁（Codex R4 HIGH）：文字相同卻是不同分支的結構。刪掉第二個
    /// `\or`，分支 2 消失；pdflatex 實測原文輸出 `B`，刪掉之後不輸出。
    func testDedup_conditionalBranchesAreNeverDeleted() {
        let input = "\\documentclass{article}\n\\begin{document}\n\\ifcase2 A\n\\or\n%% === Page 2 ===\n\\or\nB\n\\fi\n\\end{document}"
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    /// 只刪「自身配對完整」的重疊段落：段落裡有未配對的結構（封閉列舉：大括號、`\\begin`／`\\end`、
    /// `\\[`／`\\]`、`\\(`／`\\)`、`$` 的奇偶、`\\begingroup`／`\\endgroup`、`\\bgroup`／`\\egroup`、
    /// `\\left`／`\\right`），刪掉它就會改變其他地方的配對，所以不刪。含條件式相關控制字的段落一律不刪
    /// （見 `LaTeXSourceScan.linesAreSelfBalanced`），即使條件式看起來完整。
    func testDedup_onlySelfBalancedOverlapsAreDeleted() {
        let unbalanced = [
            "}", "\\end{center}", "\\]", "\\)", "$x = 1", "\\fi", "\\right)", "\\endgroup", "\\egroup",
            "{\\bfseries", "\\begin{center}", "\\ifdim\\x>0pt", "\\left(", "\\[", "} {", "$$", "$$ x", "x $$ y $",
            // 條件式相關（R4）：分支分隔、看起來完整的條件式、\newif、\unless、plain 的 \loop／\repeat，
            // 以及名稱以 if 開頭的任何控制字（含數學符號 \iff：寧可不刪）。
            "\\or", "\\else", "\\or B", "\\ifdim\\x>0pt A\\else B\\fi", "\\ifcase1 A\\or B\\fi",
            "\\newif\\iffoo", "\\unless\\ifx\\a\\b A\\fi", "\\loop", "\\repeat", "$a \\iff b$", "\\iffoo X\\fi",
        ]
        for line in unbalanced {
            let input = "\\begin{document}\nOpening.\n\(line)\n%% === Page 2 ===\n\(line)\nClosing.\n\\end{document}"
            XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input, line)
        }

        // 配對完整的段落照常去重，即使裡面有環境、數學或群組。
        let balanced = [
            ["\\begin{center}", "Centered.", "\\end{center}"],
            ["\\[", "x = 1", "\\]"],
            ["Price $x$ and {\\bfseries bold}.", "\\left( y \\right)"],
            ["$$", "x = 1", "$$"],
            ["$a$$b$ and $$c$$"],
        ]
        for block in balanced {
            let joined = block.joined(separator: "\n")
            let input = "\\begin{document}\nOpening.\n\(joined)\n%% === Page 2 ===\n\(joined)\nClosing.\n\\end{document}"
            let expected = "\\begin{document}\nOpening.\n\(joined)\n%% === Page 2 ===\nClosing.\n\\end{document}"
            XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), expected, joined)
        }
    }

    /// 真正的重複（前一頁最後幾行在下一頁開頭又出現）照常刪除；marker 之後的空行與 `%%` 註解
    /// 不影響比對，也不會被刪。
    func testDedup_contiguousOverlapIsRemovedAndBlankLinesKept() {
        let input = """
        \\begin{document}
        First paragraph.
        Line B.
        Line C.
        %% === Page 2 ===

        %% transcriber note
        Line B.
        Line C.
        Line D.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        First paragraph.
        Line B.
        Line C.
        %% === Page 2 ===

        %% transcriber note
        Line D.
        \\end{document}
        """
        let normalizer = LaTeXNormalizer()
        let result = normalizer.removeCrossPageDuplicates(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(normalizer.removeCrossPageDuplicates(result), result)
    }

    /// 重複行本身重複出現時一次刪到沒有重疊為止，所以第二輪不再刪。
    func testDedup_repeatedOverlapIsRemovedToAFixpoint() {
        let input = "Tail A.\nTail B.\n%% === Page 2 ===\nTail B.\nTail B.\nHead C.\n%% === Page 3 ===\nHead C.\nEnd."
        let normalizer = LaTeXNormalizer()
        let result = normalizer.removeCrossPageDuplicates(input)
        XCTAssertEqual(result, "Tail A.\nTail B.\n%% === Page 2 ===\nHead C.\n%% === Page 3 ===\nEnd.")
        XCTAssertEqual(normalizer.removeCrossPageDuplicates(result), result)
    }

    /// 比對範圍只在相鄰兩頁之內：前一頁只有一行時，頁尾就只有那一行，不會越過更前面的 marker。
    func testDedup_windowsStayInsideTheNeighbouringPages() {
        let input = """
        Preamble one.
        Preamble two.
        Preamble three.
        Page one line.
        %% === Page 2 ===
        Short.
        %% === Page 3 ===
        Page one line.
        Short.
        More.
        Even more.
        Last.
        """
        XCTAssertEqual(LaTeXNormalizer().removeCrossPageDuplicates(input), input)
    }

    // MARK: - Fuzz

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// 重複率高的行，加上會讓舊版誤判的 verbatim 片段（內含假 marker、`\end{itemize}`、`\item`）。
    private static let fuzzLines = [
        "Text A.", "Text B.", "Text A.", "\\centering", "\\end{table}", "\\begin{itemize}", "\\end{itemize}",
        "\\item X", "\\item Y", "", "%% note", "% plain comment", "  Text A.  ", "}", "{\\bfseries", "$x$", "$$",
        "\\begin{verbatim}\nText A.\n%% === Page 50 ===\nText A.\n\\end{verbatim}",
        "\\begin{comment}\n\\end{itemize}\n%% === Page 51 ===\n\\item Z\n\\end{comment}",
        "\\begin{Verbatim}\n\\end{itemize}\n\\end{Verbatim}",
        "\\verb\n%% === Page 52 ===", "\\item V \\verb\nText A.", "\\begin% c\n{verbatim}\nText B.\n\\end{verbatim}",
        // 條件式（R4）與巢狀列表（R4）。
        "\\or", "\\else", "\\fi", "\\ifcase1 A", "\\or B",
        "\\begin{itemize}\n\\item Outer\n\\begin{itemize}\n\\item Inner\n\\end{itemize}",
        "\\begin{enumerate}\n\\item E\n\\end{enumerate}", "\\begin{center}", "\\end{center}",
    ]

    private func makeDocument(_ rng: inout SeededGenerator) -> String {
        var lines = ["\\begin{document}"]
        var page = 1
        for _ in 0..<Int.random(in: 2...24, using: &rng) {
            if Int.random(in: 0..<4, using: &rng) == 0 {
                page += 1
                lines.append("%% === Page \(page) ===")
            } else {
                lines.append(Self.fuzzLines.randomElement(using: &rng)!)
            }
        }
        lines.append("\\end{document}")
        var document = lines.joined(separator: "\n")
        if Int.random(in: 0..<4, using: &rng) == 0 {
            document = document.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return document
    }

    /// 兩個步驟都不改任何 verbatim；去重冪等、只刪 marker 以外的行，且不改變整份文件的配對狀態。
    func testBoundaryStepsNeverTouchVerbatimAndAreIdempotent() {
        var rng = SeededGenerator(state: 0x5EED_0215)
        let normalizer = LaTeXNormalizer()
        let markerLine = try! NSRegularExpression(pattern: #"^%% === Page \d+ ===\r?$"#)
        for index in 0..<3000 {
            let source = makeDocument(&rng)
            let context = "case \(index):\n\(source.debugDescription)"
            let verbatim = LaTeXSourceScan(source).verbatimSegments

            let deduped = normalizer.removeCrossPageDuplicates(source)
            XCTAssertEqual(LaTeXSourceScan(deduped).verbatimSegments, verbatim, context)
            // 只刪自成一體的段落：整份文件的配對狀態不變。
            let sourceScan = LaTeXSourceScan(source)
            let dedupedScan = LaTeXSourceScan(deduped)
            XCTAssertEqual(
                dedupedScan.linesAreSelfBalanced(Array(dedupedScan.lineStarts.indices)),
                sourceScan.linesAreSelfBalanced(Array(sourceScan.lineStarts.indices)),
                context
            )
            XCTAssertEqual(normalizer.removeCrossPageDuplicates(deduped), deduped, context)
            // 結果的各行是原文各行的子序列，且被刪的行都不是 marker。
            let kept = deduped.components(separatedBy: "\n")
            var cursor = kept.startIndex
            for line in source.components(separatedBy: "\n") {
                if cursor < kept.endIndex, kept[cursor] == line {
                    cursor += 1
                    continue
                }
                XCTAssertNil(markerLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                             "\(context)\n刪掉了 marker 行 \(line.debugDescription)")
            }
            XCTAssertEqual(cursor, kept.endIndex, "\(context)\n去重後出現原本沒有的行")
            // 被刪的行都不含條件式相關控制字（不經 scanner 的判準）。
            let deleted = Self.deletedLines(source: source, result: deduped)
            for line in deleted {
                XCTAssertNil(Self.conditionalWord.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                             "\(context)\n刪掉了條件式行 \(line.debugDescription)")
            }

            let fixed = LaTeXNormalizer.fixSplitListEnvironments(source)
            XCTAssertEqual(LaTeXSourceScan(fixed).verbatimSegments, verbatim, context)
            XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(fixed), fixed, "\(context)\n--- fixed ---\n\(fixed.debugDescription)")
            // 環境配對完整、也沒有孤立 \item 的文件（列表結構本來就能編譯）一字不動。
            if Self.listStructureIsWellFormed(source) {
                XCTAssertEqual(fixed, source, context)
            }
        }
    }

    private static let conditionalWord = try! NSRegularExpression(
        pattern: #"\\(if[A-Za-z]*|or|else|fi|unless|loop|repeat)(?![A-Za-z])"#
    )

    /// 原文中不在結果裡的行（結果是原文的子序列時）。
    private static func deletedLines(source: String, result: String) -> [String] {
        let kept = result.components(separatedBy: "\n")
        var cursor = kept.startIndex
        var deleted: [String] = []
        for line in source.components(separatedBy: "\n") {
            if cursor < kept.endIndex, kept[cursor] == line {
                cursor += 1
            } else {
                deleted.append(line)
            }
        }
        return deleted
    }

    /// 不在任何環境裡的 `\item` 個數（依作用中的 `\begin`／`\end` 追蹤；遇到無法配對的 `\end` 就停止計算）。
    private static func lonelyItemCount(_ source: String) -> Int {
        let scan = LaTeXSourceScan(source)
        var stack: [String] = []
        var count = 0
        for word in scan.controlWords where scan.isActive(word.start) {
            switch word.name {
            case "begin", "end":
                guard let argument = scan.readGroupArgument(from: word.end) else { return count }
                if word.name == "begin" {
                    stack.append(argument.text)
                } else {
                    guard stack.last == argument.text else { return count }
                    stack.removeLast()
                }
            case "item":
                if stack.isEmpty { count += 1 }
            default:
                break
            }
        }
        return count
    }

    /// 作用中的 `\begin`／`\end` 全部配對，且每個 `\item` 都在某個環境裡。
    private static func listStructureIsWellFormed(_ source: String) -> Bool {
        let scan = LaTeXSourceScan(source)
        var stack: [String] = []
        for word in scan.controlWords where scan.isActive(word.start) {
            switch word.name {
            case "begin", "end":
                guard let argument = scan.readGroupArgument(from: word.end) else { return false }
                if word.name == "begin" {
                    stack.append(argument.text)
                } else {
                    guard stack.last == argument.text else { return false }
                    stack.removeLast()
                }
            case "item":
                if stack.isEmpty { return false }
            default:
                break
            }
        }
        return stack.isEmpty
    }

    // MARK: - fixSplitListEnvironments

    /// verbatim 內的 `\end{itemize}`、假 marker、`\item` 都不是列表結構：原文不動。
    func testSplitList_fakeMarkerInsideVerbatimIsLeftAlone() {
        let input = """
        \\begin{document}
        \\begin{verbatim}
        \\begin{itemize}
        \\item One
        \\end{itemize}
        %% === Page 3 ===
        \\item Two
        \\end{verbatim}
        Text after.
        \\end{document}
        """
        let result = LaTeXNormalizer.fixSplitListEnvironments(input)
        XCTAssertEqual(result, input)
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(result), result)
    }

    func testSplitList_fakeMarkerInsideCommentEnvironmentIsLeftAlone() {
        let input = """
        \\begin{document}
        \\begin{comment}
        \\begin{enumerate}
        \\item One
        \\end{enumerate}
        %% === Page 3 ===
        \\item Two
        \\end{comment}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    /// verbatim 外的真正分頁照常修正，且冪等。
    func testSplitList_realSplitIsStillFixedAndIdempotent() {
        let input = """
        \\begin{document}
        \\begin{itemize}
        \\item One
        \\end{itemize}
        %% === Page 3 ===
        \\item Two
        Text after.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        \\begin{itemize}
        \\item One
        %% === Page 3 ===
        \\item Two
        \\end{itemize}
        Text after.
        \\end{document}
        """
        let result = LaTeXNormalizer.fixSplitListEnvironments(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(result), result)
    }

    /// 孤立 item 那一行以 `\verb` 結尾（行尾當分隔字元，下一行是 verbatim 內容）：在它之後插入
    /// `\end{itemize}` 會插進 `\verb` 的內容裡。這種情形整個修正都不做，原文不動。
    func testSplitList_neverInsertsIntoVerbatim() {
        let input = """
        \\begin{document}
        \\begin{itemize}
        \\item One
        \\end{itemize}
        %% === Page 3 ===
        \\item Two \\verb
        x
        Text after.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    // MARK: - fixSplitListEnvironments：以產生的列表文件驗證修正（Codex R4）

    /// 產生的文件中的一個列表項目：前面是否有 page marker、是否帶一個巢狀列表。
    private struct GeneratedItem {
        var markerBefore: Bool
        var nested: [GeneratedItem]?
        var nestedEnv: String
    }

    private func makeItems(depth: Int, _ rng: inout SeededGenerator) -> [GeneratedItem] {
        (0..<Int.random(in: 1...4, using: &rng)).map { _ in
            let hasNested = depth < 2 && Int.random(in: 0..<4, using: &rng) == 0
            return GeneratedItem(
                markerBefore: Int.random(in: 0..<3, using: &rng) == 0,
                nested: hasNested ? makeItems(depth: depth + 1, &rng) : nil,
                nestedEnv: Bool.random(using: &rng) ? "itemize" : "enumerate"
            )
        }
    }

    /// 列表的各行；`splitBefore` 裡的項目（頂層）前面、marker 之前插入過早的 `\end{env}`；
    /// `nestedSplit` 為真時，第一個符合條件的巢狀列表項目前插入過早的內層結尾。
    private func listLines(
        env: String, items: [GeneratedItem], splitBefore: Set<Int> = [], nestedSplit: inout Bool,
        dropClosing: Bool = false
    ) -> [String] {
        var lines = ["\\begin{\(env)}"]
        for (index, item) in items.enumerated() {
            if item.markerBefore {
                if splitBefore.contains(index) { lines.append("\\end{\(env)}") }
                lines.append("MARKER")
            }
            lines.append("\\item L\(index)")
            if let nested = item.nested {
                var nestedLines = ["\\begin{\(item.nestedEnv)}"]
                for (inner, nestedItem) in nested.enumerated() {
                    if nestedItem.markerBefore {
                        if nestedSplit && inner > 0 {
                            nestedLines.append("\\end{\(item.nestedEnv)}")
                            nestedSplit = false
                        }
                        nestedLines.append("MARKER")
                    }
                    nestedLines.append("\\item N\(inner)")
                }
                nestedLines.append("\\end{\(item.nestedEnv)}")
                lines += nestedLines
            }
        }
        if !dropClosing { lines.append("\\end{\(env)}") }
        return lines
    }

    /// 修正的契約以產生的文件驗證：
    /// - 配對完整的列表文件（含巢狀、跨頁 marker）一字不動；
    /// - 頂層列表在 marker 前被過早關閉（一處或兩處；可能連原本的結尾也掉了）→ 修回原文；
    /// - 只有巢狀列表被過早關閉：之後的每個 `\end` 都往外錯一層，頂層可能真的出現孤立的 `\item`
    ///   （原文本來就無法編譯）。沒有孤立 `\item` 時原文不動；有的時候孤立 `\item` 的數量不增加；
    /// - 每一種都冪等，且修正後孤立 `\item` 的數量都不增加。
    func testSplitListRepairsTopLevelSplitsOfGeneratedDocuments() {
        var rng = SeededGenerator(state: 0x5EED_0216)
        var repaired = 0
        for index in 0..<3000 {
            let blocks: [(env: String, items: [GeneratedItem])?] = (0..<Int.random(in: 1...5, using: &rng)).map { _ in
                Int.random(in: 0..<3, using: &rng) == 0
                    ? nil
                    : (Bool.random(using: &rng) ? "itemize" : "enumerate", makeItems(depth: 1, &rng))
            }
            // 可以製造頂層分頁的列表：分頁點（有 marker 的第 t 項，t ≥ 1）之後的項目都沒有巢狀列表。
            let target = blocks.indices.filter { b in
                guard let list = blocks[b] else { return false }
                return list.items.indices.contains { t in
                    t > 0 && list.items[t].markerBefore && list.items[t...].allSatisfy { $0.nested == nil }
                }
            }.randomElement(using: &rng)
            let kind = Int.random(in: 0..<4, using: &rng)  // 0 原文、1 一處、2 兩處或掉結尾、3 巢狀

            func render(corrupt: Bool) -> String {
                var lines = ["\\documentclass{article}", "\\begin{document}"]
                var nestedSplit = corrupt && kind == 3
                for (b, block) in blocks.enumerated() {
                    guard let list = block else {
                        lines += ["Text \(b).", "MARKER"]
                        continue
                    }
                    var split: Set<Int> = []
                    var dropClosing = false
                    if corrupt && b == target && (kind == 1 || kind == 2) {
                        let points = list.items.indices.filter { t in
                            t > 0 && list.items[t].markerBefore && list.items[t...].allSatisfy { $0.nested == nil }
                        }
                        split = [points.randomElement(using: &rng)!]
                        if kind == 2 {
                            if Bool.random(using: &rng) {
                                split.formUnion(points)
                            } else {
                                dropClosing = true
                            }
                        }
                    }
                    lines += listLines(env: list.env, items: list.items, splitBefore: split,
                                       nestedSplit: &nestedSplit, dropClosing: dropClosing)
                }
                lines.append("\\end{document}")
                var page = 0
                let text = lines.map { line -> String in
                    guard line == "MARKER" else { return line }
                    page += 1
                    return "%% === Page \(page) ==="
                }.joined(separator: "\n")
                return text
            }

            // rng 的使用順序在兩次 render 之間必須相同：原文不用 rng，先算損壞版。
            let corrupted = render(corrupt: true)
            let original = render(corrupt: false)
            let crlf = index % 5 == 0
            let (source, damaged) = crlf
                ? (original.replacingOccurrences(of: "\n", with: "\r\n"), corrupted.replacingOccurrences(of: "\n", with: "\r\n"))
                : (original, corrupted)
            let context = "case \(index) kind \(kind):\n\(damaged.debugDescription)"

            XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(source), source, "\(context)\n(原文)")
            let fixed = LaTeXNormalizer.fixSplitListEnvironments(damaged)
            XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(fixed), fixed, context)
            XCTAssertLessThanOrEqual(Self.lonelyItemCount(fixed), Self.lonelyItemCount(damaged), context)
            switch kind {
            case 1, 2 where target != nil:
                XCTAssertEqual(fixed, source, context)
                if damaged != source { repaired += 1 }
            default:
                if Self.lonelyItemCount(damaged) == 0 {
                    XCTAssertEqual(fixed, damaged, context)
                }
            }
        }
        XCTAssertGreaterThan(repaired, 500)
    }

    // MARK: - fixSplitListEnvironments：巢狀與外層環境（Codex R4 HIGH）

    /// 內層列表的結尾夾著分頁、下一頁是外層的 `\item`：外層列表還開著，`\item Outer two` 屬於外層，
    /// 不是孤立的 item。舊版刪掉內層結尾且不補回，pdflatex 實測
    /// `\begin{itemize} on input line 3 ended by \end{document}`；原文可以編譯。
    func testSplitList_itemOfAnOuterListIsNotOrphan() {
        let input = """
        \\documentclass{article}
        \\begin{document}
        \\begin{itemize}
        \\item Outer
        \\begin{itemize}
        \\item Inner
        \\end{itemize}
        %% === Page 2 ===
        \\item Outer two
        \\end{itemize}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    /// 外層列表本身被過早關閉（它關閉之後沒有任何環境還開著）時照常修正。
    func testSplitList_outerListSplitIsStillFixed() {
        let input = """
        \\begin{document}
        \\begin{itemize}
        \\item Outer
        \\begin{itemize}
        \\item Inner
        \\end{itemize}
        \\end{itemize}
        %% === Page 2 ===
        \\item Outer two
        \\end{itemize}
        \\end{document}
        """
        let expected = """
        \\begin{document}
        \\begin{itemize}
        \\item Outer
        \\begin{itemize}
        \\item Inner
        \\end{itemize}
        %% === Page 2 ===
        \\item Outer two
        \\end{itemize}
        \\end{document}
        """
        let result = LaTeXNormalizer.fixSplitListEnvironments(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(result), result)
    }

    /// 列表外面還有其他環境（這裡是 `center`）：`\item` 在 center（trivlist）裡是合法的（pdflatex 實測可編譯），
    /// 無法確定它是孤立的跨頁續接，不動。
    func testSplitList_listInsideAnotherEnvironmentIsLeftAlone() {
        let input = """
        \\begin{document}
        \\begin{center}
        \\begin{itemize}
        \\item A
        \\end{itemize}
        %% === Page 2 ===
        \\item B
        \\end{center}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    /// 只修跨頁：`\end{…}` 與 `\item` 之間沒有 page marker 時不是本函式處理的情形。
    func testSplitList_requiresAPageMarkerInBetween() {
        let input = "\\begin{document}\n\\begin{itemize}\n\\item A\n\\end{itemize}\n\n\\item B\nText.\n\\end{document}"
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    /// `\itemsep` 等以 item 開頭的其他控制字不是 `\item`。
    func testSplitList_itemsepIsNotAnItem() {
        let input = "\\begin{document}\n\\begin{itemize}\n\\item A\n\\end{itemize}\n%% === Page 2 ===\n\\itemsep 2pt\nText.\n\\end{document}"
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    /// 同一個列表連續跨兩頁：一輪就修好，第二輪不再改。
    func testSplitList_listSplitAcrossThreePagesIsFixedInOnePass() {
        let input = """
        \\begin{document}
        \\begin{enumerate}
        \\item A
        \\end{enumerate}
        %% === Page 2 ===
        \\item B
        \\end{enumerate}
        %% === Page 3 ===
        \\item C
        \\end{enumerate}
        Text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        \\begin{enumerate}
        \\item A
        %% === Page 2 ===
        \\item B
        %% === Page 3 ===
        \\item C
        \\end{enumerate}
        Text.
        \\end{document}
        """
        let result = LaTeXNormalizer.fixSplitListEnvironments(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(result), result)
    }

    /// 孤立 item 的範圍裡環境沒有配對完整（`\item B \begin{enumerate}` 開了、在範圍外才關）：補上的
    /// `\end{…}` 會落在內層環境裡，不動。
    func testSplitList_orphanRunWithAnOpenEnvironmentIsLeftAlone() {
        let input = """
        \\begin{document}
        \\begin{itemize}
        \\item A
        \\end{itemize}
        %% === Page 2 ===
        \\item B \\begin{enumerate}
        \\item B1
        \\end{enumerate}
        Text.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(input), input)
    }

    /// CRLF 檔案同樣修正，補上的結尾用 CRLF。
    func testSplitList_CRLF() {
        let input = "\\begin{document}\r\n\\begin{itemize}\r\n\\item A\r\n\\end{itemize}\r\n%% === Page 2 ===\r\n\\item B\r\nText.\r\n\\end{document}"
        let expected = "\\begin{document}\r\n\\begin{itemize}\r\n\\item A\r\n%% === Page 2 ===\r\n\\item B\r\n\\end{itemize}\r\nText.\r\n\\end{document}"
        let result = LaTeXNormalizer.fixSplitListEnvironments(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.fixSplitListEnvironments(result), result)
    }
}
