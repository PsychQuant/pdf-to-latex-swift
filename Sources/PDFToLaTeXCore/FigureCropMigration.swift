import Foundation

// MARK: - Figure Crop Migration (PsychQuant/pdf-to-latex-swift#222)

/// 舊專案（0.4.0 之前轉寫、`tex/page-*.tex` 仍引用不帶頁碼的 `figures/<id>.png`）的重新裁切遷移，
/// 一頁一個結果。**不呼叫 AI**：figure 的 id 與 bbox 一律從既有 `responses/*.json` 讀，只是照
/// #208 起的規則（`FigureAssetPath.cropped(page:id:)`）重新裁切成帶頁碼的檔名、改寫引用。
public struct FigureMigrationOutcome: Sendable, Equatable {
    /// 封閉列舉，只有這六類，不得依性質相似類推。
    public enum Kind: Sendable, Equatable {
        /// 重新裁切過 figure、改寫了 `tex/page-NNNN.tex` 的引用。`figuresProcessed` 是這一頁
        /// responses 裡登記的 figure 數量（不是實際裁切成功的數量——裁切失敗的仍計入，原因見
        /// `notes`，與 `postProcessPage` 的既有回報方式相同）。
        case migrated(figuresProcessed: Int)
        /// 呼叫過 `postProcessPage`，但沒有任何改動：這一頁本來就沒有 figure，或引用早就是
        /// 目前這輪會寫出的樣子（已經遷移過，重跑是冪等的）。
        case unchanged
        /// `tex/page-NNNN.tex` 不存在或讀不到（這一頁從未被轉寫過，或不屬於這個專案）。
        case noPageTexFile
        /// `responses/*.json` 裡沒有任何一筆回報過這一頁——多半是這個專案走的是 block-level
        /// pipeline（回應格式不同，無法回推 figure 的 bbox），或這一頁真的從未被轉寫。
        case noFigureData
        /// manifest 裡沒有這一頁的頁面圖（`renderedImagePath` 是 nil，或這一頁根本不在 manifest
        /// 裡）：沒有圖可以裁，不會嘗試呼叫 `postProcessPage`。
        case noPageImage
        /// `tex/page-NNNN.tex` 改寫後寫回磁碟時失敗；附系統錯誤訊息。不會中斷其餘頁面的遷移。
        case writeFailed(String)
    }

    public let page: Int
    public let kind: Kind
    /// 裁切／改寫過程中的訊息（id 不安全、bbox 不合法等；與 `postProcessPage` 的 notes 同一來源）。
    public let notes: [String]

    public init(page: Int, kind: Kind, notes: [String] = []) {
        self.page = page
        self.kind = kind
        self.notes = notes
    }
}

extension PageTranscriber {

    /// 依 `responses/*.json` 裡登記的 figure bbox，重新裁切成帶頁碼的檔名（`FigureAssetPath.cropped`）
    /// 並改寫 `tex/page-NNNN.tex` 的 `\includegraphics` 引用——不呼叫 AI，純粹重放既有資料。
    ///
    /// 對每個要求的頁碼，依序：
    /// 1. 讀 `tex/page-NNNN.tex` 目前的內容（找不到 → `.noPageTexFile`）；
    /// 2. 在 `responses/*.json` 裡找這一頁的 `PageResult`（找不到 → `.noFigureData`；同一頁在多個
    ///    response 檔都出現時取排序後第一個找到的，正常流程下不會發生）；
    /// 3. 依 `resolvedPageImagePath(forPage:in:)` 找這一頁的頁面圖（找不到 → `.noPageImage`，
    ///    不會嘗試裁切）；
    /// 4. 呼叫與轉寫當下相同的 `postProcessPage`（PsychQuant/macdoc#208、#209 的規則）重新裁切、
    ///    改寫引用與寬度；結果與原內容不同才寫回磁碟（寫入失敗 → `.writeFailed`，不中斷其餘頁面），
    ///    相同則 `.unchanged`，改了則 `.migrated`。
    ///
    /// 全部處理完後，只要有任何一頁真的被改寫，就用與 `transcribe()` 相同的規則重建
    /// `accumulated.tex`（`rebuildAccumulated`）。
    ///
    /// ## 冪等
    ///
    /// 重跑時每一頁的 `tex/page-NNNN.tex` 已經是新格式（帶頁碼的裁切檔名、`width=` 已寫入），
    /// `postProcessPage` 對「已經是目標格式」的呼叫不會再產生任何改寫（`rewriteFigureIncludes`
    /// 本身冪等，見 `LaTeXNormalizer.applyFigureWidths` 的文件），所以第二輪每一頁都會落在
    /// `.unchanged`，`accumulated.tex` 也不會被重寫。
    public func migrateFigureCrops(project: ResolvedProject, pageNumbers: [Int]) throws -> [FigureMigrationOutcome] {
        let texDir = project.root.appendingPathComponent("tex", isDirectory: true)
        let responseResults = Self.loadResponsePageResults(projectDir: project.root)
        var byPage: [Int: PageResult] = [:]
        for result in responseResults where byPage[result.page] == nil {
            byPage[result.page] = result
        }

        var outcomes: [FigureMigrationOutcome] = []
        var anyChanged = false

        for page in pageNumbers {
            let pageTexURL = texDir.appendingPathComponent(String(format: "page-%04d.tex", page))
            guard let originalLatex = try? String(contentsOf: pageTexURL, encoding: .utf8) else {
                outcomes.append(FigureMigrationOutcome(page: page, kind: .noPageTexFile))
                continue
            }
            guard let pageResult = byPage[page] else {
                outcomes.append(FigureMigrationOutcome(page: page, kind: .noFigureData))
                continue
            }
            guard let pageImagePath = Self.resolvedPageImagePath(forPage: page, in: project.manifest.pages) else {
                outcomes.append(FigureMigrationOutcome(page: page, kind: .noPageImage))
                continue
            }

            let pageWidth = project.manifest.pages.first(where: { $0.number == page })?.width
            let processed = Self.postProcessPage(
                PageResult(page: page, latex: originalLatex, figures: pageResult.figures, confidence: nil, notes: nil),
                pageImagePath: pageImagePath, pageWidth: pageWidth, projectRoot: project.root
            )

            guard processed.latex != originalLatex else {
                outcomes.append(FigureMigrationOutcome(page: page, kind: .unchanged, notes: processed.notes))
                continue
            }
            do {
                try processed.latex.write(to: pageTexURL, atomically: true, encoding: .utf8)
                anyChanged = true
                outcomes.append(FigureMigrationOutcome(
                    page: page, kind: .migrated(figuresProcessed: pageResult.figures.count), notes: processed.notes
                ))
            } catch {
                outcomes.append(FigureMigrationOutcome(
                    page: page, kind: .writeFailed(error.localizedDescription), notes: processed.notes
                ))
            }
        }

        if anyChanged {
            let rebuilt = rebuildAccumulated(pageNumbers: pageNumbers, texDir: texDir, projectRoot: project.root)
            try rebuilt.write(
                to: project.root.appendingPathComponent("accumulated.tex"), atomically: true, encoding: .utf8
            )
        }

        return outcomes
    }

    /// 掃描 `responses/*.json`（依檔名排序），解碼出所有頁的 `PageResult`。讀不到或無法解碼的檔案
    /// 直接略過（不是這個遷移工具要修的問題；`responses/` 本來的讀取失敗回報屬於
    /// `LaTeXFigureWidth` 的 `unreadableResponseFiles`，遷移只是找不到對應頁面時落在
    /// `.noFigureData`，訊息已經夠明確，不重複一套錯誤累積機制）。
    private static func loadResponsePageResults(projectDir: URL) -> [PageResult] {
        let fileManager = FileManager.default
        let responsesDir = projectDir.appendingPathComponent("responses", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: responsesDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let files = ((try? fileManager.contentsOfDirectory(at: responsesDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.flatMap { LaTeXNormalizer.decodePageResponse(at: $0)?.pages ?? [] }
    }
}
