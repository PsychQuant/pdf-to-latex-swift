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

    func testExistingCounterAfterChapterIsRespected() {
        let after = """
        \\begin{document}
        %% === Page 18 ===
        \\chapter{Two}
        \\setcounter{page}{99}
        Text.
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(after)
        XCTAssertEqual(report.result, after)
        XCTAssertEqual(report.notes, [])
    }

    /// 舊版實作把 counter 放在 `\chapter` 之前（會被記到前一頁）。值與 marker 相同時視為
    /// 舊版產物：移到 `\chapter{...}` 之後。
    func testLegacyCounterBeforeChapterWithSameValueIsMovedAfterChapter() {
        let input = """
        \\begin{document}
        %% === Page 17 ===
        Previous text.
        %% === Page 18 ===
        \\setcounter{page}{18}
        \\chapter{Two}
        Chapter text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 17 ===
        \\setcounter{page}{17}
        Previous text.
        %% === Page 18 ===
        \\chapter{Two}
        \\setcounter{page}{18}
        Chapter text.
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(input)
        XCTAssertEqual(report.result, expected)
        XCTAssertTrue(report.notes.contains(PageCounterNote(line: 6, kind: .legacyCounterMoved(page: 18))))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(report.result), report.result)
    }

    /// 值與 marker 不同的前置 counter：原樣保留並回報衝突，不插入。
    func testConflictingCounterBeforeChapterIsLeftAndReported() {
        let input = """
        \\begin{document}
        %% === Page 17 ===
        Previous text.
        %% === Page 18 ===
        \\setcounter{page}{5}
        \\chapter{Two}
        Chapter text.
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(input)
        XCTAssertTrue(report.result.contains("\\setcounter{page}{5}\n\\chapter{Two}\nChapter text."))
        XCTAssertFalse(report.result.contains("{18}"))
        XCTAssertTrue(report.notes.contains(
            PageCounterNote(line: 6, kind: .conflictingCounterBeforeChapter(existing: 5, expected: 18))
        ))
    }

    /// 緊接在上一章之後的 counter 屬於上一章，不是下一章的舊版前置 counter。
    func testCounterAfterPreviousChapterIsNotTreatedAsLegacy() {
        let input = """
        \\begin{document}
        %% === Page 7 ===
        \\chapter{A}
        \\setcounter{page}{7}
        \\chapter{B}
        Text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 7 ===
        \\chapter{A}
        \\setcounter{page}{7}
        \\chapter{B}
        \\setcounter{page}{7}
        Text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(result), result)
    }

    func testCRLFLineEndingsAreHandledLikeLF() {
        let input = [
            "\\begin{document}",
            "%% === Page 1 ===",
            "",
            "\\chapter{One}",
            "Text.",
            "%% === Page 18 ===",
            "",
            "\\setcounter{page}{18}",
            "\\chapter{Two}",
            "Chapter text.",
            "\\end{document}",
        ].joined(separator: "\r\n")
        let report = LaTeXNormalizer.applyPageCounters(input)
        // 空行（只有 \r）不算內容：第一個 marker 讓給緊接的 \chapter{One}，不產生多餘 counter。
        XCTAssertEqual(report.notes.map(\.kind), [.counterInserted(page: 1), .legacyCounterMoved(page: 18)])
        XCTAssertEqual(report.notes.first?.line, 4)
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(report.result).notes, [])

        // 輸出位元組：插入的行沿用檔案的 CRLF，不混用換行。
        let expected = [
            "\\begin{document}",
            "%% === Page 1 ===",
            "",
            "\\chapter{One}",
            "\\setcounter{page}{1}",
            "Text.",
            "%% === Page 18 ===",
            "",
            "\\chapter{Two}",
            "\\setcounter{page}{18}",
            "Chapter text.",
            "\\end{document}",
        ].joined(separator: "\r\n")
        XCTAssertEqual(report.result, expected)
        XCTAssertFalse(report.result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(report.result), report.result)
    }

    // MARK: - Anchor end (switch arguments, same-line \end{document})

    func testPagenumberingArgumentOnNextLineOrAfterComment() {
        for separator in ["\n", "% note\n", "   % note\n   "] {
            let input = """
            \\begin{document}
            %% === Page 2 ===
            \\frontmatter
            Preface.
            %% === Page 9 ===
            \\pagenumbering\(separator){arabic}
            Text.
            \\end{document}
            """
            let result = LaTeXNormalizer.insertPageCounters(input)
            XCTAssertEqual(result, input.replacingOccurrences(
                of: "{arabic}\nText.", with: "{arabic}\n\\setcounter{page}{9}\nText."
            ), separator.debugDescription)
            XCTAssertEqual(LaTeXNormalizer.insertPageCounters(result), result, separator.debugDescription)
        }
    }

    func testAnchorSharingALineWithEndDocumentGetsCounterBeforeIt() {
        let chapter = """
        \\begin{document}
        %% === Page 1 ===
        Title.
        %% === Page 5 ===
        \\chapter{A}\\end{document}
        """
        let chapterResult = LaTeXNormalizer.insertPageCounters(chapter)
        XCTAssertTrue(chapterResult.hasSuffix("\\chapter{A}\n\\setcounter{page}{5}\n\\end{document}"))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(chapterResult), chapterResult)

        let mainmatter = """
        \\begin{document}
        %% === Page 1 ===
        \\frontmatter
        Preface.
        %% === Page 7 ===
        \\mainmatter\\end{document}
        """
        let mainResult = LaTeXNormalizer.insertPageCounters(mainmatter)
        XCTAssertTrue(mainResult.hasSuffix("\\mainmatter\n\\setcounter{page}{7}\n\\end{document}"))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(mainResult), mainResult)
    }

    // MARK: - Several anchors on one line (byte-level idempotency)

    func testTwoChaptersOnOneLine() {
        let input = "\\begin{document}\n%% === Page 5 ===\n\\chapter{A}\\chapter{B}\nText.\n\\end{document}"
        let expected = "\\begin{document}\n%% === Page 5 ===\n\\chapter{A}\n\\setcounter{page}{5}\n\\chapter{B}\n\\setcounter{page}{5}\nText.\n\\end{document}"
        let first = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(first, expected)
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(first), first)
    }

    func testThreeChaptersOnOneLine() {
        let input = "\\begin{document}\n%% === Page 5 ===\n\\chapter{A}\\chapter{B} \\chapter{C}\nText.\n\\end{document}"
        let first = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(first, "\\begin{document}\n%% === Page 5 ===\n\\chapter{A}\n\\setcounter{page}{5}\n\\chapter{B}\n\\setcounter{page}{5}\n \\chapter{C}\n\\setcounter{page}{5}\nText.\n\\end{document}")
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(first), first)
    }

    func testChapterAndMainmatterOnOneLine() {
        let chapterFirst = "\\begin{document}\n%% === Page 5 ===\n\\chapter{A}\\mainmatter\nText.\n\\end{document}"
        let first = LaTeXNormalizer.insertPageCounters(chapterFirst)
        XCTAssertEqual(first, "\\begin{document}\n%% === Page 5 ===\n\\chapter{A}\n\\setcounter{page}{5}\n\\mainmatter\n\\setcounter{page}{5}\nText.\n\\end{document}")
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(first), first)

        let mainmatterFirst = """
        \\begin{document}
        %% === Page 2 ===
        \\frontmatter
        Preface.
        %% === Page 9 ===
        \\mainmatter\\chapter{A}
        Text.
        \\end{document}
        """
        let second = LaTeXNormalizer.insertPageCounters(mainmatterFirst)
        XCTAssertEqual(second, mainmatterFirst.replacingOccurrences(
            of: "\\mainmatter\\chapter{A}\n", with: "\\mainmatter\\chapter{A}\n\\setcounter{page}{9}\n"
        ))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(second), second)
    }

    /// fuzz 找到的案例（LaTeXIdempotencyFuzzTests case 332）：章節 C 之後隔著幾個 marker 的 counter
    /// 其實是下一章 E 的舊版 counter。「已有 counter」的判定不可跨過下一個 page marker，否則第一輪把它當成
    /// C 的、第二輪（counter 已移到 E 之後）又替 C 插入一個。
    func testCounterOnALaterPageDoesNotCountAsTheAnchorsOwn() {
        let input = """
        \\begin{document}
        %% === Page 6 ===
        %% === Page 8 ===
        \\setcounter{page}{8}\\chapter[S]{C} % trailing
        %% === Page 9 ===
        %% === Page 10 ===
        \\setcounter{page}{10}
        \\chapter{E}
        \\end{document}
        """
        let first = LaTeXNormalizer.applyPageCounters(input)
        XCTAssertTrue(first.result.contains("\\chapter[S]{C} % trailing\n\\setcounter{page}{8}\n"))
        XCTAssertTrue(first.result.contains("\\chapter{E}\n\\setcounter{page}{10}\n"))
        let second = LaTeXNormalizer.applyPageCounters(first.result)
        XCTAssertEqual(second.result, first.result)
        XCTAssertEqual(second.notes, [])
    }

    /// 下一個 page marker 之後的 counter 屬於那一頁，不是前面章節的：章節仍要有自己的 counter，
    /// 否則章首頁的頁碼要等到下一頁的 counter 才被設定。
    func testCounterAfterTheNextMarkerBelongsToThatPage() {
        let input = """
        \\begin{document}
        %% === Page 7 ===
        Intro.
        %% === Page 8 ===
        \\chapter{A}
        %% === Page 9 ===
        \\setcounter{page}{9}
        More text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("\\chapter{A}\n\\setcounter{page}{8}\n%% === Page 9 ===\n\\setcounter{page}{9}\nMore"))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(result), result)
    }

    /// fuzz 找到的案例（case 3719／2043）：兩章之間隔著空行或註解行的舊版 counter 屬於下一章（會被移走），
    /// 不能同時被上一章當成「已有的 counter」。
    func testLegacyCounterOfTheNextChapterIsNotThePreviousChaptersCounter() {
        for separator in ["  ", "% plain comment"] {
            let input = """
            \\begin{document}
            %% === Page 3 ===
            \\setcounter{page}{3}
            \\chapter{E}
            \(separator)
             \\setcounter{page}{3}
            \\chapter{F}
            \\end{document}
            """
            let expected = """
            \\begin{document}
            %% === Page 3 ===
            \\chapter{E}
            \\setcounter{page}{3}
            \(separator)
            \\chapter{F}
             \\setcounter{page}{3}
            \\end{document}
            """
            let first = LaTeXNormalizer.applyPageCounters(input)
            XCTAssertEqual(first.result, expected, separator)
            XCTAssertEqual(first.notes.map(\.kind), [.legacyCounterMoved(page: 3), .legacyCounterMoved(page: 3)], separator)
            let second = LaTeXNormalizer.applyPageCounters(first.result)
            XCTAssertEqual(second.result, first.result, separator)
            XCTAssertEqual(second.notes, [], separator)
        }
    }

    /// fuzz 找到的案例（case 926）：同一行兩個章節共用「前一行」，舊版 counter 只屬於行首那一章；
    /// 否則兩章各產生一組刪除＋移動，編輯重疊而弄壞原文。
    func testLegacyCounterIsOwnedOnlyByTheFirstChapterOnTheLine() {
        let input = "\\begin{document}\n%% === Page 5 ===\n\\setcounter{page}{5}\n\\chapter{E}\\chapter{A}\\end{document}"
        let first = LaTeXNormalizer.applyPageCounters(input)
        XCTAssertEqual(first.result, "\\begin{document}\n%% === Page 5 ===\n\\chapter{E}\n\\setcounter{page}{5}\n\\chapter{A}\n\\setcounter{page}{5}\n\\end{document}")
        XCTAssertEqual(first.notes.map(\.kind), [.legacyCounterMoved(page: 5), .counterInserted(page: 5)])
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(first.result).result, first.result)
    }

    /// comment 套件的 `\end{comment}` 必須獨佔一行：行中的 `\end{comment}` 之後的假 marker 與章節仍在註解內。
    func testInlineEndCommentDoesNotEndTheCommentEnvironment() {
        let input = """
        \\begin{document}
        %% === Page 12 ===
        Intro.
        \\begin{comment}
        Example: \\end{comment}
        %% === Page 99 ===
        \\chapter{Fake}
        \\end{comment}
        \\chapter{Real}
        Body.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("Example: \\end{comment}\n%% === Page 99 ===\n\\chapter{Fake}\n\\end{comment}\n"))
        XCTAssertTrue(result.contains("\\chapter{Real}\n\\setcounter{page}{12}\nBody."))
        XCTAssertFalse(result.contains("{99}"))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(result), result)
    }

    // MARK: - Marker stripping (whole lines only)

    func testStrippingRemovesOnlyWholeMarkerLinesAndNeverJoinsLines() {
        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        let untouched = [
            "% example: %% === Page 12 ===\n\\includegraphics{figures/a.png}",
            "%% === Page 12 === explanation\nText.",
            "Text %% === Page 12 ===\nMore.",
        ]
        for source in untouched {
            XCTAssertEqual(normalizer.normalize(source), source, source)
        }
        XCTAssertEqual(normalizer.normalize("A\n  %% === Page 3 ===  \nB"), "A\nB")
        XCTAssertEqual(normalizer.normalize("A\n%% === Page 2 ===\n\nB"), "A\n\nB")
        XCTAssertEqual(normalizer.normalize("A\r\n%% === Page 2 ===\r\nB"), "A\r\nB")
    }

    func testUnterminatedVerbatimHidesEverythingAfterIt() {
        let input = """
        \\begin{document}
        %% === Page 2 ===
        Text.
        \\begin{verbatim}
        %% === Page 9 ===
        \\chapter{Inside}
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result, input.replacingOccurrences(
            of: "%% === Page 2 ===\n", with: "%% === Page 2 ===\n\\setcounter{page}{2}\n"
        ))
    }

    func testReportListsInsertedCounters() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        Title page.
        %% === Page 18 ===
        \\chapter{Two}
        Text.
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(input)
        XCTAssertEqual(report.notes, [
            PageCounterNote(line: 2, kind: .counterInserted(page: 1)),
            PageCounterNote(line: 5, kind: .counterInserted(page: 18)),
        ])
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(report.result).notes, [])
    }

    // MARK: - Consecutive anchors & document boundaries

    func testConsecutiveChapters() {
        let input = """
        \\begin{document}
        %% === Page 30 ===
        \\chapter{A}
        \\chapter{B}
        Text.
        \\end{document}
        """
        let expected = """
        \\begin{document}
        %% === Page 30 ===
        \\chapter{A}
        \\setcounter{page}{30}
        \\chapter{B}
        \\setcounter{page}{30}
        Text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(result), result)
    }

    func testConsecutiveSwitches() {
        let frontThenMain = """
        \\begin{document}
        %% === Page 1 ===
        \\frontmatter
        \\mainmatter
        Main text.
        \\end{document}
        """
        let first = LaTeXNormalizer.insertPageCounters(frontThenMain)
        XCTAssertEqual(first, frontThenMain.replacingOccurrences(
            of: "\\mainmatter\n", with: "\\mainmatter\n\\setcounter{page}{1}\n"
        ))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(first), first)

        let mainThenArabic = """
        \\begin{document}
        %% === Page 8 ===
        \\mainmatter
        \\pagenumbering{arabic}
        Text.
        \\end{document}
        """
        let second = LaTeXNormalizer.insertPageCounters(mainThenArabic)
        XCTAssertEqual(second, mainThenArabic.replacingOccurrences(
            of: "\\pagenumbering{arabic}\n", with: "\\pagenumbering{arabic}\n\\setcounter{page}{8}\n"
        ))
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(second), second)
    }

    func testMarkersAfterEndDocumentAreIgnored() {
        let onlyAfter = """
        \\begin{document}
        Text.
        \\end{document}
        %% === Page 7 ===
        \\chapter{After}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(onlyAfter), onlyAfter)

        let mixed = """
        \\begin{document}
        %% === Page 3 ===
        Text.
        \\end{document}
        %% === Page 7 ===
        \\chapter{After}
        """
        let result = LaTeXNormalizer.insertPageCounters(mixed)
        XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 1)
        XCTAssertTrue(result.contains("%% === Page 3 ===\n\\setcounter{page}{3}\n"))
        XCTAssertTrue(result.hasSuffix("%% === Page 7 ===\n\\chapter{After}"))
    }

    // MARK: - Multi-line chapter commands

    func testChapterTitleOnFollowingLine() {
        let input = """
        \\begin{document}
        %% === Page 20 ===
        \\chapter
        {Title On The Next Line}
        Body.
        %% === Page 21 ===
        \\chapter[Short]%
        % a comment line between the parts
        {Long Title}
        More.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("{Title On The Next Line}\n\\setcounter{page}{20}\nBody."))
        XCTAssertTrue(result.contains("{Long Title}\n\\setcounter{page}{21}\nMore."))
        XCTAssertFalse(result.contains("\\chapter\n\\setcounter"))
    }

    func testVeryLongChapterTitleHasNoLineCap() {
        let titleLines = (1...25).map { "word\($0)" }.joined(separator: "\n")
        let input = "\\begin{document}\n%% === Page 50 ===\n\\chapter{\(titleLines)}\nBody.\n\\end{document}"
        let result = LaTeXNormalizer.insertPageCounters(input)
        XCTAssertTrue(result.contains("word25}\n\\setcounter{page}{50}\nBody."))
    }

    /// 找不到章名閉合大括號：整份原始碼不動，並回報。
    func testUnterminatedChapterTitleLeavesSourceUnchangedAndIsReported() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        Text.
        %% === Page 2 ===
        \\chapter{Broken
        Body.
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(input)
        XCTAssertEqual(report.result, input)
        XCTAssertEqual(report.notes, [PageCounterNote(line: 5, kind: .chapterTitleNotFound)])
    }

    // MARK: - Inactive regions (verbatim / \verb / comments / definitions)

    private static let verbatimEnvironments: [(begin: String, end: String)] = [
        ("\\begin{verbatim}", "\\end{verbatim}"),
        ("\\begin{verbatim*}", "\\end{verbatim*}"),
        ("\\begin{Verbatim}", "\\end{Verbatim}"),
        ("\\begin{lstlisting}[language=TeX]", "\\end{lstlisting}"),
        ("\\begin{minted}{latex}", "\\end{minted}"),
        ("\\begin{comment}", "\\end{comment}"),
    ]

    func testVerbatimLikeRegionsAreInvisible() {
        for env in Self.verbatimEnvironments {
            let block = """
            \(env.begin)
            %% === Page 99 ===
            \\chapter{Fake}
            \\frontmatter
            \\includegraphics{figures/p099-fig01.png}
            \(env.end)
            """
            let input = """
            \\begin{document}
            \(block)
            %% === Page 12 ===
            Intro text.
            \(block)
            \\chapter{Real}
            Body.
            %% === Page 15 ===
            \\chapter{Next}
            More.
            \\end{document}
            """
            let result = LaTeXNormalizer.insertPageCounters(input)
            XCTAssertEqual(result.components(separatedBy: block).count - 1, 2, env.begin)
            XCTAssertTrue(result.contains("%% === Page 12 ===\n\\setcounter{page}{12}\nIntro text."), env.begin)
            XCTAssertTrue(result.contains("\\chapter{Real}\n\\setcounter{page}{12}\n"), env.begin)
            XCTAssertTrue(result.contains("\\chapter{Next}\n\\setcounter{page}{15}\n"), env.begin)
            XCTAssertFalse(result.contains("{99}"), env.begin)
            XCTAssertEqual(result.components(separatedBy: "\\setcounter{page}").count - 1, 3, env.begin)
        }
    }

    func testInlineVerbIsInvisibleAndPercentInsideVerbIsNotAComment() {
        let fakeSwitch = """
        \\begin{document}
        %% === Page 3 ===
        \\frontmatter
        \\verb|\\mainmatter| and \\verb*+\\pagenumbering{arabic}+
        Preface.
        %% === Page 6 ===
        \\chapter*{Foreword}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(fakeSwitch), fakeSwitch)

        let realSwitchAfterVerb = """
        \\begin{document}
        %% === Page 3 ===
        \\frontmatter
        Preface.
        %% === Page 5 ===
        \\verb|%| \\mainmatter
        Main text.
        \\end{document}
        """
        let result = LaTeXNormalizer.insertPageCounters(realSwitchAfterVerb)
        XCTAssertTrue(result.contains("\\verb|%| \\mainmatter\n\\setcounter{page}{5}\nMain text."))
    }

    func testSwitchesInsideMacroDefinitionsAreNotExecuted() {
        let definitions = [
            "\\newcommand{\\prefaceMode}{\\frontmatter}",
            "\\renewcommand*{\\a}[1][x]{\\frontmatter}",
            "\\providecommand\\b{\\pagenumbering{roman}}",
            "\\def\\c{\\frontmatter}",
            "\\gdef\\d#1{\\frontmatter}",
            "\\edef\\e{\\noexpand\\frontmatter}",
            "\\let\\f\\frontmatter",
            "\\NewDocumentCommand{\\g}{m}{\\frontmatter}",
            "\\RenewDocumentCommand\\h{}{\\pagenumbering{Roman}}",
        ]
        for definition in definitions {
            let input = """
            \\documentclass{book}
            \(definition)
            \\begin{document}
            \(definition)
            %% === Page 4 ===
            \\chapter{One}
            Text.
            \\end{document}
            """
            let result = LaTeXNormalizer.insertPageCounters(input)
            XCTAssertTrue(result.contains("\\chapter{One}\n\\setcounter{page}{4}\n"), definition)
        }
    }

    func testEscapedLineBreakBeforeSwitchNameIsNotASwitch() {
        let input = """
        \\begin{document}
        %% === Page 2 ===
        \\frontmatter
        Preface\\\\mainmatter text.
        %% === Page 4 ===
        \\chapter*{Foreword}
        \\end{document}
        """
        XCTAssertEqual(LaTeXNormalizer.insertPageCounters(input), input)
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

    func testNormalizeProject_reportsNotesMigratesLegacyAndKeepsVerbatimMarkers() throws {
        let (dir, mainURL) = try makeProject(main: """
        \\documentclass{book}
        \\begin{document}

        %% === Page 1 ===
        Title page of the book.
        \\begin{verbatim}
        %% === Page 99 ===
        \\chapter{Fake}
        \\end{verbatim}

        %% === Page 18 ===
        \\setcounter{page}{18}
        \\chapter{Linear Regression}
        Regression starts here.

        \\end{document}
        """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertEqual(report1.pageCounterNotes.map(\.kind), [
            .counterInserted(page: 1),
            .legacyCounterMoved(page: 18),
        ])
        XCTAssertTrue(first.contains("\\begin{verbatim}\n%% === Page 99 ===\n\\chapter{Fake}\n\\end{verbatim}"))
        XCTAssertFalse(first.contains("%% === Page 1 ==="))
        XCTAssertFalse(first.contains("%% === Page 18 ==="))
        XCTAssertTrue(first.contains("\\chapter{Linear Regression}\n\\setcounter{page}{18}\nRegression"))
        XCTAssertEqual(first.components(separatedBy: "\\setcounter{page}{18}").count - 1, 1)

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertEqual(report2.pageCounterNotes, [])
        XCTAssertEqual(try String(contentsOf: mainURL, encoding: .utf8), first)
    }
}
