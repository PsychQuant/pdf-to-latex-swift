import XCTest
@testable import PDFToLaTeXCore

final class ModelsTests: XCTestCase {
    func testBlockStatusRunnableWithoutOverwrite() {
        XCTAssertTrue(BlockStatus.segmented.isRunnableWithoutOverwrite)
        XCTAssertTrue(BlockStatus.queued.isRunnableWithoutOverwrite)
        XCTAssertTrue(BlockStatus.failed.isRunnableWithoutOverwrite)
        XCTAssertFalse(BlockStatus.pending.isRunnableWithoutOverwrite)
        XCTAssertFalse(BlockStatus.transcribed.isRunnableWithoutOverwrite)
    }

    func testBlockStatusCountsAsSuccess() {
        XCTAssertTrue(BlockStatus.transcribed.countsAsSuccess)
        XCTAssertTrue(BlockStatus.fallbackImage.countsAsSuccess)
        XCTAssertFalse(BlockStatus.failed.countsAsSuccess)
        XCTAssertFalse(BlockStatus.pending.countsAsSuccess)
    }

    func testManifestCodable() throws {
        let manifest = ProjectManifest(
            schemaVersion: 2,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
            projectName: "test",
            sourcePDF: "/tmp/test.pdf",
            projectRoot: "/tmp/test",
            pages: [],
            blocks: []
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded.projectName, "test")
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testManifestWithoutOCRResultsLoadsWithEmptyDefault() throws {
        let json = """
        {
            "schemaVersion": 2,
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "projectName": "old-project",
            "sourcePDF": "/tmp/old.pdf",
            "projectRoot": "/tmp/old",
            "pages": [],
            "blocks": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProjectManifest.self, from: json)
        XCTAssertEqual(decoded.projectName, "old-project")
        XCTAssertTrue(decoded.ocrResults.isEmpty)
    }

    func testManifestWithOCRResultsRoundTrips() throws {
        let manifest = ProjectManifest(
            schemaVersion: 3,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
            projectName: "ocr-project",
            sourcePDF: "/tmp/test.pdf",
            projectRoot: "/tmp/test",
            pages: [],
            blocks: [],
            ocrResults: [
                PageOCRResult(
                    pageNumber: 1,
                    ocrText: "Hello world",
                    pdfkitText: "Hello world",
                    agreement: 1.0,
                    hasConflicts: false
                )
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded.ocrResults.count, 1)
        XCTAssertEqual(decoded.ocrResults[0].pageNumber, 1)
        XCTAssertEqual(decoded.ocrResults[0].ocrText, "Hello world")
        XCTAssertEqual(decoded.ocrResults[0].agreement, 1.0)
    }
}
