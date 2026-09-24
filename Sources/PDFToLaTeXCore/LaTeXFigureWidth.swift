import Foundation

// MARK: - Figure Width from BBox (PsychQuant/macdoc#10, #207, #208, #209)

/// 單一 `\includegraphics{figures/...}` 的寬度還原結果。
public struct FigureWidthResolution: Sendable, Equatable {
    /// 處理結果（封閉列舉）。除 `widthApplied` 外，原始碼的寬度一律保持原樣。
    public enum Outcome: Sendable, Equatable {
        /// 已寫入 `width=\ifdim <w>bp>\linewidth\linewidth\else <w>bp\fi`（原書上的絕對寬度，
        /// 以 `\linewidth` 為上限；PsychQuant/macdoc#207）。`fraction` 是 bbox 寬（頁寬比例，
        /// 最多六位小數）；`widthPoints` 是寫進原始碼的 `<w>`（= `fraction` × manifest 頁寬，單位 bp，
        /// 最多四位小數）。實際排出的寬度是 `min(<w>bp, \linewidth)`，由 TeX 在編譯時決定。
        case widthApplied(fraction: Double, widthPoints: Double)
        /// 選項已含明確尺寸 key（`width`／`height`／`totalheight`／`scale`），原樣保留。
        case explicitSizePreserved
        /// 呼叫之前沒有作用中的 `%% === Page N ===`，無法決定屬於哪一頁。
        /// 以 `stripPageMarkers` 跑過一輪之後，marker 已被移除，未解決的圖在之後的輪次都會落在這裡。
        case noPageContext
        /// 該頁的 responses 沒有這個路徑的 figure。
        case noMatchingFigure
        /// 該頁同一路徑有多筆互相矛盾的 bbox。
        case ambiguousFigure
        /// bbox 不是合法的正規化 `[x, y, w, h]`。
        case invalidBoundingBox([Double])
        /// bbox 寬度以六位小數表示會變成 0，或乘上頁寬後以四位小數表示（bp）會變成 0：不寫入，
        /// 附 bbox 寬原值。
        case widthNotRepresentable(Double)
        /// manifest.json 沒有該頁的 `PageRecord`，或頁寬不是 `(0, 14400]` 內的有限值（14400 是 PDF
        /// 頁面尺寸上限；超過時換算出的尺寸可能超過 TeX 的 `\maxdimen`，寫進去會無法編譯）。
        case missingPageRecord
        /// 圖檔不存在：normalize 檢查原始碼引用的那個路徑；轉寫當下檢查本頁的裁切檔。
        case missingImageFile
        /// manifest.json 或 responses/ 無法讀取；附原因。
        case metadataUnavailable(String)
    }

    /// `\includegraphics` 大括號內原樣的路徑。
    public let path: String
    /// 依前置 page marker 判定的頁碼；沒有 marker 時為 nil。
    public let page: Int?
    /// 在傳入 `applyFigureWidths` 的原始碼中的行號（1 起算）。
    public let line: Int
    public let outcome: Outcome
    /// `true`：原本的選項是 v0.3.0 寫出的 `width=<比例>\textwidth`，這一輪把它的值換成新格式
    /// （`outcome` 為 `widthApplied`）。判定條件見 `LaTeXNormalizer.applyFigureWidths`。
    public let replacedLegacyWidth: Bool

    public init(path: String, page: Int?, line: Int, outcome: Outcome, replacedLegacyWidth: Bool = false) {
        self.path = path
        self.page = page
        self.line = line
        self.outcome = outcome
        self.replacedLegacyWidth = replacedLegacyWidth
    }
}

/// `applyFigureWidths` 的結果：改寫後的原始碼與逐一的處理結果。
public struct FigureWidthReport: Sendable, Equatable {
    public let result: String
    /// 每個作用中的 `\includegraphics{figures/...}` 一筆，依出現順序。
    public let resolutions: [FigureWidthResolution]
    /// 讀不到或無法解碼的 `responses/*.json`（相對於專案目錄）。metadata 只在有呼叫需要查詢時
    /// 才讀取；所有呼叫都已帶明確尺寸時不讀，此欄為空。
    public let unreadableResponseFiles: [String]

    public init(result: String, resolutions: [FigureWidthResolution], unreadableResponseFiles: [String]) {
        self.result = result
        self.resolutions = resolutions
        self.unreadableResponseFiles = unreadableResponseFiles
    }
}

/// 裁切圖檔的命名（PsychQuant/macdoc#208）：`figures/p<頁碼>-<id>.png`，頁碼至少三位數。
///
/// 路徑一定帶頁碼，兩頁用同一個 id（例如都叫 `fig1`）也不會寫到同一個檔。id 已經以**本頁**
/// 的前綴開頭（提示詞要求的 `pXXX-figYY` 形式）時不重複加；別頁的前綴不算
/// （第 19 頁的 `p018-fig1` → `figures/p019-p018-fig1.png`）。
///
/// 不同頁的檔名不會相同：前綴是 `p` + 頁碼數字 + `-`，頁碼不同則前綴在 `-` 之前就分岔。
enum FigureAssetPath {
    static func pagePrefix(_ page: Int) -> String {
        String(format: "p%03d-", page)
    }

    /// id 不是安全的檔名時回傳 nil（不裁切、不改寫 LaTeX）。
    static func cropped(page: Int, id: String) -> String? {
        guard isSafeID(id) else { return nil }
        let prefix = pagePrefix(page)
        return "figures/\(id.hasPrefix(prefix) ? id : prefix + id).png"
    }

    /// 安全的 id（封閉列舉）：非空，且每個字元都是 ASCII 英文字母、數字、`-`、`_`、`.` 之一。
    /// 其他字元一律不收，包括 `/`（`../p019-fig1` 會穿越到別頁的檔名）、`\\`、`%`、`{`、`}`、
    /// 空白（在 `\includegraphics{…}` 裡會改變 TeX 的讀法）與非 ASCII 字元。
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E
        }
    }
}

extension LaTeXNormalizer {

    /// 代表「已指定顯示尺寸」的 `\includegraphics` 選項 key（封閉列舉，比對時去掉前後空白、
    /// 區分大小寫）。`keepaspectratio`、`angle`、`trim`、`clip`、`natwidth` 等都不算。
    static let explicitSizeOptionKeys: Set<String> = ["width", "height", "totalheight", "scale"]

    /// 有效頁寬的上限（bp）：PDF 頁面尺寸上限 14400 單位（200in）。bbox 寬 ≤ 1，所以寫出的寬度
    /// 不會超過約 14400bp，低於 TeX 的 `\maxdimen`（約 16322bp）。
    static let maxPageWidthPoints: Double = 14400

    /// 寫進 `width=` 的值：原書上的絕對寬度，以 `\linewidth` 為上限（PsychQuant/macdoc#207）。
    ///
    /// 用可展開的 `\ifdim`，不依賴任何套件或新版 kernel。pdflatex（TeX Live 2025）實測：
    /// 未超出（200bp → 200.75pt）與超出（416.16bp → `\linewidth` 345pt）兩種情況；`calc`、
    /// `babel` spanish（`>` 為 active）與 french、`twocolumn`、minipage 內、`figure` 環境內，以及
    /// `angle=90` 在前（graphicx 走 `\edef` 路徑）都正確。
    static func cappedWidthValue(points: String) -> String {
        "\\ifdim \(points)bp>\\linewidth\\linewidth\\else \(points)bp\\fi"
    }

    /// 依 AI 回傳的 `FigureRegion.bbox` 還原圖片寬度：`\includegraphics{figures/…}` →
    /// `\includegraphics[width=\ifdim <w>bp>\linewidth\linewidth\else <w>bp\fi]{figures/…}`，
    /// `<w>` = bbox 寬 × 頁寬（bp）。bbox 寬 0.68、頁寬 612bp → `416.16bp`，版心放不下時縮到
    /// `\linewidth`（PsychQuant/macdoc#207：舊版的 `<比例>\textwidth` 把頁寬比例乘上版心寬，
    /// 圖只有原書的約一半大）。
    ///
    /// 這是 normalize 階段的補救層。轉寫當下由 `applyFigureWidths(toTranscribedPage:…)` 以同一份
    /// 規則先寫好（PsychQuant/macdoc#209），已帶寬度的呼叫在這裡落入 `explicitSizePreserved`。
    ///
    /// ## 對象
    ///
    /// 作用中（`LaTeXSourceScan`：不在註解、verbatim 類環境、`\verb`、巨集定義內，且位於 document
    /// body）且路徑（去掉註解、前後空白與開頭 `./`）以 `figures/` 開頭的呼叫。其他呼叫一律不動、
    /// 不回報。`*`、`[選項]`、`{路徑}` 之間可以有空白、換行與註解；同一行可以有多個呼叫。
    ///
    /// ## 配對
    ///
    /// 頁碼取呼叫之前最近的作用中 page marker。metadata 以（頁碼, 完整相對路徑）為 key；
    /// `responses/*.json` 中第 N 頁 id 為 `<id>` 的 figure 登記兩個路徑（封閉列舉）：
    /// 1. 本頁的裁切檔 `FigureAssetPath.cropped(page: N, id:)`，例如 `figures/p018-fig1.png`
    ///    （PsychQuant/macdoc#208 起的檔名）；
    /// 2. `figures/<id>.png`（之前的版本的檔名，讓既有專案仍配得上）。
    /// 原始碼路徑必須與其中之一完全相同，或是省略 `.png` 的同一路徑。不做子字串比對，也不跨頁
    /// 借用同名 figure 的 bbox。同一個 key 有多筆 bbox 時只有全部相同才算唯一。
    ///
    /// ## 既有選項的合併規則
    ///
    /// - 選項 key 由 TeX 語意的程式碼文字（`LaTeXSourceScan.texCodeText`：註解連同換行與下一行
    ///   開頭空白一起消失，pdflatex 實測 `[wid%⏎    th=3cm]` 的 key 是 width）、以大括號外的逗號
    ///   切分而得（`trim={1, 2, 3, 4}` 是一個選項）。路徑也用同一個程式碼文字比對。
    ///   含 `explicitSizeOptionKeys` 任一 key → 整個呼叫逐位元組保留，回報 `explicitSizePreserved`
    ///   （使用者寫的尺寸優先，即使與 bbox 不符）。寫在註解裡的 `width=` 不算。唯一的例外是下面的
    ///   v0.3.0 舊輸出升級。
    /// - 否則把 `width=…` 加在選項**最後一個程式碼字元之後**（必要時先補逗號），
    ///   其餘選項與註解原文、原順序保留。插入點永遠在同一行的 `%` 之前，所以不會被註解掉；
    ///   選項裡沒有程式碼時插在 `[` 之後；沒有 `[...]` 時在指令名稱（含 `*`）之後建立。
    ///   放最後是因為 graphicx 依序處理 key：先列出的 `angle`／`trim` 先生效，width 約束的是最後
    ///   顯示出來的框，正好對應在頁面上量到的 bbox。
    /// - `<w>` 為最多四位小數、去掉尾端 0 的 bp 值；比例先取最多六位小數（與 v0.3.0 相同）再乘頁寬。
    ///
    /// ## v0.3.0 舊輸出的升級（只在能確定是本工具寫的時候）
    ///
    /// v0.3.0 寫的是 `width=<比例>\textwidth`。同時滿足以下全部條件時，只把值 `<比例>\textwidth`
    /// 換成新格式，其餘位元組不動，並回報 `widthApplied` 與 `replacedLegacyWidth = true`：
    /// 1. 原文（不是程式碼視圖）恰好是 `width=<比例>\textwidth` 連續、全為程式碼、中間沒有空白；
    /// 2. 它是選項中最後一段程式碼（其後只剩空白與註解），前一個字元是 `[` 或未跳脫的逗號；
    /// 3. `<比例>` 是本工具的數字格式（最多六位小數、無尾端 0、有整數位）；
    /// 4. 其他選項沒有任何尺寸 key；
    /// 5. 這張圖依上方規則能解出 `widthApplied`，且以同一格式化規則算出的比例與 `<比例>`
    ///    **逐字相同**。
    /// 任一條不成立就當成使用者寫的尺寸，原樣保留（`explicitSizePreserved`）。殘餘風險：手寫的
    /// 選項若與本工具對這張圖會寫出的內容逐位元組相同（包括比例到六位小數都與 bbox 相同），
    /// 無法與本工具的輸出區分，會被升級。
    ///
    /// ## 不改寫、只回報（沒有任何 fallback 比例）
    ///
    /// 依序檢查，第一個不成立者即為結果：metadata 可讀（`metadataUnavailable`）→ 有 page
    /// marker（`noPageContext`）→ 有對應 figure（`noMatchingFigure`）→ bbox 唯一
    /// （`ambiguousFigure`）→ bbox 合法（`invalidBoundingBox`：必須恰好 4 個有限值，
    /// `x ≥ 0`、`y ≥ 0`、`w > 0`、`h > 0`、`x + w ≤ 1`、`y + h ≤ 1`，容差 1e-6）→ 比例以六位小數
    /// 表示不為 0（`widthNotRepresentable`）→ manifest 有該頁且頁寬有效（`missingPageRecord`）→
    /// bp 值以四位小數表示不為 0（`widthNotRepresentable`）→ 原始碼引用的圖檔存在
    /// （`missingImageFile`）。
    ///
    /// ## 冪等
    ///
    /// 改寫或升級後的呼叫帶有 `width`、且不再是 v0.3.0 的形狀，重跑時落入 `explicitSizePreserved`；
    /// 未改寫者重跑得到相同結果，唯一例外是 marker 已被移除（`stripPageMarkers`）時，未解決者改回報
    /// `noPageContext`；兩種情況原始碼都不變。
    public static func applyFigureWidths(_ source: String, projectDir: URL) -> FigureWidthReport {
        var cached: Result<FigureMetadata, FigureMetadataError>?
        return rewriteFigureIncludes(source, projectDir: projectDir, mode: .document) {
            if let cached { return cached }
            let loaded = loadFigureMetadata(projectDir: projectDir)
            cached = loaded
            return loaded
        }
    }

    /// 轉寫當下（`PageTranscriber` 的後處理，PsychQuant/macdoc#209）：一頁 AI 輸出的 LaTeX 片段。
    ///
    /// 與 `applyFigureWidths(_:projectDir:)` 走**同一個**實作（對象、配對、合併規則、舊輸出升級、
    /// 回報都相同），只有四處不同：
    /// - 頁碼就是 `page`，不看 page marker；
    /// - metadata 只有這一頁的 `figures` 與 `pageWidth`（nil → `missingPageRecord`）；id 不安全
    ///   （`FigureAssetPath.isSafeID`）的 figure 不登記；
    /// - 配對到的呼叫，路徑一律改寫成本頁的裁切檔（`figures/p018-fig1.png`；PsychQuant/macdoc#208），
    ///   不論是否補上寬度；`missingImageFile` 檢查的也是這個裁切檔；
    /// - bbox 取「對應到同一個裁切檔的所有 figure」：同頁 `fig1` 與 `p018-fig1` 撞名且 bbox 不同時，
    ///   兩種寫法的呼叫都是 `ambiguousFigure`（裁切檔裡是哪一張無法由路徑判定）。
    ///
    /// 呼叫前應先完成裁切，否則每張圖都會回報 `missingImageFile`。
    static func applyFigureWidths(
        toTranscribedPage latex: String, page: Int, figures: [FigureRegion], pageWidth: Double?, projectDir: URL
    ) -> FigureWidthReport {
        var keyed: [FigureKey: [FigureEntry]] = [:]
        for figure in figures where FigureAssetPath.isSafeID(figure.id) {
            register(figure, page: page, into: &keyed)
        }
        let metadata = FigureMetadata(
            pageWidths: pageWidth.map { [page: $0] } ?? [:], figures: keyed, unreadableResponseFiles: []
        )
        return rewriteFigureIncludes(latex, projectDir: projectDir, mode: .transcribedPage(page)) {
            .success(metadata)
        }
    }

    /// 相容 wrapper（v0.2.0 起的公開 API）：回傳 `applyFigureWidths(_:projectDir:)` 的改寫結果。
    /// 舊版把 `scale>2` 硬改成 0.8 的行為已移除。需要知道哪些圖片沒被改寫、為什麼，請用
    /// `applyFigureWidths`。
    public static func fixImageScale(_ source: String, projectDir: URL) -> String {
        applyFigureWidths(source, projectDir: projectDir).result
    }

    // MARK: - Shared rewrite (normalize + transcription)

    enum FigureRewriteMode {
        /// normalize：整份文件，頁碼取前一個 page marker，只補寬度。
        case document
        /// 轉寫當下：單頁片段，頁碼已知；另把路徑改寫成本頁的裁切檔。
        case transcribedPage(Int)
    }

    /// 兩條路徑唯一的實作。`loadMetadata` 只在有呼叫需要查詢時才呼叫（所有呼叫都帶明確尺寸、
    /// 且不必改寫路徑時不讀 responses）。
    private static func rewriteFigureIncludes(
        _ source: String, projectDir: URL, mode: FigureRewriteMode,
        loadMetadata: () -> Result<FigureMetadata, FigureMetadataError>
    ) -> FigureWidthReport {
        let scan = LaTeXSourceScan(source)
        let calls = findFigureIncludeGraphics(in: scan)
        guard !calls.isEmpty else {
            return FigureWidthReport(result: source, resolutions: [], unreadableResponseFiles: [])
        }

        var loaded: FigureMetadata?
        var resolutions: [FigureWidthResolution] = []
        var edits: [(range: Range<Int>, text: String)] = []

        for call in calls {
            let page: Int?
            let rewritesPath: Bool
            switch mode {
            case .document:
                page = scan.pageMarkers.last(where: { $0.offset < call.start })?.page
                rewritesPath = false
            case .transcribedPage(let fixed):
                page = fixed
                rewritesPath = true
            }
            let needsWidth = !call.hasExplicitSize
            var outcome = FigureWidthResolution.Outcome.explicitSizePreserved
            var replacedLegacy = false

            if needsWidth || call.legacyWidth != nil || rewritesPath {
                switch loadMetadata() {
                case .failure(let error):
                    if needsWidth { outcome = .metadataUnavailable(error.reason) }
                case .success(let metadata):
                    loaded = metadata
                    let match = page.flatMap {
                        matchFigure(path: call.normalizedPath, page: $0, metadata: metadata, byCroppedFile: rewritesPath)
                    }
                    if rewritesPath, let target = match?.croppedPath, scan.text(call.pathRange) != target {
                        edits.append((call.pathRange, target))
                    }
                    if needsWidth || call.legacyWidth != nil {
                        let resolved = resolveFigureWidth(
                            match: match, page: page, metadata: metadata, projectDir: projectDir
                        )
                        if needsWidth {
                            outcome = resolved.outcome
                            if let value = resolved.value {
                                edits.append(call.widthEdit(width: "width=" + value))
                            }
                        } else if let legacy = call.legacyWidth, let value = resolved.value,
                                  resolved.fractionText == legacy.fraction {
                            outcome = resolved.outcome
                            replacedLegacy = true
                            edits.append((legacy.valueRange, value))
                        }
                    }
                }
            }
            resolutions.append(FigureWidthResolution(
                path: call.path, page: page, line: call.line, outcome: outcome, replacedLegacyWidth: replacedLegacy
            ))
        }

        let unreadable = loaded?.unreadableResponseFiles ?? []
        guard !edits.isEmpty else {
            return FigureWidthReport(result: source, resolutions: resolutions, unreadableResponseFiles: unreadable)
        }

        // 同一個呼叫的編輯範圍互不重疊（選項或指令名稱之後 < 路徑），不同呼叫依位置排開。
        var units = scan.units
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            units.replaceSubrange(edit.range, with: Array(edit.text.utf16))
        }
        return FigureWidthReport(
            result: String(decoding: units, as: UTF16.self),
            resolutions: resolutions,
            unreadableResponseFiles: unreadable
        )
    }

    // MARK: - Resolution

    /// 原始碼路徑配對到的 metadata。
    struct FigureMatch {
        /// 要檢查存在的圖檔：normalize 是配對成功的候選路徑（原始碼路徑，或補上 `.png` 的同一
        /// 路徑）；轉寫當下是本頁的裁切檔。
        let path: String
        /// 這張圖在本頁的裁切檔；id 不安全時為 nil。
        let croppedPath: String?
        let boxes: [[Double]]
    }

    /// `byCroppedFile`（轉寫當下）：原始碼之後會改指向裁切檔，所以 bbox 取「對應到這個裁切檔的
    /// 所有 figure」，而不是只取原始碼路徑那個 key。同一頁 `fig1` 與 `p018-fig1` 撞名時，
    /// 裁切檔只有一個，兩個呼叫都是 `ambiguousFigure`。`path` 則是之後要檢查存在的那個檔。
    static func matchFigure(path: String, page: Int, metadata: FigureMetadata, byCroppedFile: Bool) -> FigureMatch? {
        var candidates = [path]
        if (path as NSString).pathExtension.isEmpty {
            candidates.append(path + ".png")
        }
        for candidate in candidates {
            guard let entries = metadata.figures[FigureKey(page: page, path: candidate)], !entries.isEmpty else {
                continue
            }
            // 同一個 key 底下的裁切檔必定相同（見 `register`）；保險起見不同時視為沒有裁切檔。
            let croppedPaths = Set(entries.map(\.croppedPath))
            let cropped = croppedPaths.count == 1 ? croppedPaths.first! : nil
            if byCroppedFile, let cropped,
               let fileEntries = metadata.figures[FigureKey(page: page, path: cropped)], !fileEntries.isEmpty {
                return FigureMatch(path: cropped, croppedPath: cropped, boxes: fileEntries.map(\.bbox))
            }
            return FigureMatch(path: candidate, croppedPath: cropped, boxes: entries.map(\.bbox))
        }
        return nil
    }

    /// 回傳結果；`widthApplied` 時另附比例的文字（供舊輸出比對）與要寫入的 `width=` 值。
    private static func resolveFigureWidth(
        match: FigureMatch?, page: Int?, metadata: FigureMetadata, projectDir: URL
    ) -> (outcome: FigureWidthResolution.Outcome, fractionText: String?, value: String?) {
        guard let page else { return (.noPageContext, nil, nil) }
        guard let match else { return (.noMatchingFigure, nil, nil) }

        var distinct: [[Double]] = []
        for box in match.boxes where !distinct.contains(box) {
            distinct.append(box)
        }
        guard distinct.count == 1, let bbox = distinct.first else { return (.ambiguousFigure, nil, nil) }
        guard isValidNormalizedBBox(bbox) else { return (.invalidBoundingBox(bbox), nil, nil) }
        guard let fractionText = formatDecimal(bbox[2], maxFractionDigits: 6),
              let fraction = Double(fractionText) else {
            return (.widthNotRepresentable(bbox[2]), nil, nil)
        }

        guard let pageWidth = metadata.pageWidths[page], pageWidth.isFinite, pageWidth > 0,
              pageWidth <= maxPageWidthPoints else {
            return (.missingPageRecord, nil, nil)
        }
        guard let pointsText = formatDecimal(fraction * pageWidth, maxFractionDigits: 4),
              let points = Double(pointsText) else {
            return (.widthNotRepresentable(bbox[2]), nil, nil)
        }
        guard FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(match.path).path) else {
            return (.missingImageFile, nil, nil)
        }

        return (
            .widthApplied(fraction: fraction, widthPoints: points),
            fractionText,
            cappedWidthValue(points: pointsText)
        )
    }

    static func isValidNormalizedBBox(_ bbox: [Double]) -> Bool {
        guard bbox.count == 4, bbox.allSatisfy(\.isFinite) else { return false }
        let (x, y, w, h) = (bbox[0], bbox[1], bbox[2], bbox[3])
        let tolerance = 1e-6
        return x >= 0 && y >= 0 && w > 0 && h > 0
            && x + w <= 1 + tolerance && y + h <= 1 + tolerance
    }

    /// 最多 `maxFractionDigits` 位小數、去掉尾端 0。正值四捨五入後變成 0（或非正、非有限）時回傳 nil。
    static func formatDecimal(_ value: Double, maxFractionDigits: Int) -> String? {
        guard value.isFinite, value > 0 else { return nil }
        var text = String(format: "%.\(maxFractionDigits)f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        guard let parsed = Double(text), parsed > 0 else { return nil }
        return text
    }

    // MARK: - Metadata

    struct FigureKey: Hashable {
        let page: Int
        let path: String
    }

    struct FigureEntry: Hashable {
        let bbox: [Double]
        /// 本頁的裁切檔（`FigureAssetPath.cropped`）；id 不安全時為 nil。
        let croppedPath: String?
    }

    struct FigureMetadata {
        /// manifest 頁碼 → 頁寬（bp）。
        let pageWidths: [Int: Double]
        /// （頁碼, 路徑）→ 所有 response 中登記到這個路徑的 figure。
        let figures: [FigureKey: [FigureEntry]]
        let unreadableResponseFiles: [String]
    }

    struct FigureMetadataError: Error {
        let reason: String
    }

    /// 把第 `page` 頁的一張 figure 登記到它的兩個路徑（見 `applyFigureWidths` 的「配對」）。
    ///
    /// 同一個 key 底下的 entry 裁切檔必定相同：舊檔名 key `figures/<id>.png` 若不帶本頁前綴，
    /// 只有同一個 id 會登記到它；帶本頁前綴的 key 只會收到裁切檔等於它自己的 figure。
    static func register(_ figure: FigureRegion, page: Int, into figures: inout [FigureKey: [FigureEntry]]) {
        let cropped = FigureAssetPath.cropped(page: page, id: figure.id)
        let entry = FigureEntry(bbox: figure.bbox, croppedPath: cropped)
        let legacy = "figures/\(figure.id).png"
        figures[FigureKey(page: page, path: legacy), default: []].append(entry)
        if let cropped, cropped != legacy {
            figures[FigureKey(page: page, path: cropped), default: []].append(entry)
        }
    }

    static func loadFigureMetadata(projectDir: URL) -> Result<FigureMetadata, FigureMetadataError> {
        let fileManager = FileManager.default
        let manifestURL = projectDir.appendingPathComponent(ProjectLayout.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .failure(FigureMetadataError(reason: "manifest.json 不存在"))
        }
        let manifest: ProjectManifest
        do {
            manifest = try ManifestStore().load(from: manifestURL)
        } catch {
            return .failure(FigureMetadataError(reason: "manifest.json 無法解析: \(error.localizedDescription)"))
        }

        let responsesDir = projectDir.appendingPathComponent("responses", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: responsesDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(FigureMetadataError(reason: "responses/ 不存在"))
        }
        let responseFiles: [URL]
        do {
            responseFiles = try fileManager.contentsOfDirectory(
                at: responsesDir, includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return .failure(FigureMetadataError(reason: "responses/ 無法讀取: \(error.localizedDescription)"))
        }

        var figures: [FigureKey: [FigureEntry]] = [:]
        var unreadable: [String] = []
        for url in responseFiles {
            guard let response = decodePageResponse(at: url) else {
                unreadable.append("responses/\(url.lastPathComponent)")
                continue
            }
            for pageResult in response.pages {
                for figure in pageResult.figures {
                    register(figure, page: pageResult.page, into: &figures)
                }
            }
        }

        let pageWidths = Dictionary(
            manifest.pages.map { ($0.number, $0.width) }, uniquingKeysWith: { first, _ in first }
        )
        return .success(FigureMetadata(
            pageWidths: pageWidths, figures: figures, unreadableResponseFiles: unreadable
        ))
    }

    /// 讀取一個 response 檔。codex 寫的是純 JSON；claude／gemini 寫的是 CLI stdout，
    /// 可能包在 markdown code fence 裡（與 `CLITranscriber` 的解析規則相同）。
    private static func decodePageResponse(at url: URL) -> PageTranscriptionResponse? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: .newlines)
            json = lines.dropFirst().reversed().drop(while: { $0.hasPrefix("```") }).reversed()
                .joined(separator: "\n")
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PageTranscriptionResponse.self, from: data)
    }

    // MARK: - Source Scanning

    struct IncludeGraphicsCall {
        enum Insertion {
            /// 沒有 `[...]`：在此插入 `[width=…]`。
            case newBrackets
            /// 選項裡沒有程式碼：直接插入 `width=…`。
            case firstOption
            /// 最後一個程式碼字元不是逗號：插入 `,width=…`。
            case appendWithComma
            /// 最後一個程式碼字元是逗號：插入 `width=…`。
            case appendAfterComma
        }

        /// v0.3.0 寫出的 `width=<比例>\textwidth`（精確形狀，見 `applyFigureWidths`）。
        struct LegacyWidth {
            /// `<比例>\textwidth` 的範圍（升級時整段換掉）。
            let valueRange: Range<Int>
            let fraction: String
        }

        /// `\` 的 UTF-16 offset。
        let start: Int
        /// 大括號內原樣的路徑。
        let path: String
        /// 大括號內（不含大括號）的範圍。
        let pathRange: Range<Int>
        /// 去掉註解、前後空白與開頭 `./` 的路徑。
        let normalizedPath: String
        /// 1 起算的行號。
        let line: Int
        let hasExplicitSize: Bool
        let legacyWidth: LegacyWidth?
        let insertionOffset: Int
        let insertion: Insertion

        func widthEdit(width: String) -> (range: Range<Int>, text: String) {
            let range = insertionOffset..<insertionOffset
            switch insertion {
            case .newBrackets: return (range, "[\(width)]")
            case .firstOption, .appendAfterComma: return (range, width)
            case .appendWithComma: return (range, "," + width)
            }
        }
    }

    /// 去掉註解後的選項文字，以大括號外的逗號切分出的 key。
    static func optionKeys(_ options: String) -> [String] {
        var keys: [String] = []
        var current = ""
        var depth = 0
        var escaped = false
        func flush() {
            let key = current.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            keys.append(key.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
        for ch in options {
            if escaped {
                escaped = false
                current.append(ch)
                continue
            }
            switch ch {
            case "\\":
                escaped = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
            case "," where depth == 0:
                flush()
                continue
            default:
                break
            }
            current.append(ch)
        }
        flush()
        return keys
    }

    /// 選項範圍 `range`（不含方括號）中，以最後一個程式碼字元 `last` 結尾的 v0.3.0 寬度選項。
    /// 條件 1–4 見 `applyFigureWidths`；條件 5（與 bbox 比對）在解析時才檢查。
    private static func legacyToolWidth(
        options range: Range<Int>, last: Int, in scan: LaTeXSourceScan
    ) -> IncludeGraphicsCall.LegacyWidth? {
        let units = scan.units
        let end = last + 1
        let suffix = Array("\\textwidth".utf16)
        let suffixStart = end - suffix.count
        guard suffixStart >= range.lowerBound, Array(units[suffixStart..<end]) == suffix else { return nil }

        var numberStart = suffixStart
        while numberStart > range.lowerBound,
              units[numberStart - 1] == 0x2E || (units[numberStart - 1] >= 0x30 && units[numberStart - 1] <= 0x39) {
            numberStart -= 1
        }
        let key = Array("width=".utf16)
        let keyStart = numberStart - key.count
        guard numberStart < suffixStart, keyStart >= range.lowerBound,
              Array(units[keyStart..<numberStart]) == key else { return nil }

        var shapeStart = keyStart
        if keyStart > range.lowerBound {
            let separator = keyStart - 1
            guard units[separator] == U.comma,
                  !(separator > range.lowerBound && units[separator - 1] == U.backslash) else { return nil }
            shapeStart = separator
        }
        guard (shapeStart..<end).allSatisfy({ scan.kinds[$0] == .code }) else { return nil }

        let fraction = String(decoding: units[numberStart..<suffixStart], as: UTF16.self)
        guard let value = Double(fraction), formatDecimal(value, maxFractionDigits: 6) == fraction else {
            return nil
        }
        let otherKeys = optionKeys(scan.texCodeText(range.lowerBound..<keyStart))
        guard !otherKeys.contains(where: { explicitSizeOptionKeys.contains($0) }) else { return nil }
        return IncludeGraphicsCall.LegacyWidth(valueRange: numberStart..<end, fraction: fraction)
    }

    /// 所有作用中、路徑以 `figures/` 開頭的 `\includegraphics` 呼叫。
    static func findFigureIncludeGraphics(in scan: LaTeXSourceScan) -> [IncludeGraphicsCall] {
        let units = scan.units
        var calls: [IncludeGraphicsCall] = []
        for word in scan.controlWords where word.name == "includegraphics" && scan.isActive(word.start) {
            var nameEnd = word.end
            var k = scan.skipIgnorable(from: word.end)
            if k < units.count && units[k] == U.star && scan.kinds[k] == .code {
                nameEnd = k + 1
                k = scan.skipIgnorable(from: nameEnd)
            }
            var optionsRange: Range<Int>?
            if k < units.count && units[k] == U.openBracket && scan.kinds[k] == .code {
                guard let end = scan.optionalEnd(from: k) else { continue }
                optionsRange = (k + 1)..<(end - 1)
                k = scan.skipIgnorable(from: end)
            }
            guard let pathEnd = scan.groupEnd(from: k) else { continue }
            let pathRange = (k + 1)..<(pathEnd - 1)

            var normalized = scan.texCodeText(pathRange).trimmingCharacters(in: .whitespacesAndNewlines)
            while normalized.hasPrefix("./") { normalized.removeFirst(2) }
            guard normalized.hasPrefix("figures/") else { continue }

            let hasExplicitSize = optionsRange.map {
                optionKeys(scan.texCodeText($0)).contains { explicitSizeOptionKeys.contains($0) }
            } ?? false

            let insertionOffset: Int
            let insertion: IncludeGraphicsCall.Insertion
            var legacyWidth: IncludeGraphicsCall.LegacyWidth?
            if let range = optionsRange {
                if let last = range.reversed().first(where: {
                    scan.kinds[$0] == .code && !U.isWhitespace(units[$0])
                }) {
                    let isSeparator = units[last] == U.comma
                        && !(last > range.lowerBound && units[last - 1] == U.backslash)
                    insertionOffset = last + 1
                    insertion = isSeparator ? .appendAfterComma : .appendWithComma
                    if hasExplicitSize {
                        legacyWidth = legacyToolWidth(options: range, last: last, in: scan)
                    }
                } else {
                    insertionOffset = range.lowerBound
                    insertion = .firstOption
                }
            } else {
                insertionOffset = nameEnd
                insertion = .newBrackets
            }

            calls.append(IncludeGraphicsCall(
                start: word.start,
                path: scan.text(pathRange),
                pathRange: pathRange,
                normalizedPath: normalized,
                line: scan.line(of: word.start) + 1,
                hasExplicitSize: hasExplicitSize,
                legacyWidth: legacyWidth,
                insertionOffset: insertionOffset,
                insertion: insertion
            ))
        }
        return calls
    }
}
