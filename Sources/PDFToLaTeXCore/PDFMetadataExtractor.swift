import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Models

/// 從原始 PDF 擷取的排版 metadata，用於校正 LaTeX preamble。
public struct PDFTypographyMetadata: Sendable, Equatable {
    public let paperSize: PaperSize
    public let dominantFontFamily: FontFamily
    public let fontEncoding: FontEncoding
    public let bodyFontSizePt: Double
    public let margins: PDFMargins?

    public enum PaperSize: String, Sendable, Equatable {
        case letter = "letterpaper"
        case a4 = "a4paper"
        case legal = "legalpaper"
        case b5 = "b5paper"
        case unknown
    }

    /// 從 PDF 字型名稱推斷出的 LaTeX 字型族。
    public enum FontFamily: String, Sendable, Equatable {
        /// DC / EC / CM / cm-super(SF) fonts — 用 `\usepackage[T1]{fontenc}` 即可
        case computerModern
        /// Latin Modern — `\usepackage{lmodern}`
        case latinModern
        /// Times — `\usepackage{newtxtext,newtxmath}` 或 `\usepackage{times}`
        case times
        /// Palatino — `\usepackage{newpxtext,newpxmath}`
        case palatino
        /// Helvetica / sans-serif
        case helvetica
        case unknown

        /// 回傳此字型族對應的 LaTeX 套件指令（不含 fontenc）。
        public var latexPackages: [String] {
            switch self {
            case .computerModern: return []  // 預設字型，不需額外套件
            case .latinModern: return ["\\usepackage{lmodern}"]
            case .times: return ["\\usepackage{newtxtext}", "\\usepackage{newtxmath}"]
            case .palatino: return ["\\usepackage{newpxtext}", "\\usepackage{newpxmath}"]
            case .helvetica: return ["\\usepackage{helvet}", "\\renewcommand{\\familydefault}{\\sfdefault}"]
            case .unknown: return []
            }
        }
    }

    /// 字型編碼，影響 `\usepackage[...]{fontenc}`。
    public enum FontEncoding: String, Sendable, Equatable {
        /// OT1：原始 Computer Modern（CMR, CMBX 等），不需要 fontenc
        case ot1
        /// T1：DC / EC / cm-super(SF) 字型，需要 `\usepackage[T1]{fontenc}`
        case t1
        case unknown
    }
}

/// PDF 頁面邊距（單位：inches）。
public struct PDFMargins: Sendable, Equatable, Codable {
    public let top: Double
    public let bottom: Double
    public let left: Double
    public let right: Double

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    /// 四邊是否近似相等（±0.15in 以內），可用單一 margin= 設定。
    public var isUniform: Bool {
        let vals = [top, bottom, left, right]
        guard let minV = vals.min(), let maxV = vals.max() else { return true }
        return (maxV - minV) < 0.15
    }

    /// 產生 LaTeX geometry 字串。
    public var geometryString: String {
        if isUniform {
            let avg = (top + bottom + left + right) / 4.0
            return "margin=\(inStr(avg))"
        }
        return "top=\(inStr(top)), bottom=\(inStr(bottom)), left=\(inStr(left)), right=\(inStr(right))"
    }

    private func inStr(_ val: Double) -> String {
        // 直接用偵測到的值，四捨五入到 0.01in
        let rounded = (val * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))in"
        }
        let s = String(format: "%.2fin", rounded)
        // 去除尾部多餘的零：0.70 → 0.7
        if s.hasSuffix("0in") && s.contains(".") {
            return s.replacingOccurrences(of: "0in", with: "in")
        }
        return s
    }
}

// MARK: - Extractor

/// 從 PDF 提取排版相關 metadata（紙張大小、字型、字級、邊距）。
public struct PDFMetadataExtractor: Sendable {

    public init() {}

    /// 分析一份 PDF，回傳排版 metadata。
    public func extract(from pdfURL: URL) -> PDFTypographyMetadata? {
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else { return nil }

        let paperSize = Self.detectPaperSize(doc: doc)
        let (fontFamily, _, encoding) = Self.detectFonts(doc: doc)
        let actualBodySize = Self.detectActualBodyFontSize(doc: doc)
        let bodySize = Self.snapToDocumentClassSize(actualBodySize)
        let margins = Self.detectMargins(doc: doc)

        return PDFTypographyMetadata(
            paperSize: paperSize,
            dominantFontFamily: fontFamily,
            fontEncoding: encoding,
            bodyFontSizePt: bodySize,
            margins: margins
        )
    }

    // MARK: - Paper Size Detection

    /// 從第一頁的 MediaBox 推斷紙張大小。
    static func detectPaperSize(doc: PDFDocument) -> PDFTypographyMetadata.PaperSize {
        guard let page = doc.page(at: 0) else { return .unknown }
        let bounds = page.bounds(for: .mediaBox)
        let widthMM = Double(bounds.width) / 72.0 * 25.4
        let heightMM = Double(bounds.height) / 72.0 * 25.4

        // US Letter: 215.9 × 279.4 mm (612 × 792 pt)
        if abs(widthMM - 215.9) < 3 && abs(heightMM - 279.4) < 3 {
            return .letter
        }
        // A4: 210 × 297 mm (595.28 × 841.89 pt)
        if abs(widthMM - 210) < 3 && abs(heightMM - 297) < 3 {
            return .a4
        }
        // US Legal: 215.9 × 355.6 mm
        if abs(widthMM - 215.9) < 3 && abs(heightMM - 355.6) < 3 {
            return .legal
        }
        // B5: 176 × 250 mm
        if abs(widthMM - 176) < 3 && abs(heightMM - 250) < 3 {
            return .b5
        }
        return .unknown
    }

    // MARK: - Font Detection

    /// 從 PDF 頁面的 Resources/Font 字典中提取字型名稱，
    /// 推斷主要字型族、本文字級和字型編碼。
    static func detectFonts(doc: PDFDocument) -> (PDFTypographyMetadata.FontFamily, Double, PDFTypographyMetadata.FontEncoding) {
        var fontNameCounts: [String: Int] = [:]

        // 取樣最多 20 頁（均勻分布）
        let totalPages = doc.pageCount
        let step = max(1, totalPages / 20)
        let sampleIndices = stride(from: 0, to: totalPages, by: step)

        for idx in sampleIndices {
            guard let page = doc.page(at: idx) else { continue }
            let names = extractFontNames(from: page)
            for name in names {
                fontNameCounts[name, default: 0] += 1
            }
        }

        let fontFamily = classifyFontFamily(fontNameCounts)
        let bodySize = inferBodyFontSize(fontFamily: fontFamily)
        let encoding = classifyFontEncoding(fontNameCounts)

        return (fontFamily, bodySize, encoding)
    }

    // MARK: - Actual Body Font Size Detection

    /// 從 PDF 的 NSAttributedString 提取實際的本文字型大小。
    /// 取樣若干本文頁面，統計最常見的字型大小（加權字元數）。
    static func detectActualBodyFontSize(doc: PDFDocument) -> Double {
        var sizeCounts: [Double: Int] = [:]

        // 取樣 body 頁面（跳過前幾頁 title/TOC）
        let startPage = min(20, doc.pageCount / 4)
        let endPage = min(startPage + 20, doc.pageCount)

        for i in startPage..<endPage {
            guard let page = doc.page(at: i),
                  let attrStr = page.attributedString else { continue }

            let fullRange = NSRange(location: 0, length: attrStr.length)
            attrStr.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                #if canImport(AppKit)
                guard let font = value as? NSFont else { return }
                #else
                guard let font = value as? UIFont else { return }
                #endif
                let size = Double(font.pointSize)
                // 量化到最近的 0.5pt，減少噪音
                let rounded = (size * 2).rounded() / 2
                sizeCounts[rounded, default: 0] += range.length
            }
        }

        // 回傳最常見的大小（加權字元數）
        guard let best = sizeCounts.max(by: { $0.value < $1.value }) else {
            return 11.0  // fallback
        }
        return best.key
    }

    /// 將偵測到的字型大小量化為 LaTeX \documentclass 支援的大小（10, 11, 12pt）。
    static func snapToDocumentClassSize(_ detectedSize: Double) -> Double {
        let validSizes: [Double] = [10.0, 11.0, 12.0]
        return validSizes.min(by: { abs($0 - detectedSize) < abs($1 - detectedSize) }) ?? 11.0
    }

    // MARK: - Margin Detection

    /// 從 PDF 本文頁面偵測邊距。
    /// - left/right：使用 full-page selection bounding box（可靠）
    /// - top/bottom：使用 characterBounds 跳過 running header 和 page number，
    ///   量到 body text 起點，對應 geometry 的 top/bottom（不含 header/footer）
    /// 取中位數以排除異常頁面。
    static func detectMargins(doc: PDFDocument) -> PDFMargins? {
        var topMargins: [Double] = []
        var bottomMargins: [Double] = []
        var leftMargins: [Double] = []
        var rightMargins: [Double] = []

        let startPage = min(20, doc.pageCount / 4)
        let endPage = min(startPage + 30, doc.pageCount)

        for i in startPage..<endPage {
            guard let page = doc.page(at: i) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            guard let text = page.string, !text.isEmpty else { continue }
            let charCount = page.numberOfCharacters
            guard charCount > 20 else { continue }

            // ── Left/Right：用 full selection（水平方向可靠） ──
            if let selection = page.selection(for: pageBounds) {
                let textBounds = selection.bounds(for: page)
                guard textBounds.width > pageBounds.width * 0.3 else { continue }

                let leftPt = Double(textBounds.minX)
                let rightPt = Double(pageBounds.width) - Double(textBounds.maxX)
                if leftPt > 10 && rightPt > 10 {
                    leftMargins.append(leftPt / 72.0)
                    rightMargins.append(rightPt / 72.0)
                }
            }

            // ── Top/Bottom：用 characterBounds 跳過 header/footer ──
            let rawLines = text.components(separatedBy: "\n")
            let nonEmptyLines = rawLines.filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard nonEmptyLines.count > 3 else { continue }

            // 跳過第一個非空行（running header）
            var headerCharCount = 0
            for rawLine in rawLines {
                headerCharCount += rawLine.count + 1
                if !rawLine.trimmingCharacters(in: .whitespaces).isEmpty { break }
            }

            // 跳過最後一個非空行（page number）
            var footerCharStart = text.count
            for rawLine in rawLines.reversed() {
                if !rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    footerCharStart = text.count - rawLine.count - 1
                    break
                }
            }

            let bodyStartIdx = min(headerCharCount, charCount - 1)
            let bodyEndIdx = max(0, min(footerCharStart - 1, charCount - 1))
            guard bodyStartIdx < bodyEndIdx else { continue }

            let bodyTopBounds = page.characterBounds(at: bodyStartIdx)
            let bodyBottomBounds = page.characterBounds(at: bodyEndIdx)
            guard bodyTopBounds.height > 0, bodyBottomBounds.height > 0 else { continue }

            // PDFKit 座標系：原點在左下角
            let topPt = Double(pageBounds.height) - Double(bodyTopBounds.maxY)
            let bottomPt = Double(bodyBottomBounds.minY)

            if topPt > 10 { topMargins.append(topPt / 72.0) }
            if bottomPt > 10 { bottomMargins.append(bottomPt / 72.0) }
        }

        guard !leftMargins.isEmpty, !topMargins.isEmpty else { return nil }

        func median(_ arr: [Double]) -> Double {
            let sorted = arr.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 0
                ? (sorted[mid - 1] + sorted[mid]) / 2.0
                : sorted[mid]
        }

        return PDFMargins(
            top: median(topMargins),
            bottom: median(bottomMargins),
            left: median(leftMargins),
            right: median(rightMargins)
        )
    }

    // MARK: - Font Name Extraction

    /// 透過 CGPDFPage 的 Resource 字典提取字型 BaseFont 名稱。
    public static func extractFontNames(from page: PDFPage) -> [String] {
        guard let cgPage = page.pageRef else { return [] }
        guard let dict = cgPage.dictionary else { return [] }

        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resourcesDict),
              let resources = resourcesDict else { return [] }

        var fontsDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fontsDict),
              let fonts = fontsDict else { return [] }

        var fontNames: [String] = []

        CGPDFDictionaryApplyBlock(fonts, { _, value, _ in
            var fontDict: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &fontDict),
                  let fd = fontDict else { return true }

            var nameRef: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(fd, "BaseFont", &nameRef),
               let ref = nameRef {
                fontNames.append(String(cString: ref))
            }

            var descendantsArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(fd, "DescendantFonts", &descendantsArray),
               let descendants = descendantsArray {
                let count = CGPDFArrayGetCount(descendants)
                for i in 0..<count {
                    var descDict: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(descendants, i, &descDict),
                       let dd = descDict {
                        var descNameRef: UnsafePointer<CChar>?
                        if CGPDFDictionaryGetName(dd, "BaseFont", &descNameRef),
                           let ref = descNameRef {
                            fontNames.append(String(cString: ref))
                        }
                    }
                }
            }

            return true
        }, nil)

        return fontNames
    }

    /// 去除 PDF 字型的 subset 前綴（如 "MPKJPF+Dcr10" → "Dcr10"）。
    public static func stripSubsetPrefix(_ name: String) -> String {
        if let plusIdx = name.firstIndex(of: "+") {
            return String(name[name.index(after: plusIdx)...])
        }
        return name
    }

    /// 從字型名稱頻率推斷 LaTeX 字型族。
    static func classifyFontFamily(
        _ fontCounts: [String: Int]
    ) -> PDFTypographyMetadata.FontFamily {
        var familyScores: [PDFTypographyMetadata.FontFamily: Int] = [:]

        for (rawName, count) in fontCounts {
            let name = stripSubsetPrefix(rawName)
            let upper = name.uppercased()

            // DC fonts (European Computer Modern, T1 encoding)
            if upper.hasPrefix("DCR") || upper.hasPrefix("DCBX") || upper.hasPrefix("DCTI") ||
               upper.hasPrefix("DCSL") || upper.hasPrefix("DCTT") || upper.hasPrefix("DCSS") ||
               upper.hasPrefix("DCCSC") || upper.hasPrefix("DCBXTI") {
                familyScores[.computerModern, default: 0] += count
            }
            // EC fonts (European Computer Modern, newer)
            else if upper.hasPrefix("ECR") || upper.hasPrefix("ECBX") || upper.hasPrefix("ECTI") ||
                    upper.hasPrefix("ECSL") {
                familyScores[.computerModern, default: 0] += count
            }
            // cm-super (SF) fonts — Type1 versions of EC/T1 Computer Modern
            else if upper.hasPrefix("SFRM") || upper.hasPrefix("SFBX") || upper.hasPrefix("SFTI") ||
                    upper.hasPrefix("SFSL") || upper.hasPrefix("SFTT") || upper.hasPrefix("SFSS") ||
                    upper.hasPrefix("SFCC") || upper.hasPrefix("SFDC") {
                familyScores[.computerModern, default: 0] += count
            }
            // Classic Computer Modern (OT1 encoding)
            else if upper.hasPrefix("CMR") || upper.hasPrefix("CMBX") || upper.hasPrefix("CMTI") ||
                    upper.hasPrefix("CMSL") || upper.hasPrefix("CMSS") || upper.hasPrefix("CMTT") {
                familyScores[.computerModern, default: 0] += count
            }
            // CM Math fonts (shared between CM and LM)
            else if upper.hasPrefix("CMMI") || upper.hasPrefix("CMSY") || upper.hasPrefix("CMEX") ||
                    upper.hasPrefix("CMMIB") || upper.hasPrefix("CMBSY") || upper.hasPrefix("MSBM") ||
                    upper.hasPrefix("MSAM") {
                // Math fonts are shared — don't count toward either CM or LM
            }
            // Latin Modern
            else if upper.hasPrefix("LMROMAN") || upper.hasPrefix("LMMONO") ||
                    upper.hasPrefix("LMSANS") || upper.hasPrefix("LMMATH") {
                familyScores[.latinModern, default: 0] += count
            }
            // Times
            else if upper.contains("TIMES") || upper.hasPrefix("NIMBUS") ||
                    upper.hasPrefix("NTXR") || upper.hasPrefix("NEWTXTEXT") {
                familyScores[.times, default: 0] += count
            }
            // Palatino
            else if upper.contains("PALLADIO") || upper.contains("PALATINO") ||
                    upper.hasPrefix("NEWPX") {
                familyScores[.palatino, default: 0] += count
            }
            // Helvetica
            else if upper.contains("HELVETICA") || upper.contains("ARIAL") {
                familyScores[.helvetica, default: 0] += count
            }
        }

        guard let best = familyScores.max(by: { $0.value < $1.value }) else {
            return .unknown
        }
        return best.key
    }

    /// 根據字型族推斷本文字級（fallback，優先使用 detectActualBodyFontSize）。
    static func inferBodyFontSize(
        fontFamily: PDFTypographyMetadata.FontFamily
    ) -> Double {
        switch fontFamily {
        case .computerModern, .latinModern:
            return 11.0
        case .times, .palatino:
            return 12.0
        case .helvetica, .unknown:
            return 11.0
        }
    }

    // MARK: - Title Page Font Analysis

    /// 標題頁上的文字片段，含字型名稱、大小、內容。
    public struct TitlePageElement: Sendable {
        public let text: String
        public let fontName: String
        public let fontSize: Double
    }

    /// 提取指定頁面上的所有文字片段及其字型大小。
    /// 預設提取第一頁（標題頁）。
    public static func extractPageFontDetails(
        doc: PDFDocument,
        pageIndex: Int = 0
    ) -> [TitlePageElement] {
        guard let page = doc.page(at: pageIndex),
              let attrStr = page.attributedString else { return [] }

        var elements: [TitlePageElement] = []
        let fullRange = NSRange(location: 0, length: attrStr.length)

        attrStr.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            #if canImport(AppKit)
            guard let font = value as? NSFont else { return }
            #else
            guard let font = value as? UIFont else { return }
            #endif
            let text = (attrStr.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            elements.append(TitlePageElement(
                text: text,
                fontName: font.fontName,
                fontSize: Double(font.pointSize)
            ))
        }
        return elements
    }

    /// 從字型名稱推斷字型編碼（OT1 vs T1）。
    /// - DC / EC / SF (cm-super) 字型 → T1
    /// - CMR / CMBX 等無 DC/EC/SF 前綴 → OT1
    /// - Latin Modern / Times / Palatino → T1（這些套件預設 T1）
    static func classifyFontEncoding(
        _ fontCounts: [String: Int]
    ) -> PDFTypographyMetadata.FontEncoding {
        var t1Score = 0
        var ot1Score = 0

        for (rawName, count) in fontCounts {
            let name = stripSubsetPrefix(rawName)
            let upper = name.uppercased()

            // T1-specific text fonts
            if upper.hasPrefix("DCR") || upper.hasPrefix("DCBX") || upper.hasPrefix("DCTI") ||
               upper.hasPrefix("DCSL") || upper.hasPrefix("DCTT") || upper.hasPrefix("DCSS") ||
               upper.hasPrefix("DCCSC") || upper.hasPrefix("DCBXTI") {
                t1Score += count
            } else if upper.hasPrefix("ECR") || upper.hasPrefix("ECBX") || upper.hasPrefix("ECTI") ||
                      upper.hasPrefix("ECSL") {
                t1Score += count
            } else if upper.hasPrefix("SFRM") || upper.hasPrefix("SFBX") || upper.hasPrefix("SFTI") ||
                      upper.hasPrefix("SFSL") || upper.hasPrefix("SFTT") || upper.hasPrefix("SFSS") ||
                      upper.hasPrefix("SFCC") {
                t1Score += count
            } else if upper.hasPrefix("LMROMAN") || upper.hasPrefix("LMMONO") || upper.hasPrefix("LMSANS") {
                t1Score += count
            }
            // OT1-specific text fonts (CM text, not math)
            else if upper.hasPrefix("CMR") || upper.hasPrefix("CMBX") || upper.hasPrefix("CMTI") ||
                    upper.hasPrefix("CMSL") || upper.hasPrefix("CMSS") || upper.hasPrefix("CMTT") ||
                    upper.hasPrefix("CMCSC") {
                ot1Score += count
            }
            // Math fonts (CMMI, CMSY, CMEX) are shared — skip
        }

        if t1Score > 0 && t1Score >= ot1Score { return .t1 }
        if ot1Score > 0 { return .ot1 }
        // Non-CM fonts (Times, Palatino) typically imply T1
        return .t1
    }
}
