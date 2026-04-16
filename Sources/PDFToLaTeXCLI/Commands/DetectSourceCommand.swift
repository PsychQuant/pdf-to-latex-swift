import ArgumentParser
import Foundation
import PDFToLaTeXCore

struct DetectSourceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect-source",
        abstract: "Detect the likely source format of a PDF (LaTeX, Word, scanned, etc.)."
    )

    @Argument(help: "Path to the PDF file.")
    var pdf: String

    @Flag(name: .long, help: "Output as JSON.")
    var json: Bool = false

    func run() throws {
        let url = URL(fileURLWithPath: (pdf as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(pdf)")
        }

        let detector = PDFSourceDetector()
        let result = detector.detect(from: url)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
        } else {
            printHumanReadable(result, file: url.lastPathComponent)
        }
    }

    private func printHumanReadable(_ result: PDFSourceDetection, file: String) {
        print("detect-source: \(file)")
        print("─────────────────────────────────────")
        print("  Format:     \(result.format.rawValue)")
        if let engine = result.engine {
            print("  Engine:     \(engine.rawValue)")
        }
        print("  Confidence: \(String(format: "%.0f%%", result.confidence * 100))")
        if let c = result.creator {
            print("  Creator:    \(c)")
        }
        if let p = result.producer {
            print("  Producer:   \(p)")
        }
        print("")
        print("  Evidence:")
        for e in result.evidence {
            print("    - \(e)")
        }
    }
}
