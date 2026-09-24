import XCTest
@testable import PDFToLaTeXCore

/// 共用作用中掃描（PsychQuant/macdoc#9、#10）。標註 A*/B* 的案例都以 pdflatex
/// （pdfTeX 1.40.27, TeX Live 2025）實際編譯確認過 TeX 的行為，見 commit body。
final class LaTeXSourceScanTests: XCTestCase {

    private static let switchNames: Set<String> = ["frontmatter", "mainmatter"]

    /// 真正會被執行的切換指令名稱（依出現順序）。
    private func executedSwitches(_ source: String) -> [String] {
        let scan = LaTeXSourceScan(source)
        return scan.controlWords
            .filter { Self.switchNames.contains($0.name) && scan.isExecuted($0.start) }
            .map(\.name)
    }

    // MARK: - \verb delimiter rules (pdflatex-verified)

    func testVerbDelimiterRules() {
        let cases: [(label: String, source: String)] = [
            ("A1 letter delimiter after *", "\\verb*X\\frontmatterX \\mainmatter"),
            ("A4 space after \\verb is skipped", "\\verb |\\frontmatter| \\mainmatter"),
            ("A5 space after * is skipped", "\\verb* |\\frontmatter| \\mainmatter"),
            ("A16 letter delimiter after a space", "\\verb X\\frontmatterX \\mainmatter"),
            ("A22 space before * disables the star form: * is the delimiter", "\\verb *\\frontmatter* \\mainmatter"),
            ("A23 tab before * keeps the star form", "\\verb\t*X\\frontmatterX \\mainmatter"),
            ("A6 % as delimiter", "\\verb%\\frontmatter% \\mainmatter"),
            ("A7 { as delimiter", "\\verb{\\frontmatter{ \\mainmatter"),
            ("A13 % as delimiter after *", "\\verb*%\\frontmatter% \\mainmatter"),
            ("A9 end of line after *: the next line is the content", "\\verb*\n\\frontmatter\n\\mainmatter"),
            ("A14 end of line after \\verb", "\\verb\n\\frontmatter\n\\mainmatter"),
            ("A15/A24 trailing blanks then end of line", "\\verb*  \n  \\frontmatter\n\\mainmatter"),
            ("A25 CRLF end of line", "\\verb*\r\n\\frontmatter\r\n\\mainmatter"),
            ("A10 missing closing delimiter ends at end of line", "\\verb|\\frontmatter\n\\mainmatter"),
        ]
        for (label, source) in cases {
            XCTAssertEqual(executedSwitches(source), ["mainmatter"], label)
        }
    }

    func testLetterRightAfterVerbIsAnotherControlWord() {
        // A11：\verbX… 是另一個控制字，不是 \verb。
        let scan = LaTeXSourceScan("\\verbX\\frontmatter X")
        XCTAssertEqual(scan.controlWords.map(\.name), ["verbX", "frontmatter"])
        XCTAssertEqual(executedSwitches("\\verbX\\frontmatter X"), ["frontmatter"])
    }

    // MARK: - Environment arguments with comments (pdflatex-verified)

    func testCommentBetweenBeginAndVerbatimNameStartsVerbatim() {
        // B1
        let source = "\\begin% note\n   {verbatim}\n\\frontmatter\n\\end{verbatim}\n\\mainmatter"
        XCTAssertEqual(executedSwitches(source), ["mainmatter"])
    }

    func testCommentBetweenBeginEndAndDocumentKeepsBodyBoundaries() {
        // B1
        let source = """
        %% === Page 99 ===
        \\documentclass{book}
        \\begin% note
        {document}
        %% === Page 3 ===
        Text.
        \\end% note
          {document}
        %% === Page 98 ===
        """
        let scan = LaTeXSourceScan(source)
        XCTAssertEqual(scan.pageMarkers.map(\.page), [3])
    }

    func testOnlyLiteralEndTerminatesVerbatim() {
        // B2
        let source = "\\begin{verbatim}\n\\end {verbatim}\n\\end% c\n{verbatim}\n\\frontmatter\n\\end{verbatim}\n\\mainmatter"
        XCTAssertEqual(executedSwitches(source), ["mainmatter"])
    }

    func testNestedVerbatimLikeEnvironments() {
        let commentAroundVerbatim = """
        \\begin{comment}
        \\begin{verbatim}
        \\frontmatter
        \\end{verbatim}
        \\frontmatter
        %% === Page 99 ===
        \\end{comment}
        \\mainmatter
        """
        XCTAssertEqual(executedSwitches(commentAroundVerbatim), ["mainmatter"])
        XCTAssertEqual(LaTeXSourceScan(commentAroundVerbatim).pageMarkers.map(\.page), [])

        let verbatimAroundListing = """
        \\begin{verbatim}
        \\begin{lstlisting}
        \\end{lstlisting}
        \\frontmatter
        \\end{verbatim}
        \\mainmatter
        """
        XCTAssertEqual(executedSwitches(verbatimAroundListing), ["mainmatter"])
    }

    // MARK: - TeX comment semantics in the code view (pdflatex-verified)

    func testCommentConsumesNewlineAndNextLineLeadingBlanks() {
        // B3：wid%⏎    th=3cm 的 key 是 width。
        let source = "wid% note\n    th=3cm"
        let scan = LaTeXSourceScan(source)
        XCTAssertEqual(scan.texCodeText(0..<scan.units.count), "width=3cm")
    }

    func testPlainNewlineIsASpace() {
        // B4：沒有註解時換行是空白，wid⏎th 的 key 是 "wid th"。
        let scan = LaTeXSourceScan("wid\n   th=3cm")
        XCTAssertEqual(scan.texCodeText(0..<scan.units.count), "wid th=3cm")
    }

    // MARK: - Page marker lines

    func testOnlyExactMarkerLinesAreMarkers() {
        let source = """
        %% === Page 3 ===
          %% === Page 4 ===\("  ")
        %% === Page 12 === explanation
        % example: %% === Page 13 ===
        Text %% === Page 14 ===
        """
        XCTAssertEqual(LaTeXSourceScan(source).pageMarkers.map(\.page), [3, 4])
    }
}
