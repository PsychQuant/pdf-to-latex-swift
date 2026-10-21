import Testing
@testable import PDFToLaTeXCore

/// Both paper lines report a class (nearest standard size, ±3 mm), never a
/// size, so a near-A4 page cannot read as an exact A4 match.
struct PaperClassLineTests {

    @Test("the typography line is labelled as a class with its tolerance")
    func typographyLine() {
        let line = PDFComparator.paperClassLine(original: "a4paper", reproduced: "a4paper")
        #expect(line == "  Paper class: orig=a4paper  repr=a4paper  [MATCH] (page 1, ±3 mm)")
        #expect(!line.contains("Paper size"))
    }

    @Test("different classes are a mismatch")
    func typographyMismatch() {
        #expect(PDFComparator.paperClassLine(original: "a4paper", reproduced: "letterpaper").contains("[MISMATCH]"))
    }

    @Test("the summary line is labelled as a class", arguments: [(true, true, "OK", "OK"), (false, true, "MISMATCH", "OK"),
                                                                    (true, false, "OK", "MISMATCH")])
    func summaryLine(paper: Bool, font: Bool, paperText: String, fontText: String) {
        let line = PDFComparator.summaryPaperClassLine(paperMatches: paper, fontMatches: font)
        #expect(line == "  Paper class: \(paperText)  Font: \(fontText)")
        #expect(!line.contains("Paper size"))
    }
}
