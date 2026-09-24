import XCTest
import PDFKit
@testable import PDFToLaTeXCore

/// 以 PDF page labels 還原頁碼（PsychQuant/macdoc#211）：marker 的 N 是實體頁序，label 才是書上印的頁碼。
final class LaTeXPageLabelTests: XCTestCase {

    // MARK: - Label parsing

    func testParsePageLabel_onlyArabicAndCanonicalRoman() {
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("12")?.style, .arabic)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("12")?.value, 12)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("0")?.value, 0)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("iv")?.style, .roman)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("iv")?.value, 4)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("XIV")?.style, .romanUpper)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("XIV")?.value, 14)
        XCTAssertEqual(LaTeXNormalizer.parsePageLabel("mmxxvi")?.value, 2026)
        for unsupported in ["", "iiii", "Iv", "A-1", "a", "1a", " 1", "\u{0663}", "99999999999999999999999"] {
            XCTAssertNil(LaTeXNormalizer.parsePageLabel(unsupported), unsupported.debugDescription)
        }
    }

    // MARK: - Counters from labels

    private static let frontMatterLabels = [1: "i", 2: "ii", 3: "iii", 4: "iv", 5: "1", 6: "2"]

    private static let frontMatterInput = """
    \\documentclass{book}
    \\begin{document}
    %% === Page 1 ===
    Title page.
    %% === Page 3 ===
    \\chapter*{Preface}
    Preface text.
    %% === Page 5 ===
    \\chapter{Introduction}
    Intro text.
    %% === Page 6 ===
    More intro.
    \\end{document}
    """

    /// 原始碼沒有任何切換指令、PDF 的 label 是 i–iv 接 1、2：第一頁進入 roman，章節處切回 arabic。
    func testRomanFrontMatterFromLabelsWithoutSourceSwitches() {
        let expected = """
        \\documentclass{book}
        \\begin{document}
        %% === Page 1 ===
        \\pagenumbering{roman}
        \\setcounter{page}{1}
        Title page.
        %% === Page 3 ===
        \\chapter*{Preface}
        \\setcounter{page}{3}
        Preface text.
        %% === Page 5 ===
        \\chapter{Introduction}
        \\pagenumbering{arabic}
        \\setcounter{page}{1}
        Intro text.
        %% === Page 6 ===
        More intro.
        \\end{document}
        """
        let first = LaTeXNormalizer.applyPageCounters(Self.frontMatterInput, pageLabels: Self.frontMatterLabels)
        XCTAssertEqual(first.result, expected)
        XCTAssertEqual(first.notes, [
            PageCounterNote(line: 3, kind: .numberingInserted(style: .roman)),
            PageCounterNote(line: 3, kind: .counterInserted(page: 1)),
            PageCounterNote(line: 6, kind: .counterInserted(page: 3)),
            PageCounterNote(line: 9, kind: .numberingInserted(style: .arabic)),
            PageCounterNote(line: 9, kind: .counterInserted(page: 1)),
        ])

        let second = LaTeXNormalizer.applyPageCounters(first.result, pageLabels: Self.frontMatterLabels)
        XCTAssertEqual(second.result, first.result)
        XCTAssertEqual(second.notes, [])
    }

    /// 原始碼已有 `\frontmatter`／`\mainmatter` 且與 label 一致：roman 區段也依 label 設定頁碼，
    /// arabic 區段用 label 的值而不是實體頁序。
    func testSourceSwitchesThatAgreeWithTheLabels() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        \\frontmatter
        \\chapter*{Preface}
        Preface text.
        %% === Page 9 ===
        \\mainmatter
        \\chapter{Intro}
        Intro text.
        \\end{document}
        """
        let labels = [1: "i", 9: "1"]
        let first = LaTeXNormalizer.applyPageCounters(input, pageLabels: labels)
        XCTAssertEqual(first.result, input
            .replacingOccurrences(of: "\\chapter*{Preface}\n", with: "\\chapter*{Preface}\n\\setcounter{page}{1}\n")
            .replacingOccurrences(of: "\\chapter{Intro}\n", with: "\\chapter{Intro}\n\\setcounter{page}{1}\n"))
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(first.result, pageLabels: labels).result, first.result)

        // 沒有 label：維持 #9 的行為（roman 區段不插入、arabic 用實體頁序）。
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(input).result, input
            .replacingOccurrences(of: "\\chapter{Intro}\n", with: "\\chapter{Intro}\n\\setcounter{page}{9}\n"))
    }

    /// label 與原始碼的切換指令不一致時以 label 為準：在指令之後補上 `\pagenumbering`。
    func testLabelOverridesADisagreeingSourceSwitch() {
        let input = "\\begin{document}\n%% === Page 4 ===\n\\mainmatter\nText.\n\\end{document}"
        let labels = [4: "iv"]
        let first = LaTeXNormalizer.applyPageCounters(input, pageLabels: labels)
        XCTAssertEqual(
            first.result,
            "\\begin{document}\n%% === Page 4 ===\n\\mainmatter\n\\pagenumbering{roman}\n\\setcounter{page}{4}\nText.\n\\end{document}"
        )
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(first.result, pageLabels: labels).result, first.result)
    }

    func testUppercaseRomanLabel() {
        let input = "\\begin{document}\n%% === Page 2 ===\n\\chapter*{Foreword}\nText.\n\\end{document}"
        let labels = [2: "II"]
        let first = LaTeXNormalizer.applyPageCounters(input, pageLabels: labels)
        XCTAssertEqual(
            first.result,
            "\\begin{document}\n%% === Page 2 ===\n\\chapter*{Foreword}\n\\pagenumbering{Roman}\n\\setcounter{page}{2}\nText.\n\\end{document}"
        )
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(first.result, pageLabels: labels).result, first.result)
    }

    /// 不是阿拉伯或羅馬數字的 label、以及 manifest 有 label 但這一頁沒有：該錨點不插入並回報，
    /// 不退回實體頁序（退回就是用猜的）。
    func testUnsupportedAndMissingLabelsAreReportedAndLeftAlone() {
        let input = """
        \\begin{document}
        %% === Page 1 ===
        Cover.
        %% === Page 2 ===
        \\chapter{Appendix}
        Text.
        %% === Page 3 ===
        \\chapter{Index}
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(input, pageLabels: [1: "", 2: "A-1", 4: "3"])
        XCTAssertEqual(report.result, input)
        XCTAssertEqual(report.notes, [
            PageCounterNote(line: 2, kind: .pageLabelUnsupported(page: 1, label: "")),
            PageCounterNote(line: 5, kind: .pageLabelUnsupported(page: 2, label: "A-1")),
            PageCounterNote(line: 8, kind: .pageLabelMissing(page: 3)),
        ])
    }

    /// 錨點之後已有 counter：沿用它的值（與 #9 相同），只在樣式不同時補上 `\pagenumbering`。
    func testExistingCountersAreKeptAndOnlyTheStyleIsAdded() {
        let input = """
        \\begin{document}
        %% === Page 3 ===
        \\chapter*{Preface}
        \\setcounter{page}{3}
        Text.
        %% === Page 7 ===
        \\chapter{One}
        \\setcounter{page}{7}
        Body.
        \\end{document}
        """
        let labels = [3: "iii", 7: "1"]
        let first = LaTeXNormalizer.applyPageCounters(input, pageLabels: labels)
        XCTAssertEqual(first.result, input
            .replacingOccurrences(of: "\\chapter*{Preface}\n", with: "\\chapter*{Preface}\n\\pagenumbering{roman}\n")
            .replacingOccurrences(of: "\\chapter{One}\n", with: "\\chapter{One}\n\\pagenumbering{arabic}\n"))
        XCTAssertEqual(first.notes.map(\.kind), [.numberingInserted(style: .roman), .numberingInserted(style: .arabic)])
        let second = LaTeXNormalizer.applyPageCounters(first.result, pageLabels: labels)
        XCTAssertEqual(second.result, first.result)
        XCTAssertEqual(second.notes, [])
    }

    /// 舊版放在章節前一行、值等於 label 的 counter：搬到章名之後，需要時連同樣式一起。
    func testLegacyCounterMatchingTheLabelIsMoved() {
        let input = "\\begin{document}\n%% === Page 3 ===\n\\setcounter{page}{3}\n\\chapter*{Preface}\nText.\n\\end{document}"
        let labels = [3: "iii"]
        let first = LaTeXNormalizer.applyPageCounters(input, pageLabels: labels)
        XCTAssertEqual(
            first.result,
            "\\begin{document}\n%% === Page 3 ===\n\\chapter*{Preface}\n\\pagenumbering{roman}\n\\setcounter{page}{3}\nText.\n\\end{document}"
        )
        XCTAssertEqual(first.notes.map(\.kind), [.numberingInserted(style: .roman), .legacyCounterMoved(page: 3)])
        XCTAssertEqual(LaTeXNormalizer.applyPageCounters(first.result, pageLabels: labels).result, first.result)
    }

    /// verbatim 內的假 marker 與假 `\chapter` 在 label 模式下同樣不存在。
    func testVerbatimIsInvisibleInLabelMode() {
        let input = """
        \\begin{document}
        %% === Page 2 ===
        Text.
        \\begin{verbatim}
        %% === Page 3 ===
        \\chapter{Fake}
        \\end{verbatim}
        \\end{document}
        """
        let report = LaTeXNormalizer.applyPageCounters(input, pageLabels: [2: "ii", 3: "1"])
        XCTAssertEqual(report.result, input.replacingOccurrences(
            of: "%% === Page 2 ===\n", with: "%% === Page 2 ===\n\\pagenumbering{roman}\n\\setcounter{page}{2}\n"
        ))
    }

    // MARK: - Fuzz

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static let inlineFragments = [
        "\\chapter{A}", "\\chapter*{B}", "\\chapter[S]{C}", "\\mainmatter", "\\frontmatter",
        "\\pagenumbering{arabic}", "\\pagenumbering{roman}", "\\pagenumbering{Roman}", "\\pagenumbering{alph}",
        "\\setcounter{page}{7}", "\\setcounter{page}{PAGE}", "\\setcounter{page}{PAGE}\n\\chapter{E}",
        "Text.", " ", "\\verb|\\chapter{V}|", "\\newcommand{\\x}{\\frontmatter}", "\\label{l}",
    ]

    private static let lineFragments = [
        "", "% plain comment",
        "\\begin{verbatim}\n%% === Page 99 ===\n\\chapter{Fake}\n\\end{verbatim}",
        "\\begin{comment}\n\\chapter{Fake}\n\\end{comment}",
        "\\chapter\n{Next line title}",
    ]

    /// 各頁的 label：前段 roman（小寫或大寫）、之後 arabic；偶爾有不支援的 label 或缺頁。
    private func makeLabels(_ rng: inout SeededGenerator) -> [Int: String] {
        let upper = Bool.random(using: &rng)
        let romanPages = Int.random(in: 0...12, using: &rng)
        let arabicStart = Int.random(in: 1...20, using: &rng)
        var labels: [Int: String] = [:]
        for page in 1...40 {
            if Int.random(in: 0..<25, using: &rng) == 0 { continue }
            if Int.random(in: 0..<25, using: &rng) == 0 {
                labels[page] = "A-\(page)"
                continue
            }
            if page <= romanPages {
                let roman = LaTeXNormalizer.romanNumeral(page)
                labels[page] = upper ? roman.uppercased() : roman
            } else {
                labels[page] = String(arabicStart + page - romanPages - 1)
            }
        }
        return labels
    }

    private func makeDocument(_ rng: inout SeededGenerator) -> String {
        var lines: [String] = []
        var page = Int.random(in: 1...5, using: &rng)
        for _ in 0..<Int.random(in: 1...12, using: &rng) {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...2:
                page += Int.random(in: 1...3, using: &rng)
                lines.append("%% === Page \(min(page, 40)) ===")
            case 3...7:
                let count = Int.random(in: 1...3, using: &rng)
                var line = (0..<count).map { _ in Self.inlineFragments.randomElement(using: &rng)! }.joined()
                    .replacingOccurrences(of: "PAGE", with: String(page))
                if Int.random(in: 0..<8, using: &rng) == 0 { line += " % trailing" }
                lines.append(line)
            default:
                lines.append(Self.lineFragments.randomElement(using: &rng)!)
            }
        }
        var document = "\\documentclass{book}\n\\begin{document}\n" + lines.joined(separator: "\n") + "\n\\end{document}"
        if Int.random(in: 0..<4, using: &rng) == 0 {
            document = document.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return document
    }

    func testLabelModeIsIdempotent() {
        var rng = SeededGenerator(state: 0x5EED_0211)
        for index in 0..<4000 {
            let source = makeDocument(&rng)
            let labels = makeLabels(&rng)
            let first = LaTeXNormalizer.applyPageCounters(source, pageLabels: labels)
            let second = LaTeXNormalizer.applyPageCounters(first.result, pageLabels: labels)
            let context = "case \(index):\n\(source.debugDescription)\nlabels: \(labels.sorted { $0.key < $1.key })\n--- first ---\n\(first.result.debugDescription)"
            XCTAssertEqual(second.result, first.result, context)
            XCTAssertFalse(second.notes.contains {
                switch $0.kind {
                case .counterInserted, .legacyCounterMoved, .numberingInserted: return true
                default: return false
                }
            }, context)
            if source.contains("\r\n") {
                XCTAssertFalse(first.result.replacingOccurrences(of: "\r\n", with: "").contains("\n"), context)
            }
            // verbatim 一字不動。
            XCTAssertEqual(LaTeXSourceScan(first.result).verbatimSegments, LaTeXSourceScan(source).verbatimSegments, context)
        }
    }

    // MARK: - normalizeProject

    private func makeProject(main: String, labels: [Int: String]?, pageCount: Int) throws -> (dir: URL, main: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            schemaVersion: 1, createdAt: "", updatedAt: "", projectName: "labels", sourcePDF: "",
            projectRoot: dir.path,
            pages: (1...pageCount).map {
                PageRecord(number: $0, width: 612, height: 792, rotation: 0,
                           renderedImagePath: nil, renderedDPI: nil, label: labels?[$0])
            },
            blocks: []
        )
        try ManifestStore().save(manifest, to: ProjectLayout.manifestURL(for: dir))
        let mainURL = dir.appendingPathComponent("accumulated.tex")
        try main.write(to: mainURL, atomically: true, encoding: .utf8)
        return (dir, mainURL)
    }

    /// 章節在實體第 6 頁（偶數）、印的是第 1 頁（奇數）：有 label 時用 1、不需要 openany；
    /// 沒有 label 時維持 #9 的 6，openany 照 #210 加上。
    private static let parityMain = """
    \\documentclass{book}
    \\begin{document}
    %% === Page 1 ===
    Title page.
    %% === Page 6 ===
    \\chapter{Introduction}
    Intro text.
    \\end{document}
    """

    func testNormalizeProject_usesManifestLabelsAndIsIdempotent() throws {
        let labels = [1: "i", 2: "ii", 3: "iii", 4: "iv", 5: "v", 6: "1"]
        let (dir, mainURL) = try makeProject(main: Self.parityMain, labels: labels, pageCount: 6)
        defer { try? FileManager.default.removeItem(at: dir) }

        let normalizer = LaTeXNormalizer()
        let report1 = try normalizer.normalizeProject(mainTexURL: mainURL)
        let first = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(first.contains("%% === Page 1 ===\n\\pagenumbering{roman}\n\\setcounter{page}{1}\nTitle page."))
        XCTAssertTrue(first.contains("\\chapter{Introduction}\n\\pagenumbering{arabic}\n\\setcounter{page}{1}\n"))
        XCTAssertEqual(report1.chapterOpening, .notNeeded)
        XCTAssertTrue(first.hasPrefix("\\documentclass{book}\n"))

        let report2 = try normalizer.normalizeProject(mainTexURL: mainURL)
        XCTAssertFalse(report2.mainFileChanged)
        XCTAssertEqual(try String(contentsOf: mainURL, encoding: .utf8), first)
    }

    func testNormalizeProject_withoutLabelsKeepsPhysicalPages() throws {
        let (dir, mainURL) = try makeProject(main: Self.parityMain, labels: nil, pageCount: 6)
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = try LaTeXNormalizer().normalizeProject(mainTexURL: mainURL)
        let result = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(result.contains("\\chapter{Introduction}\n\\setcounter{page}{6}\n"))
        XCTAssertFalse(result.contains("\\pagenumbering"))
        XCTAssertEqual(report.chapterOpening, .openAnyAdded)
    }

    /// 端到端：以程式產生的 PDF → PDFScanner → page records → manifest → normalizeProject。
    func testNormalizeProject_labelsFromAGeneratedPDF() throws {
        let pdfURL = try MinimalPDF.write(pageCount: 6, pageLabels: "<< /Nums [0 << /S /r >> 5 << /S /D >>] >>")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let (dir, mainURL) = try makeProject(main: Self.parityMain, labels: nil, pageCount: 6)
        defer { try? FileManager.default.removeItem(at: dir) }

        var manifest = try ManifestStore().load(from: ProjectLayout.manifestURL(for: dir))
        manifest.pages = ProjectBootstrap().pageRecords(from: try PDFScanner().scan(pdfAt: pdfURL))
        try ManifestStore().save(manifest, to: ProjectLayout.manifestURL(for: dir))

        _ = try LaTeXNormalizer().normalizeProject(mainTexURL: mainURL)
        let result = try String(contentsOf: mainURL, encoding: .utf8)
        XCTAssertTrue(result.contains("\\chapter{Introduction}\n\\pagenumbering{arabic}\n\\setcounter{page}{1}\n"))
    }

    // MARK: - pdflatex (gated)

    /// 實際編譯（需要 `RUN_PDFLATEX=1`）：label 模式的輸出，前五頁的頁碼標籤與原書的 label 相同
    /// （i、ii、iii、iv、1；ii 與 iv 是 openright 在奇數頁章節前補的空白頁）。
    func testPdflatex_labelModeReproducesTheOriginalPageLabels() throws {
        guard ProcessInfo.processInfo.environment["RUN_PDFLATEX"] == "1" else {
            throw XCTSkip("設定 RUN_PDFLATEX=1 才實際編譯")
        }
        let pdflatex = ProcessInfo.processInfo.environment["PDFLATEX"] ?? "/Library/TeX/texbin/pdflatex"
        guard FileManager.default.isExecutableFile(atPath: pdflatex) else { throw XCTSkip("找不到 \(pdflatex)") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LaTeXNormalizer.applyPageCounters(
            Self.frontMatterInput.replacingOccurrences(of: "\\begin{document}", with: "\\usepackage{hyperref}\n\\begin{document}"),
            pageLabels: Self.frontMatterLabels
        ).result
        let tex = dir.appendingPathComponent("labels.tex")
        try source.write(to: tex, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pdflatex)
        process.arguments = ["-interaction=nonstopmode", "-halt-on-error", tex.lastPathComponent]
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let pdf = try XCTUnwrap(PDFDocument(url: dir.appendingPathComponent("labels.pdf")))
        XCTAssertEqual((0..<pdf.pageCount).map { pdf.page(at: $0)?.label ?? "" }, ["i", "ii", "iii", "iv", "1"])
    }
}
