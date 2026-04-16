import ArgumentParser
import Foundation
import PDFToLaTeXCore

struct FixLinebreakTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix-linebreak-test",
        abstract: "測試假換行移除（dry-run）。"
    )

    @Argument(help: "TeX 檔案路徑")
    var texFile: String

    func run() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: texFile), encoding: .utf8)
        let allLines = source.components(separatedBy: "\n")

        // Debug: check line 24 (the footnote line)
        let dl24 = allLines[23].trimmingCharacters(in: .whitespaces)
        print("DEBUG L24: '\(dl24.suffix(30))'")
        print("  hasSuffix(\\\\): \(dl24.hasSuffix("\\\\"))")
        let beforeBreak24 = String(dl24.dropLast(2)).trimmingCharacters(in: .whitespaces)
        print("  visibleLen: \(LaTeXNormalizer.estimateVisibleLength(beforeBreak24))")
        print("  minChars=\(Int(88.6*0.75)) maxChars=\(Int(88.6*1.1))")

        // letterpaper, 1in margins, 11pt
        let margins = PDFMargins(top: 0.69, bottom: 0.81, left: 1.0, right: 1.0)
        let (result, count) = LaTeXNormalizer.fixSpuriousLineBreaks(
            source,
            margins: margins,
            paperWidthPt: 612.0,
            bodyFontSizePt: 11.0
        )

        print("\nSpurious line breaks removed: \(count)")

        if count > 0 {
            let origLines = allLines
            let fixedLines = result.components(separatedBy: "\n")
            var shown = 0
            for i in 0..<min(origLines.count, fixedLines.count) {
                if origLines[i] != fixedLines[i] {
                    print("\nLine \(i + 1):")
                    print("  ORIG: \(origLines[i].prefix(120))")
                    if i + 1 < origLines.count {
                        print("  NEXT: \(origLines[i + 1].prefix(120))")
                    }
                    print("  FIX:  \(fixedLines[i].prefix(120))")
                    shown += 1
                    if shown >= 20 { break }
                }
            }
        }
    }
}
