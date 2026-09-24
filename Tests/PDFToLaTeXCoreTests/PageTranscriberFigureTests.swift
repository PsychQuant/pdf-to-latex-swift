import CoreGraphics
import XCTest
@testable import PDFToLaTeXCore

/// 轉寫當下的圖片後處理：帶頁碼前綴的裁切檔（PsychQuant/macdoc#208）與寬度（#209）。
/// 不呼叫 AI：直接餵 `PageResult` 給 `PageTranscriber.postProcessPage`。
final class PageTranscriberFigureTests: XCTestCase {

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

    /// 100×100 的單色頁面圖。
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

    /// 圖檔的尺寸與中心像素顏色。
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

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(relativePath).path)
    }

    private func figureFiles() -> [String] {
        let dir = projectDir.appendingPathComponent("figures")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func process(
        page: Int, latex: String, figures: [(id: String, bbox: [Double])],
        image: String?, pageWidth: Double? = 612
    ) -> PageTranscriber.PagePostProcessResult {
        let result = PageResult(
            page: page, latex: latex,
            figures: figures.map { FigureRegion(id: $0.id, bbox: $0.bbox, caption: nil) },
            confidence: nil, notes: nil
        )
        return PageTranscriber.postProcessPage(
            result, pageImagePath: image, pageWidth: pageWidth, projectRoot: projectDir
        )
    }

    private static let red: RGB = (255, 0, 0)
    private static let blue: RGB = (0, 0, 255)
    private static func capped(_ points: String) -> String { LaTeXFigureWidthTests.capped(points) }

    // MARK: - #208 page-prefixed crops

    /// 兩頁都用 `fig1`：各自存成帶頁碼前綴的檔案，不再互相覆蓋；LaTeX 指向自己那一頁的檔。
    func testSameIdOnTwoPagesProducesTwoFilesAndEachPageReferencesItsOwn() throws {
        let image18 = try writePageImage(page: 18, color: Self.red)
        let image19 = try writePageImage(page: 19, color: Self.blue)
        let latex = "\\begin{figure}[h]\n\\includegraphics{figures/fig1.png}\n\\end{figure}"

        let page18 = process(page: 18, latex: latex, figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image18)
        let page19 = process(page: 19, latex: latex, figures: [("fig1", [0.05, 0.3, 0.9, 0.5])], image: image19)

        XCTAssertEqual(figureFiles(), ["p018-fig1.png", "p019-fig1.png"])
        XCTAssertFalse(exists("figures/fig1.png"))
        let crop18 = try inspect("figures/p018-fig1.png")
        let crop19 = try inspect("figures/p019-fig1.png")
        XCTAssertEqual([crop18.width, crop18.height], [40, 20])
        XCTAssertEqual([crop19.width, crop19.height], [90, 50])
        XCTAssertTrue(crop18.color.r > 200 && crop18.color.b < 50, "page 18 crop must be red: \(crop18.color)")
        XCTAssertTrue(crop19.color.r < 50 && crop19.color.b > 200, "page 19 crop must be blue: \(crop19.color)")

        XCTAssertEqual(page18.latex, "\\begin{figure}[h]\n\\includegraphics[\(Self.capped("244.8"))]{figures/p018-fig1.png}\n\\end{figure}")
        XCTAssertEqual(page19.latex, "\\begin{figure}[h]\n\\includegraphics[\(Self.capped("550.8"))]{figures/p019-fig1.png}\n\\end{figure}")
        XCTAssertEqual(page18.notes, [])
        XCTAssertEqual(page19.notes, [])
    }

    func testIdAlreadyCarryingThePagePrefixKeepsItsName() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let result = process(
            page: 18, latex: "\\includegraphics{figures/p018-fig1.png}",
            figures: [("p018-fig1", [0.1, 0.1, 0.4, 0.2])], image: image
        )
        XCTAssertEqual(figureFiles(), ["p018-fig1.png"])
        XCTAssertEqual(result.latex, "\\includegraphics[\(Self.capped("244.8"))]{figures/p018-fig1.png}")
    }

    func testExtensionlessAndDotSlashPathsAreRewrittenToTheCroppedFile() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let result = process(
            page: 18, latex: "\\includegraphics{./figures/fig1} \\includegraphics*{figures/fig1}",
            figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image
        )
        let w = Self.capped("244.8")
        XCTAssertEqual(
            result.latex,
            "\\includegraphics[\(w)]{figures/p018-fig1.png} \\includegraphics*[\(w)]{figures/p018-fig1.png}"
        )
    }

    /// 路徑穿越的 id（`../p019-fig1`）會蓋掉別頁的檔：不裁切、不改 LaTeX，並回報。
    func testUnsafeIdIsNeitherCroppedNorRewritten() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let latex = "\\includegraphics{figures/../p019-fig1.png}"
        let result = process(page: 18, latex: latex, figures: [("../p019-fig1", [0.1, 0.1, 0.4, 0.2])], image: image)
        XCTAssertEqual(result.latex, latex)
        XCTAssertEqual(figureFiles(), [])
        XCTAssertFalse(exists("p019-fig1.png"))
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes.first?.contains("../p019-fig1") ?? false, "\(result.notes)")
    }

    /// 同一頁兩個 id 正規化後撞名且 bbox 不同：只裁第一張、回報，寬度因無法判定而不寫。
    func testSamePageCollisionCropsOnlyTheFirstAndReportsIt() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let latex = "\\includegraphics{figures/fig1.png}\n\\includegraphics{figures/p018-fig1.png}"
        let result = process(
            page: 18, latex: latex,
            figures: [("fig1", [0.1, 0.1, 0.4, 0.2]), ("p018-fig1", [0.1, 0.5, 0.6, 0.3])], image: image
        )
        XCTAssertEqual(figureFiles(), ["p018-fig1.png"])
        let crop = try inspect("figures/p018-fig1.png")
        XCTAssertEqual([crop.width, crop.height], [40, 20])
        XCTAssertEqual(result.latex, "\\includegraphics{figures/p018-fig1.png}\n\\includegraphics{figures/p018-fig1.png}")
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.ambiguousFigure, .ambiguousFigure])
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes.first?.contains("p018-fig1.png") ?? false, "\(result.notes)")
    }

    /// 裁切失敗（頁面圖不存在）：路徑仍指向本頁的檔名（不會落回別頁的舊檔），寬度回報 missingImageFile。
    func testCropFailureStillPointsToThePageOwnPath() throws {
        let result = process(
            page: 18, latex: "\\includegraphics{figures/fig1.png}",
            figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: projectDir.appendingPathComponent("nope.png").path
        )
        XCTAssertEqual(result.latex, "\\includegraphics{figures/p018-fig1.png}")
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.missingImageFile])
        XCTAssertEqual(result.notes.count, 1)
    }

    func testCallsThatAreNotExecutedAreNeverRewritten() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let latex = """
        % \\includegraphics{figures/fig1.png}
        \\begin{verbatim}
        \\includegraphics{figures/fig1.png}
        \\end{verbatim}
        \\newcommand{\\figA}{\\includegraphics{figures/fig1.png}}
        \\verb|\\includegraphics{figures/fig1.png}|
        """
        let result = process(page: 18, latex: latex, figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image)
        XCTAssertEqual(result.latex, latex)
        XCTAssertEqual(result.figureReport.resolutions, [])
        XCTAssertEqual(figureFiles(), ["p018-fig1.png"])  // 裁切與 LaTeX 用不用無關
    }

    // MARK: - #209 width at transcription time

    func testExistingSizeOptionsAreKeptButThePathIsStillRewritten() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let result = process(
            page: 18, latex: "\\includegraphics[height=2cm]{figures/fig1.png}",
            figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image
        )
        XCTAssertEqual(result.latex, "\\includegraphics[height=2cm]{figures/p018-fig1.png}")
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.explicitSizePreserved])
    }

    func testMissingPageWidthRewritesThePathButWritesNoWidth() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let result = process(
            page: 18, latex: "\\includegraphics[angle=90]{figures/fig1.png}",
            figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image, pageWidth: nil
        )
        XCTAssertEqual(result.latex, "\\includegraphics[angle=90]{figures/p018-fig1.png}")
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.missingPageRecord])
    }

    /// 同一份合併規則：轉寫當下的結果與 normalize（`applyFigureWidths`）對同一呼叫的結果逐字相同。
    func testTranscriptionUsesTheSameMergeRuleAsNormalize() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let optionFragments = [
            "", "[]", "[clip]", "[clip % note\n]", "[angle=90,% width=3cm\n]", "[wid% c\n  th=3cm]",
            "[trim={1, 2, 3, 4}, clip]", "[alt={a]b}]", "[width=2cm]", "[% only\n]", "[scale=5]",
            "*", "*[clip]", "[clip,]", "[ ]", "[width=0.4\\textwidth]", "[width=0.5\\textwidth]",
        ]
        // normalize 用的專案 metadata：與轉寫時同一頁、同一張圖。
        let manifest = ProjectManifest(
            schemaVersion: 1, createdAt: "", updatedAt: "", projectName: "t", sourcePDF: "", projectRoot: projectDir.path,
            pages: [PageRecord(number: 18, width: 612, height: 792, rotation: 0, renderedImagePath: nil, renderedDPI: nil)],
            blocks: []
        )
        try ManifestStore().save(manifest, to: projectDir.appendingPathComponent("manifest.json"))
        let figures: [(id: String, bbox: [Double])] = [("fig1", [0.1, 0.1, 0.4, 0.2])]
        let response = PageTranscriptionResponse(pages: [PageResult(
            page: 18, latex: "", figures: figures.map { FigureRegion(id: $0.id, bbox: $0.bbox, caption: nil) },
            confidence: nil, notes: nil
        )])
        try FileManager.default.createDirectory(at: projectDir.appendingPathComponent("responses"), withIntermediateDirectories: true)
        try JSONEncoder().encode(response).write(to: projectDir.appendingPathComponent("responses/pages-018-019.json"))

        for options in optionFragments {
            let transcribed = process(
                page: 18, latex: "\\includegraphics\(options){figures/fig1.png}", figures: figures, image: image
            )
            let normalized = LaTeXNormalizer.applyFigureWidths(
                "%% === Page 18 ===\n\\includegraphics\(options){figures/p018-fig1.png}", projectDir: projectDir
            )
            XCTAssertEqual("%% === Page 18 ===\n" + transcribed.latex, normalized.result, options)
            XCTAssertEqual(
                transcribed.figureReport.resolutions.map(\.outcome), normalized.resolutions.map(\.outcome), options
            )
            // normalize 作為補救層，對轉寫結果是冪等的。
            let again = LaTeXNormalizer.applyFigureWidths("%% === Page 18 ===\n" + transcribed.latex, projectDir: projectDir)
            XCTAssertEqual(again.result, "%% === Page 18 ===\n" + transcribed.latex, options)
        }
    }
}
