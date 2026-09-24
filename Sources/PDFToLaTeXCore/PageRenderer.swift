import CoreGraphics
import Foundation
import PDFKit

public struct PageRenderer: Sendable {
    public init() {}

    public func renderPages(
        pdfAt url: URL,
        outputDirectory: URL,
        dpi: Double,
        firstPage: Int?,
        lastPage: Int?
    ) throws -> [RenderedPage] {
        guard let document = PDFDocument(url: url) else {
            throw PDFToLaTeXError.pdfOpenFailed(url)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let first = max((firstPage ?? 1), 1)
        let last = min((lastPage ?? document.pageCount), document.pageCount)
        guard first <= last else {
            return []
        }

        var renderedPages: [RenderedPage] = []
        for index in (first - 1)..<last {
            guard let page = document.page(at: index) else {
                throw PDFToLaTeXError.pageUnavailable(index)
            }

            let outputURL = outputDirectory.appendingPathComponent(String(format: "page-%04d.png", index + 1))
            try render(page: page, pageNumber: index + 1, outputURL: outputURL, dpi: dpi)
            renderedPages.append(RenderedPage(pageNumber: index + 1, imagePath: outputURL.path))
        }

        return renderedPages
    }

    /// 畫布尺寸要用「顯示時」的寬高，不是 mediaBox 原始寬高（PsychQuant/pdf-to-latex-swift#222）：
    /// `PDFPage.draw(with:.mediaBox,to:)` 對旋轉 90°／270° 的頁面，計算內容位置時是以寬高已互換
    /// 的畫布為準——canvas 若仍配置成未互換的 mediaBox 尺寸，畫出來的內容會被裁掉一部分，
    /// 旋轉 270° 時实測整頁內容完全裁掉、渲染出全白圖片（見 `RotationRenderTests`）。
    /// 0°／180° 不受影響（`PDFScanner.rotationSwapsWidthAndHeight`）。
    private func render(page: PDFPage, pageNumber: Int, outputURL: URL, dpi: Double) throws {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let swapped = PDFScanner.rotationSwapsWidthAndHeight(Int(page.rotation))
        let visualWidth = swapped ? bounds.height : bounds.width
        let visualHeight = swapped ? bounds.width : bounds.height
        let pixelWidth = max(Int((visualWidth * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((visualHeight * scale).rounded(.up)), 1)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFToLaTeXError.bitmapCreationFailed(pageNumber)
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let image = context.makeImage() else {
            throw PDFToLaTeXError.imageCreationFailed(pageNumber)
        }

        try CGImageHelper.writePNG(image, to: outputURL)
    }
}
