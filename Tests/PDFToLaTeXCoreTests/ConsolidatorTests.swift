import XCTest
@testable import PDFToLaTeXCore

final class ConsolidatorTests: XCTestCase {
    func testMechanicalStepsOnSimpleInput() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let texURL = tmpDir.appendingPathComponent("accumulated.tex")
        let source = """
        \\documentclass{article}
        \\begin{document}
        \\chapter{Introduction}
        \\begin{equation}
        x = 1
        \\end{equation}
        \\end{document}
        """
        try source.write(to: texURL, atomically: true, encoding: .utf8)

        let consolidator = Consolidator()
        let result = try consolidator.runMechanicalSteps(texFileURL: texURL)

        let fixedContent = try String(contentsOf: texURL, encoding: .utf8)
        XCTAssertTrue(fixedContent.contains("\\documentclass{book}"))
        XCTAssertTrue(result.normalizeApplied)
        XCTAssertNotNil(result.projectReport)
        XCTAssertTrue(result.projectReport!.documentClassFixed)
    }

    func testMechanicalStepsWithExternalPreamble() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let preambleURL = tmpDir.appendingPathComponent("preamble.tex")
        try "\\documentclass[11pt]{article}\n\\usepackage{amsmath}".write(
            to: preambleURL, atomically: true, encoding: .utf8
        )

        let texURL = tmpDir.appendingPathComponent("accumulated.tex")
        try "\\input{preamble}\n\\begin{document}\n\\chapter{Ch}\n$\\E(x)$\n\\end{document}".write(
            to: texURL, atomically: true, encoding: .utf8
        )

        let consolidator = Consolidator()
        let result = try consolidator.runMechanicalSteps(texFileURL: texURL)

        XCTAssertTrue(result.normalizeApplied)
        XCTAssertNotNil(result.projectReport)
        XCTAssertTrue(result.projectReport!.documentClassFixed)
        XCTAssertTrue(result.projectReport!.mathOperatorsAdded.contains("E"))

        let preamble = try String(contentsOf: preambleURL, encoding: .utf8)
        XCTAssertTrue(preamble.contains("{book}"))
        XCTAssertTrue(preamble.contains("\\DeclareMathOperator{\\E}{E}"))
    }

    func testMechanicalStepsFixesUnclosedEnv() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let texURL = tmpDir.appendingPathComponent("test.tex")
        let source = "\\begin{equation}\nx = 1"
        try source.write(to: texURL, atomically: true, encoding: .utf8)

        let consolidator = Consolidator()
        let result = try consolidator.runMechanicalSteps(texFileURL: texURL)

        XCTAssertTrue(result.envCheckApplied)
        XCTAssertFalse(result.envIssuesFound.isEmpty)

        let fixedContent = try String(contentsOf: texURL, encoding: .utf8)
        XCTAssertTrue(fixedContent.contains("\\end{equation}"))
    }

    func testBuildAgentPromptContainsErrors() {
        let errors = [
            CompileError(category: .undefinedCommand, line: 42, message: "Undefined control sequence", rawLog: "..."),
            CompileError(category: .missingMath, line: 100, message: "Missing $", rawLog: "..."),
        ]
        let prompt = Consolidator.buildAgentPrompt(errors: errors, texFilePath: "/tmp/test.tex")
        XCTAssertTrue(prompt.contains("Undefined control sequence"))
        XCTAssertTrue(prompt.contains("line 42"))
        XCTAssertTrue(prompt.contains("Missing $"))
        XCTAssertTrue(prompt.contains("line 100"))
        XCTAssertTrue(prompt.contains("/tmp/test.tex"))
    }

    func testDryRunDoesNotInvokeAgent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let texURL = tmpDir.appendingPathComponent("test.tex")
        let source = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"
        try source.write(to: texURL, atomically: true, encoding: .utf8)

        let consolidator = Consolidator()
        let result = try consolidator.consolidate(texFileURL: texURL, dryRun: true)

        XCTAssertFalse(result.agentInvoked)
        XCTAssertEqual(result.agentIterations, 0)
    }

    func testConsolidateCreatesBackup() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let texURL = tmpDir.appendingPathComponent("test.tex")
        let source = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"
        try source.write(to: texURL, atomically: true, encoding: .utf8)

        let consolidator = Consolidator()
        _ = try consolidator.consolidate(texFileURL: texURL, dryRun: true)

        let backupURL = texURL.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testConsolidateDoesNotOverwriteExistingBackup() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let texURL = tmpDir.appendingPathComponent("test.tex")
        let backupURL = texURL.appendingPathExtension("bak")

        // Create original backup with known content
        let originalContent = "ORIGINAL BACKUP CONTENT"
        try originalContent.write(to: backupURL, atomically: true, encoding: .utf8)

        // Create tex file
        try "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}".write(
            to: texURL, atomically: true, encoding: .utf8
        )

        let consolidator = Consolidator()
        _ = try consolidator.consolidate(texFileURL: texURL, dryRun: true)

        // Backup should NOT have been overwritten
        let backupContent = try String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertEqual(backupContent, originalContent)
    }
}
