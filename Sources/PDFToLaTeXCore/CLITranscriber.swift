import Foundation

/// 透過外部 CLI 工具（codex / claude / gemini）進行 block → LaTeX 轉寫。
/// 每個後端呼叫對應的 CLI binary，使用者須事先安裝並設定好認證。
public struct CLITranscriber: Sendable {
    public let backend: TranscriptionBackend

    public init(backend: TranscriptionBackend = .codex) {
        self.backend = backend
    }

    public func transcribeBlock(
        projectRoot: URL,
        block: BlockRecord,
        model: String,
        prompt: String,
        schemaURL: URL,
        outputURL: URL,
        timeoutSeconds: Double
    ) throws -> TranscriptionResult {
        guard block.imagePath != nil else {
            throw PDFToLaTeXError.cliInvalidResponse(backend.rawValue, "block 沒有 imagePath: \(block.id)")
        }

        switch backend {
        case .codex:
            return try runCodex(
                projectRoot: projectRoot, block: block, model: model,
                prompt: prompt, schemaURL: schemaURL, outputURL: outputURL,
                timeoutSeconds: timeoutSeconds
            )
        case .claude:
            return try runClaude(
                projectRoot: projectRoot, block: block, model: model,
                prompt: prompt, outputURL: outputURL, timeoutSeconds: timeoutSeconds
            )
        case .gemini:
            return try runGemini(
                projectRoot: projectRoot, block: block, model: model,
                prompt: prompt, outputURL: outputURL, timeoutSeconds: timeoutSeconds
            )
        }
    }

    /// 寫出 Codex 用的 JSON schema 檔（claude/gemini 不需要，schema 內嵌在 prompt 裡）。
    public func writeSchema(to url: URL) throws {
        let schema = """
        {
          "type": "object",
          "properties": {
            "latex": { "type": "string" },
            "confidence": { "type": ["number", "null"] },
            "needsFallback": { "type": "boolean" },
            "notes": { "type": ["string", "null"] }
          },
          "required": ["latex", "confidence", "needsFallback", "notes"],
          "additionalProperties": false
        }
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try schema.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Page-level Transcription

    /// Page-level 轉寫：送多張頁面圖片，回傳 PageTranscriptionResponse。
    public func transcribePages(
        projectRoot: URL,
        pageImages: [(pageNumber: Int, imagePath: String)],
        model: String,
        reasoningEffort: ReasoningEffort = .medium,
        prompt: String,
        schemaURL: URL,
        outputURL: URL,
        timeoutSeconds: Double
    ) throws -> PageTranscriptionResponse {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        switch backend {
        case .codex:
            return try runCodexPages(
                projectRoot: projectRoot, pageImages: pageImages, model: model,
                reasoningEffort: reasoningEffort,
                prompt: prompt, schemaURL: schemaURL, outputURL: outputURL,
                timeoutSeconds: timeoutSeconds
            )
        case .claude, .gemini:
            return try runDirectCLIPages(
                projectRoot: projectRoot, pageImages: pageImages, model: model,
                prompt: prompt, outputURL: outputURL, timeoutSeconds: timeoutSeconds
            )
        }
    }

    private func runCodexPages(
        projectRoot: URL,
        pageImages: [(pageNumber: Int, imagePath: String)],
        model: String, reasoningEffort: ReasoningEffort,
        prompt: String, schemaURL: URL, outputURL: URL,
        timeoutSeconds: Double
    ) throws -> PageTranscriptionResponse {
        var args = [
            "codex", "exec",
            "-C", projectRoot.path,
            "--skip-git-repo-check",
            "--color", "never",
            "--json",
            "-s", "read-only",
            "-c", "model_reasoning_effort=\"\(reasoningEffort.rawValue)\"",
            "-m", model
        ]
        for img in pageImages {
            args += ["-i", img.imagePath]
        }
        args += ["--output-schema", schemaURL.path, "-o", outputURL.path, "-"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let (_, _) = try executeProcess(
            process, timeout: timeoutSeconds,
            stdinData: prompt.data(using: .utf8)
        )

        let data = try Data(contentsOf: outputURL)
        do {
            return try JSONDecoder().decode(PageTranscriptionResponse.self, from: data)
        } catch {
            throw PDFToLaTeXError.cliInvalidResponse(
                backend.rawValue, String(data: data, encoding: .utf8) ?? "無法讀取輸出"
            )
        }
    }

    private func runDirectCLIPages(
        projectRoot: URL,
        pageImages: [(pageNumber: Int, imagePath: String)],
        model: String, prompt: String, outputURL: URL,
        timeoutSeconds: Double
    ) throws -> PageTranscriptionResponse {
        let binaryName = backend == .claude ? "claude" : "gemini"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = projectRoot

        if backend == .claude {
            process.arguments = [
                binaryName, "-p", prompt,
                "--model", model,
                "--output-format", "text",
                "--max-turns", "3"
            ]
        } else {
            process.arguments = [binaryName, "-p", prompt, "--model", model]
        }

        let (stdout, _) = try executeProcess(process, timeout: timeoutSeconds, stdinData: nil)
        try stdout.write(to: outputURL, atomically: true, encoding: .utf8)
        return try parsePageJSONFromText(stdout)
    }

    private func parsePageJSONFromText(_ text: String) throws -> PageTranscriptionResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            let inner = lines.dropFirst().reversed().drop(while: { $0.hasPrefix("```") }).reversed()
            jsonString = inner.joined(separator: "\n")
        } else {
            jsonString = trimmed
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw PDFToLaTeXError.cliInvalidResponse(backend.rawValue,text)
        }
        do {
            return try JSONDecoder().decode(PageTranscriptionResponse.self, from: data)
        } catch {
            throw PDFToLaTeXError.cliInvalidResponse(backend.rawValue,text)
        }
    }

    // MARK: - Block-level (legacy)

    // MARK: - Codex

    private func runCodex(
        projectRoot: URL, block: BlockRecord, model: String,
        prompt: String, schemaURL: URL, outputURL: URL, timeoutSeconds: Double
    ) throws -> TranscriptionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "codex", "exec",
            "-C", projectRoot.path,
            "--skip-git-repo-check",
            "--color", "never",
            "--json",
            "-s", "read-only",
            "-c", "model_reasoning_effort=\"low\"",
            "-m", model,
            "-i", block.imagePath!,
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            "-"
        ]

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let (_, _) = try executeProcess(
            process, timeout: timeoutSeconds,
            stdinData: prompt.data(using: .utf8)
        )

        let data = try Data(contentsOf: outputURL)
        do {
            return try JSONDecoder().decode(TranscriptionResult.self, from: data)
        } catch {
            throw PDFToLaTeXError.cliInvalidResponse(backend.rawValue,
                String(data: data, encoding: .utf8) ?? "無法讀取輸出"
            )
        }
    }

    // MARK: - Claude

    private func runClaude(
        projectRoot: URL, block: BlockRecord, model: String,
        prompt: String, outputURL: URL, timeoutSeconds: Double
    ) throws -> TranscriptionResult {
        let fullPrompt = PromptBuilder.augmentForDirectCLI(
            basePrompt: prompt, imagePath: block.imagePath!
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "claude",
            "-p", fullPrompt,
            "--model", model,
            "--output-format", "text",
            "--max-turns", "3"
        ]
        process.currentDirectoryURL = projectRoot

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let (stdout, _) = try executeProcess(process, timeout: timeoutSeconds, stdinData: nil)
        let result = try parseJSONFromText(stdout)
        try stdout.write(to: outputURL, atomically: true, encoding: .utf8)
        return result
    }

    // MARK: - Gemini

    private func runGemini(
        projectRoot: URL, block: BlockRecord, model: String,
        prompt: String, outputURL: URL, timeoutSeconds: Double
    ) throws -> TranscriptionResult {
        let fullPrompt = PromptBuilder.augmentForDirectCLI(
            basePrompt: prompt, imagePath: block.imagePath!
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "gemini",
            "-p", fullPrompt,
            "--model", model
        ]
        process.currentDirectoryURL = projectRoot

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let (stdout, _) = try executeProcess(process, timeout: timeoutSeconds, stdinData: nil)
        let result = try parseJSONFromText(stdout)
        try stdout.write(to: outputURL, atomically: true, encoding: .utf8)
        return result
    }

    // MARK: - Shared Helpers

    private func executeProcess(
        _ process: Process, timeout: Double, stdinData: Data?
    ) throws -> (stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw PDFToLaTeXError.cliNotFound(backend.rawValue)
        }

        if let data = stdinData {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            throw PDFToLaTeXError.cliTimedOut(backend.rawValue, timeout)
        }

        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            throw PDFToLaTeXError.cliFailed(backend.rawValue, process.terminationStatus, combined)
        }

        return (stdout, stderr)
    }

    /// 從 CLI stdout 文字中解析 JSON。處理可能的 markdown code fence 包裹。
    private func parseJSONFromText(_ text: String) throws -> TranscriptionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 嘗試去除 markdown code fence
        let jsonString: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            let inner = lines.dropFirst().reversed().drop(while: { $0.hasPrefix("```") }).reversed()
            jsonString = inner.joined(separator: "\n")
        } else {
            jsonString = trimmed
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw PDFToLaTeXError.cliInvalidResponse(backend.rawValue,text)
        }

        do {
            return try JSONDecoder().decode(TranscriptionResult.self, from: data)
        } catch {
            throw PDFToLaTeXError.cliInvalidResponse(backend.rawValue,text)
        }
    }
}
