import ArgumentParser
import Foundation
import PDFToLaTeXCore
import PDFKit

struct FixTitleTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix-title-test",
        abstract: "測試標題頁字型修正（dry-run，只顯示結果不寫入）。"
    )

    @Argument(help: "原始 PDF 路徑")
    var originalPDF: String

    @Argument(help: "TeX 檔案路徑")
    var texFile: String

    func run() throws {
        let pdfURL = URL(fileURLWithPath: originalPDF)
        let texURL = URL(fileURLWithPath: texFile)

        guard let doc = PDFDocument(url: pdfURL) else {
            throw ValidationError("Cannot open PDF: \(originalPDF)")
        }

        let elements = PDFMetadataExtractor.extractPageFontDetails(doc: doc, pageIndex: 0)
        print("PDF title page elements:")
        for el in elements {
            let name = PDFMetadataExtractor.stripSubsetPrefix(el.fontName)
            print("  \(name) \(el.fontSize)pt: \(el.text.prefix(40))")
        }

        let source = try String(contentsOf: texURL, encoding: .utf8)
        let fixed = LaTeXNormalizer.fixTitlePageFontSizes(source, titlePageElements: elements)

        if fixed == source {
            print("\nNo changes needed.")
        } else {
            print("\n=== DIFF (titlepage section) ===")
            // Show the titlepage block from fixed
            if let start = fixed.range(of: "\\begin{titlepage}"),
               let end = fixed.range(of: "\\end{titlepage}") {
                let block = String(fixed[start.lowerBound...end.upperBound])
                print(block)
            }
        }
    }
}
