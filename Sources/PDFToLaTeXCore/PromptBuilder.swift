import Foundation

public enum PromptBuilder {
    public static func build(for block: BlockRecord) -> String {
        let preview = (block.textPreview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let previewSection = preview.isEmpty ? "(無 OCR 預覽)" : preview

        return """
        你正在做數學課本 PDF 的逐塊轉寫。

        任務：
        - 讀取附上的單一 block 圖片
        - 將其內容忠實轉成 LaTeX snippet
        - 不要摘要、不要翻譯、不要補寫不可見內容
        - 輸出必須是符合 schema 的 JSON，且不得使用 Markdown code fence

        規則：
        - `latex` 只能是 snippet，不可包含 documentclass、preamble、\\begin{document}
        - 純文字請輸出可直接放進內文的 LaTeX
        - 若是 display equation，請輸出對應的數學環境或數學內容
        - 若內容主要是圖、示意圖、或你無法可靠辨識，請將 `needsFallback` 設為 true
        - 若部分可辨識但仍有疑慮，可在 `notes` 簡短說明
        - 保留原始大小寫、標點、編號、數學符號

        block metadata:
        - id: \(block.id)
        - type: \(block.type.rawValue)
        - page: \(block.page)

        OCR preview:
        \(previewSection)
        """
    }

    // MARK: - Page-level Prompts

    /// 根據 PDF 來源格式產生轉寫策略指引。
    public static func sourceStrategyHint(for source: PDFSourceFormat) -> String {
        switch source {
        case .latex:
            return """
            來源格式偵測：此 PDF 由 LaTeX 產生。
            轉寫策略：
            - 嘗試重建原始 LaTeX 結構，包括 \\begin{theorem}、\\begin{proof}、\\begin{lemma} 等環境
            - 保留方程式編號（如有）
            - 使用 LaTeX 慣用的數學符號寫法
            - 可以推斷 \\ref、\\label 交叉引用
            """
        case .word:
            return """
            來源格式偵測：此 PDF 由 Word/Office 產生。
            轉寫策略：
            - 使用基本 LaTeX 格式：\\textbf 代替粗體、\\textit 代替斜體
            - 不要猜測自訂環境（如 theorem、proof），除非明顯有標號
            - 公式可能來自 Equation Editor，注意符號對應
            - 圖片和表格可能有不規則的排版
            """
        case .typst:
            return """
            來源格式偵測：此 PDF 由 typst 產生。
            轉寫策略：
            - 類似 LaTeX 的結構化排版，但語法慣例可能不同
            - 嘗試重建結構化環境
            - 注意 typst 的預設字型和間距可能與 LaTeX 不同
            """
        case .scanned:
            return """
            來源格式偵測：此 PDF 是掃描件。
            轉寫策略：
            - OCR 品質可能不穩定，優先以圖片為準
            - 數學符號辨識需要格外謹慎
            - 對不確定的部分務必在 uncertainties 陣列中記錄
            - 圖片解析度可能影響細節辨識
            """
        case .designer:
            return """
            來源格式偵測：此 PDF 由排版軟體（InDesign/Quark）產生。
            轉寫策略：
            - 排版導向，結構可能不規則
            - 不要假設有 LaTeX 風格的環境
            - 使用基本 LaTeX 格式
            """
        case .unknown:
            return ""
        }
    }

    /// 建構 page-level 轉寫 prompt。包含已轉寫的 LaTeX context 和要轉寫的頁碼。
    /// `pageLayouts` 為 Phase 0 掃描出的 layout hints，文字段落附原文、公式不附。
    /// `isOCR`: true = scanned PDF (OCR 文字僅供參考), false = vector PDF (PDFKit 文字 100% 正確)。
    /// `sourceFormat`: PDF 來源格式，影響轉寫策略。
    public static func buildPagePrompt(
        pageNumbers: [Int],
        imagePaths: [String],
        latexContext: String,
        totalPages: Int,
        pageLayouts: [PDFStructureScanner.PageLayout]? = nil,
        isOCR: Bool = false,
        sourceFormat: PDFSourceFormat = .unknown
    ) -> String {
        let pageList = pageNumbers.map { String($0) }.joined(separator: ", ")

        let contextSection: String
        if latexContext.isEmpty {
            contextSection = "(這是第一批，尚無已轉寫內容。請從文件開始處撰寫。)"
        } else {
            contextSection = latexContext
        }

        let sourceHint = Self.sourceStrategyHint(for: sourceFormat)

        return """
        你正在逐步轉寫一本數學課本 PDF 成 LaTeX。
        以下是目前已累積的 .tex 檔案內容（可能有截斷中間部分）。
        你的任務是**接著寫下去**，產出可以直接 append 在下方 LaTeX 之後的內容。
        \(sourceHint.isEmpty ? "" : "\n\(sourceHint)")

        === 目前的 accumulated.tex ===
        \(contextSection)
        === 結束 ===

        現在請根據接下來的 \(pageNumbers.count) 頁圖片（第 \(pageList) 頁，全書共 \(totalPages) 頁），
        產出可以直接接在上方 LaTeX 最後一行之後的內容。

        要求：
        - 忠實還原頁面內容：文字、公式、定理、表格
        - 不要重複已轉寫的內容
        - 不要加 preamble、documentclass、\\begin{document}
        - 保持與前文一致的風格、命名、編號
        - 保留原始大小寫、標點、數學符號

        圖片處理：
        - 圖形、示意圖、照片等無法用 LaTeX 表示的 → 在 latex 中用 \\includegraphics{figures/pXXX-figYY.png}
        - 在 figures 陣列標出 bounding box（正規化座標 0-1，原點左上角）
        - bbox: [x, y, width, height]

        圖片檔案路徑：
        \(zip(pageNumbers, imagePaths).map { "第 \($0.0) 頁: \($0.1)" }.joined(separator: "\n"))
        請讀取上述圖片檔案進行轉寫。
        \(Self.buildLayoutHints(pageNumbers: pageNumbers, pageLayouts: pageLayouts, isOCR: isOCR))

        不確定區域報告：
        - 對於任何你不完全確定的部分，必須在 uncertainties 陣列中詳細記錄
        - snippet: 擷取你不確定的 LaTeX 片段原文
        - reason: 從以下選一個：ambiguous_symbol, layout_unclear, occluded_or_blurry, handwritten_or_unusual_font, complex_math_structure, table_structure, other
        - description: 用自然語言說明為何不確定，要具體到未來 AI 只看此描述就能判斷正確寫法
        - alternatives: 如果有其他可能的寫法，列出來；沒有則設為 null
        - 目標：未來的 AI 只靠看 uncertainties 就能產出正確的稿子，不需要重新看圖片

        輸出格式：
        只輸出有效的 JSON，不要用 markdown code fence，不要加其他文字。
        {
          "pages": [
            {
              "page": 頁碼,
              "latex": "可直接 append 的 LaTeX",
              "figures": [{"id": "pXXX-figYY", "bbox": [x, y, w, h], "caption": "圖說或 null"}],
              "confidence": 0.95,
              "notes": null,
              "uncertainties": [
                {
                  "snippet": "\\\\alpha_{ij}",
                  "reason": "ambiguous_symbol",
                  "description": "下標可能是 ij 或 y，圖片中此處字體較小且模糊",
                  "alternatives": ["\\\\alpha_{y}"]
                }
              ]
            }
          ]
        }
        """
    }

    /// 從 Phase 0 的 layout 分析產生 prompt hints。
    /// `isOCR`: true = scanned PDF (Vision OCR, ~99% 參考用), false = vector PDF (PDFKit, 100% 正確)。
    private static func buildLayoutHints(
        pageNumbers: [Int],
        pageLayouts: [PDFStructureScanner.PageLayout]?,
        isOCR: Bool = false
    ) -> String {
        guard let layouts = pageLayouts, !layouts.isEmpty else { return "" }

        var lines: [String] = []
        if isOCR {
            lines.append("\n頁面 layout 提示（Vision OCR 辨識結果）：")
            lines.append("- text/heading/list 的原文來自 OCR（~99% 正確，僅供參考，以圖片為準）")
            lines.append("- equation 的 OCR 不可靠，請完全以圖片為準")
        } else {
            lines.append("\n頁面 layout 提示（PDFKit 掃描結果）：")
            lines.append("- text/heading/list 的原文是 PDF 內嵌文字（100% 正確），可直接作為轉寫依據")
            lines.append("- equation 的原文不可靠（PDF 中數學符號是散落的 glyph），請以圖片為準")
        }

        for layout in layouts {
            guard pageNumbers.contains(layout.pageNumber) else { continue }
            lines.append("\n第 \(layout.pageNumber) 頁（\(layout.regions.count) 個區域）：")

            for (i, r) in layout.regions.enumerated() {
                let yRange = "y=\(Int(r.y))-\(Int(r.y + r.height))"

                switch r.type {
                case .text, .heading, .list, .header:
                    // 附原文（截斷到 200 字避免 prompt 過大）
                    let preview = String(r.text.prefix(200))
                        .replacingOccurrences(of: "\n", with: " ")
                    lines.append("  [\(i)] \(r.type.rawValue) \(yRange): \"\(preview)\"")
                case .equation:
                    // 不附原文，只標位置
                    lines.append("  [\(i)] equation \(yRange): (請從圖片辨識)")
                case .image:
                    lines.append("  [\(i)] image \(yRange): (圖片區域)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 截斷已轉寫的 LaTeX context，保留開頭結構和最近內容。
    public static func truncateContext(
        _ fullLatex: String,
        headChars: Int = 2000,
        tailChars: Int = 4000
    ) -> String {
        guard fullLatex.count > headChars + tailChars + 100 else {
            return fullLatex
        }
        let head = String(fullLatex.prefix(headChars))
        let tail = String(fullLatex.suffix(tailChars))
        return "\(head)\n\n% ... [已省略中間 \(fullLatex.count - headChars - tailChars) 字] ...\n\n\(tail)"
    }

    /// 為非 codex 後端（claude / gemini）加上圖片路徑引用和 JSON schema 說明。
    /// codex 用 `-i` flag 傳圖、`--output-schema` 指定 schema，不需要這些。
    public static func augmentForDirectCLI(basePrompt: String, imagePath: String) -> String {
        return """
        \(basePrompt)

        圖片檔案路徑: \(imagePath)
        請讀取上述圖片檔案，根據圖片內容進行轉寫。

        輸出格式要求:
        只輸出有效的 JSON，不要用 markdown code fence 包裹，不要加任何其他文字。
        JSON 結構必須嚴格符合:
        {"latex": "LaTeX snippet", "confidence": 0.95, "needsFallback": false, "notes": null}

        欄位說明:
        - latex (string): LaTeX snippet，不含 preamble
        - confidence (number|null): 信心度 0-1
        - needsFallback (boolean): 若內容主要是圖或無法可靠辨識，設為 true
        - notes (string|null): 備註
        """
    }
}
