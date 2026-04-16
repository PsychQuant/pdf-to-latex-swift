import ArgumentParser
import Foundation
import PDFToLaTeXCore

struct CompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "比較原始 PDF 與重製 PDF 的相似度。"
    )

    @Argument(help: "原始 PDF 路徑")
    var originalPDF: String

    @Argument(help: "重製 PDF 路徑")
    var reproducedPDF: String

    func run() throws {
        let origURL = URL(fileURLWithPath: originalPDF)
        let reprURL = URL(fileURLWithPath: reproducedPDF)

        guard FileManager.default.fileExists(atPath: origURL.path) else {
            throw ValidationError("Original PDF not found: \(originalPDF)")
        }
        guard FileManager.default.fileExists(atPath: reprURL.path) else {
            throw ValidationError("Reproduced PDF not found: \(reproducedPDF)")
        }

        let comparator = PDFComparator()
        _ = try comparator.compare(originalURL: origURL, reproducedURL: reprURL)
    }
}
