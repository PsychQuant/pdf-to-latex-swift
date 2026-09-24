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
        "\\item X", "\\item Y", "", "%% note", "% plain comment", "  Text A.  ",
        "\\begin{verbatim}\nText A.\n%% === Page 50 ===\nText A.\n\\end{verbatim}",
        "\\begin{comment}\n\\end{itemize}\n%% === Page 51 ===\n\\item Z\n\\end{comment}",
        "\\begin{Verbatim}\n\\end{itemize}\n\\end{Verbatim}",
        "\\verb\n%% === Page 52 ===", "\\item V \\verb\nText A.", "\\begin% c\n{verbatim}\nText B.\n\\end{verbatim}",
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

    /// 兩個步驟都不改任何 verbatim；去重冪等，且只刪 marker 以外的行。
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

            // 列表修正這裡只驗 verbatim 不變。它的冪等性由定向測試負責：產生器會做出「兩個 `\end{itemize}`
            // 之間只隔 marker」這種壞掉的輸入，v0.3.0 的同一段邏輯對它本來就不冪等（與 marker 判定無關）。
            let fixed = LaTeXNormalizer.fixSplitListEnvironments(source)
            XCTAssertEqual(LaTeXSourceScan(fixed).verbatimSegments, verbatim, context)
        }
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
}
