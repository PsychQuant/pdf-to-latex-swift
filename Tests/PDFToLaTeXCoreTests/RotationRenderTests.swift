import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import PDFToLaTeXCore

/// 旋轉頁的寬高換算與渲染（PsychQuant/pdf-to-latex-swift#222）。
///
/// `PDFPage.bounds(for: .mediaBox)` 回傳的一律是未旋轉的原始尺寸；`/Rotate` 是顯示時的轉換，
/// 90°／270° 顯示時寬高會互換。這裡用程式產生帶 `/Rotate` 的 PDF（PDFKit 設
/// `PDFPage.rotation` 後寫檔），實測 `PDFScanner` 回報的寬高、與 `PageRenderer` 實際畫出來的
/// 畫布尺寸與內容位置是否對得上。
///
/// ## 實測依據（本檔的探索過程，數字見 pdf-to-latex-swift#222 的實作報告）
///
/// 修法之前：canvas 一律用未互換的 mediaBox 尺寸配置。300×150（寬×高）的頁面設
/// `/Rotate 90` 後，`PDFPage.draw(with:.mediaBox,to:)` 計算出的內容位置是以「寬高已互換」
/// （150×300）的畫布為準——canvas 卻只有 300×150，於是：
/// - `/Rotate 90`：畫出來的內容被裁掉大半（右半邊完全空白、下半部分被截斷）。
/// - `/Rotate 270`：內容整個落在畫布外，渲染出全白圖片（PsychQuant/pdf-to-latex-swift#222 的
///   探索測試量到 0 個非白像素）。
/// - `/Rotate 0`／`180`：canvas 尺寸本來就不必互換，不受影響。
///
/// 修法：canvas／回報的寬高在 90°／270° 時互換（`PDFScanner.rotationSwapsWidthAndHeight`），
/// 修好後兩種旋轉的標記都完整出現在數學上正確的位置（見下方測試的座標推導）。
final class RotationRenderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture helpers

    /// 產生一頁 mediaBox `contentWidth`×`contentHeight`（未旋轉 content space，PDF 原點左下、
    /// y 向上）的 PDF，在右上角（x:[contentWidth-40, contentWidth], y:[contentHeight-20,
    /// contentHeight]）畫一個 40×20 的紅色標記，再視需要設定 `/Rotate`。
    private func makeMarkedPDF(
        contentWidth: CGFloat, contentHeight: CGFloat, rotation: Int, to url: URL
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("無法建立 PDF context")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: contentWidth - 40, y: contentHeight - 20, width: 40, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()

        guard rotation != 0 else { return }
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw XCTSkip("無法重新開啟 PDF 設定 rotation")
        }
        page.rotation = rotation
        guard doc.write(to: url) else {
            throw XCTSkip("寫回帶 rotation 的 PDF 失敗")
        }
    }

    /// 畫布上紅色像素的緊密外框（top-left 原點，y 向下），沒有紅色像素回傳 nil。
    private func redBoundingBox(in image: CGImage) -> (x: Range<Int>, y: Range<Int>)? {
        let width = image.width, height = image.height
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    guard offset + 2 < raw.count else { continue }
                    let r = raw[offset], g = raw[offset + 1], b = raw[offset + 2]
                    if r > 200 && g < 80 && b < 80 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        guard minX <= maxX else { return nil }
        return (minX..<(maxX + 1), minY..<(maxY + 1))
    }

    // MARK: - PDFScanner.rotationSwapsWidthAndHeight（純函式，涵蓋正規化）

    func testRotationSwapsWidthAndHeightBoundary() {
        let swaps: [Int] = [90, 270, -90, -270, 450, 630]
        let doesNotSwap: [Int] = [0, 180, -180, 360, -360, 720]
        for r in swaps {
            XCTAssertTrue(PDFScanner.rotationSwapsWidthAndHeight(r), "rotation=\(r) 應該互換寬高")
        }
        for r in doesNotSwap {
            XCTAssertFalse(PDFScanner.rotationSwapsWidthAndHeight(r), "rotation=\(r) 不應該互換寬高")
        }
    }

    // MARK: - PDFScanner.scan：回報的寬高要是「顯示時」的寬高

    func testScanReportsSwappedDimensionsForRotation90() throws {
        let url = dir.appendingPathComponent("r90.pdf")
        try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: 90, to: url)
        let snapshot = try PDFScanner().scan(pdfAt: url)[0]
        XCTAssertEqual(snapshot.width, 150, "90° 顯示時寬是原 mediaBox 的高")
        XCTAssertEqual(snapshot.height, 300, "90° 顯示時高是原 mediaBox 的寬")
        XCTAssertEqual(snapshot.rotation, 90)
    }

    func testScanReportsSwappedDimensionsForRotation270() throws {
        let url = dir.appendingPathComponent("r270.pdf")
        try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: 270, to: url)
        let snapshot = try PDFScanner().scan(pdfAt: url)[0]
        XCTAssertEqual(snapshot.width, 150)
        XCTAssertEqual(snapshot.height, 300)
        XCTAssertEqual(snapshot.rotation, 270)
    }

    func testScanReportsUnswappedDimensionsForRotation0And180() throws {
        for rotation in [0, 180] {
            let url = dir.appendingPathComponent("r\(rotation).pdf")
            try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: rotation, to: url)
            let snapshot = try PDFScanner().scan(pdfAt: url)[0]
            XCTAssertEqual(snapshot.width, 300, "rotation=\(rotation)")
            XCTAssertEqual(snapshot.height, 150, "rotation=\(rotation)")
        }
    }

    // MARK: - PageRenderer：畫布尺寸與內容完整性

    /// `/Rotate 90`：mediaBox 300×150（寬×高，content space）→ 畫布要是 150×300。
    ///
    /// 座標推導（clockwise 90°、標準 PDF 顯示轉換 `x' = y, y' = W - x`，`W` = 原寬 300）：
    /// 標記原本在 content space x:[260,300] y:[130,150]（右上角），四角代入後得顯示座標
    /// （bottom-left 原點、y 向上）x':[130,150] y':[0,40]——即寬 150、高 300 的顯示畫面裡靠
    /// 右下角的一塊 20×40 區域。換成本測試量測用的 top-left 原點、y 向下座標：
    /// x:[130,150) y:[260,300)（`y_top = 300 - y'`，即 `y_top ∈ (300-40, 300-0] = (260, 300]`，
    /// 離散像素上對應 `[260, 299]`）。
    func testRotation90RendersFullMarkerAtExpectedPosition() throws {
        let pdfURL = dir.appendingPathComponent("r90.pdf")
        try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: 90, to: pdfURL)
        let outDir = dir.appendingPathComponent("out")
        let rendered = try PageRenderer().renderPages(
            pdfAt: pdfURL, outputDirectory: outDir, dpi: 72, firstPage: nil, lastPage: nil
        )
        let image = try CGImageHelper.load(from: URL(fileURLWithPath: rendered[0].imagePath))
        XCTAssertEqual(image.width, 150, "畫布寬要互換成原 mediaBox 的高")
        XCTAssertEqual(image.height, 300, "畫布高要互換成原 mediaBox 的寬")

        let box = try XCTUnwrap(redBoundingBox(in: image), "標記完全裁掉了，畫布尺寸沒對上")
        XCTAssertEqual(box.x, 130..<150, "標記的水平位置與推導不符")
        XCTAssertEqual(box.y, 260..<300, "標記的垂直位置與推導不符")
    }

    /// 座標推導（counter-clockwise 90°／標準 PDF 顯示轉換 `x' = H - y, y' = x`，`H` = 原高 150）：
    /// 標記四角代入後得顯示座標（bottom-left 原點、y 向上）x':[0,20] y':[260,300]，換成
    /// top-left／y 向下：x:[0,20) y:[0,40)——貼著左上角的一塊 20×40 區域。
    func testRotation270RendersFullMarkerNotClippedToBlank() throws {
        let pdfURL = dir.appendingPathComponent("r270.pdf")
        try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: 270, to: pdfURL)
        let outDir = dir.appendingPathComponent("out")
        let rendered = try PageRenderer().renderPages(
            pdfAt: pdfURL, outputDirectory: outDir, dpi: 72, firstPage: nil, lastPage: nil
        )
        let image = try CGImageHelper.load(from: URL(fileURLWithPath: rendered[0].imagePath))
        XCTAssertEqual(image.width, 150)
        XCTAssertEqual(image.height, 300)

        // 修法之前這裡量到 0 個紅色像素（整頁內容被裁到畫布外，渲染出全白圖）。
        let box = try XCTUnwrap(
            redBoundingBox(in: image), "整頁內容被裁到畫布外了（#222 修好之前的行為：渲染出全白圖）"
        )
        XCTAssertEqual(box.x, 0..<20, "標記的水平位置與推導不符")
        XCTAssertEqual(box.y, 0..<40, "標記的垂直位置與推導不符")
    }

    /// 迴歸：0°／180° 本來就不需要互換，尺寸與內容位置維持原行為。
    func testRotation0And180StillRenderUnswappedCanvas() throws {
        for rotation in [0, 180] {
            let pdfURL = dir.appendingPathComponent("r\(rotation).pdf")
            try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: rotation, to: pdfURL)
            let outDir = dir.appendingPathComponent("out\(rotation)")
            let rendered = try PageRenderer().renderPages(
                pdfAt: pdfURL, outputDirectory: outDir, dpi: 72, firstPage: nil, lastPage: nil
            )
            let image = try CGImageHelper.load(from: URL(fileURLWithPath: rendered[0].imagePath))
            XCTAssertEqual(image.width, 300, "rotation=\(rotation)")
            XCTAssertEqual(image.height, 150, "rotation=\(rotation)")
            let box = try XCTUnwrap(redBoundingBox(in: image), "rotation=\(rotation) 標記不見了")
            XCTAssertEqual(box.x.count * box.y.count, 800, "rotation=\(rotation) 標記面積應完整")
        }
    }

    /// `/Rotate` 真的寫進了檔案位元組，不只是記憶體屬性——確認這份 fixture 名副其實。
    func testGeneratedPDFActuallyContainsRotateTagInBytes() throws {
        for rotation in [90, 270] {
            let url = dir.appendingPathComponent("bytes-\(rotation).pdf")
            try makeMarkedPDF(contentWidth: 300, contentHeight: 150, rotation: rotation, to: url)
            let bytes = try String(contentsOf: url, encoding: .isoLatin1)
            XCTAssertTrue(bytes.contains("/Rotate \(rotation)"), "rotation=\(rotation) 的 PDF 位元組裡沒有 /Rotate 標記")
        }
    }
}
