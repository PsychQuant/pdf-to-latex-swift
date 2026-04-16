import Foundation

/// Page-level 轉寫器。以 sliding window 方式逐批送頁面圖片給 AI CLI，
/// 搭配已轉寫的 LaTeX context 確保前後連貫。
///
/// 檔案結構：
/// - `accumulated.tex`：從 `tex/page-NNNN.tex` 自動組合的完整文件（derived, 每次重建）
/// - `tex/page-NNNN.tex`：每頁獨立的 LaTeX 片段（source of truth）
/// - `responses/pages-NNN-NNN.json`：每次 AI 呼叫的原始回應
/// - `figures/pNNN-figNN.png`：裁切的 figure 圖片
public struct PageTranscriber: Sendable {
    public init() {}

    /// 執行 page-level 轉寫。支援從中斷處自動續跑。
    /// `pagesPerRequest` 為 nil 時使用 backend 的預設值（codex/claude: 2, gemini: 3）。
    public func transcribe(
        project: inout ResolvedProject,
        pageNumbers: [Int],
        pagesPerRequest: Int? = nil,
        backend: TranscriptionBackend,
        model: String,
        reasoningEffort: ReasoningEffort = .medium,
        timeoutSeconds: Double,
        sourceFormat: PDFSourceFormat? = nil
    ) throws -> [PageResult] {
        let effectivePages = pagesPerRequest ?? backend.defaultPagesPerRequest
        let store = ManifestStore()
        let cli = CLITranscriber(backend: backend)
        let schemaURL = project.root.appendingPathComponent("tmp/page-transcription.schema.json")
        try writePageSchema(to: schemaURL)

        let texDir = project.root.appendingPathComponent("tex", isDirectory: true)
        let responsesDir = project.root.appendingPathComponent("responses", isDirectory: true)
        let figuresDir = project.root.appendingPathComponent("figures", isDirectory: true)
        let accumulatedURL = project.root.appendingPathComponent("accumulated.tex")

        for dir in [texDir, responsesDir, figuresDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 確保 preamble.tex 存在（使用者可自訂，不覆蓋）
        try ensurePreamble(projectRoot: project.root)

        // 為所有頁面建立佔位檔（已轉寫的不會被覆蓋）
        try ensurePlaceholders(pageNumbers: pageNumbers, texDir: texDir)

        // Resume: 找出尚未轉寫的頁面（含佔位檔）
        let pendingPages = resolvePendingPages(pageNumbers: pageNumbers, texDir: texDir)

        guard !pendingPages.isEmpty else {
            // 即使沒有新頁面要轉，也重建 accumulated.tex 確保一致
            let accumulated = rebuildAccumulated(pageNumbers: pageNumbers, texDir: texDir, projectRoot: project.root)
            try accumulated.write(to: accumulatedURL, atomically: true, encoding: .utf8)
            print("所有頁面已轉寫完成。")
            return []
        }

        print("待轉寫: \(pendingPages.count) 頁（從第 \(pendingPages.first!) 頁開始，每次 \(effectivePages) 頁）")

        // Phase 0: 載入 per-page layout hints（優先從 cache 讀取，沒有才掃描）
        let structureStore = StructureStore(projectRoot: project.root)
        var layoutMap: [Int: PDFStructureScanner.PageLayout] = [:]
        var isOCR = false
        var detectedSource: PDFSourceFormat = sourceFormat ?? .unknown

        let uncachedPages = structureStore.pendingPages(from: pendingPages)
        if !uncachedPages.isEmpty {
            // 有尚未掃描的頁面 → 執行全書掃描並存檔（含來源偵測）
            if let structure = try? structureStore.scanAndSave(pdfURL: project.pdfURL) {
                isOCR = structure.pdfType == PDFStructureScanner.PDFType.scanned
                if detectedSource == .unknown, let sd = structure.sourceDetection {
                    detectedSource = sd.format
                }
                print("Phase 0: 掃描完成（\(structure.pdfType.rawValue)），來源: \(detectedSource.rawValue)，已存 \(structure.pageLayouts.count) 頁 layout 到 layouts/。")
            }
        } else if let cached = try? structureStore.loadStructure() {
            isOCR = cached.pdfType == PDFStructureScanner.PDFType.scanned
            if detectedSource == .unknown, let sd = cached.sourceDetection {
                detectedSource = sd.format
            }
        }

        // 從 cache 載入需要的頁面 layouts
        let cachedLayouts = structureStore.loadPageLayouts(pageNumbers: pendingPages)
        for layout in cachedLayouts {
            layoutMap[layout.pageNumber] = layout
        }
        if !layoutMap.isEmpty {
            print("Phase 0: 已載入 \(layoutMap.count) 頁的 layout hints\(isOCR ? "（OCR）" : "")。")
        }

        var allResults: [PageResult] = []
        var index = 0

        while index < pendingPages.count {
            let batchEnd = min(index + effectivePages, pendingPages.count)
            let batchPages = Array(pendingPages[index..<batchEnd])

            let imagePaths: [String] = batchPages.compactMap { pageNum in
                project.manifest.pages.first(where: { $0.number == pageNum })?.renderedImagePath
            }

            guard imagePaths.count == batchPages.count else {
                throw PDFToLaTeXError.validation(
                    "部分頁面尚未渲染。請先執行 render 命令。缺少: \(batchPages)"
                )
            }

            // 只用已轉寫的真正內容建構 prompt context（排除 placeholder）
            let contextContent = buildPromptContext(pageNumbers: pageNumbers, texDir: texDir)
            let context = PromptBuilder.truncateContext(contextContent)
            let batchLayouts = batchPages.compactMap { layoutMap[$0] }
            let prompt = PromptBuilder.buildPagePrompt(
                pageNumbers: batchPages,
                imagePaths: imagePaths,
                latexContext: context,
                totalPages: project.manifest.pages.count,
                pageLayouts: batchLayouts.isEmpty ? nil : batchLayouts,
                isOCR: isOCR,
                sourceFormat: detectedSource
            )

            let batchLabel = batchPages.map { String(format: "%03d", $0) }.joined(separator: "-")
            let responseURL = responsesDir.appendingPathComponent("pages-\(batchLabel).json")

            print("轉寫第 \(batchPages.map(String.init).joined(separator: ", ")) 頁...")

            let response: PageTranscriptionResponse
            do {
                response = try cli.transcribePages(
                    projectRoot: project.root,
                    pageImages: zip(batchPages, imagePaths).map { (pageNumber: $0, imagePath: $1) },
                    model: model,
                    reasoningEffort: reasoningEffort,
                    prompt: prompt,
                    schemaURL: schemaURL,
                    outputURL: responseURL,
                    timeoutSeconds: timeoutSeconds
                )
            } catch let error as PDFToLaTeXError where error.isTimeout {
                // Timeout → 自動重試一次
                print("第 \(batchPages) 頁 timeout，自動重試...")
                do {
                    response = try cli.transcribePages(
                        projectRoot: project.root,
                        pageImages: zip(batchPages, imagePaths).map { (pageNumber: $0, imagePath: $1) },
                        model: model,
                        reasoningEffort: reasoningEffort,
                        prompt: prompt,
                        schemaURL: schemaURL,
                        outputURL: responseURL,
                        timeoutSeconds: timeoutSeconds
                    )
                } catch {
                    // 重試也失敗 → 跳過這批，繼續下一批
                    print("重試仍失敗（第 \(batchPages) 頁）: \(error.localizedDescription)")
                    print("跳過，繼續下一批...")
                    index = batchEnd
                    continue
                }
            } catch {
                print("轉寫失敗（第 \(batchPages) 頁）: \(error.localizedDescription)")
                print("可用 --first-page \(batchPages.first!) 從此處重試。")
                break
            }

            // Post-process 每一頁
            for pageResult in response.pages {
                // 1. 裁切 figures
                for figure in pageResult.figures {
                    guard figure.bbox.count == 4 else { continue }
                    if let imgPath = imagePaths.first(where: {
                        $0.contains(String(format: "page-%04d", pageResult.page))
                    }) ?? imagePaths.first {
                        cropFigure(figure: figure, pageImagePath: imgPath, figuresDir: figuresDir)
                    }
                }

                // 2. 寫入個別頁面 .tex（source of truth）
                let pageTexURL = texDir.appendingPathComponent(
                    String(format: "page-%04d.tex", pageResult.page)
                )
                try pageResult.latex.write(to: pageTexURL, atomically: true, encoding: .utf8)

                allResults.append(pageResult)
                print("ok page \(pageResult.page) (\(pageResult.figures.count) figures)")
            }

            // 3. 偵測並更新 preamble（SCD1: 根據內容動態調整）
            try updatePreambleIfNeeded(projectRoot: project.root, texDir: texDir, pageNumbers: pageNumbers)

            // 4. 每批完成後重建 accumulated.tex
            let updatedAccumulated = rebuildAccumulated(pageNumbers: pageNumbers, texDir: texDir, projectRoot: project.root)
            try updatedAccumulated.write(to: accumulatedURL, atomically: true, encoding: .utf8)

            // Update manifest
            project.manifest.updatedAt = Support.nowISO8601()
            try? store.save(project.manifest, to: project.manifestURL)

            index = batchEnd
        }

        print("accumulated.tex: \(accumulatedURL.path)")
        return allResults
    }

    // MARK: - Preamble

    /// 確保 preamble.tex 存在。如果已存在則不覆蓋（使用者可自訂）。
    private func ensurePreamble(projectRoot: URL) throws {
        let preambleURL = projectRoot.appendingPathComponent("preamble.tex")
        guard !FileManager.default.fileExists(atPath: preambleURL.path) else { return }
        try Self.defaultPreamble.write(to: preambleURL, atomically: true, encoding: .utf8)
    }

    /// 掃描所有已轉寫的頁面，偵測需要但 preamble 中尚未包含的 LaTeX 套件，自動補上。
    private func updatePreambleIfNeeded(projectRoot: URL, texDir: URL, pageNumbers: [Int]) throws {
        let preambleURL = projectRoot.appendingPathComponent("preamble.tex")
        guard var preamble = try? String(contentsOf: preambleURL, encoding: .utf8) else { return }

        // 收集所有已轉寫頁面的內容
        var allContent = ""
        for page in pageNumbers {
            let texURL = texDir.appendingPathComponent(String(format: "page-%04d.tex", page))
            if let content = try? String(contentsOf: texURL, encoding: .utf8),
               !content.hasPrefix(Self.placeholderMarker) {
                allContent += content
            }
        }
        guard !allContent.isEmpty else { return }

        // 偵測使用的環境/命令 → 需要的套件
        let detections: [(pattern: String, package: String)] = [
            ("\\begin{tikzpicture}", "tikz"),
            ("\\begin{algorithm}", "algorithm2e"),
            ("\\begin{lstlisting}", "listings"),
            ("\\begin{minted}", "minted"),
            ("\\begin{enumerate}", "enumitem"),
            ("\\begin{itemize}", "enumitem"),
            ("\\begin{multicols}", "multicol"),
            ("\\begin{subfigure}", "subcaption"),
            ("\\begin{landscape}", "lscape"),
            ("\\begin{longtable}", "longtable"),
            ("\\begin{align", "amsmath"),
            ("\\mathbb{", "amssymb"),
            ("\\mathcal{", "amsmath"),
            ("\\boldsymbol{", "amsmath"),
            ("\\xrightarrow", "mathtools"),
            ("\\underbrace", "amsmath"),
            ("\\cancel{", "cancel"),
            ("\\bm{", "bm"),
        ]

        var added: [String] = []
        for (pattern, package) in detections {
            if allContent.contains(pattern) && !preamble.contains("\\usepackage{\(package)}") &&
               !preamble.contains("\\usepackage[\(package)]") && !preamble.contains(",\(package)}") &&
               !preamble.contains(",\(package),") && !preamble.contains("{\(package),") {
                added.append(package)
            }
        }

        guard !added.isEmpty else { return }

        // 在 preamble 最後一行（空行前）插入新套件
        let newPackages = added.map { "\\usepackage{\($0)}" }.joined(separator: "\n")
        preamble += "\n% Auto-detected packages\n\(newPackages)\n"
        try preamble.write(to: preambleURL, atomically: true, encoding: .utf8)
        print("preamble 已更新，新增套件: \(added.joined(separator: ", "))")
    }

    private static let defaultPreamble = """
    \\documentclass[11pt,letterpaper]{article}

    % Encoding & fonts
    \\usepackage[utf8]{inputenc}
    \\usepackage[T1]{fontenc}
    \\usepackage{lmodern}

    % Math
    \\usepackage{amsmath,amssymb,amsthm,mathtools}

    % Layout
    \\usepackage[margin=1in]{geometry}
    \\usepackage{setspace}
    \\usepackage{parskip}

    % Tables & figures
    \\usepackage{booktabs,array,tabularx}
    \\usepackage{graphicx}
    \\usepackage{float}

    % References & links
    \\usepackage[hidelinks]{hyperref}

    % Theorem environments
    \\newtheorem{theorem}{Theorem}[section]
    \\newtheorem{lemma}[theorem]{Lemma}
    \\newtheorem{proposition}[theorem]{Proposition}
    \\newtheorem{corollary}[theorem]{Corollary}
    \\newtheorem{definition}[theorem]{Definition}
    \\newtheorem{example}[theorem]{Example}
    \\newtheorem{remark}[theorem]{Remark}
    \\newtheorem{assumption}[theorem]{Assumption}

    """

    // MARK: - Prompt Context

    /// 只收集已轉寫的真正 LaTeX 內容（排除 placeholder），供 AI prompt 使用。
    private func buildPromptContext(pageNumbers: [Int], texDir: URL) -> String {
        var result = ""
        for page in pageNumbers {
            let texURL = texDir.appendingPathComponent(String(format: "page-%04d.tex", page))
            guard let content = try? String(contentsOf: texURL, encoding: .utf8),
                  !content.hasPrefix(Self.placeholderMarker) else { continue }
            if content.hasPrefix("%% ===") {
                result += "\n" + content + "\n"
            } else {
                result += "\n%% === Page \(page) ===\n" + content + "\n"
            }
        }
        return result
    }

    // MARK: - Rebuild Accumulated

    /// 從所有已存在的 per-page .tex 檔案重建完整的可編譯 LaTeX 文件。
    /// 包含 preamble（\\input{preamble}）和 \\end{document}。
    private func rebuildAccumulated(pageNumbers: [Int], texDir: URL, projectRoot: URL) -> String {
        var body = ""
        for page in pageNumbers {
            let texURL = texDir.appendingPathComponent(String(format: "page-%04d.tex", page))
            if let content = try? String(contentsOf: texURL, encoding: .utf8) {
                // per-page 檔案可能已自帶 header，直接串接即可
                if content.hasPrefix("%% ===") {
                    body += "\n" + content + "\n"
                } else {
                    body += "\n%% === Page \(page) ===\n" + content + "\n"
                }
            }
        }

        return """
        \\input{preamble}
        \\begin{document}
        \(body)
        \\end{document}
        """
    }

    // MARK: - Placeholders

    private static let placeholderMarker = "%% PLACEHOLDER"

    /// 為所有尚未轉寫的頁面建立佔位 .tex 檔，讓 accumulated.tex 能顯示完整結構。
    private func ensurePlaceholders(pageNumbers: [Int], texDir: URL) throws {
        for page in pageNumbers {
            let texURL = texDir.appendingPathComponent(String(format: "page-%04d.tex", page))
            guard !FileManager.default.fileExists(atPath: texURL.path) else { continue }
            let placeholder = "\(Self.placeholderMarker)\n%% Page \(page) — 尚未轉寫\n"
            try placeholder.write(to: texURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Resume

    /// 找出尚未轉寫的頁碼（佔位檔或不存在的頁面）。
    private func resolvePendingPages(pageNumbers: [Int], texDir: URL) -> [Int] {
        pageNumbers.filter { page in
            let texURL = texDir.appendingPathComponent(String(format: "page-%04d.tex", page))
            guard let content = try? String(contentsOf: texURL, encoding: .utf8) else {
                return true // 檔案不存在
            }
            return content.hasPrefix(Self.placeholderMarker) // 佔位檔也算 pending
        }
    }

    // MARK: - Figure Cropping

    private func cropFigure(figure: FigureRegion, pageImagePath: String, figuresDir: URL) {
        do {
            let pageImage = try CGImageHelper.load(from: URL(fileURLWithPath: pageImagePath))
            let imgW = Double(pageImage.width)
            let imgH = Double(pageImage.height)

            let cropRect = CGRect(
                x: figure.bbox[0] * imgW,
                y: figure.bbox[1] * imgH,
                width: figure.bbox[2] * imgW,
                height: figure.bbox[3] * imgH
            )

            guard let cropped = pageImage.cropping(to: cropRect) else { return }
            let outputURL = figuresDir.appendingPathComponent("\(figure.id).png")
            try CGImageHelper.writePNG(cropped, to: outputURL)
        } catch {
            print("裁切 figure \(figure.id) 失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Schema

    private func writePageSchema(to url: URL) throws {
        let schema = """
        {
          "type": "object",
          "properties": {
            "pages": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "page": { "type": "integer" },
                  "latex": { "type": "string" },
                  "figures": {
                    "type": "array",
                    "items": {
                      "type": "object",
                      "properties": {
                        "id": { "type": "string" },
                        "bbox": { "type": "array", "items": { "type": "number" } },
                        "caption": { "type": ["string", "null"] }
                      },
                      "required": ["id", "bbox", "caption"],
                      "additionalProperties": false
                    }
                  },
                  "confidence": { "type": ["number", "null"] },
                  "notes": { "type": ["string", "null"] },
                  "uncertainties": {
                    "type": ["array", "null"],
                    "items": {
                      "type": "object",
                      "properties": {
                        "snippet": { "type": "string" },
                        "reason": {
                          "type": "string",
                          "enum": ["ambiguous_symbol", "layout_unclear", "occluded_or_blurry", "handwritten_or_unusual_font", "complex_math_structure", "table_structure", "other"]
                        },
                        "description": { "type": "string" },
                        "alternatives": { "type": ["array", "null"], "items": { "type": "string" } }
                      },
                      "required": ["snippet", "reason", "description", "alternatives"],
                      "additionalProperties": false
                    }
                  }
                },
                "required": ["page", "latex", "figures", "confidence", "notes", "uncertainties"],
                "additionalProperties": false
              }
            }
          },
          "required": ["pages"],
          "additionalProperties": false
        }
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try schema.write(to: url, atomically: true, encoding: .utf8)
    }
}
