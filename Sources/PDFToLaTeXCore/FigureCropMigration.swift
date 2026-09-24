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
    /// 全部處理完後，**只要 `pageNumbers` 不是空的**（即使沒有任何一頁真的被改寫），就用
    /// `tex/` 目錄裡**所有**既有頁面（不是只有這次要求遷移的 `pageNumbers` 子集）重建
    /// `accumulated.tex`（`rebuildAccumulated`）——理由見下方兩點。
    ///
    /// ### 為什麼是「所有既有頁面」而不是 `pageNumbers`
    ///
    /// 只遷移一個子集（例如只有第 5 頁需要重新裁切）時，若重建只用這個子集，`accumulated.tex`
    /// 會被覆寫成只剩第 5 頁的內容，把專案其他頁面靜默地從總文件裡刪掉——即使那些頁面的
    /// `tex/page-NNNN.tex` 本身完好無缺。`allExistingPageNumbers(texDir:)` 直接掃 `tex/` 目錄找出
    /// 專案實際擁有的全部頁面，重建永遠涵蓋整份文件。
    ///
    /// ### 為什麼是「不管有沒有改寫」都重建
    ///
    /// 若只在 `anyChanged` 時才重建：假設第一次呼叫時各頁的 `tex/page-NNNN.tex` 都已成功寫入
    /// 新格式，但 `accumulated.tex` 本身寫入失敗（例如磁碟空間不足）——此時各頁已是新格式、
    /// 但 `accumulated.tex` 仍是舊內容，兩者不一致。修好寫入障礙後重跑，這次每一頁比對出來都
    /// 是 `.unchanged`（因為都已是新格式），`anyChanged` 永遠是 false，`accumulated.tex` 就再也
    /// 沒有機會被修復。改成不論有沒有頁面改寫都重建，重跑永遠能把 `accumulated.tex` 校正回與
    /// 目前所有 `tex/page-NNNN.tex` 一致的狀態。
    ///
    /// ## 冪等
    ///
    /// 重跑時每一頁的 `tex/page-NNNN.tex` 已經是新格式（帶頁碼的裁切檔名、`width=` 已寫入），
    /// `postProcessPage` 對「已經是目標格式」的呼叫不會再產生任何改寫（`rewriteFigureIncludes`
    /// 本身冪等，見 `LaTeXNormalizer.applyFigureWidths` 的文件），所以第二輪每一頁都會落在
    /// `.unchanged`；`accumulated.tex` 仍會被重建，但內容與前一輪相同（重寫、不是改寫）。
    public func migrateFigureCrops(project: ResolvedProject, pageNumbers: [Int]) throws -> [FigureMigrationOutcome] {
        let texDir = project.root.appendingPathComponent("tex", isDirectory: true)
        let responseResults = Self.loadResponsePageResults(projectDir: project.root)
        var byPage: [Int: PageResult] = [:]
        for result in responseResults where byPage[result.page] == nil {
            byPage[result.page] = result
        }

        var outcomes: [FigureMigrationOutcome] = []

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
                outcomes.append(FigureMigrationOutcome(
                    page: page, kind: .migrated(figuresProcessed: pageResult.figures.count), notes: processed.notes
                ))
            } catch {
                outcomes.append(FigureMigrationOutcome(
                    page: page, kind: .writeFailed(error.localizedDescription), notes: processed.notes
                ))
            }
        }

        if !pageNumbers.isEmpty {
            let allPages = Self.allExistingPageNumbers(texDir: texDir)
            let rebuilt = rebuildAccumulated(pageNumbers: allPages, texDir: texDir, projectRoot: project.root)
            try rebuilt.write(
                to: project.root.appendingPathComponent("accumulated.tex"), atomically: true, encoding: .utf8
            )
        }

        return outcomes
    }

    /// 掃 `texDir` 底下所有 `page-NNNN.tex` 檔，回傳排序過的頁碼——專案「實際擁有」的全部頁面，
    /// 不是這次遷移要求的子集。重建 `accumulated.tex` 一定要用這份清單，見
    /// `migrateFigureCrops` 文件裡「為什麼是所有既有頁面」的說明。
    private static func allExistingPageNumbers(texDir: URL) -> [Int] {
        let files = (try? FileManager.default.contentsOfDirectory(at: texDir, includingPropertiesForKeys: nil)) ?? []
        guard let regex = try? NSRegularExpression(pattern: #"^page-(\d+)\.tex$"#) else { return [] }
        var numbers: [Int] = []
        for file in files {
            let name = file.lastPathComponent
            let range = NSRange(location: 0, length: (name as NSString).length)
            guard let match = regex.firstMatch(in: name, range: range),
                  let numberRange = Range(match.range(at: 1), in: name),
                  let number = Int(name[numberRange]) else { continue }
            numbers.append(number)
        }
        return numbers.sorted()
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
