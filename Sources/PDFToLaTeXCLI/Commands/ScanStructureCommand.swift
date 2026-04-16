import ArgumentParser
import Foundation
import PDFToLaTeXCore

struct ScanStructureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan-structure",
        abstract: "掃描 PDF 結構：TOC 章節偵測 + 頁面 layout 分析。"
    )

    @Option(name: .long, help: "來源 PDF。")
    var pdf: String

    @Option(name: .long, help: "專案目錄（指定後會將結果存入 structure.json + layouts/）。")
    var project: String?

    @Option(name: .long, help: "只分析特定頁面（物理頁碼）。")
    var page: Int?

    @Flag(name: .long, help: "顯示每頁的 region 詳細資訊。")
    var verbose: Bool = false

    func run() throws {
        let pdfURL = URL(fileURLWithPath: pdf)
        let scanner = PDFStructureScanner()

        if let pageNum = page {
            // 只分析單頁
            let layout = try scanner.scanPageLayout(pdfURL: pdfURL, pageNumber: pageNum)
            printPageLayout(layout)
            return
        }

        // 全書掃描
        let structure: PDFStructureScanner.DocumentStructure

        if let projectPath = project {
            // 有指定專案目錄 → 掃描 + 持久化
            let store = StructureStore(projectRoot: URL(fileURLWithPath: projectPath))
            structure = try store.scanAndSave(pdfURL: pdfURL)
            print("已儲存: structure.json + \(structure.pageLayouts.count) 頁 layout 到 layouts/")
            print()
        } else {
            // 無專案 → 只印結果不存檔
            structure = try scanner.scan(pdfURL: pdfURL)
        }

        print("=== Document Structure ===")
        print("pdf_type: \(structure.pdfType.rawValue)")
        print("total_pages: \(structure.totalPages)")
        print("page_offset: \(structure.pageOffset)")
        print("chapters: \(structure.chapters.count)")
        print()

        for ch in structure.chapters {
            print("\(ch.id): \(ch.startPage)-\(ch.endPage) \(ch.title)")
        }

        if verbose {
            print()
            print("=== Page Layouts ===")
            for layout in structure.pageLayouts {
                guard !layout.regions.isEmpty else { continue }
                printPageLayout(layout)
            }
        } else {
            // 摘要統計
            print()
            var typeCounts: [String: Int] = [:]
            for layout in structure.pageLayouts {
                for r in layout.regions {
                    typeCounts[r.type.rawValue, default: 0] += 1
                }
            }
            print("=== Region Stats ===")
            for (type, count) in typeCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(type): \(count)")
            }
        }
    }

    private func printPageLayout(_ layout: PDFStructureScanner.PageLayout) {
        print("Page \(layout.pageNumber): \(layout.regions.count) regions, \(layout.charCount) chars")
        for r in layout.regions {
            let preview = String(r.text.prefix(60)).replacingOccurrences(of: "\n", with: "↵")
            let typeStr = r.type.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(typeStr) y=\(Int(r.y))-\(Int(r.y + r.height))  \(preview)")
        }
    }
}
