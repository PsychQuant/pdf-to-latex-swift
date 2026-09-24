import XCTest
@testable import PDFToLaTeXCore

/// 管線建立 page record 時讀取 PDF 的 page labels（PsychQuant/macdoc#211）。
final class PDFPageLabelScanTests: XCTestCase {

    private func scanLabels(pageCount: Int, pageLabels: String?, indirect: Bool = false) throws -> [String?] {
        let url = try MinimalPDF.write(pageCount: pageCount, pageLabels: pageLabels, indirect: indirect)
        defer { try? FileManager.default.removeItem(at: url) }
        return try PDFScanner().scan(pdfAt: url).map(\.label)
    }

    func testScannerReadsRomanThenArabicLabels() throws {
        let labels = try scanLabels(pageCount: 6, pageLabels: "<< /Nums [0 << /S /r >> 3 << /S /D >>] >>")
        XCTAssertEqual(labels, ["i", "ii", "iii", "1", "2", "3"])
    }

    func testScannerReadsIndirectPageLabelsAndStartValues() throws {
        let labels = try scanLabels(pageCount: 3, pageLabels: "<< /Nums [0 << /S /R /St 5 >>] >>", indirect: true)
        XCTAssertEqual(labels, ["V", "VI", "VII"])
    }

    /// 前綴與不是數字的 label 照原樣記錄；要不要採用由頁碼還原決定。
    func testScannerRecordsNonNumericLabelsVerbatim() throws {
        XCTAssertEqual(try scanLabels(pageCount: 2, pageLabels: "<< /Nums [0 << /S /D /P (A-) >>] >>"), ["A-1", "A-2"])
        XCTAssertEqual(try scanLabels(pageCount: 2, pageLabels: "<< /Nums [0 << >>] >>"), ["", ""])
    }

    /// 沒有 /PageLabels 時 PDFKit 仍回傳 "1"、"2"…（實測），不能當成 label：一律記為 nil。
    func testScannerLeavesLabelNilWithoutPageLabels() throws {
        XCTAssertEqual(try scanLabels(pageCount: 3, pageLabels: nil), [nil, nil, nil])
    }

    func testBootstrapPageRecordsCarryTheLabel() throws {
        let url = try MinimalPDF.write(pageCount: 4, pageLabels: "<< /Nums [0 << /S /r >> 2 << /S /D >>] >>")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = ProjectBootstrap().pageRecords(from: try PDFScanner().scan(pdfAt: url))
        XCTAssertEqual(records.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(records.map(\.label), ["i", "ii", "1", "2"])
    }

    // MARK: - Manifest

    func testPageRecordWithoutLabelDecodesFromAnOldManifest() throws {
        let json = """
        {"number": 3, "width": 612, "height": 792, "rotation": 0}
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(PageRecord.self, from: json)
        XCTAssertEqual(record.number, 3)
        XCTAssertNil(record.label)
    }

    func testPageRecordLabelRoundTripsAndIsOmittedWhenNil() throws {
        let labelled = PageRecord(number: 1, width: 612, height: 792, rotation: 0,
                                  renderedImagePath: nil, renderedDPI: nil, label: "iv")
        let decoded = try JSONDecoder().decode(PageRecord.self, from: JSONEncoder().encode(labelled))
        XCTAssertEqual(decoded.label, "iv")

        let plain = PageRecord(number: 1, width: 612, height: 792, rotation: 0, renderedImagePath: nil, renderedDPI: nil)
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(text.contains("label"))
    }
}
