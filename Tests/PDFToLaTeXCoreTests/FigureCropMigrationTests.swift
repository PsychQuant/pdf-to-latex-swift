import CoreGraphics
import XCTest
@testable import PDFToLaTeXCore

/// 舊專案重新裁切遷移（不呼叫 AI，PsychQuant/pdf-to-latex-swift#222）。
final class FigureCropMigrationTests: XCTestCase {

    private var projectDir: URL!

    override func setUpWithError() throws {
        projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectDir)
    }

    // MARK: - Fixture helpers

    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    private static let red: RGB = (255, 0, 0)
    private static let blue: RGB = (0, 0, 255)

    private func writePageImage(page: Int, color: RGB) throws -> String {
        let size = 100
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(
            red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = projectDir.appendingPathComponent(String(format: "pages/page-%04d.png", page))
        try CGImageHelper.writePNG(try XCTUnwrap(context.makeImage()), to: url)
        return url.path
    }

    private func inspect(_ relativePath: String) throws -> (width: Int, height: Int, color: RGB) {
        let image = try CGImageHelper.load(from: projectDir.appendingPathComponent(relativePath))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (image.width, image.height, (pixel[0], pixel[1], pixel[2]))
    }

    private func writeResponses(_ pages: [PageResult], filename: String = "pages-all.json") throws {
        let dir = projectDir.appendingPathComponent("responses")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(PageTranscriptionResponse(pages: pages)).write(to: dir.appendingPathComponent(filename))
    }

    private func writePageTex(page: Int, content: String) throws {
        let dir = projectDir.appendingPathComponent("tex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(
            to: dir.appendingPathComponent(String(format: "page-%04d.tex", page)), atomically: true, encoding: .utf8
        )
    }

    private func readPageTex(page: Int) throws -> String {
        try String(
            contentsOf: projectDir.appendingPathComponent(String(format: "tex/page-%04d.tex", page)), encoding: .utf8
        )
    }

    private func makeProject(pages: [PageRecord]) -> ResolvedProject {
        let manifest = ProjectManifest(
            schemaVersion: 1, createdAt: "", updatedAt: "", projectName: "t",
            sourcePDF: "", projectRoot: projectDir.path, pages: pages, blocks: []
        )
        return ResolvedProject(
            root: projectDir, manifestURL: projectDir.appendingPathComponent("manifest.json"),
            manifest: manifest, pdfURL: projectDir.appendingPathComponent("source.pdf")
        )
    }

    // MARK: - Tests

    /// 核心場景：舊格式引用 `figures/fig1.png`，重新裁切成 `figures/p005-fig1.png` 並補寬度。
    func testMigratesOldStyleReferenceToPagePrefixedCropAndAddsWidth() throws {
        let image = try writePageImage(page: 5, color: Self.red)
        try writePageTex(page: 5, content: "Intro.\n\\includegraphics{figures/fig1.png}\nMore text.")
        try writeResponses([PageResult(
            page: 5, latex: "", figures: [FigureRegion(id: "fig1", bbox: [0.1, 0.1, 0.4, 0.3], caption: nil)],
            confidence: nil, notes: nil
        )])
        let project = makeProject(pages: [
            PageRecord(number: 5, width: 612, height: 792, rotation: 0, renderedImagePath: image, renderedDPI: nil),
        ])

        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [5])

        XCTAssertEqual(outcomes.count, 1)
        guard case .migrated(let figuresProcessed) = outcomes[0].kind else {
            return XCTFail("預期 .migrated，實際 \(outcomes[0].kind)")
        }
        XCTAssertEqual(figuresProcessed, 1)

        let rewritten = try readPageTex(page: 5)
        XCTAssertTrue(rewritten.contains("figures/p005-fig1.png"), rewritten)
        XCTAssertFalse(rewritten.contains("{figures/fig1.png}"), "不該留著舊的無頁碼引用: \(rewritten)")
        XCTAssertTrue(rewritten.contains("width="), rewritten)

        let cropped = try inspect("figures/p005-fig1.png")
        XCTAssertTrue(cropped.color.r > 200 && cropped.color.b < 50, "裁出來的內容要來自第 5 頁自己的圖: \(cropped.color)")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("accumulated.tex").path),
            "有頁面被改寫時應該重建 accumulated.tex"
        )
    }

    /// 冪等：第二輪不應該再改任何東西。
    func testIdempotentSecondRunReportsUnchanged() throws {
        let image = try writePageImage(page: 5, color: Self.red)
        try writePageTex(page: 5, content: "\\includegraphics{figures/fig1.png}")
        try writeResponses([PageResult(
            page: 5, latex: "", figures: [FigureRegion(id: "fig1", bbox: [0.1, 0.1, 0.4, 0.3], caption: nil)],
            confidence: nil, notes: nil
        )])
        let project = makeProject(pages: [
            PageRecord(number: 5, width: 612, height: 792, rotation: 0, renderedImagePath: image, renderedDPI: nil),
        ])
        let transcriber = PageTranscriber()

        let first = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        guard case .migrated = first[0].kind else { return XCTFail("第一輪應該要改寫: \(first[0].kind)") }
        let afterFirstRun = try readPageTex(page: 5)

        let second = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        XCTAssertEqual(second[0].kind, .unchanged)
        let afterSecondRun = try readPageTex(page: 5)
        XCTAssertEqual(afterFirstRun, afterSecondRun, "第二輪不應該再改動內容")
    }

    func testMissingPageTexFileReportsNoPageTexFile() throws {
        let project = makeProject(pages: [])
        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [9])
        XCTAssertEqual(outcomes, [FigureMigrationOutcome(page: 9, kind: .noPageTexFile)])
    }

    /// responses/ 裡完全沒有這一頁（例如這個專案走的是 block-level pipeline）：不嘗試裁切。
    func testMissingResponseDataReportsNoFigureData() throws {
        try writePageTex(page: 3, content: "No figures here.")
        let project = makeProject(pages: [
            PageRecord(number: 3, width: 612, height: 792, rotation: 0, renderedImagePath: nil, renderedDPI: nil),
        ])
        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [3])
        XCTAssertEqual(outcomes, [FigureMigrationOutcome(page: 3, kind: .noFigureData)])
    }

    /// manifest 有這一頁的紀錄，但沒有渲染過（renderedImagePath 是 nil）：不嘗試裁切。
    func testMissingPageImageReportsNoPageImage() throws {
        try writePageTex(page: 3, content: "\\includegraphics{figures/fig1.png}")
        try writeResponses([PageResult(
            page: 3, latex: "", figures: [FigureRegion(id: "fig1", bbox: [0.1, 0.1, 0.2, 0.2], caption: nil)],
            confidence: nil, notes: nil
        )])
        let project = makeProject(pages: [
            PageRecord(number: 3, width: 612, height: 792, rotation: 0, renderedImagePath: nil, renderedDPI: nil),
        ])
        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [3])
        XCTAssertEqual(outcomes, [FigureMigrationOutcome(page: 3, kind: .noPageImage)])
    }

    /// 這一頁確實被轉寫過，但沒有任何 figure：呼叫過 postProcessPage，但沒有東西可改。
    func testPageWithNoFiguresIsUnchanged() throws {
        try writePageTex(page: 2, content: "Just text, no figures.")
        try writeResponses([PageResult(page: 2, latex: "", figures: [], confidence: nil, notes: nil)])
        let image = try writePageImage(page: 2, color: Self.blue)
        let project = makeProject(pages: [
            PageRecord(number: 2, width: 612, height: 792, rotation: 0, renderedImagePath: image, renderedDPI: nil),
        ])
        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [2])
        XCTAssertEqual(outcomes, [FigureMigrationOutcome(page: 2, kind: .unchanged)])
    }

    /// 跨頁覆蓋的真實場景（issue #222 的動機）：兩頁都用 id `fig1`，v0.4.0 之前的檔案系統上只剩
    /// 最後裁切的那一張。遷移重新從各自的頁面圖裁切，兩頁都要拿回自己的內容。
    func testCrossPageCollisionEachPageGetsItsOwnCrop() throws {
        let image4 = try writePageImage(page: 4, color: Self.red)
        let image5 = try writePageImage(page: 5, color: Self.blue)
        try writePageTex(page: 4, content: "\\includegraphics{figures/fig1.png}")
        try writePageTex(page: 5, content: "\\includegraphics{figures/fig1.png}")
        try writeResponses([
            PageResult(
                page: 4, latex: "", figures: [FigureRegion(id: "fig1", bbox: [0.1, 0.1, 0.3, 0.3], caption: nil)],
                confidence: nil, notes: nil
            ),
            PageResult(
                page: 5, latex: "", figures: [FigureRegion(id: "fig1", bbox: [0.2, 0.2, 0.3, 0.3], caption: nil)],
                confidence: nil, notes: nil
            ),
        ])
        let project = makeProject(pages: [
            PageRecord(number: 4, width: 612, height: 792, rotation: 0, renderedImagePath: image4, renderedDPI: nil),
            PageRecord(number: 5, width: 612, height: 792, rotation: 0, renderedImagePath: image5, renderedDPI: nil),
        ])

        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [4, 5])
        XCTAssertEqual(
            outcomes,
            [
                FigureMigrationOutcome(page: 4, kind: .migrated(figuresProcessed: 1)),
                FigureMigrationOutcome(page: 5, kind: .migrated(figuresProcessed: 1)),
            ]
        )

        let crop4 = try inspect("figures/p004-fig1.png")
        let crop5 = try inspect("figures/p005-fig1.png")
        XCTAssertTrue(crop4.color.r > 200 && crop4.color.b < 50, "第 4 頁要拿到自己的紅色: \(crop4.color)")
        XCTAssertTrue(crop5.color.b > 200 && crop5.color.r < 50, "第 5 頁要拿到自己的藍色: \(crop5.color)")
    }
}
