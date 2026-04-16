import Foundation

/// 編譯錯誤分類。
public enum CompileErrorCategory: String, Codable, Sendable, Equatable {
    case undefinedCommand = "undefined_command"
    case missingMath = "missing_math"
    case missingBrace = "missing_brace"
    case environment = "environment"
    case other
}

/// 結構化的編譯錯誤。
public struct CompileError: Codable, Sendable, Equatable {
    public let category: CompileErrorCategory
    public let line: Int?
    public let message: String
    public let rawLog: String

    public init(category: CompileErrorCategory, line: Int?, message: String, rawLog: String) {
        self.category = category
        self.line = line
        self.message = message
        self.rawLog = rawLog
    }
}

/// 編譯檢查報告。
public struct CompileReport: Codable, Sendable {
    public let texFile: String
    public let errors: [CompileError]
    public let warningCount: Int
    public let success: Bool

    public init(texFile: String, errors: [CompileError], warningCount: Int, success: Bool) {
        self.texFile = texFile
        self.errors = errors
        self.warningCount = warningCount
        self.success = success
    }
}

/// 解析 pdflatex 編譯 log，產生結構化錯誤報告。
public struct TexCompileChecker: Sendable {
    public init() {}

    // MARK: - Parse Log

    /// 解析 pdflatex log 文字，回傳結構化錯誤清單。
    /// 支援兩種格式：
    /// - 傳統格式：`! Error message` + `l.NNN`
    /// - file-line-error 格式：`./file.tex:NNN: Error message`
    public static func parseLog(_ log: String) -> [CompileError] {
        let lines = log.components(separatedBy: "\n")
        var errors: [CompileError] = []
        // file:line:error 格式的 regex
        let fileLinePattern = try! NSRegularExpression(
            pattern: #"^\.?/?[^:]+:(\d+):\s*(.+)"#
        )
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("!") {
                // 傳統 ! 格式
                let errorMessage = String(line.dropFirst().trimmingCharacters(in: .whitespaces))
                let category = categorize(errorMessage)

                var lineNumber: Int? = nil
                var rawLines = [lines[i]]
                for j in (i + 1)..<min(i + 5, lines.count) {
                    rawLines.append(lines[j])
                    let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
                    if let parsed = parseLineNumber(trimmed) {
                        lineNumber = parsed
                        break
                    }
                }

                errors.append(CompileError(
                    category: category,
                    line: lineNumber,
                    message: errorMessage,
                    rawLog: rawLines.joined(separator: "\n")
                ))
            } else {
                // file:line:error 格式
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                if let match = fileLinePattern.firstMatch(in: line, range: range) {
                    let lineNumStr = nsLine.substring(with: match.range(at: 1))
                    let message = nsLine.substring(with: match.range(at: 2))
                        .trimmingCharacters(in: .whitespaces)

                    // 只擷取真正的錯誤（含已知關鍵字），跳過一般訊息
                    if isErrorMessage(message) {
                        let category = categorize(message)
                        let lineNumber = Int(lineNumStr)
                        errors.append(CompileError(
                            category: category,
                            line: lineNumber,
                            message: message,
                            rawLog: lines[i]
                        ))
                    }
                }
            }

            i += 1
        }

        return errors
    }

    /// 判斷 file-line-error 的訊息是否為真正的錯誤。
    private static func isErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        let errorKeywords = [
            "undefined control sequence",
            "missing $", "missing \\$",
            "missing }", "missing \\}",
            "missing {", "missing \\{",
            "latex error",
            "emergency stop",
            "extra }",
            "runaway argument",
            "too many }'s",
        ]
        return errorKeywords.contains { lower.contains($0) }
    }

    // MARK: - Compile

    /// 執行 pdflatex 編譯，回傳結構化報告。
    public func compile(texFileURL: URL) throws -> CompileReport {
        let dir = texFileURL.deletingLastPathComponent()
        let filename = texFileURL.lastPathComponent

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = dir
        process.arguments = [
            "pdflatex",
            "-interaction=nonstopmode",
            "-file-line-error",
            filename,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        // 讀取 .log 檔（比 stdout 更完整）
        let logURL = dir.appendingPathComponent(
            texFileURL.deletingPathExtension().lastPathComponent + ".log"
        )

        let logContent: String
        if FileManager.default.fileExists(atPath: logURL.path) {
            logContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        } else {
            logContent = String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        }

        let errors = Self.parseLog(logContent)
        let warningCount = logContent.components(separatedBy: "LaTeX Warning:").count - 1

        return CompileReport(
            texFile: texFileURL.path,
            errors: errors,
            warningCount: warningCount,
            success: process.terminationStatus == 0 && errors.isEmpty
        )
    }

    /// 將報告寫成 JSON 檔。
    public func writeReport(_ report: CompileReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private static func categorize(_ message: String) -> CompileErrorCategory {
        let lower = message.lowercased()
        if lower.contains("undefined control sequence") {
            return .undefinedCommand
        }
        if lower.contains("missing $ inserted") || lower.contains("missing \\$ inserted") {
            return .missingMath
        }
        if lower.contains("missing } inserted") || lower.contains("missing \\} inserted") {
            return .missingBrace
        }
        if lower.contains("\\begin{") && lower.contains("ended by") {
            return .environment
        }
        if lower.contains("environment") && (lower.contains("undefined") || lower.contains("ended")) {
            return .environment
        }
        return .other
    }

    /// 從 log 行解析行號 (l.NNN 格式)。
    private static func parseLineNumber(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("l.") else { return nil }
        let rest = trimmed.dropFirst(2)
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
