import Foundation
import PDFKit

// MARK: - Report Models

/// PDF 比較結果報告。
public struct PDFComparisonReport: Codable, Sendable {
    public let originalPath: String
    public let reproducedPath: String
    public let originalPages: Int
    public let reproducedPages: Int
    public let originalWords: Int
    public let reproducedWords: Int
    public let wordCoverage: Double
    public let reverseCoverage: Double
    public let textWordCoverage: Double
    public let mathWordCoverage: Double
    public let totalImagesOriginal: Int
    public let totalImagesReproduced: Int
    public let chapters: [ChapterComparison]
    public let missingChapters: [Int]
    public let averageCoverage: Double
    public let averageSimilarity: Double
    public let typography: TypographyComparison?
    public let drillDown: [ChapterDrillDown]
}

/// 單章比較結果。
public struct ChapterComparison: Codable, Sendable {
    public let chapter: Int
    public let title: String
    public let origPages: Int
    public let reprPages: Int
    public let wordCoverage: Double
    public let sequenceSimilarity: Double
    public let status: String?
}

/// 字型排版比較結果。
public struct TypographyComparison: Codable, Sendable {
    public let origPaperSize: String
    public let reprPaperSize: String
    public let origFontFamily: String
    public let reprFontFamily: String
    public let origBodyFontSize: Double
    public let reprBodyFontSize: Double
    public let origFontNames: [String: Int]
    public let reprFontNames: [String: Int]
}

/// 低相似度章節的子區段分析。
public struct ChapterDrillDown: Codable, Sendable {
    public let chapter: Int
    public let title: String
    public let segments: [SegmentComparison]
}

/// 子區段比較。
public struct SegmentComparison: Codable, Sendable {
    public let pageRange: String
    public let wordCoverage: Double
    public let sequenceSimilarity: Double
}

// MARK: - PDFComparator

/// 章節對齊式 PDF 比較器。使用 PDFKit 原生提取文字。
public struct PDFComparator: Sendable {

    public init() {}

    /// 比較兩份 PDF，輸出報告到 console 並可選存成 JSON。
    public func compare(
        originalURL: URL,
        reproducedURL: URL,
        outputDir: URL? = nil
    ) throws -> PDFComparisonReport {
        guard let docOrig = PDFDocument(url: originalURL) else {
            throw ComparisonError.cannotOpen(originalURL.path)
        }
        guard let docRepr = PDFDocument(url: reproducedURL) else {
            throw ComparisonError.cannotOpen(reproducedURL.path)
        }

        let nOrig = docOrig.pageCount
        let nRepr = docRepr.pageCount

        // ─── 1. Basic Stats ───────────────────────────────────
        printHeader("1. BASIC STATISTICS")
        print("  Original:   \(nOrig) pages")
        print("  Reproduced: \(nRepr) pages")
        let pageDiff = nRepr - nOrig
        let pageRatio = Double(nRepr) / Double(nOrig)
        print("  Difference: \(pageDiff > 0 ? "+" : "")\(pageDiff) pages (\(pct(pageRatio)))")

        let allTextOrig = extractAllText(doc: docOrig)
        let allTextRepr = extractAllText(doc: docRepr)
        let wordsOrig = allTextOrig.split(whereSeparator: \.isWhitespace).count
        let wordsRepr = allTextRepr.split(whereSeparator: \.isWhitespace).count

        print("\n  Total words:  orig=\(fmt(wordsOrig))  repr=\(fmt(wordsRepr))  (\(pct(Double(wordsRepr)/Double(wordsOrig))))")

        let imgOrig = countTotalImages(doc: docOrig)
        let imgRepr = countTotalImages(doc: docRepr)
        print("  Total images: orig=\(imgOrig)  repr=\(imgRepr)")

        // ─── 2. Full-Text Coverage ───────────────────────────
        printHeader("2. FULL-TEXT COVERAGE (bag-of-words)")
        let normOrig = normalizeText(allTextOrig)
        let normRepr = normalizeText(allTextRepr)
        let wordsSetO = Set(normOrig.split(separator: " ").map(String.init))
        let wordsSetR = Set(normRepr.split(separator: " ").map(String.init))

        let coverage = wordSetCoverage(wordsSetO, wordsSetR)
        let revCoverage = wordSetCoverage(wordsSetR, wordsSetO)

        print("  Word coverage: \(pct(coverage)) of original words found in reproduced")
        print("  Reverse coverage: \(pct(revCoverage)) of reproduced words found in original")

        let onlyOrig = wordsSetO.subtracting(wordsSetR)
        let onlyRepr = wordsSetR.subtracting(wordsSetO)
        print("\n  Unique vocabulary: orig=\(fmt(wordsSetO.count))  repr=\(fmt(wordsSetR.count))")
        print("  Words only in original:   \(fmt(onlyOrig.count))")
        print("  Words only in reproduced: \(fmt(onlyRepr.count))")

        if !onlyOrig.isEmpty {
            let sample = onlyOrig.sorted().prefix(10).joined(separator: ", ")
            print("  Sample missing words: \(sample)")
        }

        // ─── 2b. Math vs Text Coverage ──────────────────────
        let (mathSetO, textSetO) = splitMathText(wordsSetO)
        let (mathSetR, textSetR) = splitMathText(wordsSetR)

        let textCov = wordSetCoverage(textSetO, textSetR)
        let mathCov = wordSetCoverage(mathSetO, mathSetR)

        print("\n  Text-only coverage: \(pct(textCov)) (\(fmt(textSetO.count)) text words)")
        print("  Math-only coverage: \(pct(mathCov)) (\(fmt(mathSetO.count)) math-like tokens)")

        let mathOnlyOrig = mathSetO.subtracting(mathSetR)
        if !mathOnlyOrig.isEmpty {
            let sample = mathOnlyOrig.sorted().prefix(10).joined(separator: ", ")
            print("  Sample missing math: \(sample)")
        }

        // ─── 2c. Character-Level Similarity ──────────────────
        // 字元層級比對：移除所有空白後比較，不受 tokenization 差異影響
        let charOriginal = stripWhitespace(normOrig)
        let charReproduced = stripWhitespace(normRepr)
        let charCoverage = characterBigramCoverage(charOriginal, charReproduced)
        let charRevCov = characterBigramCoverage(charReproduced, charOriginal)
        print("\n  Char-level similarity (bigram): \(pct(charCoverage)) orig→repr,  \(pct(charRevCov)) repr→orig")

        // ─── 3. Chapter-Aligned Comparison ───────────────────
        printHeader("3. CHAPTER-ALIGNED COMPARISON")

        let chOrig = findChapterStarts(doc: docOrig)
        let chRepr = findChapterStarts(doc: docRepr)
        print("  Chapters found: orig=\(chOrig.count)  repr=\(chRepr.count)")

        let rangesOrig = chapterRanges(chOrig, totalPages: nOrig)
        let rangesRepr = chapterRanges(chRepr, totalPages: nRepr)

        let origMap = Dictionary(rangesOrig.map { ($0.chNum, $0) }, uniquingKeysWith: { a, _ in a })
        let reprMap = Dictionary(rangesRepr.map { ($0.chNum, $0) }, uniquingKeysWith: { a, _ in a })
        let allChNums = Set(origMap.keys).union(reprMap.keys).sorted()

        // Table header
        print("\n  \(pad("Ch", 3))  \(padR("Title", 35))  \(pad("Orig", 10))  \(pad("Repr", 10))  \(pad("Coverage", 9))  \(pad("SeqSim", 8))  \(pad("CharSim", 8))")
        print("  \(String(repeating: "─", count: 3))  \(String(repeating: "─", count: 35))  \(String(repeating: "─", count: 10))  \(String(repeating: "─", count: 10))  \(String(repeating: "─", count: 9))  \(String(repeating: "─", count: 8))  \(String(repeating: "─", count: 8))")

        var chapterResults: [ChapterComparison] = []

        for chNum in allChNums {
            let oRange = origMap[chNum]
            let rRange = reprMap[chNum]

            if let o = oRange, let r = rRange {
                let textO = extractChapterText(doc: docOrig, start: o.startPage, end: o.endPage)
                let textR = extractChapterText(doc: docRepr, start: r.startPage, end: r.endPage)

                let cov = wordSetCoverageFromText(textO, textR)
                let sim = sequenceSimilarity(textO, textR)

                // Char-level bigram similarity (robust to tokenization)
                let normO = normalizeText(textO)
                let normR = normalizeText(textR)
                let charSim = characterBigramCoverage(stripWhitespace(normO), stripWhitespace(normR))

                let origPP = "\(o.endPage - o.startPage) pp"
                let reprPP = "\(r.endPage - r.startPage) pp"
                let title = String(o.title.prefix(35))

                print("  \(pad("\(chNum)", 3))  \(padR(title, 35))  \(pad(origPP, 10))  \(pad(reprPP, 10))  \(pad(pct(cov), 8))  \(pad(pct(sim), 7))  \(pad(pct(charSim), 7))")

                chapterResults.append(ChapterComparison(
                    chapter: chNum, title: o.title,
                    origPages: o.endPage - o.startPage,
                    reprPages: r.endPage - r.startPage,
                    wordCoverage: round4(cov),
                    sequenceSimilarity: round4(sim),
                    status: nil
                ))
            } else if let o = oRange {
                let title = String(o.title.prefix(35))
                let origPP = "\(o.endPage - o.startPage) pp"
                print("  \(pad("\(chNum)", 3))  \(padR(title, 35))  \(pad(origPP, 10))  \(pad("MISSING", 10))  \(pad("N/A", 9))  \(pad("N/A", 8))")
                chapterResults.append(ChapterComparison(
                    chapter: chNum, title: o.title,
                    origPages: o.endPage - o.startPage, reprPages: 0,
                    wordCoverage: 0, sequenceSimilarity: 0,
                    status: "missing_in_reproduced"
                ))
            } else if let r = rRange {
                let title = String(r.title.prefix(35))
                let reprPP = "\(r.endPage - r.startPage) pp"
                print("  \(pad("\(chNum)", 3))  \(padR(title, 35))  \(pad("MISSING", 10))  \(pad(reprPP, 10))  \(pad("N/A", 9))  \(pad("N/A", 8))")
            }
        }

        let validChapters = chapterResults.filter { $0.status == nil }
        let avgCov = validChapters.isEmpty ? 0 :
            validChapters.map(\.wordCoverage).reduce(0, +) / Double(validChapters.count)
        let avgSim = validChapters.isEmpty ? 0 :
            validChapters.map(\.sequenceSimilarity).reduce(0, +) / Double(validChapters.count)

        if !validChapters.isEmpty {
            print("\n  Average coverage:   \(pct(avgCov))")
            print("  Average similarity: \(pct(avgSim))")
        }

        // ─── 4. Content Gaps ─────────────────────────────────
        printHeader("4. CONTENT GAPS ANALYSIS")

        let origChNums = Set(origMap.keys)
        let reprChNums = Set(reprMap.keys)
        let missing = origChNums.subtracting(reprChNums).sorted()

        if missing.isEmpty {
            print("\n  No missing chapters (all \(origChNums.count) original chapters present)")
        } else {
            print("\n  Missing chapters: \(missing)")
            for ch in missing {
                if let r = origMap[ch] {
                    print("    Chapter \(ch): \(r.title) (\(r.endPage - r.startPage) pages)")
                }
            }
        }

        let frontOrig = chOrig.first?.page ?? 0
        let frontRepr = chRepr.first?.page ?? 0
        print("\n  Front matter: orig=\(frontOrig) pages  repr=\(frontRepr) pages")

        // ─── 5. Font & Typography ──────────────────────────
        printHeader("5. FONT & TYPOGRAPHY COMPARISON")

        let extractor = PDFMetadataExtractor()
        let metaOrig = extractor.extract(from: originalURL)
        let metaRepr = extractor.extract(from: reproducedURL)

        var typoComparison: TypographyComparison?

        if let mo = metaOrig, let mr = metaRepr {
            let paperMatch = mo.paperSize == mr.paperSize ? "MATCH" : "MISMATCH"
            let fontMatch = mo.dominantFontFamily == mr.dominantFontFamily ? "MATCH" : "MISMATCH"

            let sizeMatch = mo.bodyFontSizePt == mr.bodyFontSizePt ? "MATCH" : "MISMATCH"

            let encMatch = mo.fontEncoding == mr.fontEncoding ? "MATCH" : "MISMATCH"

            print("  Paper size:  orig=\(mo.paperSize.rawValue)  repr=\(mr.paperSize.rawValue)  [\(paperMatch)]")
            print("  Font family: orig=\(mo.dominantFontFamily.rawValue)  repr=\(mr.dominantFontFamily.rawValue)  [\(fontMatch)]")
            print("  Encoding:    orig=\(mo.fontEncoding.rawValue)  repr=\(mr.fontEncoding.rawValue)  [\(encMatch)]")
            print("  Body size:   orig=\(mo.bodyFontSizePt)pt  repr=\(mr.bodyFontSizePt)pt  [\(sizeMatch)]")

            // 邊距比較
            if let moMargins = mo.margins {
                print(String(format: "\n  Margins (original):  top=%.2fin  bottom=%.2fin  left=%.2fin  right=%.2fin",
                             moMargins.top, moMargins.bottom, moMargins.left, moMargins.right))
                print("  Geometry hint: \\usepackage[\(moMargins.geometryString)]{geometry}")
            }
            if let mrMargins = mr.margins {
                print(String(format: "  Margins (reproduced): top=%.2fin  bottom=%.2fin  left=%.2fin  right=%.2fin",
                             mrMargins.top, mrMargins.bottom, mrMargins.left, mrMargins.right))
            }

            // Detailed font name inventory
            let fontsOrig = collectAllFontNames(doc: docOrig)
            let fontsRepr = collectAllFontNames(doc: docRepr)

            let origFontFamilies = groupFontFamilies(fontsOrig)
            let reprFontFamilies = groupFontFamilies(fontsRepr)

            print("\n  Font inventory (original): \(fontsOrig.count) unique fonts")
            for (family, count) in origFontFamilies.sorted(by: { $0.value > $1.value }).prefix(8) {
                print("    \(padR(family, 30))  \(count)x")
            }

            print("\n  Font inventory (reproduced): \(fontsRepr.count) unique fonts")
            for (family, count) in reprFontFamilies.sorted(by: { $0.value > $1.value }).prefix(8) {
                print("    \(padR(family, 30))  \(count)x")
            }

            // Case-insensitive comparison (PDF font names vary in case across engines)
            let origKeysLower = Set(fontsOrig.keys.map { $0.lowercased() })
            let reprKeysLower = Set(fontsRepr.keys.map { $0.lowercased() })
            let onlyInOrig = fontsOrig.keys.filter { !reprKeysLower.contains($0.lowercased()) }.sorted()
            let onlyInRepr = fontsRepr.keys.filter { !origKeysLower.contains($0.lowercased()) }.sorted()
            let sharedCount = origKeysLower.intersection(reprKeysLower).count
            if sharedCount > 0 {
                print("\n  Shared fonts (case-insensitive): \(sharedCount)")
            }
            if !onlyInOrig.isEmpty {
                print("  Fonts only in original (\(onlyInOrig.count)):")
                for f in onlyInOrig.prefix(10) {
                    print("    \(f)")
                }
            }
            if !onlyInRepr.isEmpty {
                print("  Fonts only in reproduced (\(onlyInRepr.count)):")
                for f in onlyInRepr.prefix(10) {
                    print("    \(f)")
                }
            }

            typoComparison = TypographyComparison(
                origPaperSize: mo.paperSize.rawValue,
                reprPaperSize: mr.paperSize.rawValue,
                origFontFamily: mo.dominantFontFamily.rawValue,
                reprFontFamily: mr.dominantFontFamily.rawValue,
                origBodyFontSize: mo.bodyFontSizePt,
                reprBodyFontSize: mr.bodyFontSizePt,
                origFontNames: fontsOrig,
                reprFontNames: fontsRepr
            )
        } else {
            print("  Could not extract typography metadata.")
        }

        // ─── 6. Low-Similarity Drill-Down ───────────────────
        let lowSimThreshold = 0.60
        let lowSimChapters = chapterResults.filter {
            $0.status == nil && $0.sequenceSimilarity < lowSimThreshold
        }

        var drillDownResults: [ChapterDrillDown] = []

        if !lowSimChapters.isEmpty {
            printHeader("6. LOW-SIMILARITY DRILL-DOWN (SeqSim < \(pct(lowSimThreshold)))")

            for ch in lowSimChapters {
                guard let oRange = origMap[ch.chapter],
                      let rRange = reprMap[ch.chapter] else { continue }

                print("\n  Chapter \(ch.chapter): \(ch.title) (overall \(pct(ch.sequenceSimilarity)))")

                let segSize = 5  // 每 5 頁一段
                let oPages = oRange.endPage - oRange.startPage
                let rPages = rRange.endPage - rRange.startPage
                let nSegs = max(1, oPages / segSize)

                var segments: [SegmentComparison] = []

                print("    \(padR("Segment", 20))  \(pad("Coverage", 9))  \(pad("SeqSim", 8))")
                print("    \(String(repeating: "─", count: 20))  \(String(repeating: "─", count: 9))  \(String(repeating: "─", count: 8))")

                for si in 0..<nSegs {
                    let oStart = oRange.startPage + si * oPages / nSegs
                    let oEnd = si + 1 < nSegs
                        ? oRange.startPage + (si + 1) * oPages / nSegs
                        : oRange.endPage
                    let rStart = rRange.startPage + si * rPages / nSegs
                    let rEnd = si + 1 < nSegs
                        ? rRange.startPage + (si + 1) * rPages / nSegs
                        : rRange.endPage

                    let textO = extractChapterText(doc: docOrig, start: oStart, end: oEnd)
                    let textR = extractChapterText(doc: docRepr, start: rStart, end: rEnd)

                    let cov = wordSetCoverageFromText(textO, textR)
                    let sim = sequenceSimilarity(textO, textR)

                    let label = "pp \(oStart - oRange.startPage + 1)-\(oEnd - oRange.startPage)"
                    print("    \(padR(label, 20))  \(pad(pct(cov), 9))  \(pad(pct(sim), 8))")

                    segments.append(SegmentComparison(
                        pageRange: label,
                        wordCoverage: round4(cov),
                        sequenceSimilarity: round4(sim)
                    ))
                }

                // 找最差區段
                if let worst = segments.min(by: { $0.sequenceSimilarity < $1.sequenceSimilarity }) {
                    print("    → Worst segment: \(worst.pageRange) (\(pct(worst.sequenceSimilarity)))")
                }

                drillDownResults.append(ChapterDrillDown(
                    chapter: ch.chapter, title: ch.title, segments: segments
                ))
            }
        }

        // ─── Summary ──────────────────────────────────────
        printHeader("SUMMARY")
        print("  Page ratio:     \(nRepr)/\(nOrig) = \(pct(pageRatio))")
        print("  Word ratio:     \(fmt(wordsRepr))/\(fmt(wordsOrig)) = \(pct(Double(wordsRepr)/Double(wordsOrig)))")
        print("  Word coverage:  \(pct(coverage)) (overall)  text=\(pct(textCov))  math=\(pct(mathCov))")
        if !validChapters.isEmpty {
            print("  Avg ch coverage: \(pct(avgCov))")
            print("  Avg ch sequence: \(pct(avgSim))")
        }
        if missing.isEmpty {
            print("  All chapters present")
        } else {
            print("  Missing chapters: \(missing)")
        }
        if let tc = typoComparison {
            let paperOk = tc.origPaperSize == tc.reprPaperSize ? "OK" : "MISMATCH"
            let fontOk = tc.origFontFamily == tc.reprFontFamily ? "OK" : "MISMATCH"
            print("  Paper: \(paperOk)  Font: \(fontOk)")
        }
        print("  Images: \(imgRepr) (reproduced) vs \(imgOrig) (original embedded)")
        if !lowSimChapters.isEmpty {
            let chNums = lowSimChapters.map { "\($0.chapter)" }.joined(separator: ", ")
            print("  Low-similarity chapters: \(chNums)")
        }

        // Build report
        let report = PDFComparisonReport(
            originalPath: originalURL.path,
            reproducedPath: reproducedURL.path,
            originalPages: nOrig,
            reproducedPages: nRepr,
            originalWords: wordsOrig,
            reproducedWords: wordsRepr,
            wordCoverage: round4(coverage),
            reverseCoverage: round4(revCoverage),
            textWordCoverage: round4(textCov),
            mathWordCoverage: round4(mathCov),
            totalImagesOriginal: imgOrig,
            totalImagesReproduced: imgRepr,
            chapters: chapterResults,
            missingChapters: missing,
            averageCoverage: round4(avgCov),
            averageSimilarity: round4(avgSim),
            typography: typoComparison,
            drillDown: drillDownResults
        )

        // Save JSON
        if let outDir = outputDir {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let reportURL = outDir.appendingPathComponent("comparison_report.json")
            try data.write(to: reportURL)
            print("\n  Report saved: \(reportURL.path)")
        }

        return report
    }

    // MARK: - Text Extraction

    /// 提取整份 PDF 的全部文字。
    func extractAllText(doc: PDFDocument) -> String {
        var texts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string {
                texts.append(text)
            }
        }
        return texts.joined(separator: "\n")
    }

    /// 提取指定頁面範圍的文字，過濾 running header。
    func extractChapterText(doc: PDFDocument, start: Int, end: Int) -> String {
        var texts: [String] = []
        for i in start..<end {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let lines = text.components(separatedBy: "\n")
            let filtered = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.range(of: #"^CHAPTER\s+\d+\.\s+"#,
                                 options: .regularExpression, range: nil, locale: nil) != nil {
                    return false
                }
                return true
            }
            texts.append(filtered.joined(separator: "\n"))
        }
        return texts.joined(separator: "\n")
    }

    // MARK: - Chapter Detection

    struct ChapterStart {
        let page: Int
        let chNum: Int
        let title: String
    }

    struct ChapterRange {
        let chNum: Int
        let title: String
        let startPage: Int
        let endPage: Int
    }

    /// 偵測章節起始頁。搜尋 "Chapter N" 獨立行。
    func findChapterStarts(doc: PDFDocument) -> [ChapterStart] {
        var chapters: [ChapterStart] = []
        var seen: Set<Int> = []
        let chapterPattern = try! NSRegularExpression(
            pattern: #"^Chapter\s+(\d+)$"#, options: .caseInsensitive)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let lines = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            for (lineIdx, line) in lines.enumerated() {
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                guard let match = chapterPattern.firstMatch(in: line, range: range) else { continue }

                let chNum = Int(nsLine.substring(with: match.range(at: 1)))!
                guard !seen.contains(chNum) else { continue }

                let title: String
                if lineIdx + 1 < lines.count {
                    title = lines[lineIdx + 1]
                } else {
                    title = "Chapter \(chNum)"
                }

                chapters.append(ChapterStart(page: i, chNum: chNum, title: title))
                seen.insert(chNum)
                break
            }
        }

        chapters.sort { $0.page < $1.page }
        return chapters
    }

    /// 將章節起始轉換為頁面範圍。
    func chapterRanges(_ chapters: [ChapterStart], totalPages: Int) -> [ChapterRange] {
        var ranges: [ChapterRange] = []
        for (idx, ch) in chapters.enumerated() {
            let end = idx + 1 < chapters.count ? chapters[idx + 1].page : totalPages
            ranges.append(ChapterRange(chNum: ch.chNum, title: ch.title,
                                       startPage: ch.page, endPage: end))
        }
        return ranges
    }

    // MARK: - Comparison Metrics

    /// 文字正規化：連字展開、數學符號統一、空白壓縮、轉小寫、噪音過濾。
    func normalizeText(_ text: String) -> String {
        var t = text

        // 1. 展開 PDF 連字
        let ligatures: [(String, String)] = [
            ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl")
        ]
        for (old, new) in ligatures {
            t = t.replacingOccurrences(of: old, with: new)
        }

        // 2. 統一數學符號的 Unicode 變體
        let mathNormalization: [(String, String)] = [
            ("−", "-"),      // U+2212 MINUS SIGN → U+002D HYPHEN-MINUS
            ("–", "-"),      // U+2013 EN DASH → HYPHEN
            ("—", "-"),      // U+2014 EM DASH → HYPHEN
            ("×", "x"),      // U+00D7 MULTIPLICATION SIGN → x
            ("·", "."),      // U+00B7 MIDDLE DOT → period
            ("′", "'"),      // U+2032 PRIME → apostrophe
            ("″", "''"),     // U+2033 DOUBLE PRIME
            ("≤", "<="),     // U+2264
            ("≥", ">="),     // U+2265
            ("≠", "!="),     // U+2260
            ("→", "->"),     // U+2192
            ("←", "<-"),     // U+2190
            ("⇒", "=>"),     // U+21D2
            ("\u{00A0}", " "),  // NO-BREAK SPACE → regular space
            ("\u{2009}", " "),  // THIN SPACE
            ("\u{200B}", ""),   // ZERO WIDTH SPACE → remove
            ("\u{FEFF}", ""),   // BOM → remove
        ]
        for (old, new) in mathNormalization {
            t = t.replacingOccurrences(of: old, with: new)
        }

        // 3. 壓縮空白、轉小寫、過濾噪音 token
        let words = t.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let filtered = words.filter { word in
            // 過濾純標點/符號碎片（如 "!", "!+", "!,"）
            let alphanumCount = word.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.count
            // 至少包含一個字母或數字
            return alphanumCount > 0
        }
        return filtered.joined(separator: " ").lowercased()
    }

    /// 將詞集分為「文字詞」和「數學記號」。
    /// 數學記號：含數字、含希臘字母、單字元、含運算符號的 token。
    func splitMathText(_ words: Set<String>) -> (math: Set<String>, text: Set<String>) {
        let mathChars = CharacterSet(charactersIn: "0123456789=+−×÷≤≥≠∞∑∫∂∇√∈∉⊂⊃∀∃∧∨¬⟹⟺→←↔≈≡∝∅∪∩")
        let greekRange = CharacterSet(charactersIn: "\u{0391}"..."\u{03C9}")  // Α-ω

        var math: Set<String> = []
        var text: Set<String> = []

        for word in words {
            let scalars = word.unicodeScalars
            let hasMathChar = scalars.contains { mathChars.contains($0) }
            let hasGreek = scalars.contains { greekRange.contains($0) }
            let isSingleChar = word.count == 1 && !word.first!.isLetter

            if hasMathChar || hasGreek || isSingleChar {
                math.insert(word)
            } else {
                text.insert(word)
            }
        }
        return (math, text)
    }

    /// Bag-of-words 覆蓋率。
    func wordSetCoverage(_ original: Set<String>, _ reproduced: Set<String>) -> Double {
        guard !original.isEmpty else { return reproduced.isEmpty ? 1.0 : 0.0 }
        let covered = original.intersection(reproduced)
        return Double(covered.count) / Double(original.count)
    }

    /// 移除字串中所有空白字元。
    func stripWhitespace(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map { String($0) }.joined()
    }

    /// 字元 bigram 覆蓋率：將字串拆成連續 2 字元 pair，計算覆蓋比例。
    /// 不受 tokenization/空格差異影響，能正確比對 "E (y | x)" vs "E(y|x)"。
    func characterBigramCoverage(_ textA: String, _ textB: String) -> Double {
        func bigrams(_ s: String) -> [String: Int] {
            let chars = Array(s)
            guard chars.count >= 2 else { return [:] }
            var counts: [String: Int] = [:]
            for i in 0..<(chars.count - 1) {
                let bg = String(chars[i]) + String(chars[i + 1])
                counts[bg, default: 0] += 1
            }
            return counts
        }

        let bA = bigrams(textA)
        let bB = bigrams(textB)
        guard !bA.isEmpty else { return bB.isEmpty ? 1.0 : 0.0 }

        // 計算 A 中有多少 bigram 在 B 中也出現（用 min count）
        var matched = 0
        var total = 0
        for (bg, countA) in bA {
            total += countA
            matched += min(countA, bB[bg, default: 0])
        }
        return Double(matched) / Double(total)
    }

    /// 從原始文字計算 bag-of-words 覆蓋率。
    func wordSetCoverageFromText(_ textA: String, _ textB: String) -> Double {
        let normA = normalizeText(textA)
        let normB = normalizeText(textB)
        let setA = Set(normA.split(separator: " ").map(String.init))
        let setB = Set(normB.split(separator: " ").map(String.init))
        return wordSetCoverage(setA, setB)
    }

    /// 詞級序列相似度。使用分塊 LCS 近似計算。
    func sequenceSimilarity(_ textA: String, _ textB: String, maxWords: Int = 50000) -> Double {
        let normA = normalizeText(textA)
        let normB = normalizeText(textB)
        var wordsA = normA.split(separator: " ").map(String.init)
        var wordsB = normB.split(separator: " ").map(String.init)

        if wordsA.isEmpty && wordsB.isEmpty { return 1.0 }
        if wordsA.isEmpty || wordsB.isEmpty { return 0.0 }

        if wordsA.count > maxWords {
            let step = wordsA.count / maxWords
            wordsA = stride(from: 0, to: wordsA.count, by: step).map { wordsA[$0] }
        }
        if wordsB.count > maxWords {
            let step = wordsB.count / maxWords
            wordsB = stride(from: 0, to: wordsB.count, by: step).map { wordsB[$0] }
        }

        let chunkSize = 200
        let totalChunks = max(1, min(wordsA.count, wordsB.count) / chunkSize)
        var totalMatches = 0
        var totalLength = 0

        for ci in 0..<totalChunks {
            let startA = ci * wordsA.count / totalChunks
            let endA = min(startA + chunkSize, wordsA.count)
            let startB = ci * wordsB.count / totalChunks
            let endB = min(startB + chunkSize, wordsB.count)

            let chunkA = Array(wordsA[startA..<endA])
            let chunkB = Array(wordsB[startB..<endB])

            let lcsLen = lcsLength(chunkA, chunkB)
            totalMatches += lcsLen
            totalLength += chunkA.count + chunkB.count
        }

        return totalLength > 0 ? Double(2 * totalMatches) / Double(totalLength) : 0
    }

    /// 最長公共子序列長度（動態規劃，空間 O(n)）。
    private func lcsLength(_ a: [String], _ b: [String]) -> Int {
        let m = a.count, n = b.count
        guard m > 0 && n > 0 else { return 0 }

        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            prev = curr
            curr = [Int](repeating: 0, count: n + 1)
        }
        return prev[n]
    }

    // MARK: - Font Analysis

    /// 收集 PDF 中所有唯一字型名稱及其出現頁數。
    func collectAllFontNames(doc: PDFDocument) -> [String: Int] {
        var fontCounts: [String: Int] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let names = PDFMetadataExtractor.extractFontNames(from: page)
            // 每頁每字型只計一次
            for name in Set(names) {
                let stripped = PDFMetadataExtractor.stripSubsetPrefix(name)
                fontCounts[stripped, default: 0] += 1
            }
        }
        return fontCounts
    }

    /// 將字型名稱分組為族群（取字母前綴，case-insensitive）。
    func groupFontFamilies(_ fonts: [String: Int]) -> [String: Int] {
        var families: [String: Int] = [:]
        for (name, count) in fonts {
            let key = extractFontFamilyKey(name).uppercased()
            families[key, default: 0] += count
        }
        return families
    }

    /// 從字型名稱提取 family key。
    private func extractFontFamilyKey(_ name: String) -> String {
        // 常見模式：Dcr10, Dcbx10, SFRM1095, CMMI10, LMRoman10-Regular
        // 移除數字後綴和 -Style 部分
        let cleaned = name.replacingOccurrences(
            of: #"[-].*$"#, with: "", options: .regularExpression)
        let withoutTrailingDigits = cleaned.replacingOccurrences(
            of: #"\d+$"#, with: "", options: .regularExpression)
        return withoutTrailingDigits.isEmpty ? name : withoutTrailingDigits
    }

    // MARK: - Image Counting

    /// 透過 CGPDFPage 的 XObject 資源計算嵌入圖片數。
    func countTotalImages(doc: PDFDocument) -> Int {
        var total = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let cgPage = page.pageRef,
                  let dict = cgPage.dictionary else { continue }

            var resourcesDict: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resourcesDict),
                  let resources = resourcesDict else { continue }

            var xObjectDict: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjectDict),
                  let xObjects = xObjectDict else { continue }

            CGPDFDictionaryApplyBlock(xObjects, { _, value, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(value, .stream, &stream),
                      let s = stream else { return true }
                let sDict = CGPDFStreamGetDictionary(s)
                var subtypeRef: UnsafePointer<CChar>?
                if let sd = sDict,
                   CGPDFDictionaryGetName(sd, "Subtype", &subtypeRef),
                   let ref = subtypeRef,
                   String(cString: ref) == "Image" {
                    total += 1
                }
                return true
            }, nil)
        }
        return total
    }

    // MARK: - Formatting Helpers

    private func printHeader(_ title: String) {
        let line = String(repeating: "─", count: 80)
        print("\n\(line)")
        print("  \(title)")
        print(line)
    }

    /// 右對齊填充。
    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    /// 左對齊填充。
    private func padR(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func fmt(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func round4(_ v: Double) -> Double {
        (v * 10000).rounded() / 10000
    }

    // MARK: - Errors

    enum ComparisonError: LocalizedError {
        case cannotOpen(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path):
                return "Cannot open PDF: \(path)"
            }
        }
    }
}
