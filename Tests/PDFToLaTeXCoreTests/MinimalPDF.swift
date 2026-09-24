import Foundation

/// 以程式產生的最小 PDF（PsychQuant/macdoc#211 的 fixture；不引入外部檔案）。
///
/// 每頁是空白的 612×792 頁面。`pageLabels` 是 catalog 的 `/PageLabels` number tree 原文，例如
/// `<< /Nums [0 << /S /r >> 3 << /S /D >>] >>`（前三頁 i–iii，之後 1、2、3…）；`nil` 表示沒有
/// `/PageLabels`。`indirect` 為真時 `/PageLabels` 以間接物件（`n 0 R`）存放。xref 位移依實際位元組計算。
enum MinimalPDF {
    static func make(pageCount: Int, pageLabels: String? = nil, indirect: Bool = false) -> Data {
        var objects: [String] = []
        let firstPage = 3
        let labelsObject = firstPage + pageCount
        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if let pageLabels {
            catalog += indirect ? " /PageLabels \(labelsObject) 0 R" : " /PageLabels \(pageLabels)"
        }
        objects.append(catalog + " >>")
        let kids = (0..<pageCount).map { "\(firstPage + $0) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
        for _ in 0..<pageCount {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
        }
        if let pageLabels, indirect {
            objects.append(pageLabels)
        }

        var output = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = output.utf8.count
        output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            output += String(format: "%010d 00000 n \n", offset)
        }
        output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(output.utf8)
    }

    /// 寫到暫存檔並回傳路徑（呼叫端負責刪除）。
    static func write(pageCount: Int, pageLabels: String? = nil, indirect: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try make(pageCount: pageCount, pageLabels: pageLabels, indirect: indirect).write(to: url)
        return url
    }
}
