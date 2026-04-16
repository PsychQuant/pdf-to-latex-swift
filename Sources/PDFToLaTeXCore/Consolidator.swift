import Foundation

/// 機械步驟的執行結果。
public struct MechanicalResult: Sendable {
    public let normalizeApplied: Bool
    public let envCheckApplied: Bool
    public let envIssuesFound: [EnvIssue]
    public let compileErrors: [CompileError]
    public let compileReport: CompileReport?
    public let projectReport: NormalizeProjectReport?

    public init(
        normalizeApplied: Bool, envCheckApplied: Bool,
        envIssuesFound: [EnvIssue], compileErrors: [CompileError],
        compileReport: CompileReport?,
        projectReport: NormalizeProjectReport? = nil
    ) {
        self.normalizeApplied = normalizeApplied
        self.envCheckApplied = envCheckApplied
        self.envIssuesFound = envIssuesFound
        self.compileErrors = compileErrors
        self.compileReport = compileReport
        self.projectReport = projectReport
    }
}

/// 完整 consolidation pipeline 的結果。
public struct ConsolidationResult: Sendable {
    public let mechanicalResult: MechanicalResult
    public let agentInvoked: Bool
    public let agentIterations: Int
    public let finalErrors: [CompileError]
    public let success: Bool

    public init(
        mechanicalResult: MechanicalResult, agentInvoked: Bool,
        agentIterations: Int, finalErrors: [CompileError], success: Bool
    ) {
        self.mechanicalResult = mechanicalResult
        self.agentInvoked = agentInvoked
        self.agentIterations = agentIterations
        self.finalErrors = finalErrors
        self.success = success
    }
}

/// 編排完整的 LaTeX consolidation pipeline。
/// 先跑機械步驟（normalize → fix-envs → compile-check），再用 AI agent 修復剩餘錯誤。
/// 所有機械步驟皆為冪等，重複執行不會覆蓋先前的修正。
public struct Consolidator: Sendable {
    public let normalizer: LaTeXNormalizer
    public let envChecker: LaTeXEnvChecker
    public let compileChecker: TexCompileChecker

    public init(
        normalizer: LaTeXNormalizer = LaTeXNormalizer(
            symbolRules: ["\\bm{": "\\boldsymbol{"],
            stripPageMarkers: false
        ),
        envChecker: LaTeXEnvChecker = LaTeXEnvChecker(),
        compileChecker: TexCompileChecker = TexCompileChecker()
    ) {
        self.normalizer = normalizer
        self.envChecker = envChecker
        self.compileChecker = compileChecker
    }

    // MARK: - Mechanical Steps

    /// 執行所有機械步驟（不呼叫 agent）。
    /// 使用專案層級正規化，處理外部 preamble、數學運算子、貨幣符號等。
    public func runMechanicalSteps(texFileURL: URL) throws -> MechanicalResult {
        // 1. 專案層級正規化（含 preamble 解析、document class 修正、
        //    數學運算子偵測、貨幣 $ 跳脫、符號替換、跨頁重複移除）
        let projectReport = try normalizer.normalizeProject(mainTexURL: texFileURL)
        let normalizeApplied = projectReport.mainFileChanged || projectReport.preambleFileChanged

        // 2. 重新讀取（normalizeProject 可能已修改檔案）
        var source = try String(contentsOf: texFileURL, encoding: .utf8)

        // 3. Environment check + fix
        let issues = envChecker.check(source)
        let envCheckApplied = !issues.isEmpty
        if envCheckApplied {
            let fixed = envChecker.fix(source)
            source = fixed
            try source.write(to: texFileURL, atomically: true, encoding: .utf8)
        }

        // 4. Compile check（需要 pdflatex 可用）
        var compileErrors: [CompileError] = []
        var compileReport: CompileReport? = nil
        if isCommandAvailable("pdflatex") {
            let report = try compileChecker.compile(texFileURL: texFileURL)
            compileErrors = report.errors
            compileReport = report
        }

        return MechanicalResult(
            normalizeApplied: normalizeApplied,
            envCheckApplied: envCheckApplied,
            envIssuesFound: issues,
            compileErrors: compileErrors,
            compileReport: compileReport,
            projectReport: projectReport
        )
    }

    // MARK: - Agent Prompt

    /// 根據剩餘錯誤生成 agent prompt。
    public static func buildAgentPrompt(errors: [CompileError], texFilePath: String) -> String {
        var prompt = """
        You are a LaTeX expert. Fix ONLY the listed compilation errors in the file below.
        Do NOT rewrite, restructure, or reformat any code. Only fix the specific errors.

        File: \(texFilePath)

        Errors to fix:
        """

        for (i, error) in errors.enumerated() {
            let lineInfo = error.line.map { "line \($0)" } ?? "unknown line"
            prompt += "\n\(i + 1). [\(error.category.rawValue)] \(error.message) at \(lineInfo)"
        }

        prompt += """

        \nInstructions:
        - Read the file, fix each error, and write the corrected file back.
        - For undefined commands: add \\usepackage or \\newcommand as needed.
        - For missing $: wrap the expression in $ delimiters.
        - For missing }: add the missing brace.
        - For environment mismatches: correct the \\end{} name.
        - Do not change anything else.
        """

        return prompt
    }

    // MARK: - Full Pipeline

    /// 執行完整 consolidation pipeline（機械 + agent）。
    /// `sourceFormat`: PDF 來源格式，影響正規化策略（預留，目前傳入但尚未改變 normalizer 行為）。
    public func consolidate(
        texFileURL: URL,
        agent: TranscriptionBackend = .claude,
        model: String? = nil,
        dryRun: Bool = false,
        maxIterations: Int = 3,
        sourceFormat: PDFSourceFormat = .unknown
    ) throws -> ConsolidationResult {
        // Backup（冪等：只在沒有 .bak 時建立，避免覆蓋之前的備份）
        let backupURL = texFileURL.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            let source = try String(contentsOf: texFileURL, encoding: .utf8)
            try source.write(to: backupURL, atomically: true, encoding: .utf8)
        }

        // Mechanical steps
        let mechanical = try runMechanicalSteps(texFileURL: texFileURL)

        guard !dryRun else {
            return ConsolidationResult(
                mechanicalResult: mechanical,
                agentInvoked: false,
                agentIterations: 0,
                finalErrors: mechanical.compileErrors,
                success: mechanical.compileErrors.isEmpty
            )
        }

        // Agent loop
        var currentErrors = mechanical.compileErrors
        var iterations = 0

        while !currentErrors.isEmpty && iterations < maxIterations {
            iterations += 1

            let prompt = Self.buildAgentPrompt(errors: currentErrors, texFilePath: texFileURL.path)
            try invokeAgent(agent: agent, model: model, prompt: prompt, projectRoot: texFileURL.deletingLastPathComponent())

            // Re-check
            if isCommandAvailable("pdflatex") {
                let report = try compileChecker.compile(texFileURL: texFileURL)
                currentErrors = report.errors
            } else {
                break
            }
        }

        return ConsolidationResult(
            mechanicalResult: mechanical,
            agentInvoked: iterations > 0,
            agentIterations: iterations,
            finalErrors: currentErrors,
            success: currentErrors.isEmpty
        )
    }

    // MARK: - Private

    private func invokeAgent(
        agent: TranscriptionBackend,
        model: String?,
        prompt: String,
        projectRoot: URL
    ) throws {
        let resolvedModel = model ?? agent.defaultModel
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = projectRoot

        switch agent {
        case .codex:
            process.arguments = [
                "codex", "exec",
                "-C", projectRoot.path,
                "-s", "full",
                "-m", resolvedModel,
                "-p", prompt,
            ]
        case .claude:
            process.arguments = [
                "claude",
                "-p", prompt,
                "--model", resolvedModel,
                "--allowedTools", "Read,Write,Bash",
            ]
        case .gemini:
            process.arguments = [
                "gemini",
                "-p", prompt,
                "--model", resolvedModel,
            ]
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()
    }

    private func isCommandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
