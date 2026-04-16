import ArgumentParser
import Foundation
import PDFToLaTeXCore
import PDFKit

struct TitleFontsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "title-fonts",
        abstract: "顯示 PDF 指定頁面上每個文字片段的字型與大小。"
    )

    @Argument(help: "PDF 路徑")
    var pdfPath: String

    @Option(name: .shortAndLong, help: "要分析的頁碼（0-indexed，預設 0）")
    var page: Int = 0

    func run() throws {
        let url = URL(fileURLWithPath: pdfPath)
        guard let doc = PDFDocument(url: url) else {
            throw ValidationError("Cannot open PDF: \(pdfPath)")
        }
        guard page >= 0, page < doc.pageCount else {
            throw ValidationError("Page \(page) out of range (0..\(doc.pageCount - 1))")
        }

        let elements = PDFMetadataExtractor.extractPageFontDetails(doc: doc, pageIndex: page)

        print("Page \(page) — \(elements.count) text fragments:\n")
        let sep = String(repeating: "─", count: 80)
        print(sep)
        let header = "  " + pad("Font", 14) + pad("Size", 8) + "Text"
        print(header)
        print(sep)

        for el in elements {
            let shortName = PDFMetadataExtractor.stripSubsetPrefix(el.fontName)
            let preview = String(el.text.prefix(60))
            let line = "  " + pad(shortName, 14) + pad(String(format: "%.1fpt", el.fontSize), 8) + preview
            print(line)
        }

        // Summary: unique sizes
        let uniqueSizes = Set(elements.map { (($0.fontSize * 2).rounded() / 2) }).sorted()
        print("\n  Unique font sizes: \(uniqueSizes.map { "\($0)pt" }.joined(separator: ", "))")
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
