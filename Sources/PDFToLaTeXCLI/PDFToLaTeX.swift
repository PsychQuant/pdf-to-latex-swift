import ArgumentParser
import Foundation
import PDFToLaTeXCore

@main
struct PDFToLatexCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf-to-latex",
        abstract: "macOS 上的 PDF 轉 LaTeX 工作流骨架。",
        discussion: """
        這個 CLI 先處理可重現的本地步驟：建立專案、掃描 PDF 頁面、維護 manifest，
        後續再往 block segmentation、AI 轉寫、像素驗證與 lossless 組裝擴充。
        """,
        version: "0.2.0",
        subcommands: [
            InitProjectCommand.self,
            SegmentCommand.self,
            RenderPagesCommand.self,
            SegmentBlocksCommand.self,
            TranscribeBlocksCommand.self,
            TranscribePagesCommand.self,
            ResumeCommand.self,
            DetectChaptersCommand.self,
            AssembleTexCommand.self,
            ScanStructureCommand.self,
            CompareCommand.self,
            DetectSourceCommand.self,
            TitleFontsCommand.self,
            FixTitleTestCommand.self,
            FixLinebreakTestCommand.self,
            StatusCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

extension ChapterStrategy: ExpressibleByArgument {}
