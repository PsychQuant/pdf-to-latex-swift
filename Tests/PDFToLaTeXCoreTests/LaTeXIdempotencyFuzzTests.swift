import XCTest
@testable import PDFToLaTeXCore

/// 「插入改變了下一輪的辨識」這一類 bug 的掃描（PsychQuant/macdoc#9、#10）：以固定種子產生大量
/// 混合錨點、同行組合、註解、verbatim、巨集定義與 CRLF 的文件，檢查不變量。
final class LaTeXIdempotencyFuzzTests: XCTestCase {

    /// 固定種子的線性同餘產生器，讓失敗可以重現。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static let inlineFragments = [
        "\\chapter{A}", "\\chapter*{B}", "\\chapter[S]{C}", "\\chapter{D}%\n{}",
        "\\mainmatter", "\\frontmatter", "\\pagenumbering{arabic}", "\\pagenumbering{roman}",
        "\\pagenumbering\n{arabic}", "\\pagenumbering% c\n{arabic}", "\\setcounter{page}{7}",
        "\\setcounter{page}{PAGE}", "\\setcounter{page}{PAGE}\n\\chapter{E}",
        "Text.", " ", "\\verb|\\chapter{V}|", "\\verb*X\\mainmatterX",
        "\\newcommand{\\x}{\\frontmatter}", "\\let\\y% c\n\\mainmatter", "\\label{l}",
    ]

    private static let lineFragments = [
        "", "% plain comment", "  ",
        "\\begin{verbatim}\n%% === Page 99 ===\n\\chapter{Fake}\n\\end{verbatim}",
        "\\begin{comment}\nExample: \\end{comment}\n\\chapter{Fake}\n\\end{comment}",
        "\\begin{Verbatim}\n\\mainmatter\n\\end{Verbatim}\\chapter{Dropped}",
        "\\chapter\n{Next line title}",
    ]

    private func makeDocument(_ rng: inout SeededGenerator) -> String {
        var lines: [String] = []
        var page = Int.random(in: 1...5, using: &rng)
        for _ in 0..<Int.random(in: 1...12, using: &rng) {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...2:
                page += Int.random(in: 1...3, using: &rng)
                lines.append("%% === Page \(page) ===")
            case 3...7:
                let count = Int.random(in: 1...3, using: &rng)
                // PAGE 代入目前的頁碼，才產生得出「值與 marker 相同的既有 counter」。
                var line = (0..<count).map { _ in Self.inlineFragments.randomElement(using: &rng)! }.joined()
                    .replacingOccurrences(of: "PAGE", with: String(page))
                if Bool.random(using: &rng) && Int.random(in: 0..<4, using: &rng) == 0 { line += " % trailing" }
                lines.append(line)
            default:
                lines.append(Self.lineFragments.randomElement(using: &rng)!)
            }
        }
        var body = lines.joined(separator: "\n")
        // \end{document} 與最後一行同行時，那一行不能有註解（否則 \end{document} 被註解掉）。
        let lastLine = body.components(separatedBy: "\n").last ?? ""
        let sameLine = Bool.random(using: &rng) && !lastLine.contains("%")
        body += sameLine ? "\\end{document}" : "\n\\end{document}"
        var document = "\\documentclass{book}\n\\begin{document}\n" + body + "\n%% === Page 999 ===\n\\chapter{After}"
        if Int.random(in: 0..<4, using: &rng) == 0 {
            document = document.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return document
    }

    func testPageCountersAreIdempotentAndStayInsideTheDocument() {
        var rng = SeededGenerator(state: 0x5EED_0009)
        for index in 0..<4000 {
            let source = makeDocument(&rng)
            let first = LaTeXNormalizer.applyPageCounters(source)
            let second = LaTeXNormalizer.applyPageCounters(first.result)
            let context = "case \(index):\n\(source.debugDescription)\n--- first ---\n\(first.result.debugDescription)"

            XCTAssertEqual(second.result, first.result, context)
            XCTAssertFalse(second.notes.contains {
                if case .counterInserted = $0.kind { return true }
                if case .legacyCounterMoved = $0.kind { return true }
                return false
            }, context)

            // 真正的 \end{document}（掃描器判定；例如 fancyvrb 會丟掉 \end{Verbatim} 同行其後的
            // \end{document}，pdflatex 實測）之後的內容一字不動。
            let sourceScan = LaTeXSourceScan(source)
            let resultScan = LaTeXSourceScan(first.result)
            if sourceScan.body.upperBound < sourceScan.units.count {
                XCTAssertEqual(
                    Array(sourceScan.units[sourceScan.body.upperBound...]),
                    Array(resultScan.units[resultScan.body.upperBound...]),
                    context
                )
            }
            // CRLF 檔案不出現單獨的 LF。
            if source.contains("\r\n") {
                XCTAssertFalse(first.result.replacingOccurrences(of: "\r\n", with: "").contains("\n"), context)
            }
        }
    }

    /// 移除 markers 之後，pipeline 再跑一次不變。這一條**不**驗證 counter 的歸屬或冪等性：
    /// markers 一旦移除，第二輪 `insertPageCounters` 已經沒有頁碼依據，counter 插錯位置也會通過
    /// （Codex R4 MEDIUM）。counter 本身的冪等性由上方的 page-counter fuzz 與定向測試負責。
    ///
    /// 另外加兩個不經 `LaTeXSourceScan` 的判準，讓 scanner 誤判也會被抓到：
    /// - strip 後的各行是 strip 前各行的子序列，且被刪的每一行都是 `%% === Page N ===`；
    /// - 產生器裡放在 verbatim 內的假 marker 片段原封不動。
    func testStrippingMarkersAfterCountersIsStableAndOnlyRemovesMarkerLines() {
        var rng = SeededGenerator(state: 0x5EED_0010)
        let normalizer = LaTeXNormalizer(stripPageMarkers: true)
        let markerLine = try! NSRegularExpression(pattern: #"^%% === Page \d+ ===\r?$"#)
        let verbatimSnippet = "\\begin{verbatim}\n%% === Page 99 ===\n\\chapter{Fake}\n\\end{verbatim}"
        for index in 0..<2000 {
            let source = makeDocument(&rng)
            let counted = LaTeXNormalizer.insertPageCounters(source)
            let first = normalizer.removePageMarkers(counted)
            let second = normalizer.removePageMarkers(LaTeXNormalizer.insertPageCounters(first))
            XCTAssertEqual(second, first, "case \(index):\n\(source.debugDescription)")

            let kept = first.components(separatedBy: "\n")
            var cursor = kept.startIndex
            for line in counted.components(separatedBy: "\n") {
                if cursor < kept.endIndex, kept[cursor] == line {
                    cursor += 1
                    continue
                }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNotNil(markerLine.firstMatch(in: line, range: range),
                                "case \(index): strip 刪掉了非 marker 行 \(line.debugDescription)")
            }
            XCTAssertEqual(cursor, kept.endIndex, "case \(index): strip 後出現原本沒有的行")

            let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
            let snippet = verbatimSnippet.replacingOccurrences(of: "\n", with: lineEnding)
            if counted.contains(snippet) {
                XCTAssertTrue(first.contains(snippet), "case \(index): verbatim 內的假 marker 被刪")
            }
        }
    }

    // MARK: - Figure widths

    /// 把結果與原文逐字對齊，只允許插入 `[width=…]`、`,width=…`、`width=…`；回傳插入次數，
    /// 對不上時回傳 -1。
    private func insertionCount(source: String, result: String) -> Int {
        let inserts = ["[width=0.5\\textwidth]", ",width=0.5\\textwidth", "width=0.5\\textwidth"].map { Array($0.utf16) }
        let a = Array(source.utf16)
        let b = Array(result.utf16)
        var i = 0
        var j = 0
        var count = 0
        while j < b.count {
            if i < a.count && a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            guard let insert = inserts.first(where: { j + $0.count <= b.count && Array(b[j..<(j + $0.count)]) == $0 }) else {
                return -1
            }
            j += insert.count
            count += 1
        }
        return i == a.count ? count : -1
    }

    private static let optionFragments = [
        "", "[]", "[clip]", "[clip % note\n]", "[angle=90,% width=3cm\n]", "[wid% c\n  th=3cm]",
        "[trim={1, 2, 3, 4}, clip]", "[alt={a]b}]", "[width=2cm]", "[% only\n]", "[scale=5]",
    ]

    func testFigureWidthsAreIdempotentAndOnlyAddAWidthOption() throws {
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir.appendingPathComponent("figures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir.appendingPathComponent("responses"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }
        let manifest = ProjectManifest(
            schemaVersion: 1, createdAt: "", updatedAt: "", projectName: "fuzz", sourcePDF: "", projectRoot: projectDir.path,
            pages: (1...40).map { PageRecord(number: $0, width: 612, height: 792, rotation: 0, renderedImagePath: nil, renderedDPI: nil) },
            blocks: []
        )
        try ManifestStore().save(manifest, to: projectDir.appendingPathComponent("manifest.json"))
        let response = PageTranscriptionResponse(pages: (1...40).map {
            PageResult(page: $0, latex: "", figures: [FigureRegion(id: "fig", bbox: [0.1, 0.1, 0.5, 0.2], caption: nil)],
                       confidence: nil, notes: nil)
        })
        try JSONEncoder().encode(response).write(to: projectDir.appendingPathComponent("responses/all.json"))
        try Data([0]).write(to: projectDir.appendingPathComponent("figures/fig.png"))

        var rng = SeededGenerator(state: 0x5EED_0011)
        for index in 0..<2000 {
            var lines: [String] = []
            var page = 1
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    page += 1
                    lines.append("%% === Page \(page) ===")
                case 1:
                    lines.append("\\begin{verbatim}\n\\includegraphics{figures/fig.png}\n\\end{verbatim}")
                default:
                    let calls = (0..<Int.random(in: 1...2, using: &rng)).map { _ -> String in
                        let star = Bool.random(using: &rng) ? "*" : ""
                        let options = Self.optionFragments.randomElement(using: &rng)!
                        return "\\includegraphics\(star)\(options){figures/fig.png}"
                    }
                    lines.append(calls.joined(separator: Bool.random(using: &rng) ? "\\hfill" : " "))
                }
            }
            let source = lines.joined(separator: "\n")
            let first = LaTeXNormalizer.applyFigureWidths(source, projectDir: projectDir)
            let second = LaTeXNormalizer.applyFigureWidths(first.result, projectDir: projectDir)
            let context = "case \(index):\n\(source.debugDescription)\n--- first ---\n\(first.result.debugDescription)"
            XCTAssertEqual(second.result, first.result, context)

            // 只多了 width 選項：結果 = 原文 + 每張套用的圖恰好一段插入；verbatim 區塊不變。
            let applied = first.resolutions.filter {
                if case .widthApplied = $0.outcome { return true }
                return false
            }.count
            XCTAssertEqual(insertionCount(source: source, result: first.result), applied, context)
            let block = "\\begin{verbatim}\n\\includegraphics{figures/fig.png}\n\\end{verbatim}"
            XCTAssertEqual(
                first.result.components(separatedBy: block).count, source.components(separatedBy: block).count, context
            )
        }
    }
}
