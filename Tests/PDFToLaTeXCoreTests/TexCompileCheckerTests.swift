import XCTest
@testable import PDFToLaTeXCore

final class TexCompileCheckerTests: XCTestCase {
    func testParseUndefinedCommand() {
        let log = """
        ! Undefined control sequence.
        l.42 \\bm
                {x}
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].category, .undefinedCommand)
        XCTAssertEqual(errors[0].line, 42)
    }

    func testParseMissingMath() {
        let log = """
        ! Missing $ inserted.
        <inserted text>
                        $
        l.100 Some text with x_i
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].category, .missingMath)
        XCTAssertEqual(errors[0].line, 100)
    }

    func testParseMissingBrace() {
        let log = """
        ! Missing } inserted.
        l.55 \\textbf{hello
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].category, .missingBrace)
        XCTAssertEqual(errors[0].line, 55)
    }

    func testParseEnvironmentError() {
        let log = """
        ! LaTeX Error: \\begin{equation} on input line 10 ended by \\end{align}.
        l.12 \\end{align}
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].category, .environment)
    }

    func testParseMultipleErrors() {
        let log = """
        ! Undefined control sequence.
        l.10 \\bm
                {x}

        ! Missing $ inserted.
        l.20 some x_i

        ! Missing } inserted.
        l.30 \\textbf{hello
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors[0].category, .undefinedCommand)
        XCTAssertEqual(errors[1].category, .missingMath)
        XCTAssertEqual(errors[2].category, .missingBrace)
    }

    func testParseCleanLog() {
        let log = """
        This is pdfTeX, Version 3.14
        Output written on test.pdf (1 page)
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertTrue(errors.isEmpty)
    }

    func testParseOtherError() {
        let log = """
        ! Some unknown error here.
        l.5 blah
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].category, .other)
    }

    func testParseFileLineErrorFormat() {
        let log = """
        ./accumulated.tex:425: Undefined control sequence.
        ./accumulated.tex:467: Undefined control sequence.
        ./accumulated.tex:100: Missing $ inserted.
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors[0].category, .undefinedCommand)
        XCTAssertEqual(errors[0].line, 425)
        XCTAssertEqual(errors[1].line, 467)
        XCTAssertEqual(errors[2].category, .missingMath)
        XCTAssertEqual(errors[2].line, 100)
    }

    func testParseFileLineErrorIgnoresNonErrors() {
        let log = """
        This is pdfTeX, Version 3.141592653
        ./accumulated.tex:425: Undefined control sequence.
        [1] [2] [3]
        Output written on test.pdf
        """
        let errors = TexCompileChecker.parseLog(log)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].category, .undefinedCommand)
    }

    func testCompileReportEncoding() throws {
        let report = CompileReport(
            texFile: "/tmp/test.tex",
            errors: [
                CompileError(category: .undefinedCommand, line: 42, message: "Undefined", rawLog: "...")
            ],
            warningCount: 2,
            success: false
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CompileReport.self, from: data)
        XCTAssertEqual(decoded.errors.count, 1)
        XCTAssertEqual(decoded.errors[0].category, .undefinedCommand)
        XCTAssertEqual(decoded.warningCount, 2)
        XCTAssertFalse(decoded.success)
    }
}
