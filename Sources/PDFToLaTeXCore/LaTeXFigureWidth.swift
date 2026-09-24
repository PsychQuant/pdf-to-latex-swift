import Foundation

// MARK: - Figure Width from BBox (PsychQuant/macdoc#10)

/// 單一 `\includegraphics{figures/...}` 的寬度還原結果。
public struct FigureWidthResolution: Sendable, Equatable {
    /// 處理結果（封閉列舉）。除 `widthApplied` 外，原始碼一律保持原樣。
    public enum Outcome: Sendable, Equatable {
        /// 已寫入 `width=<fraction>\textwidth`。`fraction` 就是寫進原始碼的數值；
        /// `widthPoints` = `fraction` × manifest 頁寬（pt），供稽核原書上的實際寬度。
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
        /// bbox 寬度以六位小數表示會變成 0：不寫入，附原值。
        case widthNotRepresentable(Double)
        /// manifest.json 沒有該頁的 `PageRecord`，或頁寬不是正的有限值。
        case missingPageRecord
        /// 裁切圖檔（`figures/<id>.png`）不存在。
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

    public init(path: String, page: Int?, line: Int, outcome: Outcome) {
        self.path = path
        self.page = page
        self.line = line
        self.outcome = outcome
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

extension LaTeXNormalizer {

    /// 代表「已指定顯示尺寸」的 `\includegraphics` 選項 key（封閉列舉，比對時去掉前後空白、
    /// 區分大小寫）。`keepaspectratio`、`angle`、`trim`、`clip`、`natwidth` 等都不算。
    static let explicitSizeOptionKeys: Set<String> = ["width", "height", "totalheight", "scale"]

    /// 依 AI 回傳的 `FigureRegion.bbox` 還原圖片寬度：`\includegraphics{figures/…}` →
    /// `\includegraphics[width=<bbox 寬>\textwidth]{figures/…}`（bbox 寬 0.68 → `0.68\textwidth`）。
    ///
    /// ## 對象
    ///
    /// 作用中（`LaTeXSourceScan`：不在註解、verbatim 類環境、`\verb`、巨集定義內，且位於 document
    /// body）且路徑（去掉註解、前後空白與開頭 `./`）以 `figures/` 開頭的呼叫。其他呼叫一律不動、
    /// 不回報。`*`、`[選項]`、`{路徑}` 之間可以有空白、換行與註解；同一行可以有多個呼叫。
    ///
    /// ## 配對
    ///
    /// 頁碼取呼叫之前最近的作用中 page marker。metadata 以（頁碼, 完整相對路徑）為 key：
    /// `responses/*.json` 中第 N 頁的 figure `id` 對應路徑 `figures/<id>.png`（裁切圖的實際檔名）；
    /// 原始碼路徑必須與它完全相同，或是省略 `.png` 的同一路徑。不做子字串比對，也不跨頁借用
    /// 同名 figure 的 bbox。
    ///
    /// ## 既有選項的合併規則
    ///
    /// - 選項 key 由 TeX 語意的程式碼文字（`LaTeXSourceScan.texCodeText`：註解連同換行與下一行
    ///   開頭空白一起消失，pdflatex 實測 `[wid%⏎    th=3cm]` 的 key 是 width）、以大括號外的逗號
    ///   切分而得（`trim={1, 2, 3, 4}` 是一個選項）。路徑也用同一個程式碼文字比對。
    ///   含 `explicitSizeOptionKeys` 任一 key → 整個呼叫逐位元組保留，回報 `explicitSizePreserved`
    ///   （使用者寫的尺寸優先，即使與 bbox 不符）。寫在註解裡的 `width=` 不算。
    /// - 否則把 `width=<w>\textwidth` 加在選項**最後一個程式碼字元之後**（必要時先補逗號），
    ///   其餘選項與註解原文、原順序保留。插入點永遠在同一行的 `%` 之前，所以不會被註解掉；
    ///   選項裡沒有程式碼時插在 `[` 之後；沒有 `[...]` 時在指令名稱（含 `*`）之後建立。
    ///   放最後是因為 graphicx 依序處理 key：先列出的 `angle`／`trim` 先生效，width 約束的是最後
    ///   顯示出來的框，正好對應在頁面上量到的 bbox。
    /// - `<w>` 為最多六位小數、去掉尾端 0 的 bbox 寬；回報的 `fraction` 就是寫入的數值。
    ///
    /// ## 不改寫、只回報（沒有任何 fallback 比例）
    ///
    /// 依序檢查，第一個不成立者即為結果：metadata 可讀（`metadataUnavailable`）→ 有 page
    /// marker（`noPageContext`）→ 有對應 figure（`noMatchingFigure`）→ bbox 唯一
    /// （`ambiguousFigure`）→ bbox 合法（`invalidBoundingBox`：必須恰好 4 個有限值，
    /// `x ≥ 0`、`y ≥ 0`、`w > 0`、`h > 0`、`x + w ≤ 1`、`y + h ≤ 1`，容差 1e-6）→ 寬度以六位小數
    /// 表示不為 0（`widthNotRepresentable`）→ manifest 有該頁（`missingPageRecord`）→ 裁切圖檔
    /// 存在（`missingImageFile`）。
    ///
    /// ## 冪等
    ///
    /// 改寫後的呼叫帶有 `width`，重跑時落入 `explicitSizePreserved`；未改寫者重跑得到相同結果，
    /// 唯一例外是 marker 已被移除（`stripPageMarkers`）時，未解決者改回報 `noPageContext`；
    /// 兩種情況原始碼都不變。
    public static func applyFigureWidths(_ source: String, projectDir: URL) -> FigureWidthReport {
        let scan = LaTeXSourceScan(source)
        let calls = findFigureIncludeGraphics(in: scan)
        guard !calls.isEmpty else {
            return FigureWidthReport(result: source, resolutions: [], unreadableResponseFiles: [])
        }

        var metadata: Result<FigureMetadata, FigureMetadataError>?
        var resolutions: [FigureWidthResolution] = []
        var edits: [(range: Range<Int>, text: String)] = []

        for call in calls {
            let page = scan.pageMarkers.last(where: { $0.offset < call.start })?.page
            var outcome = FigureWidthResolution.Outcome.explicitSizePreserved
            var widthText: String?

            if !call.hasExplicitSize {
                let loadedOnce = metadata ?? loadFigureMetadata(projectDir: projectDir)
                metadata = loadedOnce
                switch loadedOnce {
                case .failure(let error):
                    outcome = .metadataUnavailable(error.reason)
                case .success(let loaded):
                    (outcome, widthText) = resolveFigureWidth(
                        path: call.normalizedPath, page: page, metadata: loaded, projectDir: projectDir
                    )
                }
            }

            if let widthText {
                edits.append(call.widthEdit(width: "width=\(widthText)\\textwidth"))
            }
            resolutions.append(FigureWidthResolution(
                path: call.path, page: page, line: call.line, outcome: outcome
            ))
        }

        let unreadable = (try? metadata?.get())?.unreadableResponseFiles ?? []
        guard !edits.isEmpty else {
            return FigureWidthReport(result: source, resolutions: resolutions, unreadableResponseFiles: unreadable)
        }

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

    /// 相容 wrapper（v0.2.0 起的公開 API）：回傳 `applyFigureWidths(_:projectDir:)` 的改寫結果。
    /// 舊版把 `scale>2` 硬改成 0.8 的行為已移除。需要知道哪些圖片沒被改寫、為什麼，請用
    /// `applyFigureWidths`。
    public static func fixImageScale(_ source: String, projectDir: URL) -> String {
        applyFigureWidths(source, projectDir: projectDir).result
    }

    // MARK: - Resolution

    /// 回傳結果與要寫入的寬度文字（只有 `widthApplied` 時非 nil）。
    private static func resolveFigureWidth(
        path: String, page: Int?, metadata: FigureMetadata, projectDir: URL
    ) -> (FigureWidthResolution.Outcome, String?) {
        guard let page else { return (.noPageContext, nil) }

        var candidates = [path]
        if (path as NSString).pathExtension.isEmpty {
            candidates.append(path + ".png")
        }
        guard let (canonicalPath, boxes) = candidates.lazy.compactMap({ candidate in
            metadata.figures[FigureKey(page: page, path: candidate)].map { (candidate, $0) }
        }).first else {
            return (.noMatchingFigure, nil)
        }

        var distinct: [[Double]] = []
        for box in boxes where !distinct.contains(box) {
            distinct.append(box)
        }
        guard distinct.count == 1, let bbox = distinct.first else { return (.ambiguousFigure, nil) }
        guard isValidNormalizedBBox(bbox) else { return (.invalidBoundingBox(bbox), nil) }
        guard let widthText = formatWidthFraction(bbox[2]), let written = Double(widthText) else {
            return (.widthNotRepresentable(bbox[2]), nil)
        }

        guard let pageWidth = metadata.pageWidths[page], pageWidth.isFinite, pageWidth > 0 else {
            return (.missingPageRecord, nil)
        }
        let imagePath = projectDir.appendingPathComponent(canonicalPath).path
        guard FileManager.default.fileExists(atPath: imagePath) else { return (.missingImageFile, nil) }

        return (.widthApplied(fraction: written, widthPoints: written * pageWidth), widthText)
    }

    static func isValidNormalizedBBox(_ bbox: [Double]) -> Bool {
        guard bbox.count == 4, bbox.allSatisfy(\.isFinite) else { return false }
        let (x, y, w, h) = (bbox[0], bbox[1], bbox[2], bbox[3])
        let tolerance = 1e-6
        return x >= 0 && y >= 0 && w > 0 && h > 0
            && x + w <= 1 + tolerance && y + h <= 1 + tolerance
    }

    /// 最多六位小數、去掉尾端 0。正值四捨五入後變成 0（或非正、非有限）時回傳 nil。
    static func formatWidthFraction(_ value: Double) -> String? {
        guard value.isFinite, value > 0 else { return nil }
        var text = String(format: "%.6f", value)
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

    struct FigureMetadata {
        /// manifest 頁碼 → 頁寬（pt）。
        let pageWidths: [Int: Double]
        /// （頁碼, `figures/<id>.png`）→ 所有 response 中的 bbox。
        let figures: [FigureKey: [[Double]]]
        let unreadableResponseFiles: [String]
    }

    struct FigureMetadataError: Error {
        let reason: String
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

        var figures: [FigureKey: [[Double]]] = [:]
        var unreadable: [String] = []
        for url in responseFiles {
            guard let response = decodePageResponse(at: url) else {
                unreadable.append("responses/\(url.lastPathComponent)")
                continue
            }
            for pageResult in response.pages {
                for figure in pageResult.figures {
                    let key = FigureKey(page: pageResult.page, path: "figures/\(figure.id).png")
                    figures[key, default: []].append(figure.bbox)
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

        /// `\` 的 UTF-16 offset。
        let start: Int
        /// 大括號內原樣的路徑。
        let path: String
        /// 去掉註解、前後空白與開頭 `./` 的路徑。
        let normalizedPath: String
        /// 1 起算的行號。
        let line: Int
        let hasExplicitSize: Bool
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
            if let range = optionsRange {
                if let last = range.reversed().first(where: {
                    scan.kinds[$0] == .code && !U.isWhitespace(units[$0])
                }) {
                    let isSeparator = units[last] == U.comma
                        && !(last > range.lowerBound && units[last - 1] == U.backslash)
                    insertionOffset = last + 1
                    insertion = isSeparator ? .appendAfterComma : .appendWithComma
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
                normalizedPath: normalized,
                line: scan.line(of: word.start) + 1,
                hasExplicitSize: hasExplicitSize,
                insertionOffset: insertionOffset,
                insertion: insertion
            ))
        }
        return calls
    }
}
