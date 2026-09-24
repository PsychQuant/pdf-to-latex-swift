import XCTest
@testable import PDFToLaTeXCore

/// 頁碼還原（PsychQuant/macdoc#9）：`%% === Page N ===` → `\setcounter{page}{N}`。
final class LaTeXPageCounterTests: XCTestCase {

    // MARK: - First marker

    func testFirstMarker_setsCounterRightAfterMarker() {
        let input = """
        \\begin{document}
        %% === Page 5 ===
        Preface text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 5 ===
        \\setcounter{page}{5}
        Preface text.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(input), expected)
    }

    func testFirstMarker_ignoresMarkerLikeLinesInPreamble() {
        let input = """
        %% === Page 99 ===
        \\documentclass{book}
        \\begin{document}
        %% === Page 3 ===
        Opening text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertFalse(result.contains("\\setcounter{page}{99}"))
        XCTAssertTrue(result.contains("%% === Page 3 ===\n\\setcounter{page}{3}\nOpening text."))
    }

    func testFirstMarkerFollowedByChapter_noRedundantCounter() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        \\chapter{Intro}
        Intro text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 1 ===
        \\chapter{Intro}
        \\setcounter{page}{1}
        Intro text.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(input), expected)
    }

    // MARK: - Chapter boundaries

    /// `\chapter` 會先 `\clearpage`：counter 若放在 `\chapter` 之前，會落在前一頁、
    /// 章首頁變成 N+1。所以必須放在 `\chapter{...}` 之後。
    func testChapterMarker_counterGoesAfterChapterLine() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        Title page.
        %% === Page 17 ===
        Tail of the previous part.
        %% === Page 18 ===
        \\chapter{Two}
        Chapter text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 1 ===
        \\setcounter{page}{1}
        Title page.
        %% === Page 17 ===
        Tail of the previous part.
        %% === Page 18 ===
        \\chapter{Two}
        \\setcounter{page}{18}
        Chapter text.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(input), expected)
    }

    func testChapterMarker_usesNearestPrecedingMarker() {
        let input = """
        \\begin{document}
        %% === Page 30 ===
        Some text.
        %% === Page 31 ===
        More text.
        \\chapter{Three}
        Body.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("\\chapter{Three}\n\\setcounter{page}{31}\nBody."))
    }

    func testChapterStarAndShortTitleAreChapterBoundaries() {
        let input = """
        \\begin{document}
        %% === Page 2 ===
        \\chapter*{Preface}
        Preface text.
        %% === Page 7 ===
        \\chapter[Short]{A Long Title}
        Body.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("\\chapter*{Preface}\n\\setcounter{page}{2}\n"))
        XCTAssertTrue(result.contains("\\chapter[Short]{A Long Title}\n\\setcounter{page}{7}\n"))
    }

    func testChapterLikeCommandIsNotAChapterBoundary() {
        let input = """
        \\begin{document}
        %% === Page 4 ===
        \\chapter{Four}
        \\chapterauthor{Someone}
        Body.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 1)
        XCTAssertTrue(result.contains("\\chapter{Four}\n\\setcounter{page}{4}\n\\chapterauthor{Someone}"))
    }

    func testMultiLineChapterTitle_counterGoesAfterClosingBrace() {
        let input = """
        \\begin{document}
        %% === Page 40 ===
        \\chapter{A Very Long Title
        That Wraps}
        Body.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("That Wraps}\n\\setcounter{page}{40}\nBody."))
        XCTAssertFalse(result.contains("Title\n\\setcounter"))
    }

    func testChapterWithoutPrecedingMarker_isLeftAlone() {
        let input = """
        \\begin{document}
        \\chapter{Orphan}
        Text.
        %% === Page 3 ===
        More.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertFalse(result.contains("\\chapter{Orphan}\n\\setcounter"))
    }

    func testCommentedOutChapterIsIgnored() {
        let input = """
        \\begin{document}
        %% === Page 6 ===
        Text.
        % \\chapter{Not really}
        More.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 1)
    }

    // MARK: - Idempotency & existing counters

    func testIdempotent() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        Title page.
        %% === Page 18 ===
        \\chapter{Two}
        Chapter text.
        %% === Page 40 ===
        \\chapter{Three}
        More text.
        \\end{document}
        """
        let first = LaTeXNormalizer.insertPageCounters(input)
        let second = LaTeXNormalizer.insertPageCounters(first)
        XCTAssertNotEqual(first, input)
        XCTAssertEqual(first, second)
    }

    func testExistingAuthoredCounterIsRespected() {
        let after = """
        \\begin{document}
        %% === Page 18 ===
        \\chapter{Two}
        \\setcounter{page}{99}
        Text.
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(after), after)

        let before = """
        \\begin{document}
        %% === Page 18 ===
        \\setcounter{page}{18}
        \\chapter{Two}
        Text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(before)
        XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 1)
    }

    func testNoMarkers_unchanged() {
        let input = "\\begin{document}\n\\chapter{Intro}\nText.\n\\end{document}"
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(input), input)
    }

    // MARK: - Roman numerals (conservative contract)

    /// `\frontmatter` … `\mainmatter` 是可觀察的明確結構：front matter 內不寫
    /// 阿拉伯頁碼（marker 是實體頁序，不是羅馬頁標籤），`\mainmatter` 重設 counter 後
    /// 再還原原書頁碼。切換本身由 `\frontmatter`/`\mainmatter` 完成，不重複輸出。
    func testFrontMatterMainMatter_switching() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        \\frontmatter
        \\chapter*{Preface}
        Preface text.
        %% === Page 9 ===
        \\mainmatter
        Opening text of the main matter.
        %% === Page 12 ===
        \\chapter{Intro}
        Intro text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 1 ===
        \\frontmatter
        \\chapter*{Preface}
        Preface text.
        %% === Page 9 ===
        \\mainmatter
        \\setcounter{page}{9}
        Opening text of the main matter.
        %% === Page 12 ===
        \\chapter{Intro}
        \\setcounter{page}{12}
        Intro text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(result), result)
    }

    func testMainMatterFollowedByChapter_noRedundantCounter() {
        let input = """
        \\begin{document}
        \\frontmatter
        %% === Page 3 ===
        Preface text.
        %% === Page 9 ===
        \\mainmatter
        \\chapter{Intro}
        Intro text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 1)
        XCTAssertTrue(result.contains("\\mainmatter\n\\chapter{Intro}\n\\setcounter{page}{9}\n"))
    }

    func testExplicitPagenumberingRomanRegion() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        \\pagenumbering{roman}
        Preface text.
        %% === Page 4 ===
        \\chapter*{Contents}
        %% === Page 7 ===
        \\pagenumbering{arabic}
        \\chapter{Intro}
        Intro text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 1)
        XCTAssertTrue(result.contains("\\chapter{Intro}\n\\setcounter{page}{7}\n"))
        XCTAssertFalse(result.contains("\\chapter*{Contents}\n\\setcounter"))
    }

    func testUnmanagedNumberingStyleGetsNoCounters() {
        let input = """
        \\begin{document}
        %% === Page 50 ===
        \\pagenumbering{alph}
        \\chapter{Appendix}
        Text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertFalse(result.contains("\\setcounter{page}"))
    }

    /// 負向契約：頁碼數字小、位在第一章之前、甚至有 `\chapter*{Preface}` 與
    /// `\tableofcontents`，都不構成明確 front-matter 結構 —— 不得推測 Roman。
    func testSmallPageNumbersAloneDoNotTriggerRoman() {
        let input = """
        \\begin{document}
        %% === Page 2 ===
        \\chapter*{Preface}
        Preface text.
        %% === Page 4 ===
        \\tableofcontents
        %% === Page 9 ===
        \\chapter{Introduction}
        Body.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 2 ===
        \\chapter*{Preface}
        \\setcounter{page}{2}
        Preface text.
        %% === Page 4 ===
        \\tableofcontents
        %% === Page 9 ===
        \\chapter{Introduction}
        \\setcounter{page}{9}
        Body.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result, expected)
        XCTAssertFalse(result.contains("\\pagenumbering"))
        XCTAssertFalse(result.lowercased().contains("roman"))
    }

    // MARK: - normalizeProject integration

    private func makeProject(main: String) throws -> (dir: URL, main: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mainURL = dir.appendingPathComponent("accumulated.tex")
        try main.write(to: mainURL, atomically: true, encoding: .utf8)
        return (dir, mainURL)
    }

    private let projectMain = """
    \\documentclass{book}
    \\begin{document}

    %% === Page 1 ===
    Title page of the book.

    %% === Page 17 ===
    Closing remarks of the previous part.

    %% === Page 18 ===
    \\chapter{Linear Regression}
    Regression starts here.

    %% === Page 42 ===
    \\chapter{Asymptotics}
    Asymptotics starts here.

    \\end{document}
    """

    func testNormalizeProject_insertsCountersAndIsIdempotent() throws {
        let (dir, mainURL) = try makeProject(main: projectMain)
        defer { try? FileManager.default.removeItem(at: dir) }

        let normalizer = LaTeXNormalizer()
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertTrue(report1.mainFileChanged)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(first.contains("%% === Page 1 ===\n\\setcounter{page}{1}\nTitle page"))
        XCTAssertTrue(first.contains("\\chapter{Linear Regression}\n\\setcounter{page}{18}\n"))
        XCTAssertTrue(first.contains("\\chapter{Asymptotics}\n\\setcounter{page}{42}\n"))

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        let second = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertEqual(first, second)
    }

    func testNormalizeProject_countersSurviveMarkerStripping() throws {
        let (dir, mainURL) = try makeProject(main: projectMain)
        defer { try? FileManager.default.removeItem(at: dir) }

        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        _ = try normalizer.normalizeProject(mainTexURL: mainURL)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertFalse(first.contains("=== Page"))
        XCTAssertTrue(first.contains("\\setcounter{page}{1}\nTitle page"))
        XCTAssertTrue(first.contains("\\chapter{Linear Regression}\n\\setcounter{page}{18}\n"))
        XCTAssertTrue(first.contains("\\chapter{Asymptotics}\n\\setcounter{page}{42}\n"))

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertEqual(try String(contentsOf: mainURL, encoding: .utf8), first)
    }
}
