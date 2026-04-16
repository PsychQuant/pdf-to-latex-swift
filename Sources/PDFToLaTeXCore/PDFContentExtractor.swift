import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 解析 PDF content stream，單次遍歷提取三類資訊：
/// 1. 字體使用（區分 math vs text，精確到 Y 位置）
/// 2. 向量路徑（表格線、theorem box 矩形）
/// 3. 嵌入圖片（位置 + 原始像素資料）
public struct PDFContentExtractor: Sendable {
    public init() {}

    // MARK: - Result Types

    /// 一個文字片段的字體和位置。
    public struct TextFragment: Codable, Sendable {
        public let fontName: String     // e.g., "Cmmi10"
        public let fontSize: CGFloat
        public let x: CGFloat
        public let y: CGFloat
        public let isMath: Bool
    }

    /// 偵測到的直線段。
    public struct DetectedLine: Codable, Sendable {
        public let x1, y1, x2, y2: CGFloat
        public var isHorizontal: Bool { abs(y2 - y1) < 1 }
        public var isVertical: Bool { abs(x2 - x1) < 1 }
        public var length: CGFloat { hypot(x2 - x1, y2 - y1) }
    }

    /// 偵測到的矩形（theorem box、表格邊框等）。
    public struct DetectedRect: Codable, Sendable {
        public let x, y, width, height: CGFloat
    }

    /// 嵌入圖片的位置和尺寸。
    public struct EmbeddedImage: Codable, Sendable {
        public let resourceName: String
        public let x, y, width, height: CGFloat   // 頁面座標
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// 單頁的完整提取結果。
    public struct PageExtraction: Codable, Sendable {
        public let textFragments: [TextFragment]
        public let lines: [DetectedLine]
        public let rectangles: [DetectedRect]
        public let images: [EmbeddedImage]

        /// 數學字體出現的 Y 區間（合併相近的）。
        public var mathYRanges: [(yMin: CGFloat, yMax: CGFloat)] {
            let sorted = textFragments.filter { $0.isMath }.sorted { $0.y < $1.y }
            guard !sorted.isEmpty else { return [] }

            var ranges: [(CGFloat, CGFloat)] = []
            var lo = sorted[0].y
            var hi = sorted[0].y + sorted[0].fontSize

            for frag in sorted.dropFirst() {
                if frag.y - hi > 20 {
                    ranges.append((lo, hi))
                    lo = frag.y
                    hi = frag.y + frag.fontSize
                } else {
                    hi = max(hi, frag.y + frag.fontSize)
                }
            }
            ranges.append((lo, hi))
            return ranges
        }

        // CodingKeys — mathYRanges is computed, skip it
        enum CodingKeys: String, CodingKey {
            case textFragments, lines, rectangles, images
        }
    }

    // MARK: - Math Font Detection

    /// 根據字體名判斷是否為數學字體（Computer Modern / AMS）。
    public static func isMathFont(_ name: String) -> Bool {
        // 去除子集前綴（如 "MPKJPF+Cmmi10" → "Cmmi10"）
        let base = name.components(separatedBy: "+").last ?? name
        let lower = base.lowercased()

        // Computer Modern math fonts
        if lower.hasPrefix("cmmi")  { return true }  // Math Italic
        if lower.hasPrefix("cmsy")  { return true }  // Math Symbol
        if lower.hasPrefix("cmex")  { return true }  // Math Extended
        if lower.hasPrefix("cmmib") { return true }  // Math Italic Bold
        if lower.hasPrefix("cmbsy") { return true }  // Bold Math Symbol

        // AMS fonts
        if lower.hasPrefix("msbm")  { return true }  // AMS Blackboard Bold (ℝ, ℤ)
        if lower.hasPrefix("msam")  { return true }  // AMS Symbol A

        // STIX / other math fonts
        if lower.contains("math")   { return true }

        return false
    }

    // MARK: - Content Stream Parsing

    /// 解析頁面 content stream，回傳提取結果。
    public func extract(from page: PDFPage) -> PageExtraction {
        guard let cgPage = page.pageRef else {
            return PageExtraction(textFragments: [], lines: [], rectangles: [], images: [])
        }

        let ctx = ScanContext()
        populateResources(cgPage: cgPage, ctx: ctx)

        guard let table = CGPDFOperatorTableCreate() else {
            return PageExtraction(textFragments: [], lines: [], rectangles: [], images: [])
        }

        // Register all operator callbacks
        Self.registerCallbacks(table: table)

        let stream = CGPDFContentStreamCreateWithPage(cgPage)

        let ptr = Unmanaged.passRetained(ctx).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, ptr)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        Unmanaged<ScanContext>.fromOpaque(ptr).release()

        return PageExtraction(
            textFragments: ctx.textFragments,
            lines: ctx.lines,
            rectangles: ctx.rects,
            images: ctx.images
        )
    }

    /// 提取嵌入圖片並存為 PNG。回傳儲存的路徑。
    public func extractImages(from page: PDFPage, pageNumber: Int, outputDir: URL) -> [String] {
        guard let cgPage = page.pageRef, let dict = cgPage.dictionary else { return [] }
        var resDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resDict), let res = resDict else { return [] }
        var xobjDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjDict), let xobjs = xobjDict else { return [] }

        let state = ImageExtractionState(pageNumber: pageNumber, outputDir: outputDir)
        let ptr = Unmanaged.passRetained(state).toOpaque()

        CGPDFDictionaryApplyBlock(xobjs, { _, value, info in
            guard let info else { return true }
            let state = Unmanaged<ImageExtractionState>.fromOpaque(info).takeUnretainedValue()

            var streamRef: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &streamRef), let stream = streamRef,
                  let sd = CGPDFStreamGetDictionary(stream) else { return true }

            var subtypeName: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(sd, "Subtype", &subtypeName)
            guard subtypeName.map({ String(cString: $0) }) == "Image" else { return true }

            // Get image dimensions
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(sd, "Width", &w)
            CGPDFDictionaryGetInteger(sd, "Height", &h)
            guard w > 0, h > 0 else { return true }

            // Get raw data
            var format: CGPDFDataFormat = .raw
            guard let data = CGPDFStreamCopyData(stream, &format) else { return true }

            // Try to create CGImage from data
            if let provider = CGDataProvider(data: data),
               let cgImage = CGImage(
                   width: Int(w), height: Int(h),
                   bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: Int(w) * 3,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: provider,
                   decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent
               ) {
                let filename = String(format: "p%03d-img%02d.png", state.pageNumber, state.imageIndex)
                let url = state.outputDir.appendingPathComponent(filename)

                if let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil
                ) {
                    CGImageDestinationAddImage(dest, cgImage, nil)
                    if CGImageDestinationFinalize(dest) {
                        state.savedPaths.append(url.path)
                    }
                }
                state.imageIndex += 1
            }
            return true
        }, ptr)

        let result = state.savedPaths
        Unmanaged<ImageExtractionState>.fromOpaque(ptr).release()
        return result
    }

    // MARK: - Internal

    /// 用於圖片提取的狀態（class 以便在 C callback 中 mutate）。
    private final class ImageExtractionState {
        let pageNumber: Int
        let outputDir: URL
        var imageIndex: Int = 0
        var savedPaths: [String] = []

        init(pageNumber: Int, outputDir: URL) {
            self.pageNumber = pageNumber
            self.outputDir = outputDir
        }
    }

    /// Mutable scanning context，用 class 方便通過指標傳遞給 C callback。
    private final class ScanContext {
        // Current state
        var ctm: CGAffineTransform = .identity
        var textMatrix: CGAffineTransform = .identity
        var lineMatrix: CGAffineTransform = .identity
        var currentFontKey: String = ""    // resource key (e.g., "TT5")
        var currentFontSize: CGFloat = 0
        var stateStack: [(ctm: CGAffineTransform, fontKey: String, fontSize: CGFloat)] = []

        // Path state
        var currentPoint: CGPoint = .zero
        var pathSegments: [(CGPoint, CGPoint)] = []
        var pathRects: [CGRect] = []

        // Resource maps (populated before scan)
        var fontNameMap: [String: String] = [:]   // TT5 → Dcr10
        var imageInfoMap: [String: (w: Int, h: Int)] = [:]

        // Results
        var textFragments: [TextFragment] = []
        var lines: [DetectedLine] = []
        var rects: [DetectedRect] = []
        var images: [EmbeddedImage] = []
    }

    /// 從頁面 Resources 預讀字體名稱對映和圖片尺寸。
    private func populateResources(cgPage: CGPDFPage, ctx: ScanContext) {
        guard let dict = cgPage.dictionary else { return }
        var resDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resDict), let res = resDict else { return }

        // Fonts
        var fontDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(res, "Font", &fontDict), let fonts = fontDict {
            CGPDFDictionaryApplyBlock(fonts, { key, value, info in
                guard let info else { return true }
                let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
                var sd: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(value, .dictionary, &sd), let s = sd {
                    var bn: UnsafePointer<CChar>?
                    CGPDFDictionaryGetName(s, "BaseFont", &bn)
                    if let name = bn.map({ String(cString: $0) }) {
                        let short = name.components(separatedBy: "+").last ?? name
                        ctx.fontNameMap[String(cString: key)] = short
                    }
                }
                return true
            }, Unmanaged.passUnretained(ctx).toOpaque())
        }

        // XObjects (images)
        var xobjDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(res, "XObject", &xobjDict), let xobjs = xobjDict {
            CGPDFDictionaryApplyBlock(xobjs, { key, value, info in
                guard let info else { return true }
                let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
                var streamRef: CGPDFStreamRef?
                if CGPDFObjectGetValue(value, .stream, &streamRef), let stream = streamRef,
                   let sd = CGPDFStreamGetDictionary(stream) {
                    var subtypeName: UnsafePointer<CChar>?
                    CGPDFDictionaryGetName(sd, "Subtype", &subtypeName)
                    if subtypeName.map({ String(cString: $0) }) == "Image" {
                        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                        CGPDFDictionaryGetInteger(sd, "Width", &w)
                        CGPDFDictionaryGetInteger(sd, "Height", &h)
                        ctx.imageInfoMap[String(cString: key)] = (Int(w), Int(h))
                    }
                }
                return true
            }, Unmanaged.passUnretained(ctx).toOpaque())
        }
    }

    // MARK: - Operator Callbacks

    private static func registerCallbacks(table: CGPDFOperatorTableRef) {
        // Graphics state
        CGPDFOperatorTableSetCallback(table, "q", cb_q)
        CGPDFOperatorTableSetCallback(table, "Q", cb_Q)
        CGPDFOperatorTableSetCallback(table, "cm", cb_cm)

        // Text
        CGPDFOperatorTableSetCallback(table, "BT", cb_BT)
        CGPDFOperatorTableSetCallback(table, "Tf", cb_Tf)
        CGPDFOperatorTableSetCallback(table, "Td", cb_Td)
        CGPDFOperatorTableSetCallback(table, "TD", cb_Td)   // same handling
        CGPDFOperatorTableSetCallback(table, "Tm", cb_Tm)
        CGPDFOperatorTableSetCallback(table, "T*", cb_Tstar)
        CGPDFOperatorTableSetCallback(table, "Tj", cb_Tj)
        CGPDFOperatorTableSetCallback(table, "TJ", cb_TJ)
        CGPDFOperatorTableSetCallback(table, "'",  cb_Tj)   // next line + show = T* + Tj
        CGPDFOperatorTableSetCallback(table, "\"", cb_Tj)   // set spacing + next line + show

        // Path
        CGPDFOperatorTableSetCallback(table, "m", cb_m)
        CGPDFOperatorTableSetCallback(table, "l", cb_l)
        CGPDFOperatorTableSetCallback(table, "re", cb_re)
        CGPDFOperatorTableSetCallback(table, "S", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "s", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "f", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "F", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "f*", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "B", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "B*", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "b", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "b*", cb_stroke)
        CGPDFOperatorTableSetCallback(table, "n", cb_endpath)

        // XObject
        CGPDFOperatorTableSetCallback(table, "Do", cb_Do)
    }

    // MARK: Graphics State

    private static let cb_q: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        ctx.stateStack.append((ctx.ctm, ctx.currentFontKey, ctx.currentFontSize))
    }

    private static let cb_Q: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        if let prev = ctx.stateStack.popLast() {
            ctx.ctm = prev.ctm
            ctx.currentFontKey = prev.fontKey
            ctx.currentFontSize = prev.fontSize
        }
    }

    private static let cb_cm: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var a: CGPDFReal = 0, b: CGPDFReal = 0, c: CGPDFReal = 0
        var d: CGPDFReal = 0, e: CGPDFReal = 0, f: CGPDFReal = 0
        // Pop in reverse order: f, e, d, c, b, a
        CGPDFScannerPopNumber(scanner, &f)
        CGPDFScannerPopNumber(scanner, &e)
        CGPDFScannerPopNumber(scanner, &d)
        CGPDFScannerPopNumber(scanner, &c)
        CGPDFScannerPopNumber(scanner, &b)
        CGPDFScannerPopNumber(scanner, &a)
        let m = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
                                   d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
        ctx.ctm = m.concatenating(ctx.ctm)
    }

    // MARK: Text Operators

    private static let cb_BT: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        ctx.textMatrix = .identity
        ctx.lineMatrix = .identity
    }

    private static let cb_Tf: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var size: CGPDFReal = 0
        var name: UnsafePointer<CChar>?
        CGPDFScannerPopNumber(scanner, &size)
        CGPDFScannerPopName(scanner, &name)
        if let n = name {
            ctx.currentFontKey = String(cString: n)
            ctx.currentFontSize = CGFloat(size)
        }
    }

    private static let cb_Td: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var tx: CGPDFReal = 0, ty: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner, &ty)
        CGPDFScannerPopNumber(scanner, &tx)
        let translate = CGAffineTransform(translationX: CGFloat(tx), y: CGFloat(ty))
        ctx.textMatrix = translate.concatenating(ctx.lineMatrix)
        ctx.lineMatrix = ctx.textMatrix
    }

    private static let cb_Tm: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var a: CGPDFReal = 0, b: CGPDFReal = 0, c: CGPDFReal = 0
        var d: CGPDFReal = 0, e: CGPDFReal = 0, f: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner, &f)
        CGPDFScannerPopNumber(scanner, &e)
        CGPDFScannerPopNumber(scanner, &d)
        CGPDFScannerPopNumber(scanner, &c)
        CGPDFScannerPopNumber(scanner, &b)
        CGPDFScannerPopNumber(scanner, &a)
        ctx.textMatrix = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
                                            d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
        ctx.lineMatrix = ctx.textMatrix
    }

    private static let cb_Tstar: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        // T* = Td(0, -leading)。Leading 預設 0，我們近似用 -fontSize。
        let translate = CGAffineTransform(translationX: 0, y: -ctx.currentFontSize)
        ctx.textMatrix = translate.concatenating(ctx.lineMatrix)
        ctx.lineMatrix = ctx.textMatrix
    }

    /// Tj / ' / " — 顯示文字，記錄字體和位置。
    private static let cb_Tj: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        recordTextPosition(ctx: ctx)
    }

    /// TJ — 顯示文字陣列。
    private static let cb_TJ: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        recordTextPosition(ctx: ctx)
    }

    private static func recordTextPosition(ctx: ScanContext) {
        let fontName = ctx.fontNameMap[ctx.currentFontKey] ?? ctx.currentFontKey
        guard !fontName.isEmpty else { return }

        // 文字在頁面上的位置 = CTM × textMatrix 的平移分量
        let combined = ctx.textMatrix.concatenating(ctx.ctm)
        let x = combined.tx
        let y = combined.ty

        ctx.textFragments.append(TextFragment(
            fontName: fontName,
            fontSize: abs(ctx.currentFontSize),
            x: x, y: y,
            isMath: PDFContentExtractor.isMathFont(fontName)
        ))
    }

    // MARK: Path Operators

    private static let cb_m: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var x: CGPDFReal = 0, y: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner, &y)
        CGPDFScannerPopNumber(scanner, &x)
        let pt = CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(ctx.ctm)
        ctx.currentPoint = pt
    }

    private static let cb_l: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var x: CGPDFReal = 0, y: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner, &y)
        CGPDFScannerPopNumber(scanner, &x)
        let pt = CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(ctx.ctm)
        ctx.pathSegments.append((ctx.currentPoint, pt))
        ctx.currentPoint = pt
    }

    private static let cb_re: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var x: CGPDFReal = 0, y: CGPDFReal = 0, w: CGPDFReal = 0, h: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner, &h)
        CGPDFScannerPopNumber(scanner, &w)
        CGPDFScannerPopNumber(scanner, &y)
        CGPDFScannerPopNumber(scanner, &x)
        let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
            .applying(ctx.ctm)
        ctx.pathRects.append(rect)
    }

    /// 路徑繪製完成（stroke / fill）→ 收集線段和矩形。
    private static let cb_stroke: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        flushPath(ctx: ctx)
    }

    private static let cb_endpath: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        // n = end path without painting，但仍清空路徑狀態
        ctx.pathSegments.removeAll()
        ctx.pathRects.removeAll()
    }

    private static func flushPath(ctx: ScanContext) {
        // 收集有意義的線段（長度 > 20pt）
        for (p1, p2) in ctx.pathSegments {
            let len = hypot(p2.x - p1.x, p2.y - p1.y)
            if len > 20 {
                ctx.lines.append(DetectedLine(x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y))
            }
        }
        // 收集有意義的矩形（面積 > 100 sq pt，排除微小裝飾）
        for r in ctx.pathRects {
            if abs(r.width) > 10, abs(r.height) > 10 {
                ctx.rects.append(DetectedRect(
                    x: min(r.origin.x, r.origin.x + r.width),
                    y: min(r.origin.y, r.origin.y + r.height),
                    width: abs(r.width), height: abs(r.height)
                ))
            }
        }
        ctx.pathSegments.removeAll()
        ctx.pathRects.removeAll()
    }

    // MARK: XObject (Image) Operator

    private static let cb_Do: @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void = { scanner, info in
        guard let info else { return }
        let ctx = Unmanaged<ScanContext>.fromOpaque(info).takeUnretainedValue()
        var name: UnsafePointer<CChar>?
        CGPDFScannerPopName(scanner, &name)
        guard let n = name else { return }
        let key = String(cString: n)

        // 只處理 Image XObject
        guard let imgInfo = ctx.imageInfoMap[key] else { return }

        // Image 被映射到 1×1 的 unit square，CTM 決定實際位置和大小
        let origin = CGPoint.zero.applying(ctx.ctm)
        let size = CGSize(width: 1, height: 1).applying(ctx.ctm)

        ctx.images.append(EmbeddedImage(
            resourceName: key,
            x: origin.x, y: origin.y,
            width: abs(size.width), height: abs(size.height),
            pixelWidth: imgInfo.w, pixelHeight: imgInfo.h
        ))
    }
}
