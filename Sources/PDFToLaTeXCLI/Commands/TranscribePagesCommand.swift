import ArgumentParser
import Foundation
import PDFToLaTeXCore

struct TranscribePagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe-pages",
        abstract: "Page-level 轉寫：整頁送 AI，搭配 LaTeX context sliding window。"
    )

    @Option(name: .long, help: "專案資料夾。")
    var project: String?

    @Option(name: .long, help: "來源 PDF。")
    var pdf: String?

    @Option(name: .long, help: "輸出資料夾。")
    var output: String?

    @Option(name: .long, help: "起始頁碼。")
    var firstPage: Int?

    @Option(name: .long, help: "結束頁碼。")
    var lastPage: Int?

    @Option(name: .long, help: "頁面渲染 DPI。")
    var pageDPI: Double = 144

    @Option(name: .long, help: "AI 模型名稱（預設依 backend: claude=claude-sonnet-4-6, codex=gpt-5.4, gemini=gemini-3.1-pro-preview）。")
    var model: String?

    @Option(name: .long, help: "AI CLI 後端 (codex|claude|gemini)。預設從 model 名稱自動偵測，未指定 model 時預設 claude。")
    var backend: String?

    @Option(name: .long, help: "每次送幾頁（預設 2）。")
    var pagesPerRequest: Int?

    @Option(name: .long, help: "Reasoning effort (none|low|medium|high|xhigh)。")
    var reasoningEffort: String = "medium"

    @Option(name: .long, help: "單次請求超時秒數。")
    var timeoutSeconds: Double = 600

    mutating func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resolver = ProjectResolver()
        let pipeline = BlockSegmentationPipeline()

        var resolvedProject = try resolver.resolve(
            project: project, pdf: pdf, output: output, cwd: cwd
        )
        try pipeline.ensurePageRecords(in: &resolvedProject)
        let pageNumbers = try pipeline.resolvePageNumbers(
            total: resolvedProject.manifest.pages.count,
            firstPage: firstPage, lastPage: lastPage
        )

        // Ensure pages are rendered
        try pipeline.ensureRenderedPages(
            in: &resolvedProject, pageNumbers: pageNumbers, dpi: pageDPI
        )

        let resolvedBackend: TranscriptionBackend
        if let b = backend.flatMap({ TranscriptionBackend(rawValue: $0) }) {
            resolvedBackend = b
        } else if let m = model {
            resolvedBackend = TranscriptionBackend.detect(from: m)
        } else {
            resolvedBackend = .codex
        }
        let resolvedModel = model ?? resolvedBackend.defaultModel
        let resolvedEffort = ReasoningEffort(rawValue: reasoningEffort) ?? .medium

        let transcriber = PageTranscriber()
        let results = try transcriber.transcribe(
            project: &resolvedProject,
            pageNumbers: pageNumbers,
            pagesPerRequest: pagesPerRequest,
            backend: resolvedBackend,
            model: resolvedModel,
            reasoningEffort: resolvedEffort,
            timeoutSeconds: timeoutSeconds
        )

        let figureCount = results.reduce(0) { $0 + $1.figures.count }
        print("已轉寫 \(results.count) 頁，裁切 \(figureCount) 個 figures。")
        print("project: \(resolvedProject.root.path)")
    }
}
