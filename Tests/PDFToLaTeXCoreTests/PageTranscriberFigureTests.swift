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

    /// 大小寫不同的 id（`Fig1`／`fig1`）在 macOS 預設（不分大小寫）的檔案系統上是同一個檔：
    /// 視為撞名，只裁第一個，寬度回報 ambiguous。
    func testIdsDifferingOnlyInCaseAreTreatedAsTheSameFile() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let latex = "\\includegraphics{figures/Fig1.png}\n\\includegraphics{figures/fig1.png}"
        let result = process(
            page: 18, latex: latex,
            figures: [("Fig1", [0.1, 0.1, 0.4, 0.2]), ("fig1", [0.1, 0.5, 0.6, 0.3])], image: image
        )
        XCTAssertEqual(figureFiles(), ["p018-fig1.png"])
        let crop = try inspect("figures/p018-fig1.png")
        XCTAssertEqual([crop.width, crop.height], [40, 20])
        XCTAssertEqual(result.latex, "\\includegraphics{figures/p018-fig1.png}\n\\includegraphics{figures/p018-fig1.png}")
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.ambiguousFigure, .ambiguousFigure])
        XCTAssertEqual(result.notes.count, 1)
    }

    /// 裁切失敗（頁面圖不存在）：本次沒有產生裁切檔，引用原樣保留（不改指向不存在的檔），
    /// 寬度回報 missingImageFile，並記一筆 note。
    func testCropFailureLeavesTheReferenceUnchanged() throws {
        let latex = "\\includegraphics{figures/fig1.png}\n\\includegraphics[width=3cm]{figures/fig1.png}"
        let result = process(
            page: 18, latex: latex,
            figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: projectDir.appendingPathComponent("nope.png").path
        )
        XCTAssertEqual(result.latex, latex)
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.missingImageFile, .explicitSizePreserved])
        XCTAssertEqual(result.notes.count, 1)
    }

    /// 之前的執行留下的同名裁切檔不算數：只有這次成功寫出的檔才改寫路徑、補寬度。
    func testStaleCroppedFileFromAnEarlierRunIsNotTrusted() throws {
        try FileManager.default.createDirectory(at: projectDir.appendingPathComponent("figures"), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: projectDir.appendingPathComponent("figures/p018-fig1.png"))
        let latex = "\\includegraphics{figures/fig1.png}"
        let result = process(
            page: 18, latex: latex, figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: nil
        )
        XCTAssertEqual(result.latex, latex)
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.missingImageFile])
    }

    func testCallsThatAreNotExecutedAreNeverRewritten() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let latex = """
        % \\includegraphics{figures/fig1.png}
        \\begin{verbatim}
        \\includegraphics{figures/fig1.png}
        \\end{verbatim}
        \\verb|\\includegraphics{figures/fig1.png}|
        """
        let result = process(page: 18, latex: latex, figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image)
        XCTAssertEqual(result.latex, latex)
        XCTAssertEqual(result.figureReport.resolutions, [])
        XCTAssertEqual(figureFiles(), ["p018-fig1.png"])  // 裁切與 LaTeX 用不用無關
    }

    /// 巨集定義內的圖片之後會被呼叫：路徑也要跟著裁切檔改名（否則呼叫時找不到檔）；
    /// 寬度仍只補在作用中的呼叫（與 normalize 相同），定義內的不回報。
    func testPathsInsideMacroDefinitionsFollowTheRenamedFile() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let latex = """
        \\newcommand{\\figA}{\\includegraphics{figures/fig1.png}}
        \\def\\figB{\\includegraphics[scale=0.5]{figures/fig1}}
        \\figA \\figB
        """
        let result = process(page: 18, latex: latex, figures: [("fig1", [0.1, 0.1, 0.4, 0.2])], image: image)
        XCTAssertEqual(result.latex, """
        \\newcommand{\\figA}{\\includegraphics{figures/p018-fig1.png}}
        \\def\\figB{\\includegraphics[scale=0.5]{figures/p018-fig1.png}}
        \\figA \\figB
        """)
        XCTAssertEqual(result.figureReport.resolutions, [])
    }

    /// bbox 超出頁面（不合法）：仍裁切與頁面相交的部分（不讓文件因缺圖而無法編譯），但寬度不補
    /// （`invalidBoundingBox`），並記一筆 note 說明圖可能被截斷。
    func testOutOfRangeBBoxIsCroppedToThePageButGetsNoWidthAndIsReported() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let result = process(
            page: 18, latex: "\\includegraphics{figures/fig1.png}",
            figures: [("fig1", [0.8, 0.1, 0.4, 0.2])], image: image
        )
        XCTAssertEqual(figureFiles(), ["p018-fig1.png"])
        XCTAssertEqual(try inspect("figures/p018-fig1.png").width, 20)
        XCTAssertEqual(result.latex, "\\includegraphics{figures/p018-fig1.png}")
        XCTAssertEqual(result.figureReport.resolutions.map(\.outcome), [.invalidBoundingBox([0.8, 0.1, 0.4, 0.2])])
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes.first?.contains("p018-fig1.png") ?? false, "\(result.notes)")
    }

    /// id 含 `.`（安全字元）時，省略 `.png` 的引用仍配得上（pdflatex 實測 `figures/p018-fig_2.b`
    /// 會自動補 `.png` 找到檔）。
    func testExtensionlessReferenceToADottedIdIsMatched() throws {
        let image = try writePageImage(page: 18, color: Self.red)
        let result = process(
            page: 18, latex: "\\includegraphics{figures/fig_2.b}",
            figures: [("fig_2.b", [0.1, 0.1, 0.4, 0.2])], image: image
        )
        XCTAssertEqual(figureFiles(), ["p018-fig_2.b.png"])
        XCTAssertEqual(result.latex, "\\includegraphics[\(Self.capped("244.8"))]{figures/p018-fig_2.b.png}")
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

    // MARK: - #221 resolvedPageImagePath：AI 回傳批次外頁碼時不能裁到錯的頁面圖

    private func record(_ number: Int, image: String?) -> PageRecord {
        PageRecord(number: number, width: 612, height: 792, rotation: 0, renderedImagePath: image, renderedDPI: nil)
    }

    /// 批次內的一般情況：直接用這一頁自己的圖。
    func testResolvedPageImagePathFindsPageWithinManifest() {
        let pages = [record(5, image: "pages/page-0005.png"), record(6, image: "pages/page-0006.png")]
        XCTAssertEqual(PageTranscriber.resolvedPageImagePath(forPage: 6, in: pages), "pages/page-0006.png")
    }

    /// `resolvedPageImagePath` 本身是通用查找，不知道也不管「批次」是什麼——給它什麼清單就在
    /// 那份清單裡查。這個行為是 `migrateFigureCrops`（不呼叫 AI 的遷移入口）依賴的：它刻意傳整份
    /// manifest，因為它沒有批次概念，bbox 是舊 responses 資料本身就跟頁碼綁定的
    /// （PsychQuant/macdoc#221 第二輪審查釐清：`transcribe()` 不能這樣用，見下面
    /// `testBatchRestrictedPageRecordsExcludesPagesOutsideTheBatch` 與
    /// `testTranscribeStylePipelineRejectsPageOutsideBatchEvenWhenManifestHasIt`）。
    func testResolvedPageImagePathFindsAnyPageInGivenList() {
        let manifestPages = [
            record(1, image: "pages/page-0001.png"),
            record(2, image: "pages/page-0002.png"),
            record(7, image: "pages/page-0007.png"),
        ]
        XCTAssertEqual(
            PageTranscriber.resolvedPageImagePath(forPage: 7, in: manifestPages), "pages/page-0007.png"
        )
    }

    /// `batchRestrictedPageRecords` 把 manifest 限制在批次頁碼內——這才是 `transcribe()` 防止
    /// 「批次外頁碼被裁切」的實際機制（PsychQuant/macdoc#221 第二輪審查：光是拿掉
    /// `?? imagePaths.first`、改查整份 manifest 不夠，manifest 裡剛好有那一頁的渲染圖，不代表這批
    /// 回應的 bbox 適用於那張圖）。
    func testBatchRestrictedPageRecordsExcludesPagesOutsideTheBatch() {
        let manifestPages = [
            record(1, image: "pages/page-0001.png"),
            record(2, image: "pages/page-0002.png"),
            record(8, image: "pages/page-0008.png"),
        ]
        let restricted = PageTranscriber.batchRestrictedPageRecords(manifestPages, batchPages: [1, 2])
        XCTAssertEqual(restricted.map(\.number).sorted(), [1, 2], "第 8 頁不在批次裡，不該出現在限制後的清單")
        XCTAssertNil(
            PageTranscriber.resolvedPageImagePath(forPage: 8, in: restricted),
            "批次外頁碼即使 manifest 裡有渲染圖，限制後也查不到"
        )
    }

    func testBatchRestrictedPageRecordsKeepsPagesWithinTheBatch() {
        let manifestPages = [
            record(1, image: "pages/page-0001.png"),
            record(2, image: "pages/page-0002.png"),
            record(8, image: "pages/page-0008.png"),
        ]
        let restricted = PageTranscriber.batchRestrictedPageRecords(manifestPages, batchPages: [1, 2])
        XCTAssertEqual(
            PageTranscriber.resolvedPageImagePath(forPage: 2, in: restricted), "pages/page-0002.png"
        )
    }

    /// 端對端重現 Codex 第二輪審查的具體情境：本批次只送第 1、2 頁；第 8 頁先前已渲染過、
    /// manifest 有它的圖；AI 把這批某個 figure 誤標成第 8 頁。組合
    /// `batchRestrictedPageRecords` + `resolvedPageImagePath`（`transcribe()` 實際呼叫的路徑）
    /// 必須查不到圖，`postProcessPage` 因此不裁切、記 note、引用維持原樣——不能因為 manifest 裡
    /// 剛好有第 8 頁的圖，就把這批的 bbox 套上去裁。
    func testTranscribeStylePipelineRejectsPageOutsideBatchEvenWhenManifestHasIt() throws {
        let batchImage1 = try writePageImage(page: 1, color: Self.red)
        let page8Image = try writePageImage(page: 8, color: Self.blue)
        let manifestPages = [record(1, image: batchImage1), record(8, image: page8Image)]
        let batchPages = [1, 2]

        let restricted = PageTranscriber.batchRestrictedPageRecords(manifestPages, batchPages: batchPages)
        let resolved = PageTranscriber.resolvedPageImagePath(forPage: 8, in: restricted)
        XCTAssertNil(resolved, "第 8 頁不在這批 [1, 2] 裡，即使 manifest 有第 8 頁的圖也不該解析出路徑")

        let result = process(
            page: 8, latex: "\\includegraphics{figures/fig1.png}",
            figures: [("fig1", [0.1, 0.1, 0.4, 0.4])], image: resolved
        )
        XCTAssertFalse(figureFiles().contains(where: { $0.contains("p008") }), "批次外頁碼不該有任何裁切檔被寫出")
        XCTAssertTrue(
            result.notes.contains { $0.contains("找不到第 8 頁的頁面圖") },
            "應該記一筆 note 說明未裁切: \(result.notes)"
        )
        XCTAssertEqual(
            result.latex, "\\includegraphics{figures/fig1.png}", "引用要維持原樣，不能被改寫成裁切檔路徑"
        )
    }

    /// manifest 裡完全沒有這個頁碼（徹底幻覺）：回傳 nil，讓呼叫端不裁切、記 note。
    func testResolvedPageImagePathReturnsNilWhenPageNotInManifest() {
        let pages = [record(1, image: "pages/page-0001.png"), record(2, image: "pages/page-0002.png")]
        XCTAssertNil(PageTranscriber.resolvedPageImagePath(forPage: 99, in: pages))
    }

    /// manifest 裡有這一頁的紀錄，但還沒渲染過（renderedImagePath 是 nil）：同樣回傳 nil，
    /// 不能誤用別頁的圖頂替。
    func testResolvedPageImagePathReturnsNilWhenPageNotYetRendered() {
        let pages = [record(1, image: "pages/page-0001.png"), record(2, image: nil)]
        XCTAssertNil(PageTranscriber.resolvedPageImagePath(forPage: 2, in: pages))
    }

    /// 端對端：`resolvedPageImagePath` 用整份清單查到的圖，裁出來的內容必須來自那一頁自己的圖，
    /// 顏色不能是清單裡其他頁面的顏色（直接驗證裁切結果，不只是路徑字串）——這是
    /// `migrateFigureCrops` 實際依賴的行為（它傳整份 manifest，見上面
    /// `testResolvedPageImagePathFindsAnyPageInGivenList` 的說明）。
    func testMigrationStyleLookupCropsFromThePagesOwnImageNotAnotherPage() throws {
        let batchFirstImage = try writePageImage(page: 1, color: Self.red)
        let ownImage = try writePageImage(page: 7, color: Self.blue)
        let manifestPages = [record(1, image: batchFirstImage), record(7, image: ownImage)]

        let resolved = PageTranscriber.resolvedPageImagePath(forPage: 7, in: manifestPages)
        XCTAssertEqual(resolved, ownImage)

        let result = process(
            page: 7, latex: "\\includegraphics{figures/fig1.png}",
            figures: [("fig1", [0.1, 0.1, 0.4, 0.4])], image: resolved
        )
        XCTAssertTrue(result.notes.isEmpty, "resolvedPageImagePath 找得到圖時不應該有 note")
        let cropped = try inspect("figures/p007-fig1.png")
        XCTAssertTrue(
            cropped.color.b > 200 && cropped.color.r < 50,
            "裁出來的內容必須來自第 7 頁自己的圖（藍），不是批次第一張（紅）: \(cropped.color)"
        )
    }
}
