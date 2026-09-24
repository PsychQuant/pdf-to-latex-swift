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
        /// 呼叫過 `postProcessPage`，但這一頁的 `tex/page-NNNN.tex` **文字內容**沒有改動：這一頁
        /// 本來就沒有 figure，或引用早就是目前這輪會寫出的樣子（已經遷移過，重跑是冪等的）。
        ///
        /// **`.unchanged` 只保證 tex 文字沒變，不保證磁碟上完全沒有任何動作**：`postProcessPage`
        /// 每次都會重新裁切一次（`cropFigures` 本身無條件執行），所以即使引用文字不變，裁切檔
        /// 仍可能被重寫（例如先前被誤刪，這一輪會自動補回來）。裁切失敗、id 不安全等原因造成
        /// 「沒有東西可裁切所以文字也沒變」時，原因記在 `notes`，不會反映在 `kind` 本身——這個
        /// 六類列舉只回答「tex 檔要不要重寫」，細節看 `notes`（Codex R2 審查）。
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
    /// ## 回傳的六類列舉只涵蓋「逐頁」結果，不是整個操作唯一可能的結果
    ///
    /// `throws` 用來表達影響整個操作、與任何單一頁面無關的失敗（`tex/` 目錄列舉失敗、
    /// `accumulated.tex` 寫入失敗）；這種情況下呼叫端**拿不到已經處理完的 `outcomes`**——不會有
    /// 部分結果，因為它整個 throw 掉了。六類列舉（`FigureMigrationOutcome.Kind`）只描述「某一頁
    /// 有沒有被改寫、為什麼沒有」，不是宣稱涵蓋這個函式所有可能的失敗方式（Codex R2 審查）。
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
    /// 全部處理完後，**只要 `pageNumbers` 不是空的、且 `tex/` 目錄裡確實找得到至少一頁**
    /// （即使沒有任何一頁真的被改寫），就用 `tex/` 目錄裡**所有**既有頁面（不是只有這次要求遷移
    /// 的 `pageNumbers` 子集）重建 `accumulated.tex`（`rebuildAccumulated`）——理由見下方兩點。
    /// `tex/` 目錄裡一頁都找不到時**完全不碰** `accumulated.tex`（見下方「所有既有頁面」一節結尾），
    /// 不會覆寫掉可能還完好的既有總文件。
    ///
    /// ### 為什麼是「所有既有頁面」而不是 `pageNumbers`
    ///
    /// 只遷移一個子集（例如只有第 5 頁需要重新裁切）時，若重建只用這個子集，`accumulated.tex`
    /// 會被覆寫成只剩第 5 頁的內容，把專案其他頁面靜默地從總文件裡刪掉——即使那些頁面的
    /// `tex/page-NNNN.tex` 本身完好無缺。`allExistingPageNumbers(texDir:)` 直接掃 `tex/` 目錄找出
    /// 專案實際擁有的全部頁面，重建永遠涵蓋整份文件。
    ///
    /// **這份清單本身是空的（`tex/` 不存在，或存在但沒有任何檔名符合 `page-NNNN.tex` 的檔案）
    /// 時，直接跳過整個重建，不寫 `accumulated.tex`**（協調者加審的第四輪 Codex 審查）：這代表
    /// 專案目前完全沒有可以組成總文件的頁面來源，可能是全新專案（本來就沒有 `accumulated.tex`
    /// 可覆寫，跳過無傷）、也可能是 `tex/` 被移走或還沒從備份還原（這時候多半還留著上一次完整
    /// 的 `accumulated.tex`，寫一份空的上去會是真正的資料遺失）。兩種情況「不重建」都是安全的
    /// 選擇；呼叫端已經能從逐頁 `outcomes` 看出沒有任何一頁被處理，不需要另外的封閉列舉再說一次
    /// 同一件事。
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

        // allPages 空的話（tex/ 真的不存在，或存在但一個符合 page-NNNN.tex 格式的檔案都沒有）
        // 完全不碰 accumulated.tex——沒有任何頁面可以重建，寫出一份空文件只會覆寫掉可能還完好的
        // 既有總文件（協調者加審的第四輪 Codex 審查：tex/ 被移走或尚未從備份還原時，
        // accumulated.tex 可能還留著上一次的完整內容，這時候「不重建」比「重建成空的」安全）。
        if !pageNumbers.isEmpty {
            let allPages = try Self.allExistingPageNumbers(texDir: texDir)
            if !allPages.isEmpty {
                let rebuilt = try rebuildAccumulated(pageNumbers: allPages, texDir: texDir, projectRoot: project.root)
                try rebuilt.write(
                    to: project.root.appendingPathComponent("accumulated.tex"), atomically: true, encoding: .utf8
                )
            }
        }

        return outcomes
    }

    /// 掃 `texDir` 底下所有 `page-NNNN.tex` 檔，回傳排序過的頁碼——專案「實際擁有」的全部頁面，
    /// 不是這次遷移要求的子集。重建 `accumulated.tex` 一定要用這份清單，見
    /// `migrateFigureCrops` 文件裡「為什麼是所有既有頁面」的說明。
    ///
    /// ## 目錄不存在 vs 列舉失敗（Codex R2、R3 審查）
    ///
    /// `texDir` 真的不存在時回傳空陣列——這是合法狀態（專案從未渲染過任何頁面）。但目錄**存在**、
    /// 列舉卻失敗（權限、I/O 錯誤）時**往外拋錯，不吞成空清單**：吞掉的話，
    /// `migrateFigureCrops` 會拿著這份假的「一頁都沒有」清單去重建 `accumulated.tex`，用一份
    /// 沒有任何頁面正文的內容覆寫掉原本完好的總文件——這比「不重建」還糟。
    ///
    /// R2 的版本先用 `FileManager.fileExists(atPath:)` 判斷「存不存在」，存在才列舉。R3 指出這個
    /// 前置檢查本身就不可靠：`fileExists` 回傳 `false` 不只代表路徑真的不存在，也可能代表**存取
    /// 失敗**（例如符號連結指到權限受限的目錄）——兩者都回傳 `false`，光看這一個 Bool 分不出來，
    /// 於是又繞回同一種「假裝是空的」風險，只是換了個位置。
    ///
    /// 改法：不先猜，直接嘗試列舉，只把**這個操作自己丟出來、確認是「找不到檔案」**的錯誤
    /// （`CocoaError.fileReadNoSuchFile`，`contentsOfDirectory` 對不存在路徑實測丟的就是這個）
    /// 當作「合法的空狀態」而回傳 `[]`；其他任何錯誤（權限不足等）原樣往外拋，不臆測。判斷依據
    /// 是操作實際回報的錯誤，不是另一個可能同樣不可靠的前置檢查。
    ///
    /// ## 只接受與重建時會組出來的檔名逐字相同（協調者加審的第四輪 Codex 審查）
    ///
    /// 重建（`rebuildAccumulated`）用 `String(format: "page-%04d.tex", n)` 從整數反推路徑去讀檔；
    /// 這裡列舉如果只用寬鬆的正則 `^page-(\d+)\.tex$`（沒有要求四位數補零），`tex/` 目錄裡若同時
    /// 有 `page-1.tex`（使用者手動留下的）與 `page-0001.tex`（工具自己寫的），兩者都解析成頁碼
    /// `1`，回傳的清單會出現重複（`[1, 1, ...]`），重建卻兩次都讀 `page-0001.tex`——不是分別處理
    /// 實際列舉到的檔案，總文件裡第 1 頁的內容會重複。反過來，若目錄裡只有 `page-1.tex`
    /// （沒有 `page-0001.tex`），寬鬆正則會讓清單裡出現「頁碼 1」，但重建去讀的
    /// `page-0001.tex` 根本不存在，會撞上前面剛加的「讀不到就 throw」。
    ///
    /// 解法：解析出頁碼後，**用同一個 `String(format:)` 反推回檔名，只有跟原始檔名逐字相同才收**
    /// ——`page-1.tex` 反推出的正確檔名是 `page-0001.tex`，跟自己不同，直接排除；只有真正由這個
    /// 遷移工具（或轉寫當下）寫出的標準檔名會被接受。因為每個頁碼只有一種合法拼法，
    /// 列舉出來的頁碼本身結構上不可能重複，`Set` 只是額外的防禦、不是修這個 bug 的必要條件。
    private static func allExistingPageNumbers(texDir: URL) throws -> [Int] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: texDir, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        let regex = try NSRegularExpression(pattern: #"^page-(\d+)\.tex$"#)
        var numbers = Set<Int>()
        for file in files {
            let name = file.lastPathComponent
            let range = NSRange(location: 0, length: (name as NSString).length)
            guard let match = regex.firstMatch(in: name, range: range),
                  let numberRange = Range(match.range(at: 1), in: name),
                  let number = Int(name[numberRange]),
                  name == String(format: "page-%04d.tex", number) else { continue }
            numbers.insert(number)
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
