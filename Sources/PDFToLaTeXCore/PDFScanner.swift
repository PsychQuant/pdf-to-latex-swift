import Foundation
import PDFKit

public struct PDFScanner: Sendable {
    public init() {}

    public func scan(pdfAt url: URL) throws -> [PDFPageSnapshot] {
        guard let document = PDFDocument(url: url) else {
            throw PDFToLaTeXError.pdfOpenFailed(url)
        }

        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw PDFToLaTeXError.pageUnavailable(index)
            }

            let bounds = page.bounds(for: .mediaBox)
            return PDFPageSnapshot(
                number: index + 1,
                width: Double(bounds.width),
                height: Double(bounds.height),
                rotation: Int(page.rotation)
            )
        }
    }
}
