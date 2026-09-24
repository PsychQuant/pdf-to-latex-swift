import XCTest
@testable import PDFToLaTeXCore

final class LaTeXNormalizerTests: XCTestCase {

    // MARK: - Original String-Level Tests

    func testDocumentClassFix_articleToBook() {
        let input = "\\documentclass{article}\n\\begin{document}\n\\chapter{Intro}\n\\end{document}"
        let result = LaTeXNormalizer().normalize(input)
        XCTAssertTrue(result.contains("\\documentclass{book}"))
        XCTAssertFalse(result.contains("\\documentclass{article}"))
    }

    func testDocumentClassFix_noChapterKeepsArticle() {
        let input = "\\documentclass{article}\n\\begin{document}\n\\section{Intro}\n\\end{document}"
        let result = LaTeXNormalizer().normalize(input)
        XCTAssertTrue(result.contains("\\documentclass{article}"))
    }

    func testDocumentClassFix_withOptions() {
        let input = "\\documentclass[11pt,a4paper]{article}\n\\chapter{Intro}"
        let result = LaTeXNormalizer.fixDocumentClassInSource(input, hasChapters: true)
        XCTAssertTrue(result.contains("\\documentclass[11pt,a4paper]{book}"))
        XCTAssertFalse(result.contains("{article}"))
    }

    func testDocumentClassFix_withOptionsNoChapter() {
        let input = "\\documentclass[11pt]{article}\n\\section{Intro}"
        let result = LaTeXNormalizer.fixDocumentClassInSource(input, hasChapters: false)
        XCTAssertTrue(result.contains("{article}"))
    }

    func testDocumentClassFix_alreadyBook() {
        let input = "\\documentclass[11pt]{book}\n\\chapter{Intro}"
        let result = LaTeXNormalizer.fixDocumentClassInSource(input, hasChapters: true)
        XCTAssertEqual(result, input)
    }

    func testSymbolNormalization() {
        let input = "\\bm{x} and \\bm{\\beta}"
        let normalizer = LaTeXNormalizer(symbolRules: ["\\bm{": "\\boldsymbol{"])
        let result = normalizer.normalize(input)
        XCTAssertEqual(result, "\\boldsymbol{x} and \\boldsymbol{\\beta}")
    }

    func testCrossPageDedup() {
        let input = """
        Line A
        Line B
        Line C
        %% === Page 2 ===
        Line B
        Line C
        Line D
        """
        let result = LaTeXNormalizer().normalize(input)
        XCTAssertEqual(result.components(separatedBy: "Line B").count, 2)
        XCTAssertEqual(result.components(separatedBy: "Line C").count, 2)
        XCTAssertTrue(result.contains("Line D"))
    }

    func testStripPageMarkers() {
        let input = "Line 1\n%% === Page 2 ===\nLine 2\n%% === Page 3 ===\nLine 3"
        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        let result = normalizer.normalize(input)
        XCTAssertFalse(result.contains("=== Page"))
        XCTAssertTrue(result.contains("Line 1"))
        XCTAssertTrue(result.contains("Line 2"))
        XCTAssertTrue(result.contains("Line 3"))
    }

    func testNoChangesForCleanInput() {
        let input = "\\documentclass{book}\n\\begin{document}\n\\chapter{Intro}\n\\end{document}"
        let result = LaTeXNormalizer().normalize(input)
        XCTAssertEqual(result, input)
    }

    func testMultipleSymbolRules() {
        let input = "\\bm{x} + \\mathbb{R}"
        let normalizer = LaTeXNormalizer(symbolRules: [
            "\\bm{": "\\boldsymbol{",
            "\\mathbb{": "\\mathbf{",
        ])
        let result = normalizer.normalize(input)
        XCTAssertTrue(result.contains("\\boldsymbol{x}"))
        XCTAssertTrue(result.contains("\\mathbf{R}"))
    }

    // MARK: - Preamble Resolution

    func testResolvePreambleURL() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let preambleURL = tmpDir.appendingPathComponent("preamble.tex")
        try "\\documentclass{article}\n\\usepackage{amsmath}".write(
            to: preambleURL, atomically: true, encoding: .utf8
        )

        let mainURL = tmpDir.appendingPathComponent("main.tex")
        let mainSource = "\\input{preamble}\n\\begin{document}\nHello\n\\end{document}"

        let resolved = LaTeXNormalizer.resolvePreambleURL(from: mainSource, relativeTo: mainURL)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.lastPathComponent, "preamble.tex")
    }

    func testResolvePreambleURL_noInput() {
        let mainSource = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"
        let mainURL = URL(fileURLWithPath: "/tmp/main.tex")
        let resolved = LaTeXNormalizer.resolvePreambleURL(from: mainSource, relativeTo: mainURL)
        XCTAssertNil(resolved)
    }

    func testResolvePreambleURL_commentedOutIgnored() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let preambleURL = tmpDir.appendingPathComponent("preamble.tex")
        try "\\documentclass{article}".write(
            to: preambleURL, atomically: true, encoding: .utf8
        )

        let mainURL = tmpDir.appendingPathComponent("main.tex")
        let mainSource = "% \\input{preamble}\n\\begin{document}\nHello\n\\end{document}"

        let resolved = LaTeXNormalizer.resolvePreambleURL(from: mainSource, relativeTo: mainURL)
        XCTAssertNil(resolved)
    }

    // MARK: - Math Operator Detection

    func testDetectMissingMathOperators_basic() {
        let main = "The expectation is $\\E(x)$ and variance $\\var(x)$."
        let preamble = "\\documentclass{article}\n\\usepackage{amsmath}"
        let missing = LaTeXNormalizer.detectMissingMathOperators(
            mainSource: main, preambleSource: preamble
        )
        let cmds = missing.map { $0.command }
        XCTAssertTrue(cmds.contains("E"))
        XCTAssertTrue(cmds.contains("var"))
    }

    func testDetectMissingMathOperators_alreadyDefined() {
        let main = "The expectation is $\\E(x)$."
        let preamble = "\\documentclass{article}\n\\DeclareMathOperator{\\E}{E}"
        let missing = LaTeXNormalizer.detectMissingMathOperators(
            mainSource: main, preambleSource: preamble
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testDetectMissingMathOperators_newcommandCounts() {
        let main = "$\\cov(x,y)$"
        let preamble = "\\newcommand{\\cov}{\\operatorname{cov}}"
        let missing = LaTeXNormalizer.detectMissingMathOperators(
            mainSource: main, preambleSource: preamble
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testDetectMissingMathOperators_noFalsePositive() {
        let main = "Some text without math operators."
        let preamble = "\\documentclass{article}"
        let missing = LaTeXNormalizer.detectMissingMathOperators(
            mainSource: main, preambleSource: preamble
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testDetectMissingMathOperators_vecIsBuiltIn() {
        let main = "$\\vec(A)$"
        let preamble = "\\documentclass{article}"
        let missing = LaTeXNormalizer.detectMissingMathOperators(
            mainSource: main, preambleSource: preamble
        )
        let vec = missing.first { $0.command == "vec" }
        XCTAssertNotNil(vec)
        XCTAssertTrue(vec!.isBuiltIn)
    }

    func testDetectMissingMathOperators_partialNameNotMatched() {
        // \variable should not trigger \var detection
        let main = "The $\\variable$ is important."
        let preamble = "\\documentclass{article}"
        let missing = LaTeXNormalizer.detectMissingMathOperators(
            mainSource: main, preambleSource: preamble
        )
        let hasVar = missing.contains { $0.command == "var" }
        XCTAssertFalse(hasVar)
    }

    // MARK: - Package Detection

    func testDetectMissingPackages_xcolor() {
        let main = "\\begin{figure}[htbp]\n\\includegraphics{img.png}\n\\end{figure}"
        let preamble = "\\documentclass{book}\n\\usepackage{graphicx}"
        let missing = LaTeXNormalizer.detectMissingPackages(mainSource: main, preambleSource: preamble)
        XCTAssertTrue(missing.contains("xcolor"))
    }

    func testDetectMissingPackages_alreadyLoaded() {
        let main = "\\begin{figure}[htbp]\\end{figure}"
        let preamble = "\\documentclass{book}\n\\usepackage{xcolor}"
        let missing = LaTeXNormalizer.detectMissingPackages(mainSource: main, preambleSource: preamble)
        XCTAssertFalse(missing.contains("xcolor"))
    }

    func testDetectMissingPackages_withOptions() {
        let main = "\\begin{figure}[htbp]\\end{figure}"
        let preamble = "\\documentclass{book}\n\\usepackage[dvipsnames]{xcolor}"
        let missing = LaTeXNormalizer.detectMissingPackages(mainSource: main, preambleSource: preamble)
        XCTAssertFalse(missing.contains("xcolor"))
    }

    // MARK: - Verbatim-in-Fbox Fix

    func testFixVerbatimInFbox_removesWrapper() {
        let input = """
        \\begin{center}
        \\fbox{%
        \\begin{minipage}{0.78\\textwidth}
        \\begin{verbatim}
        x = 1
        \\end{verbatim}
        \\end{minipage}%
        }
        \\end{center}
        """
        let result = LaTeXNormalizer.fixVerbatimInFbox(input)
        XCTAssertFalse(result.contains("\\fbox{%"))
        XCTAssertTrue(result.contains("\\begin{minipage}"))
        XCTAssertTrue(result.contains("\\begin{verbatim}"))
        XCTAssertTrue(result.contains("x = 1"))
    }

    func testFixVerbatimInFbox_noVerbatimUntouched() {
        let input = "\\fbox{%\n\\begin{minipage}{0.5\\textwidth}\nHello\n\\end{minipage}%\n}"
        let result = LaTeXNormalizer.fixVerbatimInFbox(input)
        XCTAssertTrue(result.contains("\\fbox{%"))
    }

    // MARK: - Equation Split Fix

    func testFixEquationSplits_removesInternalSplit() {
        let input = """
        \\begin{equation}
        x = 1
        \\]
        \\[
        y = 2
        \\tag{3.1}
        \\end{equation}
        """
        let result = LaTeXNormalizer.fixEquationSplits(input)
        XCTAssertFalse(result.contains("\\]"))
        XCTAssertFalse(result.contains("\\["))
        XCTAssertTrue(result.contains("x = 1"))
        XCTAssertTrue(result.contains("y = 2"))
        XCTAssertTrue(result.contains("\\begin{equation}"))
        XCTAssertTrue(result.contains("\\end{equation}"))
    }

    func testFixEquationSplits_outsideEquationUntouched() {
        let input = "\\[\nx = 1\n\\]\n\\[\ny = 2\n\\]"
        let result = LaTeXNormalizer.fixEquationSplits(input)
        XCTAssertEqual(result, input)
    }

    func testFixEquationSplits_equationStarSupported() {
        let input = "\\begin{equation*}\nx = 1\n\\]\n\\[\ny = 2\n\\end{equation*}"
        let result = LaTeXNormalizer.fixEquationSplits(input)
        XCTAssertFalse(result.contains("\\]"))
    }

    // MARK: - Transcription Artifacts

    func testFixCommonArtifacts_copyrightInMath() {
        let input = "{\\small $\\copyright$2000}"
        let result = LaTeXNormalizer.fixCommonTranscriptionArtifacts(input)
        XCTAssertEqual(result, "{\\small \\textcopyright{}2000}")
    }

    func testFixCommonArtifacts_copyrightWithDollar() {
        let input = "{\\small $\\copyright\\$2000, 2014}"
        let result = LaTeXNormalizer.fixCommonTranscriptionArtifacts(input)
        XCTAssertEqual(result, "{\\small \\textcopyright{}2000, 2014}")
    }

    func testFixCommonArtifacts_idempotent() {
        let input = "{\\small \\textcopyright{}2000}"
        let result = LaTeXNormalizer.fixCommonTranscriptionArtifacts(input)
        XCTAssertEqual(result, input)
    }

    func testFixCommonArtifacts_noMatchUnchanged() {
        let input = "Normal $x + y$ text."
        let result = LaTeXNormalizer.fixCommonTranscriptionArtifacts(input)
        XCTAssertEqual(result, input)
    }

    // MARK: - Add Math Operators

    func testAddMathOperatorDefinitions() {
        let preamble = "\\documentclass{article}\n\\usepackage{amsmath}"
        let ops = [
            MathOperatorDef(command: "E"),
            MathOperatorDef(command: "var"),
        ]
        let result = LaTeXNormalizer.addMathOperatorDefinitions(ops, to: preamble)
        XCTAssertTrue(result.contains("\\DeclareMathOperator{\\E}{E}"))
        XCTAssertTrue(result.contains("\\DeclareMathOperator{\\var}{var}"))
        XCTAssertTrue(result.contains("% Math operators (auto-detected)"))
    }

    func testAddMathOperatorDefinitions_builtInHasLetRelax() {
        let preamble = "\\documentclass{article}"
        let ops = [MathOperatorDef(command: "vec", isBuiltIn: true)]
        let result = LaTeXNormalizer.addMathOperatorDefinitions(ops, to: preamble)
        XCTAssertTrue(result.contains("\\let\\vec\\relax"))
        XCTAssertTrue(result.contains("\\DeclareMathOperator{\\vec}{vec}"))
        // \let\vec\relax should come before \DeclareMathOperator
        let letPos = result.range(of: "\\let\\vec\\relax")!.lowerBound
        let declarePos = result.range(of: "\\DeclareMathOperator{\\vec}")!.lowerBound
        XCTAssertTrue(letPos < declarePos)
    }

    func testAddMathOperatorDefinitions_empty() {
        let preamble = "\\documentclass{article}"
        let result = LaTeXNormalizer.addMathOperatorDefinitions([], to: preamble)
        XCTAssertEqual(result, preamble)
    }

    func testAddMathOperatorsBeforeDocument() {
        let source = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"
        let ops = [MathOperatorDef(command: "E")]
        let result = LaTeXNormalizer.addMathOperatorsBeforeDocument(ops, in: source)
        XCTAssertTrue(result.contains("\\DeclareMathOperator{\\E}{E}"))
        // Should appear before \begin{document}
        let declarePos = result.range(of: "\\DeclareMathOperator")!.lowerBound
        let beginPos = result.range(of: "\\begin{document}")!.lowerBound
        XCTAssertTrue(declarePos < beginPos)
    }

    // MARK: - Currency Dollar Escaping

    func testEscapeCurrencyDollars_basic() {
        let input = "The wage is $15 per hour."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertEqual(result, "The wage is \\$15 per hour.")
        XCTAssertEqual(count, 1)
    }

    func testEscapeCurrencyDollars_withDecimals() {
        let input = "The median wage ($19.23) is shown."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertEqual(result, "The median wage (\\$19.23) is shown.")
        XCTAssertEqual(count, 1)
    }

    func testEscapeCurrencyDollars_multipleInOneLine() {
        let input = "between $10 and $40."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertTrue(result.contains("\\$10"))
        XCTAssertTrue(result.contains("\\$40"))
        XCTAssertEqual(count, 2)
    }

    func testEscapeCurrencyDollars_alreadyEscaped() {
        let input = "The wage is \\$15 per hour."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertEqual(result, input)
        XCTAssertEqual(count, 0)
    }

    func testEscapeCurrencyDollars_mathModeNotAffected() {
        let input = "If $x = 2^p$ then..."
        let (result, _) = LaTeXNormalizer.escapeCurrencyDollars(input)
        // $x should not be affected (x is not a digit)
        // $2^p$ — the 2 is followed by ^ which is not in our trailing char set
        XCTAssertEqual(result, input)
    }

    func testEscapeCurrencyDollars_idempotent() {
        let input = "Price is $15, cost is $23.90."
        let (first, _) = LaTeXNormalizer.escapeCurrencyDollars(input)
        let (second, count2) = LaTeXNormalizer.escapeCurrencyDollars(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(count2, 0)
    }

    func testEscapeCurrencyDollars_noMatchReturnsOriginal() {
        let input = "No dollars here, just math $x + y = z$."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertEqual(result, input)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Currency Dollar Escaping — 反斜線奇偶邊界（PsychQuant/pdf-to-latex-swift#4）

    /// 前導反斜線數量從 0 到 4，逐一驗證奇偶判斷：偶數（含 0）＝未跳脫、要補一個反斜線；
    /// 奇數＝已跳脫、原樣保留、不計入跳脫數。
    func testEscapeCurrencyDollars_backslashParityBoundary() {
        for backslashCount in 0...4 {
            let backslashes = String(repeating: "\\", count: backslashCount)
            let input = "Value: \(backslashes)$15 end."
            let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
            if backslashCount.isMultiple(of: 2) {
                // 偶數（含 0）：未跳脫，補一個反斜線，原有反斜線不變。
                let expected = "Value: \(backslashes)\\$15 end."
                XCTAssertEqual(result, expected, "backslashCount=\(backslashCount) 應視為未跳脫")
                XCTAssertEqual(count, 1, "backslashCount=\(backslashCount) 應計為 1 次跳脫")
            } else {
                // 奇數：最後一個反斜線已跳脫這個 $，原樣保留、不計數。
                XCTAssertEqual(result, input, "backslashCount=\(backslashCount) 應視為已跳脫，維持原樣")
                XCTAssertEqual(count, 0, "backslashCount=\(backslashCount) 不應計入跳脫數")
            }
        }
    }

    /// 兩個反斜線是 LaTeX 換行指令 `\\`，跟它後面的 `$` 是否跳脫無關——`$` 仍算未跳脫，要補一個反斜線，
    /// 原本的換行指令維持兩個反斜線不變（issue #4 明確舉的例子）。
    func testEscapeCurrencyDollars_lineBreakThenUnescapedDollarIsStillEscaped() {
        let input = "End of line\\\\$15 continues."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertEqual(result, "End of line\\\\\\$15 continues.")
        XCTAssertEqual(count, 1)
    }

    /// 已跳脫的重複執行本身要冪等（奇數反斜線的一般化版本，涵蓋 1 到 5 個反斜線）。
    func testEscapeCurrencyDollars_idempotentAcrossBackslashCounts() {
        for backslashCount in 0...5 {
            let backslashes = String(repeating: "\\", count: backslashCount)
            let input = "Value: \(backslashes)$15 end."
            let (first, _) = LaTeXNormalizer.escapeCurrencyDollars(input)
            let (second, count2) = LaTeXNormalizer.escapeCurrencyDollars(first)
            XCTAssertEqual(first, second, "backslashCount=\(backslashCount) 第二次處理不應再變動")
            XCTAssertEqual(count2, 0, "backslashCount=\(backslashCount) 第二次處理不應再計入跳脫數")
        }
    }

    /// 跨行不會誤判：上一行結尾的反斜線不該影響下一行開頭 `$` 的奇偶判斷（逐行處理，`line` 變數
    /// 本來就是單行字串，結構上不可能跨行比對——這裡把它寫成明確的迴歸測試）。
    func testEscapeCurrencyDollars_trailingBackslashOnPreviousLineDoesNotLeakAcrossLines() {
        let input = "First line ends with backslash\\\nSecond line has $15 unescaped."
        let (result, count) = LaTeXNormalizer.escapeCurrencyDollars(input)
        XCTAssertEqual(result, "First line ends with backslash\\\nSecond line has \\$15 unescaped.")
        XCTAssertEqual(count, 1, "上一行結尾的反斜線不該讓下一行的 $15 被誤判為已跳脫")
    }

    // MARK: - Project-Level Integration

    func testNormalizeProject_withExternalPreamble() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create preamble with article class
        let preambleURL = tmpDir.appendingPathComponent("preamble.tex")
        try """
        \\documentclass[11pt,a4paper]{article}
        \\usepackage{amsmath}
        """.write(to: preambleURL, atomically: true, encoding: .utf8)

        // Create main file with \chapter and \E
        let mainURL = tmpDir.appendingPathComponent("accumulated.tex")
        try """
        \\input{preamble}
        \\begin{document}
        \\chapter{Introduction}
        The expectation $\\E(x)$ and variance $\\var(x)$.
        The wage is $15 per hour.
        \\end{document}
        """.write(to: mainURL, atomically: true, encoding: .utf8)

        let normalizer = LaTeXNormalizer()
        let report = try normalizer.normalizeProject(mainTexURL: mainURL)

        // Preamble should be fixed
        XCTAssertTrue(report.preambleFileChanged)
        XCTAssertTrue(report.documentClassFixed)
        XCTAssertTrue(report.mathOperatorsAdded.contains("E"))
        XCTAssertTrue(report.mathOperatorsAdded.contains("var"))

        // Verify preamble content
        let preamble = try String(contentsOf: preambleURL, encoding: .utf8)
        XCTAssertTrue(preamble.contains("{book}"))
        XCTAssertFalse(preamble.contains("{article}"))
        XCTAssertTrue(preamble.contains("\\DeclareMathOperator{\\E}{E}"))
        XCTAssertTrue(preamble.contains("\\DeclareMathOperator{\\var}{var}"))

        // Main file should have currency escaped
        let main = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(main.contains("\\$15"))
        XCTAssertEqual(report.currencyDollarsEscaped, 1)
    }

    func testNormalizeProject_idempotent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let preambleURL = tmpDir.appendingPathComponent("preamble.tex")
        try "\\documentclass[11pt]{article}\n\\usepackage{amsmath}".write(
            to: preambleURL, atomically: true, encoding: .utf8
        )

        let mainURL = tmpDir.appendingPathComponent("main.tex")
        try "\\input{preamble}\n\\begin{document}\n\\chapter{Ch1}\n$\\E(x)$ costs $15.\n\\end{document}".write(
            to: mainURL, atomically: true, encoding: .utf8
        )

        let normalizer = LaTeXNormalizer()

        // First run
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertTrue(report1.mainFileChanged || report1.preambleFileChanged)

        let mainAfterFirst = try String(contentsOf: mainURL, encoding: .utf8)
        let preambleAfterFirst = try String(contentsOf: preambleURL, encoding: .utf8)

        // Second run — should be no-op
        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertFalse(report2.preambleFileChanged)
        XCTAssertFalse(report2.documentClassFixed)
        XCTAssertTrue(report2.mathOperatorsAdded.isEmpty)
        XCTAssertEqual(report2.currencyDollarsEscaped, 0)

        // Content should be unchanged
        let mainAfterSecond = try String(contentsOf: mainURL, encoding: .utf8)
        let preambleAfterSecond = try String(contentsOf: preambleURL, encoding: .utf8)
        XCTAssertEqual(mainAfterFirst, mainAfterSecond)
        XCTAssertEqual(preambleAfterFirst, preambleAfterSecond)
    }

    func testNormalizeProject_noPreamble() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mainURL = tmpDir.appendingPathComponent("main.tex")
        try """
        \\documentclass{article}
        \\usepackage{amsmath}
        \\begin{document}
        \\chapter{Intro}
        $\\E(x) = 0$
        \\end{document}
        """.write(to: mainURL, atomically: true, encoding: .utf8)

        let normalizer = LaTeXNormalizer()
        let report = try normalizer.normalizeProject(mainTexURL: mainURL)

        XCTAssertTrue(report.mainFileChanged)
        XCTAssertNil(report.preambleURL)
        XCTAssertTrue(report.documentClassFixed)
        XCTAssertTrue(report.mathOperatorsAdded.contains("E"))

        let content = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(content.contains("{book}"))
        XCTAssertTrue(content.contains("\\DeclareMathOperator{\\E}{E}"))
    }

    // MARK: - Manual Chapter Formatting Fix

    func testFixManualChapterFormatting_noindentLargeTextbf() {
        let input = """
        Some text before.

        \\noindent{\\Large\\textbf{Chapter 10}}

        \\bigskip

        \\noindent{\\LARGE\\textbf{The Bootstrap}}

        \\bigskip

        Content after.
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertTrue(result.contains("\\chapter{The Bootstrap}"))
        XCTAssertFalse(result.contains("\\noindent{\\Large\\textbf{Chapter 10}}"))
        XCTAssertTrue(result.contains("Content after."))
    }

    func testFixManualChapterFormatting_centeringPar() {
        let input = """
        {\\centering\\noindent{\\Large\\textbf{Chapter 11}}\\par}

        {\\centering\\noindent{\\LARGE\\textbf{NonParametric Regression}}\\par}

        Content.
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertTrue(result.contains("\\chapter{NonParametric Regression}"))
        XCTAssertFalse(result.contains("Chapter 11"))
    }

    func testFixManualChapterFormatting_bfseries() {
        let input = """
        \\noindent{\\Large\\bfseries Chapter 13}

        \\bigskip

        \\noindent{\\LARGE\\bfseries Generalized Method of Moments}

        \\bigskip
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertTrue(result.contains("\\chapter{Generalized Method of Moments}"))
    }

    func testFixManualChapterFormatting_plainTextbf() {
        let input = """
        \\noindent\\textbf{Chapter 19}

        \\bigskip

        \\noindent\\textbf{Panel Data}

        Content.
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertTrue(result.contains("\\chapter{Panel Data}"))
    }

    func testFixManualChapterFormatting_hugeSize() {
        let input = """
        \\noindent{\\LARGE\\textbf{Chapter 12}}

        \\vspace{1.5em}

        \\noindent{\\Huge\\textbf{Series Estimation}}

        \\vspace{2em}
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertTrue(result.contains("\\chapter{Series Estimation}"))
    }

    func testFixManualChapterFormatting_preservesProperChapter() {
        let input = """
        \\chapter{Introduction}

        Some content.

        \\chapter{Conditional Expectation}
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertEqual(input, result, "Proper \\chapter{} commands should not be modified")
    }

    func testFixManualChapterFormatting_ignoresChapterReferencesInText() {
        let input = """
        As discussed in Chapter 4, the estimator is consistent.

        See the results from Chapter 10 for more details.
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertEqual(input, result, "Chapter references in running text should not be modified")
    }

    func testFixManualChapterFormatting_idempotent() {
        let input = """
        \\noindent{\\Large\\textbf{Chapter 15}}

        \\bigskip

        \\noindent{\\LARGE\\bfseries Endogeneity}

        \\bigskip

        Content.
        """
        let first = LaTeXNormalizer.fixManualChapterFormatting(input)
        let second = LaTeXNormalizer.fixManualChapterFormatting(first)
        XCTAssertEqual(first, second, "Should be idempotent")
    }

    func testFixManualChapterFormatting_skipsSectionNumbers() {
        // The title line should NOT match "5.1 Introduction" (section number)
        let input = """
        \\noindent{\\Large\\textbf{Chapter 5}}

        \\bigskip

        \\noindent{\\LARGE\\textbf{An Introduction to Large Sample Asymptotics}}

        \\bigskip

        \\noindent\\textbf{5.1 \\quad Introduction}
        """
        let result = LaTeXNormalizer.fixManualChapterFormatting(input)
        XCTAssertTrue(result.contains("\\chapter{An Introduction to Large Sample Asymptotics}"))
        XCTAssertTrue(result.contains("\\noindent\\textbf{5.1 \\quad Introduction}"),
                      "Section headings should be preserved")
    }

    // MARK: - Duplicate Chapter Removal

    func testRemoveDuplicateChapters_basic() {
        let input = """
        \\chapter{Least Squares Regression}

        Some content from first occurrence.

        \\chapter{Least Squares Regression}

        Real chapter content.
        """
        let result = LaTeXNormalizer.removeDuplicateChapters(input)
        // Should have exactly one \chapter{Least Squares Regression}
        let count = result.components(separatedBy: "\\chapter{Least Squares Regression}").count - 1
        XCTAssertEqual(count, 1, "Should remove duplicate chapter")
        XCTAssertTrue(result.contains("Some content from first occurrence."),
                      "Content between duplicates should be preserved")
        XCTAssertTrue(result.contains("Real chapter content."))
    }

    func testRemoveDuplicateChapters_noDuplicates() {
        let input = """
        \\chapter{Introduction}

        \\chapter{Methodology}

        \\chapter{Results}
        """
        let result = LaTeXNormalizer.removeDuplicateChapters(input)
        XCTAssertEqual(input, result, "No duplicates means no changes")
    }

    func testRemoveDuplicateChapters_nonConsecutiveSameTitleKept() {
        let input = """
        \\chapter{Methods}

        \\chapter{Results}

        \\chapter{Methods}
        """
        let result = LaTeXNormalizer.removeDuplicateChapters(input)
        // Non-consecutive same titles should be kept
        let count = result.components(separatedBy: "\\chapter{Methods}").count - 1
        XCTAssertEqual(count, 2, "Non-consecutive duplicates should be kept")
    }

    func testRemoveDuplicateChapters_idempotent() {
        let input = """
        \\chapter{Least Squares Regression}

        Content A.

        \\chapter{Least Squares Regression}

        Content B.
        """
        let first = LaTeXNormalizer.removeDuplicateChapters(input)
        let second = LaTeXNormalizer.removeDuplicateChapters(first)
        XCTAssertEqual(first, second, "Should be idempotent")
    }

    // MARK: - Paper Size Fix Tests

    func testFixPaperSize_a4ToLetter() {
        let input = "\\documentclass[11pt,a4paper]{book}"
        let result = LaTeXNormalizer.fixPaperSize(input, targetSize: .letter)
        XCTAssertTrue(result.contains("letterpaper"))
        XCTAssertFalse(result.contains("a4paper"))
    }

    func testFixPaperSize_letterToA4() {
        let input = "\\documentclass[11pt,letterpaper]{book}"
        let result = LaTeXNormalizer.fixPaperSize(input, targetSize: .a4)
        XCTAssertTrue(result.contains("a4paper"))
        XCTAssertFalse(result.contains("letterpaper"))
    }

    func testFixPaperSize_alreadyCorrect() {
        let input = "\\documentclass[11pt,letterpaper]{book}"
        let result = LaTeXNormalizer.fixPaperSize(input, targetSize: .letter)
        XCTAssertEqual(input, result, "Should not modify when already correct")
    }

    func testFixPaperSize_idempotent() {
        let input = "\\documentclass[11pt,a4paper]{book}"
        let first = LaTeXNormalizer.fixPaperSize(input, targetSize: .letter)
        let second = LaTeXNormalizer.fixPaperSize(first, targetSize: .letter)
        XCTAssertEqual(first, second, "Should be idempotent")
    }

    func testFixPaperSize_unknown() {
        let input = "\\documentclass[11pt,a4paper]{book}"
        let result = LaTeXNormalizer.fixPaperSize(input, targetSize: .unknown)
        XCTAssertEqual(input, result, "Unknown paper size should not modify")
    }

    // MARK: - Font Package Fix Tests

    func testFixFontPackage_removeLmodern() {
        let input = """
        \\usepackage[utf8]{inputenc}
        \\usepackage[T1]{fontenc}
        \\usepackage{lmodern}
        \\usepackage{amsmath}
        """
        let result = LaTeXNormalizer.fixFontPackage(input, targetFamily: .computerModern)
        XCTAssertFalse(result.contains("lmodern"), "Should remove lmodern for CM fonts")
        XCTAssertTrue(result.contains("fontenc"), "Should keep fontenc")
        XCTAssertTrue(result.contains("amsmath"), "Should keep other packages")
    }

    func testFixFontPackage_keepLmodern() {
        let input = """
        \\usepackage[T1]{fontenc}
        \\usepackage{lmodern}
        """
        let result = LaTeXNormalizer.fixFontPackage(input, targetFamily: .latinModern)
        XCTAssertTrue(result.contains("lmodern"), "Should keep lmodern for LM fonts")
    }

    func testFixFontPackage_addLmodern() {
        let input = """
        \\usepackage[T1]{fontenc}
        \\usepackage{amsmath}
        """
        let result = LaTeXNormalizer.fixFontPackage(input, targetFamily: .latinModern)
        XCTAssertTrue(result.contains("lmodern"), "Should add lmodern for LM target")
    }

    func testFixFontPackage_idempotent() {
        let input = """
        \\usepackage[T1]{fontenc}
        \\usepackage{lmodern}
        \\usepackage{amsmath}
        """
        let first = LaTeXNormalizer.fixFontPackage(input, targetFamily: .computerModern)
        let second = LaTeXNormalizer.fixFontPackage(first, targetFamily: .computerModern)
        XCTAssertEqual(first, second, "Should be idempotent")
    }

    func testFixFontPackage_unknown() {
        let input = "\\usepackage{lmodern}"
        let result = LaTeXNormalizer.fixFontPackage(input, targetFamily: .unknown)
        XCTAssertEqual(input, result, "Unknown font should not modify")
    }

    func testFixFontPackage_timesReplacesLmodern() {
        let input = """
        \\usepackage[T1]{fontenc}
        \\usepackage{lmodern}
        """
        let result = LaTeXNormalizer.fixFontPackage(input, targetFamily: .times)
        XCTAssertFalse(result.contains("lmodern"), "Should remove lmodern")
        XCTAssertTrue(result.contains("newtxtext"), "Should add newtxtext")
    }
}
