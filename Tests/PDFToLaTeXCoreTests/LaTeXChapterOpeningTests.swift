import XCTest
import PDFKit
@testable import PDFToLaTeXCore

/// 章節從偶數頁開始時改用 `openany`（PsychQuant/macdoc#210）。book 預設的 `openright` 讓 `\chapter`
/// 先 `\cleardoublepage`：還原的頁碼是偶數時，LaTeX 補一張空白頁，而它的頁碼與章首頁相同
/// （pdflatex 實測：原書 8 頁、章節起於 1／4／7，openright 輸出 10 頁、第 4 頁出現兩次）。
final class LaTeXChapterOpeningTests: XCTestCase {

    // MARK: - chapterPageCounterValues

    func testChapterCounterValues_readsTheCounterRightAfterEachChapter() {
        let source = """
        \\begin{document}
        \\chapter{One}
        \\setcounter{page}{1}
        \\chapter*{Two}\\setcounter{page}{ 4 }
        \\chapter[Short]{Three}
        % comment
        \\setcounter{page}{7}
        \\setcounter{page}{3}
        \\chapter{Legacy before}
        Text.
        \\chapter{No counter}
        \\setcounter{section}{2}
        \\chapter{Switch}
        \\pagenumbering{roman}
        \\setcounter{page}{2}
        \\chapter{Unparsed}
        \\setcounter{page}{\\value{x}}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.chapterPageCounterValues(source), [1, 4, 7, 2])
    }

    func testChapterCounterValues_ignoresChaptersInVerbatimCommentsAndDefinitions() {
        let source = """
        \\begin{document}
        \\begin{verbatim}
        \\chapter{Fake}
        \\setcounter{page}{2}
        \\end{verbatim}
        % \\chapter{Commented}\\setcounter{page}{4}
        \\newcommand{\\x}{\\chapter{Defined}\\setcounter{page}{6}}
        \\chapter{Real}
        \\setcounter{page}{9}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.chapterPageCounterValues(source), [9])
    }

    func testChapterCounterValues_counterAfterTheNextMarkerIsNotTheChapters() {
        let source = """
        \\begin{document}
        %% === Page 3 ===
        \\chapter{A}
        %% === Page 4 ===
        \\setcounter{page}{4}
        \\chapter{B}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.chapterPageCounterValues(source), [])
    }

    // MARK: - ensureOpenAny

    private func assertOpenAny(
        _ source: String, _ expected: String, _ outcome: ChapterOpeningOutcome,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let first = LaTeXNormalizer.ensureOpenAny(source)
        XCTAssertEqual(first.result, expected, file: file, line: line)
        XCTAssertEqual(first.outcome, outcome, file: file, line: line)
        // 冪等：第二輪不再改動。
        let second = LaTeXNormalizer.ensureOpenAny(first.result)
        XCTAssertEqual(second.result, first.result, file: file, line: line)
        if outcome == .openAnyAdded {
            XCTAssertEqual(second.outcome, .alreadyOpenAny, file: file, line: line)
        }
    }

    func testEnsureOpenAny_addsTheOption() {
        assertOpenAny("\\documentclass{book}\n", "\\documentclass[openany]{book}\n", .openAnyAdded)
        assertOpenAny(
            "\\documentclass[11pt,letterpaper]{book}\n", "\\documentclass[11pt,letterpaper,openany]{book}\n", .openAnyAdded
        )
        assertOpenAny("\\documentclass[]{book}", "\\documentclass[openany]{book}", .openAnyAdded)
        assertOpenAny("\\documentclass[ 11pt , ]{book}", "\\documentclass[ 11pt , openany]{book}", .openAnyAdded)
    }

    /// 選項與參數之間可以有註解與換行（pdflatex 實測這些寫法加上 openany 後都生效）。
    func testEnsureOpenAny_commentsInsideTheOptions() {
        assertOpenAny(
            "\\documentclass[11pt,% size\n]{book}", "\\documentclass[11pt,% size\nopenany]{book}", .openAnyAdded
        )
        assertOpenAny(
            "\\documentclass[11pt % size\n]{book}", "\\documentclass[11pt % size\n,openany]{book}", .openAnyAdded
        )
        assertOpenAny("\\documentclass[11pt]%\n{book}", "\\documentclass[11pt,openany]%\n{book}", .openAnyAdded)
        assertOpenAny("\\documentclass % c\n{book}", "\\documentclass[openany] % c\n{book}", .openAnyAdded)
        assertOpenAny(
            "\\documentclass[11pt,% openany\n]{book}", "\\documentclass[11pt,% openany\nopenany]{book}", .openAnyAdded
        )
    }

    func testEnsureOpenAny_leavesExplicitChoicesAlone() {
        assertOpenAny("\\documentclass[openany]{book}", "\\documentclass[openany]{book}", .alreadyOpenAny)
        assertOpenAny("\\documentclass[11pt, openany ]{book}", "\\documentclass[11pt, openany ]{book}", .alreadyOpenAny)
        assertOpenAny("\\documentclass[openright]{book}", "\\documentclass[openright]{book}", .explicitOpenRightKept)
        assertOpenAny("\\documentclass[oneside]{book}", "\\documentclass[oneside]{book}", .oneSide)
    }

    func testEnsureOpenAny_onlyTheExecutedBookClass() {
        assertOpenAny("\\documentclass{report}", "\\documentclass{report}", .notBookClass)
        assertOpenAny("\\documentclass[11pt]{article}", "\\documentclass[11pt]{article}", .notBookClass)
        assertOpenAny("\\documentclass{memoir}", "\\documentclass{memoir}", .notBookClass)
        assertOpenAny("No class here.", "No class here.", .notBookClass)
        assertOpenAny(
            "% \\documentclass{book}\n\\documentclass{report}", "% \\documentclass{book}\n\\documentclass{report}",
            .notBookClass
        )
        assertOpenAny(
            "\\newcommand{\\cls}{\\documentclass{report}}\n\\documentclass{book}",
            "\\newcommand{\\cls}{\\documentclass{report}}\n\\documentclass[openany]{book}",
            .openAnyAdded
        )
    }

    // MARK: - normalizeProject

    private func makeProject(main: String, preamble: String? = nil) throws -> (dir: URL, main: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let preamble {
            try preamble.write(to: dir.appendingPathComponent("preamble.tex"), atomically: true, encoding: .utf8)
        }
        let mainURL = dir.appendingPathComponent("accumulated.tex")
        try main.write(to: mainURL, atomically: true, encoding: .utf8)
        return (dir, mainURL)
    }

    private static let evenChapterBody = """
    \\begin{document}
    %% === Page 1 ===
    \\chapter{One}
    Page one text.\\newpage
    %% === Page 2 ===
    Page two text.\\newpage
    %% === Page 3 ===
    Page three text.
    %% === Page 4 ===
    \\chapter{Two}
    Page four text.\\newpage
    %% === Page 5 ===
    Page five text.\\newpage
    %% === Page 6 ===
    Page six text.
    %% === Page 7 ===
    \\chapter{Three}
    Page seven text.\\newpage
    %% === Page 8 ===
    Page eight text.
    \\clearpage
    \\tableofcontents
    \\end{document}
    """

    func testNormalizeProject_chapterOnAnEvenPageAddsOpenAnyAndIsIdempotent() throws {
        let (dir, mainURL) = try makeProject(main: "\\documentclass{book}\n\\usepackage{hyperref}\n" + Self.evenChapterBody)
        defer { try? FileManager.default.removeItem(at: dir) }

        let normalizer = LaTeXNormalizer()
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertEqual(report1.chapterOpening, .openAnyAdded)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(first.hasPrefix("\\documentclass[openany]{book}\n"))
        XCTAssertTrue(first.contains("\\chapter{Two}\n\\setcounter{page}{4}\n"))

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertEqual(report2.chapterOpening, .alreadyOpenAny)
        XCTAssertEqual(try String(contentsOf: mainURL, encoding: .utf8), first)
    }

    func testNormalizeProject_onlyOddChapterPagesLeaveTheClassAlone() throws {
        let body = Self.evenChapterBody
            .replacingOccurrences(of: "%% === Page 4 ===\n\\chapter{Two}", with: "%% === Page 4 ===\nMore three.")
        let (dir, mainURL) = try makeProject(main: "\\documentclass{book}\n" + body)
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = try LaTeXNormalizer().normalizeProject(mainTexURL: mainURL)
        XCTAssertEqual(report.chapterOpening, .notNeeded)
        XCTAssertTrue(try String(contentsOf: mainURL, encoding: .utf8).hasPrefix("\\documentclass{book}\n"))
    }

    /// 外部 preamble：openany 加在 preamble.tex 的 `\documentclass`（article 先被步驟 2 改成 book）。
    func testNormalizeProject_openAnyGoesIntoTheExternalPreamble() throws {
        let (dir, mainURL) = try makeProject(
            main: "\\input{preamble}\n" + Self.evenChapterBody,
            preamble: "\\documentclass[11pt,letterpaper]{article}\n\\usepackage{amsmath}\n"
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertEqual(report1.chapterOpening, .openAnyAdded)
        XCTAssertTrue(report1.preambleFileChanged)
        let preambleURL = dir.appendingPathComponent("preamble.tex")
        let preamble = try String(contentsOf: preambleURL, encoding: .utf8)
        XCTAssertTrue(preamble.hasPrefix("\\documentclass[11pt,letterpaper,openany]{book}\n"))

        // markers 已移除：第二輪仍從章節後的 counter 認得偶數頁，不再改動。
        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertFalse(report2.preambleFileChanged)
        XCTAssertEqual(report2.chapterOpening, .alreadyOpenAny)
        XCTAssertEqual(try String(contentsOf: preambleURL, encoding: .utf8), preamble)
    }

    func testNormalizeProject_explicitOpenRightIsKeptAndReported() throws {
        let (dir, mainURL) = try makeProject(main: "\\documentclass[openright]{book}\n" + Self.evenChapterBody)
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = try LaTeXNormalizer().normalizeProject(mainTexURL: mainURL)
        XCTAssertEqual(report.chapterOpening, .explicitOpenRightKept)
        XCTAssertTrue(try String(contentsOf: mainURL, encoding: .utf8).hasPrefix("\\documentclass[openright]{book}\n"))
    }

    // MARK: - pdflatex (gated)

    /// 實際編譯（需要 `RUN_PDFLATEX=1` 與 pdflatex）：normalize 之後的輸出頁數、每頁頁碼標籤
    /// （hyperref 寫入的 /PageLabels）與目錄，都與原書一致；只拿掉 openany 則出現重複的第 4 頁。
    func testPdflatex_openAnyRemovesTheDuplicatedPageNumber() throws {
        guard ProcessInfo.processInfo.environment["RUN_PDFLATEX"] == "1" else {
            throw XCTSkip("設定 RUN_PDFLATEX=1 才實際編譯")
        }
        let pdflatex = ProcessInfo.processInfo.environment["PDFLATEX"] ?? "/Library/TeX/texbin/pdflatex"
        guard FileManager.default.isExecutableFile(atPath: pdflatex) else { throw XCTSkip("找不到 \(pdflatex)") }

        let (dir, mainURL) = try makeProject(main: "\\documentclass{book}\n\\usepackage{hyperref}\n" + Self.evenChapterBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try LaTeXNormalizer().normalizeProject(mainTexURL: mainURL)
        let normalized = try String(contentsOf: mainURL, encoding: .utf8)
        let withoutOpenAny = normalized.replacingOccurrences(of: "[openany]{book}", with: "{book}")
        XCTAssertNotEqual(withoutOpenAny, normalized)

        func compile(_ source: String, name: String) throws -> (labels: [String], toc: String) {
            let tex = dir.appendingPathComponent("\(name).tex")
            try source.write(to: tex, atomically: true, encoding: .utf8)
            for _ in 0..<2 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: pdflatex)
                process.arguments = ["-interaction=nonstopmode", "-halt-on-error", tex.lastPathComponent]
                process.currentDirectoryURL = dir
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, name)
            }
            let pdf = try XCTUnwrap(PDFDocument(url: dir.appendingPathComponent("\(name).pdf")))
            let labels = (0..<pdf.pageCount).map { pdf.page(at: $0)?.label ?? "" }
            let toc = try String(contentsOf: dir.appendingPathComponent("\(name).toc"), encoding: .utf8)
            return (labels, toc)
        }

        let after = try compile(normalized, name: "after")
        XCTAssertEqual(after.labels, ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        let before = try compile(withoutOpenAny, name: "before")
        XCTAssertEqual(before.labels, ["1", "2", "3", "4", "4", "5", "6", "7", "8", "9"])
        for toc in [after.toc, before.toc] {
            XCTAssertTrue(toc.contains("{\\numberline {1}One}{1}"))
            XCTAssertTrue(toc.contains("{\\numberline {2}Two}{4}"))
            XCTAssertTrue(toc.contains("{\\numberline {3}Three}{7}"))
        }
    }
}
