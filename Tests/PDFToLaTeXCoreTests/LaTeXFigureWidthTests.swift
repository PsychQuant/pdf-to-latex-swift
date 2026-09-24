import XCTest
@testable import PDFToLaTeXCore

/// 圖片寬度還原（PsychQuant/macdoc#10、#207）：`FigureRegion.bbox` × 頁寬 →
/// `width=\ifdim <w>bp>\linewidth\linewidth\else <w>bp\fi`（原書的絕對寬度，以 `\linewidth` 為上限）。
final class LaTeXFigureWidthTests: XCTestCase {

    /// 本工具寫入的寬度值（PsychQuant/macdoc#207）。
    static func capped(_ points: String) -> String {
        "width=\\ifdim \(points)bp>\\linewidth\\linewidth\\else \(points)bp\\fi"
    }

    /// 規格範例：bbox 寬 0.68 × 頁寬 612bp = 416.16bp。
    static let w68 = capped("416.16")

    // MARK: - Fixture

    private var projectDir: URL!

    override func setUpWithError() throws {
        projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectDir)
    }

    private func writeManifest(pages: [(number: Int, width: Double)]) throws {
        let manifest = ProjectManifest(
            schemaVersion: 1, createdAt: "2026-09-24T00:00:00+08:00",
            updatedAt: "2026-09-24T00:00:00+08:00", projectName: "fixture",
            sourcePDF: "input/book.pdf", projectRoot: projectDir.path,
            pages: pages.map {
                PageRecord(number: $0.number, width: $0.width, height: 792, rotation: 0,
                           renderedImagePath: nil, renderedDPI: nil)
            },
            blocks: []
        )
        try ManifestStore().save(manifest, to: projectDir.appendingPathComponent("manifest.json"))
    }

    private func writeResponse(_ name: String, figures: [(page: Int, id: String, bbox: [Double])]) throws {
        let pages = Dictionary(grouping: figures, by: { $0.page })
            .sorted { $0.key < $1.key }
            .map { page, figs in
                PageResult(page: page, latex: "",
                           figures: figs.map { FigureRegion(id: $0.id, bbox: $0.bbox, caption: nil) },
                           confidence: nil, notes: nil)
            }
        let dir = projectDir.appendingPathComponent("responses", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PageTranscriptionResponse(pages: pages))
        try data.write(to: dir.appendingPathComponent(name))
    }

    private func writeRawResponse(_ name: String, _ text: String) throws {
        let dir = projectDir.appendingPathComponent("responses", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeImage(_ relativePath: String) throws {
        let url = projectDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    }

    /// 規格範例：第 12 頁、頁寬 612pt、bbox [0.12, 0.08, 0.68, 0.31]。
    private func writeSpecExample() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        try writeImage("figures/p012-fig01.png")
    }

    private func apply(_ source: String) -> FigureWidthReport {
        LaTeXNormalizer.applyFigureWidths(source, projectDir: projectDir)
    }

    // MARK: - Spec example

    func testSpecExample_noOptions_getsBBoxWidthFraction() throws {
        try writeSpecExample()
        let source = """
        %% === Page 12 ===
        \\begin{figure}[h]
        \\includegraphics{figures/p012-fig01.png}
        \\end{figure}
        """
        let report = apply(source)

        XCTAssertEqual(report.result, source.replacingOccurrences(
            of: "\\includegraphics{figures/p012-fig01.png}",
            with: "\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}"
        ))
        XCTAssertEqual(report.resolutions.count, 1)
        let resolution = try XCTUnwrap(report.resolutions.first)
        XCTAssertEqual(resolution.path, "figures/p012-fig01.png")
        XCTAssertEqual(resolution.page, 12)
        XCTAssertEqual(resolution.line, 3)
        guard case let .widthApplied(fraction, widthPoints) = resolution.outcome else {
            return XCTFail("expected widthApplied, got \(resolution.outcome)")
        }
        XCTAssertEqual(fraction, 0.68, accuracy: 1e-12)
        XCTAssertEqual(widthPoints, 416.16)  // 寫進原始碼的 bp 值（0.68 × 612bp ≈ 5.78in）
        XCTAssertFalse(resolution.replacedLegacyWidth)
    }

    func testExtensionlessPathMatchesCroppedPNG() throws {
        try writeSpecExample()
        let report = apply("%% === Page 12 ===\n\\includegraphics{figures/p012-fig01}")
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.w68)]{figures/p012-fig01}")
    }

    func testStarredFormAndSpacingAreHandled() throws {
        try writeSpecExample()
        let report = apply("%% === Page 12 ===\n\\includegraphics* {figures/p012-fig01.png}")
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics*[\(Self.w68)] {figures/p012-fig01.png}")
    }

    // MARK: - Merge rule for existing options

    func testExplicitSizeOptionsArePreservedVerbatim() throws {
        try writeSpecExample()
        let explicit = [
            "[width=0.5\\linewidth]",
            "[height=3cm]",
            "[totalheight=2in]",
            "[scale=0.4]",
            "[angle=90, width=4cm]",
            "[ width = 3cm ]",
        ]
        for options in explicit {
            let source = "%% === Page 12 ===\n\\includegraphics\(options){figures/p012-fig01.png}"
            let report = apply(source)
            XCTAssertEqual(report.result, source, "options \(options) must be kept as written")
            XCTAssertEqual(report.resolutions.first?.outcome, .explicitSizePreserved, "options \(options)")
        }
    }

    /// 舊行為把 scale>2 硬改成 0.8；新契約下 scale 是使用者明確寫的尺寸，原樣保留。
    func testLargeScaleIsNoLongerRewrittenToArbitraryValue() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics[scale=5]{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertFalse(report.result.contains("0.8"))
    }

    func testNonSizeOptionsAreKeptAndWidthIsAppendedLast() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics[angle=90, trim={1 2 3 4}, clip]{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(
            report.result,
            "%% === Page 12 ===\n\\includegraphics[angle=90, trim={1 2 3 4}, clip,\(Self.w68)]{figures/p012-fig01.png}"
        )
    }

    func testEmptyOptionBracketGetsWidth() throws {
        try writeSpecExample()
        let report = apply("%% === Page 12 ===\n\\includegraphics[]{figures/p012-fig01.png}")
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}")
    }

    // MARK: - Leave unchanged + report

    func testMissingMetadataLeavesTextUnchanged() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig02", [0.1, 0.1, 0.5, 0.2])])
        try writeImage("figures/p012-fig01.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .noMatchingFigure)
    }

    func testMissingManifestLeavesTextUnchanged() throws {
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        try writeImage("figures/p012-fig01.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        guard case .metadataUnavailable = report.resolutions.first?.outcome else {
            return XCTFail("expected metadataUnavailable, got \(String(describing: report.resolutions.first?.outcome))")
        }
    }

    func testMissingResponsesDirectoryLeavesTextUnchanged() throws {
        try writeManifest(pages: [(12, 612)])
        try writeImage("figures/p012-fig01.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        guard case .metadataUnavailable = report.resolutions.first?.outcome else {
            return XCTFail("expected metadataUnavailable, got \(String(describing: report.resolutions.first?.outcome))")
        }
    }

    func testMissingImageFileLeavesTextUnchanged() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .missingImageFile)
    }

    func testMissingPageRecordLeavesTextUnchanged() throws {
        try writeManifest(pages: [(11, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        try writeImage("figures/p012-fig01.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .missingPageRecord)
    }

    func testInvalidBBoxLeavesTextUnchanged() throws {
        let invalid: [[Double]] = [
            [0.1, 0.1, 0.5],            // 不是 4 個值
            [0.5, 0.1, 0.7, 0.2],       // 超出頁面右緣
            [0.1, 0.1, -0.2, 0.3],      // 負寬
            [0.1, 0.1, 0, 0.3],         // 零寬
            [0.1, 0.9, 0.5, 0.2],       // 超出頁面下緣
            [-0.1, 0.1, 0.5, 0.2],      // 負座標
        ]
        try writeManifest(pages: [(12, 612)])
        try writeImage("figures/p012-fig01.png")
        for bbox in invalid {
            try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", bbox)])
            let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
            let report = apply(source)
            XCTAssertEqual(report.result, source, "bbox \(bbox)")
            guard case .invalidBoundingBox = report.resolutions.first?.outcome else {
                XCTFail("bbox \(bbox): expected invalidBoundingBox, got \(String(describing: report.resolutions.first?.outcome))")
                continue
            }
        }
    }

    func testNoPageContextLeavesTextUnchanged() throws {
        try writeSpecExample()
        let source = "\\includegraphics{figures/p012-fig01.png}\n%% === Page 12 ===\nText."
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .noPageContext)
    }

    func testConflictingMetadataIsAmbiguous() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-011-012.json", figures: [(12, "p012-fig01", [0.1, 0.1, 0.5, 0.2])])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.1, 0.1, 0.6, 0.2])])
        try writeImage("figures/p012-fig01.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .ambiguousFigure)
    }

    func testIdenticalDuplicateMetadataIsNotAmbiguous() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-011-012.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        try writeImage("figures/p012-fig01.png")
        let report = apply("%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}")
        XCTAssertTrue(report.result.contains("[\(Self.w68)]"))
    }

    func testUnreadableResponseFileIsReported_fencedResponseIsRead() throws {
        try writeManifest(pages: [(12, 612)])
        try writeRawResponse("pages-010-011.json", "not json at all")
        try writeRawResponse("pages-012-013.json", """
        ```json
        {"pages":[{"page":12,"latex":"","figures":[{"id":"p012-fig01","bbox":[0.12,0.08,0.68,0.31],"caption":null}],"confidence":null,"notes":null}]}
        ```
        """)
        try writeImage("figures/p012-fig01.png")
        let report = apply("%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}")
        XCTAssertTrue(report.result.contains("[\(Self.w68)]"))
        XCTAssertEqual(report.unreadableResponseFiles, ["responses/pages-010-011.json"])
    }

    // MARK: - Matching discipline

    /// 同名 figure 出現在不同頁：以（頁, 完整相對路徑）配對，不跨頁誤配。
    func testSameNamedFiguresOnDifferentPagesMatchByPage() throws {
        try writeManifest(pages: [(12, 612), (15, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "fig1", [0.1, 0.1, 0.4, 0.2])])
        try writeResponse("pages-014-015.json", figures: [(15, "fig1", [0.05, 0.1, 0.9, 0.2])])
        try writeImage("figures/fig1.png")
        let source = """
        %% === Page 12 ===
        \\includegraphics{figures/fig1.png}
        %% === Page 15 ===
        \\includegraphics{figures/fig1.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, """
        %% === Page 12 ===
        \\includegraphics[\(Self.capped("244.8"))]{figures/fig1.png}
        %% === Page 15 ===
        \\includegraphics[\(Self.capped("550.8"))]{figures/fig1.png}
        """)
        XCTAssertEqual(report.resolutions.map(\.page), [12, 15])
    }

    func testFigureListedOnlyOnAnotherPageDoesNotMatch() throws {
        try writeManifest(pages: [(12, 612), (15, 612)])
        try writeResponse("pages-014-015.json", figures: [(15, "p012-fig01", [0.1, 0.1, 0.5, 0.2])])
        try writeImage("figures/p012-fig01.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .noMatchingFigure)
    }

    func testSubstringOfFigureIdDoesNotMatch() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig1", [0.1, 0.1, 0.5, 0.2])])
        try writeImage("figures/p012-fig10.png")
        try writeImage("figures/xp012-fig1.png")
        let source = """
        %% === Page 12 ===
        \\includegraphics{figures/p012-fig10.png}
        \\includegraphics{figures/xp012-fig1.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.map(\.outcome), [.noMatchingFigure, .noMatchingFigure])
    }

    func testNonFigurePathsAndCommentedCallsAreIgnored() throws {
        try writeSpecExample()
        let source = """
        %% === Page 12 ===
        \\includegraphics{logo.pdf}
        % \\includegraphics{figures/p012-fig01.png}
        Price 100\\% \\includegraphics{figures/p012-fig01.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source.replacingOccurrences(
            of: "100\\% \\includegraphics{", with: "100\\% \\includegraphics[\(Self.w68)]{"
        ))
        XCTAssertEqual(report.resolutions.count, 1)
        XCTAssertEqual(report.resolutions.first?.line, 4)
    }

    // MARK: - Inactive regions (verbatim / \verb / definitions / after \end{document})

    func testVerbatimLikeRegionsAreNeverRewrittenAndTheirMarkersDoNotCount() throws {
        try writeManifest(pages: [(12, 612), (99, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        // 若 verbatim 裡的假 marker 被採信，下方真正的圖會拿到第 99 頁的 0.2。
        try writeResponse("pages-099-100.json", figures: [(99, "p012-fig01", [0.1, 0.1, 0.2, 0.2])])
        try writeImage("figures/p012-fig01.png")
        let environments: [(begin: String, end: String)] = [
            ("\\begin{verbatim}", "\\end{verbatim}"),
            ("\\begin{verbatim*}", "\\end{verbatim*}"),
            ("\\begin{Verbatim}", "\\end{Verbatim}"),
            ("\\begin{lstlisting}[language=TeX]", "\\end{lstlisting}"),
            ("\\begin{minted}{latex}", "\\end{minted}"),
            ("\\begin{comment}", "\\end{comment}"),
        ]
        for env in environments {
            let block = """
            \(env.begin)
            %% === Page 99 ===
            \\chapter{Fake}
            \\includegraphics{figures/p012-fig01.png}
            \(env.end)
            """
            let source = """
            %% === Page 12 ===
            Intro.
            \(block)
            \\includegraphics{figures/p012-fig01.png}
            """
            let report = apply(source)
            XCTAssertTrue(report.result.contains(block), env.begin)
            XCTAssertTrue(report.result.hasSuffix(
                "\(env.end)\n\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}"
            ), env.begin)
            XCTAssertEqual(report.resolutions.map(\.page), [12], env.begin)
        }
    }

    /// comment 套件的 `\end{comment}` 必須獨佔一行（pdflatex 實測）：行中那個不結束，
    /// 其後的假 marker 與 `\includegraphics` 仍在註解內。
    func testInlineEndCommentDoesNotEndTheCommentEnvironment() throws {
        try writeManifest(pages: [(12, 612), (99, 612)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
        try writeResponse("pages-099-100.json", figures: [(99, "p012-fig01", [0.1, 0.1, 0.2, 0.2])])
        try writeImage("figures/p012-fig01.png")
        let block = """
        \\begin{comment}
        Example: \\end{comment}
        %% === Page 99 ===
        \\includegraphics{figures/p012-fig01.png}
        \\end{comment}
        """
        let source = "%% === Page 12 ===\n\(block)\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\(block)\n\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}")
        XCTAssertEqual(report.resolutions.map(\.page), [12])
    }

    func testInlineVerbIsNeverRewritten_percentInsideVerbIsNotAComment() throws {
        try writeSpecExample()
        let source = """
        %% === Page 12 ===
        \\verb|\\includegraphics{figures/p012-fig01.png}| and \\verb*!\\includegraphics{figures/p012-fig01.png}!
        \\verb|%| \\includegraphics{figures/p012-fig01.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source.replacingOccurrences(
            of: "\\verb|%| \\includegraphics{", with: "\\verb|%| \\includegraphics[\(Self.w68)]{"
        ))
        XCTAssertEqual(report.resolutions.map(\.line), [3])
    }

    func testCallsInsideMacroDefinitionsAreNeverRewritten() throws {
        try writeSpecExample()
        let source = """
        %% === Page 12 ===
        \\newcommand{\\figA}{\\includegraphics{figures/p012-fig01.png}}
        \\def\\figB{\\includegraphics{figures/p012-fig01.png}}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions, [])
    }

    func testCallsAfterEndDocumentAreNeverRewritten() throws {
        try writeSpecExample()
        let source = """
        \\begin{document}
        %% === Page 12 ===
        Text.
        \\end{document}
        \\includegraphics{figures/p012-fig01.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions, [])
    }

    // MARK: - Comments inside includegraphics arguments

    func testSizeKeyAfterCommentLineIsRecognized() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics[angle=90,% note\nwidth=3cm]{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .explicitSizePreserved)
    }

    func testSizeKeyInsideCommentIsNotASizeKey() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics[angle=90,% width=3cm\n]{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(
            report.result,
            "%% === Page 12 ===\n\\includegraphics[angle=90,\(Self.w68)% width=3cm\n]{figures/p012-fig01.png}"
        )
    }

    /// width 絕不能落在同一行的 `%` 之後（否則會被註解掉）。
    func testWidthIsNeverAppendedAfterACommentOnTheSameLine() throws {
        try writeSpecExample()
        let cases: [(String, String)] = [
            ("[clip % note\n]", "[clip,\(Self.w68) % note\n]"),
            ("[clip % ] not the end\n]", "[clip,\(Self.w68) % ] not the end\n]"),
            ("[% only a comment\n]", "[\(Self.w68)% only a comment\n]"),
            ("[clip,% note\n]", "[clip,\(Self.w68)% note\n]"),
        ]
        for (options, expected) in cases {
            let source = "%% === Page 12 ===\n\\includegraphics\(options){figures/p012-fig01.png}"
            let report = apply(source)
            XCTAssertEqual(
                report.result,
                "%% === Page 12 ===\n\\includegraphics\(expected){figures/p012-fig01.png}",
                options
            )
            for line in report.result.components(separatedBy: "\n") {
                if let percent = line.firstIndex(of: "%"), let width = line.range(of: "width=\\ifdim") {
                    XCTAssertLessThan(width.lowerBound, percent, "width after a comment in: \(line)")
                }
            }
        }
    }

    /// pdflatex 實測（B3）：`wid%⏎    th=3cm` 的 key 是 width（寬 85.35826pt = 3cm）。
    func testKeySplitAcrossACommentIsRecognized() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics[wid% note\n    th=3cm]{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .explicitSizePreserved)
    }

    /// pdflatex 實測（B3）：路徑跨註解仍是同一個檔名。
    func testPathSplitAcrossACommentIsRecognized() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-% note\n      fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.w68)]{figures/p012-% note\n      fig01.png}")
        guard case .widthApplied = report.resolutions.first?.outcome else {
            return XCTFail("expected widthApplied, got \(String(describing: report.resolutions.first?.outcome))")
        }
    }

    func testCommentBetweenCommandAndPathGetsBracketsBeforeTheComment() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics% note\n{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.w68)]% note\n{figures/p012-fig01.png}")
    }

    // MARK: - Option values with braces and commas

    func testNestedBracesAndCommasInsideValues() throws {
        try writeSpecExample()
        let cases: [(String, String)] = [
            ("[angle=90, trim={1, 2, 3, 4}, viewport={0 {0} 10 10}, clip]",
             "[angle=90, trim={1, 2, 3, 4}, viewport={0 {0} 10 10}, clip,\(Self.w68)]"),
            ("[alt={width=3cm}]", "[alt={width=3cm},\(Self.w68)]"),
            ("[alt={a]b}, clip]", "[alt={a]b}, clip,\(Self.w68)]"),
        ]
        for (options, expected) in cases {
            let source = "%% === Page 12 ===\n\\includegraphics\(options){figures/p012-fig01.png}"
            XCTAssertEqual(
                apply(source).result,
                "%% === Page 12 ===\n\\includegraphics\(expected){figures/p012-fig01.png}",
                options
            )
        }
    }

    func testStarredFormWithOptions() throws {
        try writeSpecExample()
        let report = apply("%% === Page 12 ===\n\\includegraphics*[clip]{figures/p012-fig01.png}")
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics*[clip,\(Self.w68)]{figures/p012-fig01.png}")
    }

    func testMultipleCallsOnOneLine() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-012-013.json", figures: [
            (12, "p012-fig01", [0.05, 0.1, 0.45, 0.3]),
            (12, "p012-fig02", [0.5, 0.1, 0.4, 0.3]),
        ])
        try writeImage("figures/p012-fig01.png")
        try writeImage("figures/p012-fig02.png")
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}\\hfill\\includegraphics[angle=90]{figures/p012-fig02.png}"
        let report = apply(source)
        XCTAssertEqual(
            report.result,
            "%% === Page 12 ===\n\\includegraphics[\(Self.capped("275.4"))]{figures/p012-fig01.png}\\hfill\\includegraphics[angle=90,\(Self.capped("244.8"))]{figures/p012-fig02.png}"
        )
        XCTAssertEqual(report.resolutions.map(\.line), [2, 2])
    }

    // MARK: - Width formatting

    /// bbox 寬先取六位小數（`fraction`），乘上頁寬後取四位小數、去掉尾端 0 寫入（`widthPoints`）。
    func testSmallWidthsKeepSignificantDigitsAndReportWhatIsWritten() throws {
        try writeManifest(pages: [(12, 600)])
        try writeImage("figures/p012-fig01.png")
        let cases: [(bboxWidth: Double, fraction: Double, written: String)] = [
            (0.0000123, 0.000012, "0.0072"),
            (0.1234567, 0.123457, "74.0742"),
            (0.5, 0.5, "300"),
            (1.0, 1, "600"),
        ]
        for (bboxWidth, expectedFraction, written) in cases {
            try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0, 0.1, bboxWidth, 0.2])])
            let report = apply("%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}")
            XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.capped(written))]{figures/p012-fig01.png}")
            guard case let .widthApplied(fraction, widthPoints) = report.resolutions.first?.outcome else {
                XCTFail("expected widthApplied for \(bboxWidth)")
                continue
            }
            XCTAssertEqual(fraction, expectedFraction)
            XCTAssertEqual(widthPoints, Double(written))
        }
    }

    func testWidthThatWouldRoundToZeroIsLeftUnchangedAndReported() throws {
        try writeManifest(pages: [(12, 612)])
        try writeImage("figures/p012-fig01.png")
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.1, 0.1, 4e-7, 0.2])])
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .widthNotRepresentable(4e-7))
    }

    /// 比例本身寫得出來，但乘上（很窄的）頁寬之後以四位小數表示是 0：同樣不寫入。
    func testPointWidthThatWouldRoundToZeroIsLeftUnchangedAndReported() throws {
        try writeManifest(pages: [(12, 10)])
        try writeImage("figures/p012-fig01.png")
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.1, 0.1, 0.000001, 0.2])])
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .widthNotRepresentable(0.000001))
    }

    /// 頁寬超過 PDF 的頁面上限（14400 單位 = 200in）視為無效：換算出的尺寸可能超過 TeX 的
    /// \maxdimen，寫進去會讓文件無法編譯。
    func testImplausiblePageWidthIsTreatedAsInvalidPageRecord() throws {
        // NaN／∞ 無法寫進 JSON manifest，由 `isFinite` 守住（與 #10 相同）。
        for width in [14400.5, 1e9, -612, 0] {
            try writeManifest(pages: [(12, width)])
            try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0.12, 0.08, 0.68, 0.31])])
            try writeImage("figures/p012-fig01.png")
            let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
            let report = apply(source)
            XCTAssertEqual(report.result, source, "page width \(width)")
            XCTAssertEqual(report.resolutions.first?.outcome, .missingPageRecord, "page width \(width)")
        }
    }

    func testPageWidthAtThePDFLimitIsStillValid() throws {
        try writeManifest(pages: [(12, 14400)])
        try writeResponse("pages-012-013.json", figures: [(12, "p012-fig01", [0, 0.08, 1, 0.31])])
        try writeImage("figures/p012-fig01.png")
        let report = apply("%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}")
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.capped("14400"))]{figures/p012-fig01.png}")
    }

    // MARK: - v0.3.0 的相對寬度升級（PsychQuant/macdoc#207）

    /// v0.3.0 寫出的四種形狀（`[…]` 新建、空選項、接在逗號後、補逗號），值與該頁 bbox
    /// 以同一格式化規則算出的比例逐字相同 → 視為本工具的舊輸出，升級成新格式。
    func testLegacyToolWidthIsUpgraded() throws {
        try writeSpecExample()
        let cases: [(String, String)] = [
            ("[width=0.68\\textwidth]", "[\(Self.w68)]"),
            ("[width=0.68\\textwidth ]", "[\(Self.w68) ]"),
            ("[clip,width=0.68\\textwidth]", "[clip,\(Self.w68)]"),
            ("[angle=90, trim={1 2 3 4},width=0.68\\textwidth % note\n]", "[angle=90, trim={1 2 3 4},\(Self.w68) % note\n]"),
            ("[width=0.68\\textwidth% only a comment\n]", "[\(Self.w68)% only a comment\n]"),
        ]
        for (options, expected) in cases {
            let source = "%% === Page 12 ===\n\\includegraphics\(options){figures/p012-fig01.png}"
            let report = apply(source)
            XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics\(expected){figures/p012-fig01.png}", options)
            let resolution = try XCTUnwrap(report.resolutions.first)
            XCTAssertTrue(resolution.replacedLegacyWidth, options)
            guard case let .widthApplied(fraction, widthPoints) = resolution.outcome else {
                XCTFail("\(options): expected widthApplied, got \(resolution.outcome)")
                continue
            }
            XCTAssertEqual(fraction, 0.68)
            XCTAssertEqual(widthPoints, 416.16)

            let second = apply(report.result)
            XCTAssertEqual(second.result, report.result, "second run must not change \(options)")
            XCTAssertEqual(second.resolutions.first?.outcome, .explicitSizePreserved, options)
            XCTAssertFalse(second.resolutions.first?.replacedLegacyWidth ?? true, options)
        }
    }

    /// 只要不是本工具會寫出的精確形狀，或值與 bbox 對不上，就當成使用者寫的尺寸原樣保留。
    func testWidthsThatAreNotExactlyTheLegacyToolOutputArePreserved() throws {
        try writeSpecExample()
        let preserved = [
            "[width=0.5\\textwidth]",             // 值與 bbox（0.68）不符
            "[width=0.680\\textwidth]",           // 不是本工具的數字格式
            "[width=.68\\textwidth]",
            "[ width=0.68\\textwidth]",           // 本工具不會在 key 前留空白
            "[clip, width=0.68\\textwidth]",
            "[width = 0.68\\textwidth]",
            "[width=0.68 \\textwidth]",
            "[width={0.68\\textwidth}]",
            "[width=0.68\\textwidth,clip]",        // 不是最後一個選項
            "[width=0.68\\linewidth]",            // 不是 \textwidth
            "[width=0.68\\textwidth\\relax]",
            "[height=2cm,width=0.68\\textwidth]", // 另有尺寸 key：v0.3.0 不會補 width
            "[scale=1,width=0.68\\textwidth]",
            "[width=1cm,width=0.68\\textwidth]",
            "[width=0.68\\textwidth,% c\n]",
            "[wid% c\nth=0.68\\textwidth]",
        ]
        for options in preserved {
            let source = "%% === Page 12 ===\n\\includegraphics\(options){figures/p012-fig01.png}"
            let report = apply(source)
            XCTAssertEqual(report.result, source, options)
            XCTAssertEqual(report.resolutions.first?.outcome, .explicitSizePreserved, options)
            XCTAssertFalse(report.resolutions.first?.replacedLegacyWidth ?? true, options)
        }
    }

    /// 形狀相同但對不上 metadata（沒有這張圖、頁寬無效、圖檔不存在、沒有 page marker）時，
    /// 不能證明是本工具寫的，原樣保留。
    func testLegacyShapeWithoutMatchingMetadataIsPreserved() throws {
        try writeManifest(pages: [(12, 612)])
        try writeResponse("pages-012-013.json", figures: [
            (12, "p012-fig01", [0.12, 0.08, 0.68, 0.31]),
            (12, "p012-fig02", [0.12, 0.08, 0.68, 0.31]),
        ])
        try writeImage("figures/p012-fig01.png")  // p012-fig02 沒有裁切檔
        let source = """
        \\includegraphics[width=0.68\\textwidth]{figures/p012-fig01.png}
        %% === Page 12 ===
        \\includegraphics[width=0.68\\textwidth]{figures/p012-fig02.png}
        \\includegraphics[width=0.68\\textwidth]{figures/p012-fig03.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.map(\.outcome), [.explicitSizePreserved, .explicitSizePreserved, .explicitSizePreserved])
    }

    func testLegacyShapeInsideVerbatimOrDefinitionIsNeverTouched() throws {
        try writeSpecExample()
        let source = """
        %% === Page 12 ===
        \\begin{verbatim}
        \\includegraphics[width=0.68\\textwidth]{figures/p012-fig01.png}
        \\end{verbatim}
        \\newcommand{\\figA}{\\includegraphics[width=0.68\\textwidth]{figures/p012-fig01.png}}
        % \\includegraphics[width=0.68\\textwidth]{figures/p012-fig01.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions, [])
    }

    /// 只有明確尺寸（且不是舊版形狀）時不需要 metadata：不讀 responses，也不回報讀不到的檔案。
    func testExplicitNonLegacySizesDoNotLoadMetadata() throws {
        try writeManifest(pages: [(12, 612)])
        try writeRawResponse("pages-010-011.json", "not json at all")
        let report = apply("%% === Page 12 ===\n\\includegraphics[width=3cm]{figures/p012-fig01.png}")
        XCTAssertEqual(report.resolutions.map(\.outcome), [.explicitSizePreserved])
        XCTAssertEqual(report.unreadableResponseFiles, [])
    }

    // MARK: - 帶頁碼前綴的裁切檔（PsychQuant/macdoc#208）

    /// 轉寫時 id `fig1` 的第 18 頁裁切圖存成 `figures/p018-fig1.png`；normalize 以（頁, 完整路徑）
    /// 仍配得上，且不會借用第 19 頁同 id 的 bbox。
    func testPagePrefixedCroppedPathsMatchTheirOwnPage() throws {
        try writeManifest(pages: [(18, 612), (19, 612)])
        try writeResponse("pages-018-019.json", figures: [
            (18, "fig1", [0.1, 0.1, 0.4, 0.2]),
            (19, "fig1", [0.05, 0.1, 0.9, 0.2]),
        ])
        try writeImage("figures/p018-fig1.png")
        try writeImage("figures/p019-fig1.png")
        let source = """
        %% === Page 18 ===
        \\includegraphics{figures/p018-fig1.png}
        %% === Page 19 ===
        \\includegraphics{figures/p019-fig1}
        \\includegraphics{figures/p018-fig1.png}
        """
        let report = apply(source)
        XCTAssertEqual(report.result, """
        %% === Page 18 ===
        \\includegraphics[\(Self.capped("244.8"))]{figures/p018-fig1.png}
        %% === Page 19 ===
        \\includegraphics[\(Self.capped("550.8"))]{figures/p019-fig1}
        \\includegraphics{figures/p018-fig1.png}
        """)
        XCTAssertEqual(report.resolutions.last?.outcome, .noMatchingFigure)
    }

    /// id 已經帶本頁前綴（提示詞要求的 `pXXX-figYY`）時不重複加前綴，路徑與 v0.3.0 相同。
    func testIdAlreadyCarryingThePagePrefixKeepsItsPath() throws {
        XCTAssertEqual(FigureAssetPath.cropped(page: 12, id: "p012-fig01"), "figures/p012-fig01.png")
        try writeSpecExample()
        let report = apply("%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}")
        XCTAssertEqual(report.result, "%% === Page 12 ===\n\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}")
    }

    func testCroppedPathNaming() {
        let cases: [(page: Int, id: String, path: String?)] = [
            (18, "fig1", "figures/p018-fig1.png"),
            (18, "p018-fig1", "figures/p018-fig1.png"),
            (19, "p018-fig1", "figures/p019-p018-fig1.png"),   // 別頁的前綴不算
            (18, "p18-fig1", "figures/p018-p18-fig1.png"),
            (7, "Fig_2.b", "figures/p007-Fig_2.b.png"),
            (1234, "fig1", "figures/p1234-fig1.png"),
            (18, "", nil),
            (18, "../p019-fig1", nil),                          // 路徑穿越：會蓋掉別頁的檔
            (18, "a/b", nil),
            (18, "a\\b", nil),
            (18, "a%b", nil),
            (18, "a b", nil),
            (18, "a{b}", nil),
            (18, "圖1", nil),
        ]
        for c in cases {
            XCTAssertEqual(FigureAssetPath.cropped(page: c.page, id: c.id), c.path, "page \(c.page) id \(c.id)")
        }
    }

    /// 同一頁兩個 id 正規化後撞名（`fig1` 與 `p018-fig1`）且 bbox 不同：無法判定是哪一張，回報 ambiguous。
    func testIdsCollidingAfterPrefixingOnTheSamePageAreAmbiguous() throws {
        try writeManifest(pages: [(18, 612)])
        try writeResponse("pages-018-019.json", figures: [
            (18, "fig1", [0.1, 0.1, 0.4, 0.2]),
            (18, "p018-fig1", [0.1, 0.5, 0.6, 0.2]),
        ])
        try writeImage("figures/p018-fig1.png")
        let source = "%% === Page 18 ===\n\\includegraphics{figures/p018-fig1.png}"
        let report = apply(source)
        XCTAssertEqual(report.result, source)
        XCTAssertEqual(report.resolutions.first?.outcome, .ambiguousFigure)
    }

    // MARK: - Idempotency

    func testSecondRunChangesNothing() throws {
        try writeSpecExample()
        try writeManifest(pages: [(12, 612), (15, 612)])
        // p015-fig01 有 metadata 但沒有裁切檔：兩次都應原樣保留並回報。
        try writeResponse("pages-014-015.json", figures: [(15, "p015-fig01", [0.2, 0.1, 0.5, 0.3])])
        let source = """
        %% === Page 12 ===
        \\includegraphics{figures/p012-fig01.png}
        %% === Page 15 ===
        \\includegraphics{figures/p015-fig01.png}
        """
        let first = apply(source)
        XCTAssertNotEqual(first.result, source)
        let second = apply(first.result)
        XCTAssertEqual(second.result, first.result)
        XCTAssertEqual(second.resolutions.map(\.outcome), [.explicitSizePreserved, .missingImageFile])
        XCTAssertEqual(first.resolutions.last?.outcome, .missingImageFile)
    }

    func testFixImageScaleCompatibilityWrapperUsesNewAlgorithm() throws {
        try writeSpecExample()
        let source = "%% === Page 12 ===\n\\includegraphics{figures/p012-fig01.png}"
        XCTAssertEqual(LaTeXNormalizer.fixImageScale(source, projectDir: projectDir), apply(source).result)
    }

    // MARK: - normalizeProject integration

    func testNormalizeProject_appliesFigureWidthsAndReportsThem() throws {
        try writeSpecExample()
        let mainURL = projectDir.appendingPathComponent("accumulated.tex")
        try """
        \\documentclass{book}
        \\usepackage{graphicx}
        \\begin{document}

        %% === Page 12 ===
        \\begin{figure}[h]
        \\centering
        \\includegraphics{figures/p012-fig01.png}
        \\caption{Scatter plot of wages.}
        \\end{figure}
        \\includegraphics{figures/p012-fig09.png}

        \\end{document}
        """.write(to: mainURL, atomically: true, encoding: .utf8)

        let normalizer = LaTeXNormalizer()
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(report1.mainFileChanged)
        XCTAssertTrue(first.contains("\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}"))
        XCTAssertTrue(first.contains("\\includegraphics{figures/p012-fig09.png}"))
        XCTAssertEqual(report1.figureWidthResolutions.map(\.path),
                       ["figures/p012-fig01.png", "figures/p012-fig09.png"])
        guard case .widthApplied = report1.figureWidthResolutions.first?.outcome else {
            return XCTFail("expected widthApplied")
        }
        XCTAssertEqual(report1.figureWidthResolutions.last?.outcome, .noMatchingFigure)

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertEqual(try String(contentsOf: mainURL, encoding: .utf8), first)
        XCTAssertEqual(report2.figureWidthResolutions.map(\.outcome),
                       [.explicitSizePreserved, .noMatchingFigure])
    }

    /// stripPageMarkers 模式：第一輪在移除 marker 之前完成配對；第二輪 marker 已不在，
    /// 已改寫者落入 explicitSizePreserved，未解決者回報 noPageContext（頁面連結已隨 marker
    /// 移除），原始碼位元組不變。
    func testNormalizeProject_stripPageMarkers_secondRunIsByteIdentical() throws {
        try writeSpecExample()
        let mainURL = projectDir.appendingPathComponent("accumulated.tex")
        try """
        \\documentclass{book}
        \\usepackage{graphicx}
        \\begin{document}

        %% === Page 12 ===
        \\begin{verbatim}
        %% === Page 99 ===
        \\includegraphics{figures/p012-fig01.png}
        \\end{verbatim}
        \\includegraphics{figures/p012-fig01.png}
        \\includegraphics{figures/p012-fig09.png}

        \\end{document}
        """.write(to: mainURL, atomically: true, encoding: .utf8)

        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertFalse(first.contains("%% === Page 12 ==="))
        XCTAssertTrue(first.contains("\\begin{verbatim}\n%% === Page 99 ===\n\\includegraphics{figures/p012-fig01.png}\n\\end{verbatim}"))
        XCTAssertTrue(first.contains("\\end{verbatim}\n\\includegraphics[\(Self.w68)]{figures/p012-fig01.png}"))
        XCTAssertEqual(report1.figureWidthResolutions.map(\.outcome).count, 2)
        XCTAssertEqual(report1.figureWidthResolutions.last?.outcome, .noMatchingFigure)

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertEqual(try String(contentsOf: mainURL, encoding: .utf8), first)
        XCTAssertEqual(report2.figureWidthResolutions.map(\.outcome), [.explicitSizePreserved, .noPageContext])
    }
}
