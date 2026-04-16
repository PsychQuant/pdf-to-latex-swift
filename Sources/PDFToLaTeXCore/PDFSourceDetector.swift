import Foundation
import PDFKit

// MARK: - Models

/// PDF 文件的來源格式。
public enum PDFSourceFormat: String, Codable, Sendable, CaseIterable {
    case latex       // pdfTeX, XeTeX, LuaTeX, dvipdfm(x)
    case word        // Microsoft Word, Pages, Google Docs
    case typst       // typst
    case designer    // Adobe InDesign, QuarkXPress
    case scanned     // 掃描件（無/少文字層）
    case unknown
}

/// LaTeX 引擎（僅當 source == .latex 時有意義）。
public enum LaTeXEngine: String, Codable, Sendable {
    case pdfTeX
    case xeTeX
    case luaTeX
    case dvipdfm     // dvipdfm / dvipdfmx
    case unknown
}

/// PDF 來源偵測結果。
public struct PDFSourceDetection: Codable, Sendable {
    public let format: PDFSourceFormat
    public let confidence: Double
    public let engine: LaTeXEngine?
    public let creator: String?
    public let producer: String?
    public let evidence: [String]

    public init(
        format: PDFSourceFormat,
        confidence: Double,
        engine: LaTeXEngine? = nil,
        creator: String? = nil,
        producer: String? = nil,
        evidence: [String]
    ) {
        self.format = format
        self.confidence = confidence
        self.engine = engine
        self.creator = creator
        self.producer = producer
        self.evidence = evidence
    }

    /// 單行摘要。
    public var summary: String {
        let engineStr = engine.map { " (\($0.rawValue))" } ?? ""
        return "\(format.rawValue)\(engineStr) [confidence: \(String(format: "%.0f%%", confidence * 100))]"
    }
}

// MARK: - Detector

/// 從 PDF metadata 和字型分析推斷原始文件的來源格式。
public struct PDFSourceDetector: Sendable {

    public init() {}

    /// 偵測 PDF 的來源格式。
    public func detect(from pdfURL: URL) -> PDFSourceDetection {
        guard let doc = PDFDocument(url: pdfURL) else {
            return PDFSourceDetection(
                format: .unknown, confidence: 0,
                evidence: ["Failed to open PDF"]
            )
        }

        var evidence: [String] = []
        var scores: [PDFSourceFormat: Double] = [:]

        // ── 1. Document Info metadata ────────────────────────────
        let (creator, producer) = Self.extractDocumentInfo(doc: doc)
        if let c = creator { evidence.append("Creator: \"\(c)\"") }
        if let p = producer { evidence.append("Producer: \"\(p)\"") }

        let (metaFormat, metaEngine, metaScore, metaEvidence) =
            Self.classifyFromMetadata(creator: creator, producer: producer)
        scores[metaFormat, default: 0] += metaScore
        evidence.append(contentsOf: metaEvidence)

        // ── 2. Font analysis ─────────────────────────────────────
        let fontNames = Self.collectFontNames(doc: doc, samplePages: 20)
        let (fontFormat, fontScore, fontEvidence) =
            Self.classifyFromFonts(fontNames)
        scores[fontFormat, default: 0] += fontScore
        evidence.append(contentsOf: fontEvidence)

        // ── 3. Text layer detection (scanned?) ───────────────────
        let (hasText, textEvidence) = Self.checkTextLayer(doc: doc)
        if !hasText {
            scores[.scanned, default: 0] += 0.6
        }
        evidence.append(contentsOf: textEvidence)

        // ── 4. Determine best format ─────────────────────────────
        let best = scores.max(by: { $0.value < $1.value })
        let format = best?.key ?? .unknown
        let confidence = min(1.0, best?.value ?? 0)

        // Engine is only meaningful for latex
        let engine: LaTeXEngine? = (format == .latex) ? metaEngine : nil

        return PDFSourceDetection(
            format: format,
            confidence: confidence,
            engine: engine,
            creator: creator,
            producer: producer,
            evidence: evidence
        )
    }

    // MARK: - Document Info Extraction

    /// 從 PDFDocument.documentAttributes 提取 Creator 和 Producer。
    static func extractDocumentInfo(doc: PDFDocument) -> (creator: String?, producer: String?) {
        guard let attrs = doc.documentAttributes else { return (nil, nil) }

        // PDFKit uses these keys
        let creator = attrs["Creator"] as? String
            ?? attrs[PDFDocumentAttribute.creatorAttribute] as? String
        let producer = attrs["Producer"] as? String
            ?? attrs[PDFDocumentAttribute.producerAttribute] as? String

        return (creator, producer)
    }

    // MARK: - Metadata Classification

    /// 從 Creator / Producer 字串推斷來源格式。
    static func classifyFromMetadata(
        creator: String?,
        producer: String?
    ) -> (format: PDFSourceFormat, engine: LaTeXEngine, score: Double, evidence: [String]) {
        let combined = [creator, producer].compactMap { $0?.lowercased() }
        var evidence: [String] = []

        // ── LaTeX engines ────────────────────────────────────────
        for s in combined {
            if s.contains("pdftex") || s.contains("pdflatex") {
                evidence.append("Metadata indicates pdfTeX")
                return (.latex, .pdfTeX, 0.9, evidence)
            }
            if s.contains("xetex") || s.contains("xelatex") {
                evidence.append("Metadata indicates XeTeX")
                return (.latex, .xeTeX, 0.9, evidence)
            }
            if s.contains("luatex") || s.contains("lualatex") {
                evidence.append("Metadata indicates LuaTeX")
                return (.latex, .luaTeX, 0.9, evidence)
            }
            if s.contains("dvipdfm") {
                evidence.append("Metadata indicates dvipdfm(x)")
                return (.latex, .dvipdfm, 0.9, evidence)
            }
            // Generic "TeX" (after checking specific engines)
            if s.contains("tex") && !s.contains("text") {
                evidence.append("Metadata contains 'TeX'")
                return (.latex, .unknown, 0.7, evidence)
            }
        }

        // ── Word / Office ────────────────────────────────────────
        for s in combined {
            if s.contains("microsoft word") || s.contains("microsoft office") {
                evidence.append("Metadata indicates Microsoft Word")
                return (.word, .unknown, 0.9, evidence)
            }
            if s.contains("pages") {
                evidence.append("Metadata indicates Apple Pages")
                return (.word, .unknown, 0.8, evidence)
            }
            if s.contains("google") {
                evidence.append("Metadata indicates Google Docs")
                return (.word, .unknown, 0.8, evidence)
            }
            if s.contains("libreoffice") || s.contains("openoffice") {
                evidence.append("Metadata indicates LibreOffice/OpenOffice")
                return (.word, .unknown, 0.85, evidence)
            }
        }

        // ── Typst ────────────────────────────────────────────────
        for s in combined {
            if s.contains("typst") {
                evidence.append("Metadata indicates typst")
                return (.typst, .unknown, 0.9, evidence)
            }
        }

        // ── Designer tools ───────────────────────────────────────
        for s in combined {
            if s.contains("indesign") {
                evidence.append("Metadata indicates Adobe InDesign")
                return (.designer, .unknown, 0.9, evidence)
            }
            if s.contains("quark") {
                evidence.append("Metadata indicates QuarkXPress")
                return (.designer, .unknown, 0.85, evidence)
            }
        }

        evidence.append("No recognizable software in metadata")
        return (.unknown, .unknown, 0, evidence)
    }

    // MARK: - Font-based Classification

    /// 從多頁取樣收集所有字型名稱。
    static func collectFontNames(doc: PDFDocument, samplePages: Int) -> [String: Int] {
        var counts: [String: Int] = [:]
        let total = doc.pageCount
        let step = max(1, total / samplePages)

        for idx in stride(from: 0, to: total, by: step) {
            guard let page = doc.page(at: idx) else { continue }
            for name in PDFMetadataExtractor.extractFontNames(from: page) {
                let stripped = PDFMetadataExtractor.stripSubsetPrefix(name)
                counts[stripped, default: 0] += 1
            }
        }
        return counts
    }

    /// 從字型名稱頻率推斷來源格式。
    static func classifyFromFonts(
        _ fontCounts: [String: Int]
    ) -> (format: PDFSourceFormat, score: Double, evidence: [String]) {
        var evidence: [String] = []

        // ── LaTeX fonts ──────────────────────────────────────────
        let latexPrefixes = [
            // Computer Modern (OT1)
            "CMR", "CMBX", "CMTI", "CMSL", "CMSS", "CMTT", "CMCSC",
            // Computer Modern Math
            "CMMI", "CMSY", "CMEX", "CMMIB", "CMBSY", "MSAM", "MSBM",
            // DC/EC (T1 Computer Modern)
            "DCR", "DCBX", "DCTI", "DCSL", "DCTT", "DCSS", "DCCSC",
            "ECR", "ECBX", "ECTI", "ECSL",
            // cm-super (SF)
            "SFRM", "SFBX", "SFTI", "SFSL", "SFTT", "SFSS",
            // Latin Modern
            "LMROMAN", "LMMONO", "LMSANS", "LMMATH",
        ]

        var latexFontCount = 0
        var latexFonts: [String] = []

        for (name, count) in fontCounts {
            let upper = name.uppercased()
            if latexPrefixes.contains(where: { upper.hasPrefix($0) }) {
                latexFontCount += count
                if latexFonts.count < 5 { latexFonts.append(name) }
            }
        }

        if latexFontCount > 0 {
            let ratio = Double(latexFontCount) / Double(fontCounts.values.reduce(0, +))
            evidence.append("LaTeX fonts detected: \(latexFonts.joined(separator: ", ")) (\(Int(ratio * 100))% of total)")
            if ratio > 0.3 {
                return (.latex, min(0.8, ratio), evidence)
            }
        }

        // ── Word/Office fonts ────────────────────────────────────
        let wordFonts = ["CALIBRI", "CAMBRIA", "ARIAL", "TIMESNEWROMAN",
                         "TIMES NEW ROMAN", "SEGOEUI", "VERDANA", "TAHOMA"]
        var wordFontCount = 0

        for (name, count) in fontCounts {
            let upper = name.uppercased().replacingOccurrences(of: "-", with: "")
            if wordFonts.contains(where: { upper.contains($0) }) {
                wordFontCount += count
            }
        }

        if wordFontCount > 0 {
            evidence.append("Office fonts detected (Calibri, Cambria, etc.)")
            return (.word, 0.6, evidence)
        }

        if fontCounts.isEmpty {
            evidence.append("No fonts found (possibly scanned)")
            return (.scanned, 0.4, evidence)
        }

        evidence.append("Fonts not recognized as LaTeX or Office")
        return (.unknown, 0, evidence)
    }

    // MARK: - Text Layer Detection

    /// 檢查前幾頁是否有文字層。
    static func checkTextLayer(doc: PDFDocument) -> (hasText: Bool, evidence: [String]) {
        let sampleCount = min(5, doc.pageCount)
        var pagesWithText = 0

        for i in 0..<sampleCount {
            guard let page = doc.page(at: i),
                  let text = page.string,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
                continue
            }
            pagesWithText += 1
        }

        let ratio = Double(pagesWithText) / Double(sampleCount)
        if ratio < 0.3 {
            return (false, ["Text layer sparse or absent (\(pagesWithText)/\(sampleCount) pages have text)"])
        }
        return (true, ["Text layer present (\(pagesWithText)/\(sampleCount) pages)"])
    }
}
