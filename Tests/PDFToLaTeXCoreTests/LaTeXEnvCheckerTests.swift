import XCTest
@testable import PDFToLaTeXCore

final class LaTeXEnvCheckerTests: XCTestCase {
    func testMatchedEnvironments_noIssues() {
        let input = "\\begin{equation}\nx = 1\n\\end{equation}"
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertTrue(issues.isEmpty)
    }

    func testUnclosedEnvironment() {
        let input = "\\begin{equation}\nx = 1"
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .unclosed)
        XCTAssertEqual(issues[0].environment, "equation")
    }

    func testExtraClosed() {
        let input = "x = 1\n\\end{equation}"
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .extraClose)
    }

    func testMismatch() {
        let input = "\\begin{equation}\nx = 1\n\\end{align}"
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertFalse(issues.isEmpty)
    }

    func testNestedEnvironments() {
        let input = """
        \\begin{theorem}
        \\begin{equation}
        x = 1
        \\end{equation}
        \\end{theorem}
        """
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertTrue(issues.isEmpty)
    }

    func testAutoFix_unclosed() {
        let input = "\\begin{equation}\nx = 1"
        let fixed = LaTeXEnvChecker().fix(input)
        XCTAssertTrue(fixed.contains("\\end{equation}"))
    }

    func testAutoFix_extraClose() {
        let input = "x = 1\n\\end{equation}"
        let fixed = LaTeXEnvChecker().fix(input)
        XCTAssertFalse(fixed.contains("\\end{equation}"))
    }

    func testMultipleIssues() {
        let input = """
        \\begin{theorem}
        Some text
        \\begin{equation}
        x = 1
        """
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertEqual(issues.count, 2)
        let kinds = Set(issues.map(\.kind))
        XCTAssertEqual(kinds, [.unclosed])
    }

    func testSameLineBeginEnd() {
        let input = "\\begin{equation}x = 1\\end{equation}"
        let issues = LaTeXEnvChecker().check(input)
        XCTAssertTrue(issues.isEmpty)
    }
}
