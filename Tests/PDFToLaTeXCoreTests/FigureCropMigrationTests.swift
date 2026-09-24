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

    // MARK: - Codex R1 回歸：只遷移子集不能刪掉 accumulated.tex 裡的其他頁面

    /// 專案有第 3-6 頁，只要求遷移第 5 頁：accumulated.tex 重建後要包含全部四頁的內容，
    /// 不能只剩被要求遷移的那一頁。
    func testPartialMigrationPreservesOtherPagesInAccumulated() throws {
        try writePageTex(page: 3, content: "Page three body.")
        try writePageTex(page: 4, content: "Page four body.")
        let image5 = try writePageImage(page: 5, color: Self.red)
        try writePageTex(page: 5, content: "\\includegraphics{figures/fig1.png}")
        try writePageTex(page: 6, content: "Page six body.")
        try writeResponses([PageResult(
            page: 5, latex: "", figures: [FigureRegion(id: "fig1", bbox: [0.1, 0.1, 0.4, 0.3], caption: nil)],
            confidence: nil, notes: nil
        )])
        let project = makeProject(pages: [
            PageRecord(number: 5, width: 612, height: 792, rotation: 0, renderedImagePath: image5, renderedDPI: nil),
        ])

        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [5])
        XCTAssertEqual(outcomes.count, 1, "只要求遷移第 5 頁，回報也只該有第 5 頁一筆")
        guard case .migrated = outcomes[0].kind else { return XCTFail("第 5 頁應該被改寫: \(outcomes[0].kind)") }

        let accumulated = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )
        XCTAssertTrue(accumulated.contains("Page three body."), "第 3 頁不見了:\n\(accumulated)")
        XCTAssertTrue(accumulated.contains("Page four body."), "第 4 頁不見了:\n\(accumulated)")
        XCTAssertTrue(accumulated.contains("figures/p005-fig1.png"), "第 5 頁沒改寫成新格式:\n\(accumulated)")
        XCTAssertTrue(accumulated.contains("Page six body."), "第 6 頁不見了:\n\(accumulated)")
    }

    /// 第一次呼叫的 accumulated.tex 是「壞的／過時的」（模擬上次寫入失敗留下的殘檔）：即使這次
    /// 每一頁都已經是新格式（全部落在 .unchanged），重跑仍要把 accumulated.tex 修正回正確內容，
    /// 不能因為沒有任何一頁被改寫就跳過重建。
    func testAccumulatedIsRepairedOnRerunEvenWhenNoPageChanges() throws {
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

        _ = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        let correctAccumulated = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )

        // 模擬上一次 accumulated.tex 寫入失敗留下的殘檔（或被其他東西弄壞）。
        try "STALE GARBAGE".write(
            to: projectDir.appendingPathComponent("accumulated.tex"), atomically: true, encoding: .utf8
        )

        let second = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        XCTAssertEqual(second, [FigureMigrationOutcome(page: 5, kind: .unchanged)], "第二輪每一頁都不該再改動")

        let repaired = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )
        XCTAssertEqual(repaired, correctAccumulated, "即使沒有頁面被改寫，accumulated.tex 也要被修回正確內容")
        XCTAssertNotEqual(repaired, "STALE GARBAGE")
    }

    // MARK: - Codex R1 回歸：.unchanged 底下的失敗細節要透過 notes 看得到

    /// id 不安全（含空白）：不裁切、不改寫，但 notes 要說明原因，不能悄悄地什麼都不做。
    func testUnsafeFigureIdIsUnchangedButNotesExplainWhy() throws {
        let image = try writePageImage(page: 7, color: Self.blue)
        try writePageTex(page: 7, content: "\\includegraphics{figures/bad id.png}")
        try writeResponses([PageResult(
            page: 7, latex: "", figures: [FigureRegion(id: "bad id", bbox: [0.1, 0.1, 0.2, 0.2], caption: nil)],
            confidence: nil, notes: nil
        )])
        let project = makeProject(pages: [
            PageRecord(number: 7, width: 612, height: 792, rotation: 0, renderedImagePath: image, renderedDPI: nil),
        ])

        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [7])
        XCTAssertEqual(outcomes[0].kind, .unchanged)
        XCTAssertTrue(
            outcomes[0].notes.contains { $0.contains("不是安全的檔名") },
            "notes 應該解釋為什麼沒有裁切: \(outcomes[0].notes)"
        )
    }

    /// 已經遷移過的裁切檔被刪掉（例如使用者手動清過 figures/）：重跑要自動補回來，即使 tex 內容
    /// 沒有變動（outcome 仍是 .unchanged，但檔案要存在）。
    func testMigrationRecreatesDeletedCropFile() throws {
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
        _ = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])

        let croppedURL = projectDir.appendingPathComponent("figures/p005-fig1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: croppedURL.path))
        try FileManager.default.removeItem(at: croppedURL)

        let second = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        XCTAssertEqual(second[0].kind, .unchanged, "tex 內容不會再變（引用早就指向這個檔名）")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: croppedURL.path),
            "裁切檔被刪掉後重跑應該自動補回來"
        )
    }

    // MARK: - Codex R2 回歸：列舉 tex/ 目錄失敗不能被吞成空清單

    /// `tex/` 目錄列舉失敗（這裡用「同名路徑其實是檔案，不是目錄」模擬 I/O 錯誤）時應該整個
    /// throw，不能把失敗吞成空清單再拿去重建 accumulated.tex——那樣會用沒有任何頁面正文的內容
    /// 覆寫掉原本完好的總文件，比「乾脆不重建」還糟。
    func testDirectoryListingFailureThrowsInsteadOfOverwritingAccumulatedWithEmptyContent() throws {
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
        _ = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        let goodAccumulated = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )
        XCTAssertFalse(goodAccumulated.isEmpty)

        // 把 tex/ 換成同名的「檔案」：路徑存在，但不是目錄——列舉時會丟錯。
        let texDirURL = projectDir.appendingPathComponent("tex")
        try FileManager.default.removeItem(at: texDirURL)
        try "not a directory".write(to: texDirURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try transcriber.migrateFigureCrops(project: project, pageNumbers: [5]))

        let afterFailure = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )
        XCTAssertEqual(afterFailure, goodAccumulated, "列舉目錄失敗時不該把 accumulated.tex 換成空內容")
    }

    /// `tex/` 目錄真的不存在（專案從未渲染過任何頁面）是合法狀態，不該 throw；只是所有要求的頁面
    /// 都會落在 `.noPageTexFile`，也不會有 accumulated.tex 可重建成有內容的東西。
    func testMissingTexDirectoryIsNotTreatedAsAnError() throws {
        let project = makeProject(pages: [])
        let outcomes = try PageTranscriber().migrateFigureCrops(project: project, pageNumbers: [1])
        XCTAssertEqual(outcomes, [FigureMigrationOutcome(page: 1, kind: .noPageTexFile)])
    }

    /// Codex R3 指出的確切情境：`tex/` 是指向「父目錄權限受限」的符號連結時，
    /// `FileManager.fileExists(atPath:)` 對它回報 `false`——跟「真的不存在」是同一個布林值，
    /// 分不出來。R2 的版本靠這個 Bool 判斷「不存在就回傳空清單」，會在這裡誤判。R3 修法拿掉這個
    /// 前置檢查，改成直接嘗試列舉、只把操作本身丟出的 `.fileReadNoSuchFile` 當空清單，這裡驗證
    /// 這個情境下拋出的是別的錯誤（不是 `.fileReadNoSuchFile`），因此會 throw、不會誤判成空清單
    /// 去覆寫 accumulated.tex。
    func testSymlinkedTexDirectoryWithInaccessibleParentThrowsInsteadOfAppearingEmpty() throws {
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
        _ = try transcriber.migrateFigureCrops(project: project, pageNumbers: [5])
        let goodAccumulated = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )
        XCTAssertFalse(goodAccumulated.isEmpty)

        // 把真正的 tex/ 搬到一個「父目錄權限受限」的地方，projectDir/tex 換成指向它的符號連結。
        let hiddenParent = projectDir.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: hiddenParent, withIntermediateDirectories: true)
        let realTexURL = hiddenParent.appendingPathComponent("realTex")
        let originalTexURL = projectDir.appendingPathComponent("tex")
        try FileManager.default.moveItem(at: originalTexURL, to: realTexURL)
        try FileManager.default.createSymbolicLink(at: originalTexURL, withDestinationURL: realTexURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hiddenParent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hiddenParent.path)
            try? FileManager.default.removeItem(at: hiddenParent)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalTexURL.path),
            "先確認這個情境下 fileExists 真的回報 false（跟「真的不存在」分不出來），這正是要修的問題"
        )

        XCTAssertThrowsError(try transcriber.migrateFigureCrops(project: project, pageNumbers: [5]))

        let afterFailure = try String(
            contentsOf: projectDir.appendingPathComponent("accumulated.tex"), encoding: .utf8
        )
        XCTAssertEqual(afterFailure, goodAccumulated, "存取被拒時不該把 accumulated.tex 換成空內容")
    }
}
