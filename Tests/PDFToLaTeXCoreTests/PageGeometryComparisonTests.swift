import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFToLaTeXCore

struct PageGeometryComparisonTests {

    /// Writes a PDF with one page per size; each page carries a line of text so
    /// the text comparison has something to read.
    static func makePDF(_ sizes: [CGSize]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-\(UUID().uuidString).pdf")
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for (index, size) in sizes.enumerated() {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Chapter 1 page \(index + 1) sample text",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 72, y: size.height - 72)
            CTLineDraw(line, context)
            context.endPage()
        }
        context.closePDF()
        return url
    }

    static let pdfMaker = CGSize(width: 595.32, height: 842.04)
    static let letter = CGSize(width: 612, height: 792)

    @Test("page sizes are grouped, classified and mismatches listed")
    func groupsAndMismatches() throws {
        let original = try #require(PDFDocument(url: Self.makePDF([Self.pdfMaker, Self.pdfMaker, Self.pdfMaker, Self.pdfMaker])))
        let reproduced = try #require(PDFDocument(url: Self.makePDF([Self.pdfMaker, Self.pdfMaker, Self.letter, Self.pdfMaker])))
        let geometry = PageGeometryComparison.compare(original: original, reproduced: reproduced)

        #expect(geometry.originalSizes == [
            PageSizeGroup(width: 595.32, height: 842.04, classification: "nearA4", pages: [1, 2, 3, 4]),
        ])
        #expect(geometry.reproducedSizes.contains(
            PageSizeGroup(width: 612, height: 792, classification: "other", pages: [3])))
        #expect(geometry.mismatchedPages == [3])
    }

    @Test("exact A4 is recognised with the exact 210 × 297 mm size")
    func exactA4() throws {
        let a4 = CGSize(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72)
        let document = try #require(PDFDocument(url: Self.makePDF([a4])))
        let geometry = PageGeometryComparison.compare(original: document, reproduced: document)
        #expect(geometry.originalSizes.first?.classification == "exactA4")
        #expect(geometry.mismatchedPages.isEmpty)
    }

    @Test("compare() adds the geometry section to the report and keeps the text fields")
    func reportCarriesGeometry() throws {
        let originalURL = try Self.makePDF([Self.pdfMaker, Self.pdfMaker, Self.pdfMaker])
        let reproducedURL = try Self.makePDF([Self.pdfMaker, Self.pdfMaker, Self.letter])
        let report = try PDFComparator().compare(originalURL: originalURL, reproducedURL: reproducedURL)
        #expect(report.pageGeometry?.mismatchedPages == [3])
        #expect(report.originalPages == 3)
        #expect(report.reproducedPages == 3)
    }

    @Test("a report saved before the geometry field existed still decodes")
    func backwardCompatibleJSON() throws {
        let originalURL = try Self.makePDF([Self.pdfMaker])
        let report = try PDFComparator().compare(originalURL: originalURL, reproducedURL: originalURL)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object.removeValue(forKey: "pageGeometry")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PDFComparisonReport.self, from: legacy)
        #expect(decoded.pageGeometry == nil)
        #expect(decoded.originalPages == 1)
    }
}
