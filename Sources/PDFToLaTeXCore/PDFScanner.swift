import Foundation
import PDFKit

public struct PDFScanner: Sendable {
    public init() {}

    /// 每頁的尺寸、旋轉與 page label。
    ///
    /// page label 取自 `PDFPage.label`，但只在 PDF 的 catalog 真的有 `/PageLabels` 時採用：沒有
    /// `/PageLabels` 時 PDFKit 仍回傳 `"1"`、`"2"`…（實測），那是實體頁序，不是書上印的頁碼，
    /// 所以記為 nil（PsychQuant/macdoc#211）。
    public func scan(pdfAt url: URL) throws -> [PDFPageSnapshot] {
        guard let document = PDFDocument(url: url) else {
            throw PDFToLaTeXError.pdfOpenFailed(url)
        }
        let hasPageLabels = Self.hasPageLabels(document)

        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw PDFToLaTeXError.pageUnavailable(index)
            }

            let bounds = page.bounds(for: .mediaBox)
            return PDFPageSnapshot(
                number: index + 1,
                width: Double(bounds.width),
                height: Double(bounds.height),
                rotation: Int(page.rotation),
                label: hasPageLabels ? page.label : nil
            )
        }
    }

    /// catalog 是否有 `/PageLabels`（直接或間接物件皆可）。
    static func hasPageLabels(_ document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(catalog, "PageLabels", &object)
    }
}
