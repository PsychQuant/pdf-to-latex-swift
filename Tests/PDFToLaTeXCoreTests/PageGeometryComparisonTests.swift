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

    static let nearA4 = CGSize(width: 596, height: 843)
    static let letter = CGSize(width: 612, height: 792)

    @Test("page sizes are grouped, classified and mismatches listed")
    func groupsAndMismatches() throws {
        let original = try #require(PDFDocument(url: Self.makePDF([Self.nearA4, Self.nearA4, Self.nearA4, Self.nearA4])))
        let reproduced = try #require(PDFDocument(url: Self.makePDF([Self.nearA4, Self.nearA4, Self.letter, Self.nearA4])))
        let geometry = PageGeometryComparison.compare(original: original, reproduced: reproduced)

        #expect(geometry.originalSizes == [
            PageSizeGroup(width: 596, height: 843, classification: "nearA4", pages: [1, 2, 3, 4]),
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

    @Test("a size difference below 0.01 bp is still listed")
    func smallDifferenceListed() throws {
        let exact = CGSize(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72)
        let rounded = CGSize(width: 595.28, height: 841.89)
        let geometry = PageGeometryComparison.compare(
            original: try #require(PDFDocument(url: Self.makePDF([exact]))),
            reproduced: try #require(PDFDocument(url: Self.makePDF([rounded]))))
        #expect(geometry.mismatchedPages == [1])
        #expect(geometry.originalSizes.first?.classification == "exactA4")
        #expect(geometry.reproducedSizes.first?.classification == "exactA4")
    }

    @Test("sizes on both sides of the near-A4 boundary are separate groups with their own class")
    func groupsDoNotStraddleClasses() throws {
        // 1.4996 and 1.5003 bp wider than A4; both print as 596.78.
        let near = CGSize(width: 596.7752, height: 841.8898), other = CGSize(width: 596.7759, height: 841.8898)
        let document = try #require(PDFDocument(url: Self.makePDF([near, other, near])))
        let groups = PageGeometryComparison.compare(original: document, reproduced: document).originalSizes
        #expect(groups.map(\.classification) == ["nearA4", "other"])
        #expect(groups.map(\.pages) == [[1, 3], [2]])
    }

    @Test("sizes are taken as displayed, after the page's rotation")
    func rotationApplied() throws {
        let a4 = CGSize(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72)
        let rotated = try #require(PDFDocument(url: Self.makePDF([a4])))
        rotated.page(at: 0)?.rotation = 90
        let landscape = try #require(PDFDocument(url: Self.makePDF([CGSize(width: a4.height, height: a4.width)])))
        let geometry = PageGeometryComparison.compare(original: rotated, reproduced: landscape)
        #expect(geometry.mismatchedPages.isEmpty)
        let shown = try #require(geometry.originalSizes.first)
        #expect(shown.width > shown.height)
        #expect(shown.classification == "other")
    }

    @Test("labels that would print alike get more decimals")
    func distinctLabels() {
        let groups = [PageSizeGroup(width: 596.7752, height: 841.8898, classification: "nearA4", pages: [1]),
                      PageSizeGroup(width: 596.7759, height: 841.8898, classification: "other", pages: [2]),
                      PageSizeGroup(width: 612, height: 792, classification: "other", pages: [3])]
        #expect(PageGeometryComparison.labels(groups) == ["596.7752 × 841.8898 bp", "596.7759 × 841.8898 bp", "612.00 × 792.00 bp"])
    }

    @Test("compare() adds the geometry section to the report and keeps the text fields")
    func reportCarriesGeometry() throws {
        let originalURL = try Self.makePDF([Self.nearA4, Self.nearA4, Self.nearA4])
        let reproducedURL = try Self.makePDF([Self.nearA4, Self.nearA4, Self.letter])
        let report = try PDFComparator().compare(originalURL: originalURL, reproducedURL: reproducedURL)
        #expect(report.pageGeometry?.mismatchedPages == [3])
        #expect(report.originalPages == 3)
        #expect(report.reproducedPages == 3)
    }

    @Test("a report saved before the geometry field existed still decodes")
    func backwardCompatibleJSON() throws {
        let originalURL = try Self.makePDF([Self.nearA4])
        let report = try PDFComparator().compare(originalURL: originalURL, reproducedURL: originalURL)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object.removeValue(forKey: "pageGeometry")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PDFComparisonReport.self, from: legacy)
        #expect(decoded.pageGeometry == nil)
        #expect(decoded.originalPages == 1)
    }
}
