import CoreGraphics
import Foundation
import PDFKit
import Vision

/// 快速掃描 PDF 結構：用 PDFKit 抽內嵌文字，解析 TOC，偵測章節分界和頁面 layout。
/// Vector PDF → PDFKit 直抽（< 2 秒）。Scanned PDF → Vision OCR（每頁 ~0.5 秒）。
public struct PDFStructureScanner: Sendable {
    public init() {}

    // MARK: - Data Types

    /// PDF 的類型。影響整個 pipeline 的處理方式。
    public enum PDFType: String, Codable, Sendable {
        case vector     // LaTeX/Word 生成，有內嵌文字層 → PDFKit 直抽（快、免費、100% 正確）
        case scanned    // 影印/掃描，頁面是圖片 → 需要 Vision OCR 或直接送 AI
        case mixed      // 部分頁面有文字、部分沒有
    }

    /// 頁面上的一個 text region。
    public struct PageRegion: Codable, Sendable {
        public enum RegionType: String, Codable, Sendable {
            case header          // 頁首（章節名 + 頁碼）
            case heading         // 小節標題（如 "2.19 Linear Predictor Error Variance"）
            case text            // 正文段落
            case equation        // 獨立公式
            case list            // 列表項
            case image           // 圖片區域（PDFKit 偵測到的非文字區域）
        }
        public let type: RegionType
        public let x: CGFloat
        public let y: CGFloat
        public let width: CGFloat
        public let height: CGFloat
        public let text: String
    }

    /// 單頁的 layout 分析結果。
    public struct PageLayout: Codable, Sendable {
        public let pageNumber: Int  // 物理頁碼 (1-based)
        public let pageWidth: CGFloat
        public let pageHeight: CGFloat
        public let regions: [PageRegion]
        public let charCount: Int
    }

    /// Document-level 結構（不含 per-page layouts，那些獨立存檔）。
    public struct DocumentStructure: Codable, Sendable {
        public let pdfType: PDFType
        public let pageOffset: Int
        public let chapters: [ChapterSpec]
        public let totalPages: Int
        /// PDF 來源格式偵測結果（可選，由 detect-source 寫入）。
        public var sourceDetection: PDFSourceDetection?
        /// 記憶體中暫存的 layouts（不序列化，用 StructureStore 逐頁讀寫）。
        public var pageLayouts: [PageLayout]

        enum CodingKeys: String, CodingKey {
            case pdfType, pageOffset, chapters, totalPages, sourceDetection
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pdfType = try c.decode(PDFType.self, forKey: .pdfType)
            pageOffset = try c.decode(Int.self, forKey: .pageOffset)
            chapters = try c.decode([ChapterSpec].self, forKey: .chapters)
            totalPages = try c.decode(Int.self, forKey: .totalPages)
            sourceDetection = try c.decodeIfPresent(PDFSourceDetection.self, forKey: .sourceDetection)
            pageLayouts = []  // 從 structure.json 載入時不含 layouts
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pdfType, forKey: .pdfType)
            try c.encode(pageOffset, forKey: .pageOffset)
            try c.encode(chapters, forKey: .chapters)
            try c.encode(totalPages, forKey: .totalPages)
            try c.encodeIfPresent(sourceDetection, forKey: .sourceDetection)
            // pageLayouts 不序列化到 structure.json（各頁獨立存檔）
        }

        public init(pdfType: PDFType, pageOffset: Int, chapters: [ChapterSpec], totalPages: Int, pageLayouts: [PageLayout], sourceDetection: PDFSourceDetection? = nil) {
            self.pdfType = pdfType
            self.pageOffset = pageOffset
            self.chapters = chapters
            self.totalPages = totalPages
            self.pageLayouts = pageLayouts
            self.sourceDetection = sourceDetection
        }
    }

    // MARK: - Public API

    /// 掃描 PDF 結構，回傳章節分界和頁面 offset。
    public func scan(pdfURL: URL) throws -> DocumentStructure {
        guard let document = PDFDocument(url: pdfURL) else {
            throw PDFToLaTeXError.pdfOpenFailed(pdfURL)
        }

        let totalPages = document.pageCount

        // Step 0: 偵測 PDF 類型（vector / scanned / mixed）
        let pdfType = detectPDFType(document: document)

        // Step 1: 從前 15 頁找 TOC（vector PDF 用 PDFKit 直抽）
        var tocEntries: [TOCEntry] = []
        var offset = 0
        var chapters: [ChapterSpec] = []

        if pdfType != .scanned {
            // Vector or mixed — PDFKit 文字可用
            let tocScanPages = min(15, totalPages)
            let tocText = (0..<tocScanPages).compactMap { i in
                document.page(at: i)?.string
            }
            tocEntries = parseTOC(pages: tocText)
            offset = detectPageOffset(document: document, tocEntries: tocEntries, totalPages: totalPages)
            chapters = buildChapterSpecs(entries: tocEntries, pageOffset: offset, totalPages: totalPages)
        } else {
            // Scanned — 用 Vision OCR 辨識前 15 頁文字，再解析 TOC
            let tocScanPages = min(15, totalPages)
            let tocText = (0..<tocScanPages).compactMap { i -> String? in
                guard let page = document.page(at: i),
                      let cgImage = renderPageToCGImage(page: page) else { return nil }
                return recognizeText(in: cgImage)
            }
            tocEntries = parseTOC(pages: tocText)
            offset = detectPageOffset(document: document, tocEntries: tocEntries, totalPages: totalPages)
            chapters = buildChapterSpecs(entries: tocEntries, pageOffset: offset, totalPages: totalPages)
        }

        // Step 2: 每頁 layout 分析
        let pageLayouts: [PageLayout]
        if pdfType != .scanned {
            // Vector — 用 PDFKit strip-scan（快速、精確）
            pageLayouts = (0..<totalPages).map { i -> PageLayout in
                guard let page = document.page(at: i) else {
                    return PageLayout(pageNumber: i + 1, pageWidth: 0, pageHeight: 0, regions: [], charCount: 0)
                }
                return analyzePageLayout(page: page, pageNumber: i + 1)
            }
        } else {
            // Scanned — 用 Vision OCR 辨識每頁文字和位置
            pageLayouts = (0..<totalPages).map { i -> PageLayout in
                guard let page = document.page(at: i) else {
                    return PageLayout(pageNumber: i + 1, pageWidth: 0, pageHeight: 0, regions: [], charCount: 0)
                }
                return analyzePageLayoutWithOCR(page: page, pageNumber: i + 1)
            }
        }

        return DocumentStructure(
            pdfType: pdfType,
            pageOffset: offset,
            chapters: chapters,
            totalPages: totalPages,
            pageLayouts: pageLayouts
        )
    }

    /// 偵測 PDF 類型：抽樣幾頁看有沒有內嵌文字。
    func detectPDFType(document: PDFDocument) -> PDFType {
        let totalPages = document.pageCount
        // 抽樣：前 3 頁 + 中間 2 頁 + 後 2 頁
        var sampleIndices: [Int] = []
        for i in 0..<min(3, totalPages) { sampleIndices.append(i) }
        if totalPages > 10 {
            sampleIndices.append(totalPages / 3)
            sampleIndices.append(totalPages * 2 / 3)
        }
        if totalPages > 5 {
            sampleIndices.append(totalPages - 2)
            sampleIndices.append(totalPages - 1)
        }
        sampleIndices = Array(Set(sampleIndices)).filter { $0 >= 0 && $0 < totalPages }

        var hasText = 0
        var noText = 0

        for i in sampleIndices {
            let charCount = document.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            if charCount > 50 {
                hasText += 1
            } else {
                noText += 1
            }
        }

        if noText == 0 { return .vector }
        if hasText == 0 { return .scanned }
        return .mixed
    }

    /// 只掃描特定頁面的 layout（不做 TOC 解析）。自動偵測 PDF 類型選擇 PDFKit 或 Vision OCR。
    public func scanPageLayout(pdfURL: URL, pageNumber: Int) throws -> PageLayout {
        guard let document = PDFDocument(url: pdfURL) else {
            throw PDFToLaTeXError.pdfOpenFailed(pdfURL)
        }
        guard let page = document.page(at: pageNumber - 1) else {
            throw PDFToLaTeXError.pageUnavailable(pageNumber - 1)
        }
        let pdfType = detectPDFType(document: document)
        if pdfType == .scanned {
            return analyzePageLayoutWithOCR(page: page, pageNumber: pageNumber)
        }
        return analyzePageLayout(page: page, pageNumber: pageNumber)
    }

    // MARK: - Page Layout Analysis (PDFKit native)

    /// 用 PDFKit 的 selection(for:) strip-scan，以 X 範圍變化偵測 block 邊界。
    /// 正文是滿版寬，公式是窄且居中 — 用這個差異來分割。
    /// 同時嘗試用 `PDFContentExtractor` 提取字體資訊輔助分類。
    func analyzePageLayout(page: PDFPage, pageNumber: Int) -> PageLayout {
        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width
        let pageHeight = pageBounds.height
        let fullText = page.string ?? ""

        guard !fullText.isEmpty else {
            return PageLayout(pageNumber: pageNumber, pageWidth: pageWidth,
                              pageHeight: pageHeight, regions: [], charCount: 0)
        }

        // Step 0: 嘗試用 content stream 提取字體資訊
        let extractor = PDFContentExtractor()
        let extraction = extractor.extract(from: page)
        // 判斷字體是否有區分力：同時有 math fonts 和 text fonts 才可信
        let hasMathFonts = extraction.textFragments.contains { $0.isMath }
        let hasTextFonts = extraction.textFragments.contains { !$0.isMath }
        let fontDiscriminative = hasMathFonts && hasTextFonts
        let mathRanges = fontDiscriminative ? extraction.mathYRanges : []

        // Step 1: strip-scan，每 14pt 一條（≈ 一行文字）
        let strips = scanStrips(page: page, pageWidth: pageWidth, pageHeight: pageHeight, stripHeight: 14)

        // Step 2: 聚類 strips 為 blocks（Y gap 或 X 範圍變化為邊界）
        let blocks = clusterStrips(strips, pageWidth: pageWidth)

        // Step 3: 分類每個 block（有字體證據時傳入 mathYRanges）
        let regions: [PageRegion] = blocks.map { block in
            let regionType = classifyRegion(
                text: block.text, x: block.x0, y: block.y,
                width: block.x1 - block.x0, height: block.height,
                pageWidth: pageWidth, pageHeight: pageHeight,
                mathYRanges: mathRanges
            )
            return PageRegion(
                type: regionType,
                x: block.x0, y: block.y,
                width: block.x1 - block.x0, height: block.height,
                text: block.text
            )
        }

        return PageLayout(
            pageNumber: pageNumber,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            regions: regions,
            charCount: fullText.count
        )
    }

    private struct Strip {
        var y: CGFloat
        var height: CGFloat
        var x0: CGFloat
        var x1: CGFloat
        var text: String
    }

    private struct RawBlock {
        var y: CGFloat
        var height: CGFloat
        var x0: CGFloat
        var x1: CGFloat
        var text: String
    }

    /// 以固定高度的水平帶掃描頁面，取得每條帶的文字和 X 範圍。
    private func scanStrips(page: PDFPage, pageWidth: CGFloat, pageHeight: CGFloat, stripHeight: CGFloat) -> [Strip] {
        var strips: [Strip] = []
        var scanY: CGFloat = 0

        while scanY < pageHeight {
            let rect = CGRect(x: 0, y: scanY, width: pageWidth, height: stripHeight)
            if let selection = page.selection(for: rect),
               let text = selection.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bounds = selection.bounds(for: page)
                strips.append(Strip(
                    y: bounds.minY, height: max(bounds.height, stripHeight),
                    x0: bounds.minX, x1: bounds.maxX,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            scanY += stripHeight
        }

        return strips
    }

    /// 聚類 strips 為 blocks。分割條件：Y gap > 18pt 或 X 範圍明顯變化。
    private func clusterStrips(_ strips: [Strip], pageWidth: CGFloat) -> [RawBlock] {
        guard !strips.isEmpty else { return [] }

        // 先計算「正文」的典型 X 範圍（最常出現的寬度）
        let bodyThreshold = pageWidth * 0.55

        var blocks: [RawBlock] = []
        var current = RawBlock(
            y: strips[0].y, height: strips[0].height,
            x0: strips[0].x0, x1: strips[0].x1,
            text: strips[0].text
        )

        for i in 1..<strips.count {
            let strip = strips[i]
            let currentBottom = current.y + current.height
            let yGap = strip.y - currentBottom

            let currentWidth = current.x1 - current.x0
            let stripWidth = strip.x1 - strip.x0

            // 判斷是否應該分割
            let bigYGap = yGap > 18
            // 寬 → 窄（正文 → 公式）或 窄 → 寬（公式 → 正文）
            let widthTransition = (currentWidth > bodyThreshold && stripWidth < bodyThreshold)
                || (currentWidth < bodyThreshold && stripWidth > bodyThreshold)
            // X 起點大幅移動
            let xJump = abs(strip.x0 - current.x0) > 40 && abs(stripWidth - currentWidth) > 60

            if bigYGap || widthTransition || xJump {
                blocks.append(current)
                current = RawBlock(
                    y: strip.y, height: strip.height,
                    x0: strip.x0, x1: strip.x1,
                    text: strip.text
                )
            } else {
                // 延伸當前 block
                let newBottom = strip.y + strip.height
                current.height = newBottom - current.y
                current.x0 = min(current.x0, strip.x0)
                current.x1 = max(current.x1, strip.x1)
                current.text += "\n" + strip.text
            }
        }
        blocks.append(current)

        return blocks
    }

    /// 根據座標、文字內容、以及可選的字體證據分類 region 類型。
    /// `mathYRanges` 來自 `PDFContentExtractor`，當字體有區分力時提供。為空表示無字體證據（fallback 到純 heuristics）。
    private func classifyRegion(
        text: String, x: CGFloat, y: CGFloat,
        width: CGFloat, height: CGFloat,
        pageWidth: CGFloat, pageHeight: CGFloat,
        mathYRanges: [(yMin: CGFloat, yMax: CGFloat)] = []
    ) -> PageRegion.RegionType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        let centerX = x + width / 2
        let pageCenterX = pageWidth / 2
        let isCentered = abs(centerX - pageCenterX) < pageWidth * 0.15
        let isNarrow = width < pageWidth * 0.5

        // Header: 頁面頂部，含 "CHAPTER" 或很短
        if y < 30 && (trimmed.hasPrefix("CHAPTER") || trimmed.hasPrefix("APPENDIX") || trimmed.count < 50) {
            return .header
        }

        // Heading: 含 section 編號，短文字
        let hasSecNum = trimmed.range(of: #"^\d+\.\d+\s*[A-Z]"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^\d+\s+[A-Z][a-z]"#, options: .regularExpression) != nil
        if hasSecNum && trimmed.count < 80 {
            return .heading
        }

        // --- Equation detection: 多路徑策略 ---

        // Path A: 字體證據（有區分力時使用）
        // 如果這個 block 的 Y 範圍跟 math font Y 範圍高度重疊，判定為公式
        let blockYMin = y
        let blockYMax = y + height
        let fontMathEvidence: Bool = {
            guard !mathYRanges.isEmpty else { return false }
            // 計算 block 與 math ranges 的重疊比例
            var overlapTotal: CGFloat = 0
            for range in mathYRanges {
                let overlapMin = max(blockYMin, range.yMin)
                let overlapMax = min(blockYMax, range.yMax)
                if overlapMax > overlapMin {
                    overlapTotal += overlapMax - overlapMin
                }
            }
            let blockHeight = max(height, 1)
            let overlapRatio = overlapTotal / blockHeight
            // 高重疊（> 60%）且窄/居中 → 高信心公式
            return overlapRatio > 0.6
        }()

        // Path B: Layout heuristics（原有邏輯，字體無區分力時的主要路徑）
        let mathChars: Set<Character> = ["α", "β", "γ", "δ", "σ", "μ", "λ", "θ", "ε", "π",
                                          "φ", "ψ", "ω", "∑", "∫", "≥", "≤", "∈", "∀", "∃",
                                          "±", "×", "÷", "√", "∞", "≈", "≠", "∂"]
        let mathCount = trimmed.filter { mathChars.contains($0) }.count
        let hasEqNumber = lines.last?.trimmingCharacters(in: .whitespaces)
            .range(of: #"^\(\d+\.\d+\)$"#, options: .regularExpression) != nil
        let layoutMathEvidence = (isNarrow && isCentered && (mathCount > 0 || hasEqNumber))
            || (isCentered && hasEqNumber && height < 60)

        // 組合判定：任一路徑觸發且佈局合理 → equation
        if fontMathEvidence && (isNarrow || isCentered) {
            return .equation
        }
        if layoutMathEvidence {
            return .equation
        }

        // List: 多行以數字或 bullet 開頭
        let listLines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.range(of: #"^\d+\."#, options: .regularExpression) != nil
                || t.hasPrefix("•") || t.hasPrefix("-")
        }.count
        if listLines >= 2 {
            return .list
        }

        return .text
    }

    // MARK: - Vision OCR Layout Analysis (scanned PDF)

    /// 把 PDF 頁面渲染成 CGImage（72 DPI，足夠 OCR 用）。
    private func renderPageToCGImage(page: PDFPage, dpi: CGFloat = 150) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let pixelWidth = Int((bounds.width * scale).rounded(.up))
        let pixelHeight = Int((bounds.height * scale).rounded(.up))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    /// 用 Vision OCR 辨識圖片中的所有文字，回傳合併的字串。
    private func recognizeText(in image: CGImage) -> String {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        try? handler.perform([request])

        guard let observations = request.results else { return "" }
        // 按 Y 座標排序（Vision 原點左下 → 由上到下 = Y 遞減）
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 用 Vision OCR 分析 scanned PDF 的頁面 layout。
    /// 產出的結構與 PDFKit 路徑相同（regions + classification），但文字來自 OCR。
    func analyzePageLayoutWithOCR(page: PDFPage, pageNumber: Int) -> PageLayout {
        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width
        let pageHeight = pageBounds.height

        guard let cgImage = renderPageToCGImage(page: page) else {
            return PageLayout(pageNumber: pageNumber, pageWidth: pageWidth,
                              pageHeight: pageHeight, regions: [], charCount: 0)
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        try? handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            return PageLayout(pageNumber: pageNumber, pageWidth: pageWidth,
                              pageHeight: pageHeight, regions: [], charCount: 0)
        }

        // 把 Vision observations 轉成 Strip 格式，讓後續的 clusterStrips + classifyRegion 共用
        let strips: [Strip] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            // Vision boundingBox: 正規化 (0-1)，原點左下角
            let bbox = obs.boundingBox
            let x0 = bbox.minX * pageWidth
            let x1 = bbox.maxX * pageWidth
            let y = bbox.minY * pageHeight   // PDF 座標系也是左下原點
            let h = bbox.height * pageHeight

            return Strip(y: y, height: h, x0: x0, x1: x1, text: text)
        }
        // 按 Y 排序（由下到上，跟 PDFKit strip-scan 一致）
        .sorted { $0.y < $1.y }

        // 共用 cluster + classify 邏輯
        let blocks = clusterStrips(strips, pageWidth: pageWidth)
        let totalChars = strips.reduce(0) { $0 + $1.text.count }

        let regions: [PageRegion] = blocks.map { block in
            let regionType = classifyRegion(
                text: block.text, x: block.x0, y: block.y,
                width: block.x1 - block.x0, height: block.height,
                pageWidth: pageWidth, pageHeight: pageHeight
            )
            return PageRegion(
                type: regionType,
                x: block.x0, y: block.y,
                width: block.x1 - block.x0, height: block.height,
                text: block.text
            )
        }

        return PageLayout(
            pageNumber: pageNumber,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            regions: regions,
            charCount: totalChars
        )
    }

    // MARK: - TOC Parsing

    struct TOCEntry {
        let chapterNumber: String  // "1", "2", "A", "B" etc.
        let title: String
        let contentPage: Int       // 內容頁碼（非物理頁碼）
    }

    /// 從 TOC 頁面文字中解析章節級條目。
    func parseTOC(pages: [String]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        let allText = pages.joined(separator: "\n")
        let lines = allText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 策略：找到連續的「章節編號 + 標題 + 頁碼」模式
        // 學術書 TOC 典型格式：
        //   "1  Introduction                    1"
        //   "2  Conditional Expectation ...      9"
        //   "A  Matrix Algebra                 335"
        // PDFKit 抽出來可能是多行：
        //   "1\nIntroduction\n1"  或  "1 Introduction ... 1"

        // Pattern 1: 單行完整 — "N Title ... page"
        let singleLinePattern = #"^(\d+|[A-C])\s+([A-Z][A-Za-z\s\-:,]+?)\s*\.{2,}\s*\.?\s*(\d+)\s*$"#

        // Pattern 2: 單行無 dots — "N Title page"
        let noDotPattern = #"^(\d+|[A-C])\s+([A-Z][A-Za-z\s\-:,]{5,}?)\s+(\d+)\s*$"#

        for line in lines {
            // 跳過 section-level 條目（如 "1.1", "2.3"）
            if line.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil { continue }
            // 跳過 "Exercises" 和 "Preface"
            if line.hasPrefix("Exercises") || line.hasPrefix("Preface") { continue }

            if let match = line.range(of: singleLinePattern, options: .regularExpression) {
                if let entry = extractEntry(from: String(line[match]), pattern: singleLinePattern) {
                    entries.append(entry)
                }
            } else if let match = line.range(of: noDotPattern, options: .regularExpression) {
                if let entry = extractEntry(from: String(line[match]), pattern: noDotPattern) {
                    entries.append(entry)
                }
            }
        }

        // 如果單行 pattern 沒抓到，嘗試多行拼接
        if entries.isEmpty {
            entries = parseMultiLineTOC(lines: lines)
        }

        // 去重（同一章可能被抓到多次）
        var seen = Set<String>()
        entries = entries.filter { entry in
            let key = entry.chapterNumber
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        return entries.sorted { $0.contentPage < $1.contentPage }
    }

    private func extractEntry(from text: String, pattern: String) -> TOCEntry? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges >= 4 else { return nil }

        let numRange = Range(match.range(at: 1), in: text)!
        let titleRange = Range(match.range(at: 2), in: text)!
        let pageRange = Range(match.range(at: 3), in: text)!

        let number = String(text[numRange]).trimmingCharacters(in: .whitespaces)
        let title = String(text[titleRange]).trimmingCharacters(in: .whitespaces)
        guard let page = Int(String(text[pageRange])) else { return nil }

        // 過濾太短的標題（可能是誤判）
        guard title.count >= 4 else { return nil }

        return TOCEntry(chapterNumber: number, title: title, contentPage: page)
    }

    /// 多行 TOC 拼接：PDFKit 有時會把章節編號、標題、頁碼拆成不同行。
    func parseMultiLineTOC(lines: [String]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        var i = 0

        while i < lines.count - 1 {
            let current = lines[i]

            // 找純數字或字母行（章節編號）
            let isChapterNum = current.range(
                of: #"^(\d{1,2}|[A-C])$"#, options: .regularExpression
            ) != nil

            if isChapterNum, i + 1 < lines.count {
                let titleLine = lines[i + 1]
                // 標題行應以大寫字母開頭
                guard let first = titleLine.first, first.isUppercase else {
                    i += 1
                    continue
                }

                // 找頁碼：可能在標題行末尾，或下一行
                let titlePagePattern = #"^(.+?)\s*\.{2,}\s*\.?\s*(\d+)\s*$"#
                if let regex = try? NSRegularExpression(pattern: titlePagePattern),
                   let match = regex.firstMatch(
                    in: titleLine,
                    range: NSRange(titleLine.startIndex..., in: titleLine)
                   ),
                   match.numberOfRanges >= 3 {
                    let titleRange = Range(match.range(at: 1), in: titleLine)!
                    let pageRange = Range(match.range(at: 2), in: titleLine)!
                    if let page = Int(String(titleLine[pageRange])) {
                        let title = String(titleLine[titleRange]).trimmingCharacters(in: .whitespaces)
                        entries.append(TOCEntry(
                            chapterNumber: current, title: title, contentPage: page
                        ))
                        i += 2
                        continue
                    }
                }

                // 頁碼在下一行
                if i + 2 < lines.count, let page = Int(lines[i + 2]) {
                    entries.append(TOCEntry(
                        chapterNumber: current, title: titleLine, contentPage: page
                    ))
                    i += 3
                    continue
                }
            }
            i += 1
        }

        return entries
    }

    // MARK: - Page Offset Detection

    /// 偵測前置頁面數。找到第一個「不是 TOC / 不是 Preface」的內容頁面。
    /// TOC 頁面的特徵：大量 dot leaders (". . .")。
    func detectPageOffset(
        document: PDFDocument,
        tocEntries: [TOCEntry],
        totalPages: Int
    ) -> Int {
        guard let firstChapter = tocEntries.first(where: { $0.contentPage <= 2 }) else {
            return detectOffsetByScanning(document: document, totalPages: totalPages)
        }

        let searchPage = firstChapter.contentPage
        let scanLimit = min(25, totalPages)

        // 策略：從前往後掃，跳過 title、TOC、preface 頁面，
        // 找到第一個看起來像「正文」的頁面。
        for physIndex in 0..<scanLimit {
            guard let text = document.page(at: physIndex)?.string else { continue }

            // 跳過 TOC 頁面（含大量 dot leaders）
            let dotCount = text.components(separatedBy: ". . .").count - 1
            if dotCount >= 3 { continue }

            // 跳過太短的頁面（title page、空白頁等）
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 200 { continue }

            // 跳過 Preface 頁面
            if trimmed.lowercased().hasPrefix("preface") { continue }

            // 找到了！這應該是 content page 1（或 firstChapter 的頁面）
            let offset = physIndex - searchPage + 1
            if offset >= 1 && offset <= 20 {
                return offset
            }
        }

        return detectOffsetByScanning(document: document, totalPages: totalPages)
    }

    /// Fallback: 找頁面文字中含 section "1.1" 的最早非 TOC 頁面。
    private func detectOffsetByScanning(document: PDFDocument, totalPages: Int) -> Int {
        let scanLimit = min(25, totalPages)
        for i in 0..<scanLimit {
            guard let text = document.page(at: i)?.string else { continue }
            // 跳過 TOC 頁面
            let dotCount = text.components(separatedBy: ". . .").count - 1
            if dotCount >= 3 { continue }
            // 找 "1.1 " 作為 section heading（不是 TOC listing）
            if text.range(of: #"(?m)^1\.1\s+[A-Z]\w"#, options: .regularExpression) != nil {
                return i  // physical page i = content page 1, so offset = i
            }
        }
        return min(9, totalPages - 1)
    }

    // MARK: - Build Chapter Specs

    func buildChapterSpecs(
        entries: [TOCEntry],
        pageOffset: Int,
        totalPages: Int
    ) -> [ChapterSpec] {
        guard !entries.isEmpty else { return [] }

        var specs: [ChapterSpec] = []

        // Front matter
        if pageOffset > 0 {
            specs.append(ChapterSpec(
                id: "front-matter",
                title: "Front Matter",
                startPage: 1,
                endPage: pageOffset
            ))
        }

        for (index, entry) in entries.enumerated() {
            let physStart = entry.contentPage + pageOffset

            let physEnd: Int
            if index + 1 < entries.count {
                physEnd = entries[index + 1].contentPage + pageOffset - 1
            } else {
                physEnd = totalPages
            }

            guard physStart <= totalPages, physEnd >= physStart else { continue }

            let chId: String
            if let num = Int(entry.chapterNumber) {
                chId = String(format: "ch%02d", num)
            } else {
                chId = "app-\(entry.chapterNumber.lowercased())"
            }

            specs.append(ChapterSpec(
                id: chId,
                title: "\(entry.chapterNumber) \(entry.title)",
                startPage: physStart,
                endPage: min(physEnd, totalPages)
            ))
        }

        return specs
    }
}
