import Foundation
import PDFKit

public struct PDFScanner: Sendable {
    public init() {}

    /// 每頁的尺寸、旋轉與 page label。
    ///
    /// page label 取自 `PDFPage.label`，但只在 PDF 的 catalog 真的有 `/PageLabels` 時採用：沒有
    /// `/PageLabels` 時 PDFKit 仍回傳 `"1"`、`"2"`…（實測），那是實體頁序，不是書上印的頁碼，
    /// 所以記為 nil（PsychQuant/macdoc#211）。
    public func scan(pdfAt url: URL) throws -> [PDFPageSnapshot] {
        guard let document = PDFDocument(url: url) else {
            throw PDFToLaTeXError.pdfOpenFailed(url)
        }
        let hasPageLabels = Self.hasPageLabels(document)

        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw PDFToLaTeXError.pageUnavailable(index)
            }

            let bounds = page.bounds(for: .mediaBox)
            let rotation = Int(page.rotation)
            let swapped = Self.rotationSwapsWidthAndHeight(rotation)
            return PDFPageSnapshot(
                number: index + 1,
                width: Double(swapped ? bounds.height : bounds.width),
                height: Double(swapped ? bounds.width : bounds.height),
                rotation: rotation,
                label: hasPageLabels ? page.label : nil
            )
        }
    }

    /// catalog 是否有 `/PageLabels`（直接或間接物件皆可）。
    static func hasPageLabels(_ document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(catalog, "PageLabels", &object)
    }

    /// `rotation`（`PDFPage.rotation`，度數，可能是負值或 ≥360）正規化到 `[0, 360)` 後是否為
    /// 90 或 270（PsychQuant/pdf-to-latex-swift#222）。
    ///
    /// `PDFPage.bounds(for: .mediaBox)` 回傳的一律是**未旋轉**的原始尺寸（PDF 內容座標系裡定義的
    /// 寬高），`/Rotate` 是顯示時的轉換，不改變 mediaBox 本身。90°／270° 顯示時寬高互換
    /// （直向頁轉成橫向顯示，或反之）；0°／180° 不互換（180° 只是上下左右翻轉，尺寸不變）。
    ///
    /// 實測依據（`RotationRenderTests`）：`PDFPage.draw(with:.mediaBox,to:)` 對旋轉頁計算的內容
    /// 位置，是以「寬高已互換」的畫布為準——canvas 若仍用未互換的 mediaBox 尺寸配置，90°／270°
    /// 的內容會有一半以上被裁掉甚至完全消失（見 `PageRenderer.render`），bbox 換算成 bp 的寬度
    /// 也會用錯邊。not `public`：只有本 target 內（`PDFScanner` 本身與 `PageRenderer`）需要這個
    /// 判斷，不是給外部呼叫端用的獨立功能。
    static func rotationSwapsWidthAndHeight(_ rotation: Int) -> Bool {
        let normalized = ((rotation % 360) + 360) % 360
        return normalized == 90 || normalized == 270
    }
}
