import Foundation

// MARK: - Figure Width from BBox (PsychQuant/macdoc#10)

/// 單一 `\includegraphics{figures/...}` 的寬度還原結果。
public struct FigureWidthResolution: Sendable, Equatable {
    /// 處理結果（封閉列舉）。除 `widthApplied` 外，原始碼一律保持原樣。
    public enum Outcome: Sendable, Equatable {
        /// 已寫入 `width=<fraction>\textwidth`。`fraction` 是 bbox 的寬（頁寬比例），
        /// `widthPoints` = `fraction` × manifest 頁寬（pt），供稽核原書上的實際寬度。
        case widthApplied(fraction: Double, widthPoints: Double)
        /// 選項已含明確尺寸 key（`width`／`height`／`totalheight`／`scale`），原樣保留。
        case explicitSizePreserved
        /// 呼叫之前沒有 `%% === Page N ===` 標記，無法決定屬於哪一頁。
        case noPageContext
        /// 該頁的 responses 沒有這個路徑的 figure。
        case noMatchingFigure
        /// 該頁同一路徑有多筆互相矛盾的 bbox。
        case ambiguousFigure
        /// bbox 不是合法的正規化 `[x, y, w, h]`。
        case invalidBoundingBox([Double])
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
    /// 每個 `\includegraphics{figures/...}`（註解內的除外）一筆，依出現順序。
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
    /// ## 配對
    ///
    /// 對象是路徑（去掉前後空白與開頭 `./`）以 `figures/` 開頭、且不在註解內的呼叫。
    /// 頁碼取呼叫之前最近的 `%% === Page N ===`。metadata 以（頁碼, 完整相對路徑）為 key：
    /// `responses/*.json` 中第 N 頁的 figure `id` 對應路徑 `figures/<id>.png`（裁切圖的實際檔名）；
    /// 原始碼路徑必須與它完全相同，或是省略 `.png` 的同一路徑。不做子字串比對，也不跨頁借用
    /// 同名 figure 的 bbox。
    ///
    /// ## 既有選項的合併規則
    ///
    /// - 選項已含 `explicitSizeOptionKeys` 任一 key → 整個呼叫逐位元組保留，
    ///   回報 `explicitSizePreserved`（使用者寫的尺寸優先，即使與 bbox 不符）。
    /// - 否則把 `width=<w>\textwidth` 加在選項**最後**，其餘選項原文、原順序保留；
    ///   沒有 `[...]` 時在指令名稱（含 `*`）之後建立。放最後是因為 graphicx 依序處理 key：
    ///   先列出的 `angle`／`trim` 先生效，width 約束的是最後顯示出來的框，正好對應在頁面上量到的 bbox。
    /// - `<w>` 最多四位小數、去掉尾端的 0。
    ///
    /// ## 不改寫、只回報（沒有任何 fallback 比例）
    ///
    /// 依序檢查，第一個不成立者即為結果：metadata 可讀（`metadataUnavailable`）→ 有 page
    /// marker（`noPageContext`）→ 有對應 figure（`noMatchingFigure`）→ bbox 唯一
    /// （`ambiguousFigure`）→ bbox 合法（`invalidBoundingBox`：必須恰好 4 個有限值，
    /// `x ≥ 0`、`y ≥ 0`、`w > 0`、`h > 0`、`x + w ≤ 1`、`y + h ≤ 1`，容差 1e-6）→ manifest 有該頁
    /// （`missingPageRecord`）→ 裁切圖檔存在（`missingImageFile`）。
    ///
    /// ## 冪等
    ///
    /// 改寫後的呼叫帶有 `width`，重跑時落入 `explicitSizePreserved`；未改寫者重跑得到相同結果。
    public static func applyFigureWidths(_ source: String, projectDir: URL) -> FigureWidthReport {
        let calls = findFigureIncludeGraphics(in: source)
        guard !calls.isEmpty else {
            return FigureWidthReport(result: source, resolutions: [], unreadableResponseFiles: [])
        }

        let markers = pageMarkerOffsets(in: source)
        var metadata: Result<FigureMetadata, FigureMetadataError>?
        var resolutions: [FigureWidthResolution] = []
        var edits: [(range: Range<Int>, text: String)] = []

        for call in calls {
            let page = markers.last(where: { $0.offset < call.start })?.page
            let outcome: FigureWidthResolution.Outcome

            if call.hasExplicitSize {
                outcome = .explicitSizePreserved
            } else {
                let loadedOnce = metadata ?? loadFigureMetadata(projectDir: projectDir)
                metadata = loadedOnce
                switch loadedOnce {
                case .failure(let error):
                    outcome = .metadataUnavailable(error.reason)
                case .success(let loaded):
                    outcome = resolveFigureWidth(
                        path: call.normalizedPath, page: page, metadata: loaded, projectDir: projectDir
                    )
                }
            }

            if case let .widthApplied(fraction, _) = outcome {
                edits.append(call.widthEdit(width: "width=\(formatWidthFraction(fraction))\\textwidth"))
            }
            resolutions.append(FigureWidthResolution(
                path: call.path, page: page, line: call.line, outcome: outcome
            ))
        }

        let unreadable = (try? metadata?.get())?.unreadableResponseFiles ?? []
        guard !edits.isEmpty else {
            return FigureWidthReport(result: source, resolutions: resolutions, unreadableResponseFiles: unreadable)
        }

        var units = Array(source.utf16)
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

    private static func resolveFigureWidth(
        path: String, page: Int?, metadata: FigureMetadata, projectDir: URL
    ) -> FigureWidthResolution.Outcome {
        guard let page else { return .noPageContext }

        var candidates = [path]
        if (path as NSString).pathExtension.isEmpty {
            candidates.append(path + ".png")
        }
        guard let (canonicalPath, boxes) = candidates.lazy.compactMap({ candidate in
            metadata.figures[FigureKey(page: page, path: candidate)].map { (candidate, $0) }
        }).first else {
            return .noMatchingFigure
        }

        var distinct: [[Double]] = []
        for box in boxes where !distinct.contains(box) {
            distinct.append(box)
        }
        guard distinct.count == 1, let bbox = distinct.first else { return .ambiguousFigure }
        guard isValidNormalizedBBox(bbox) else { return .invalidBoundingBox(bbox) }

        guard let pageWidth = metadata.pageWidths[page], pageWidth.isFinite, pageWidth > 0 else {
            return .missingPageRecord
        }
        let imagePath = projectDir.appendingPathComponent(canonicalPath).path
        guard FileManager.default.fileExists(atPath: imagePath) else { return .missingImageFile }

        return .widthApplied(fraction: bbox[2], widthPoints: bbox[2] * pageWidth)
    }

    static func isValidNormalizedBBox(_ bbox: [Double]) -> Bool {
        guard bbox.count == 4, bbox.allSatisfy(\.isFinite) else { return false }
        let (x, y, w, h) = (bbox[0], bbox[1], bbox[2], bbox[3])
        let tolerance = 1e-6
        return x >= 0 && y >= 0 && w > 0 && h > 0
            && x + w <= 1 + tolerance && y + h <= 1 + tolerance
    }

    static func formatWidthFraction(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
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
        /// `\` 的 UTF-16 offset。
        let start: Int
        /// 指令名稱（含 `*`）之後的 offset；沒有 `[...]` 時在此插入選項。
        let nameEnd: Int
        /// `[` 與 `]` 之間的範圍（UTF-16）；沒有選項時為 nil。
        let optionsRange: Range<Int>?
        let options: String?
        /// 大括號內原樣的路徑。
        let path: String
        let line: Int

        var normalizedPath: String {
            var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
            return trimmed
        }

        var hasExplicitSize: Bool {
            guard let options else { return false }
            return LaTeXNormalizer.optionKeys(options).contains {
                LaTeXNormalizer.explicitSizeOptionKeys.contains($0)
            }
        }

        func widthEdit(width: String) -> (range: Range<Int>, text: String) {
            guard let optionsRange, let options else {
                return (nameEnd..<nameEnd, "[\(width)]")
            }
            var kept = options
            while let last = kept.last, last.isWhitespace { kept.removeLast() }
            if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (optionsRange, width)
            }
            return (optionsRange, kept.hasSuffix(",") ? kept + width : kept + "," + width)
        }
    }

    /// 頂層（不在大括號內）逗號分隔的選項 key。
    static func optionKeys(_ options: String) -> [String] {
        var keys: [String] = []
        var current = ""
        var depth = 0
        func flush() {
            let key = current.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            keys.append(key.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
        for ch in options {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            if ch == "," && depth == 0 {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        return keys
    }

    /// 以 UTF-16 offset 表示的 page marker（與 NSRegularExpression 一致）。
    static func pageMarkerOffsets(in source: String) -> [(offset: Int, page: Int)] {
        let pattern = #"^[ \t]*%%[ \t]*===[ \t]*Page[ \t]+(\d+)[ \t]*==="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Int(ns.substring(with: match.range(at: 1))).map { (match.range.location, $0) }
        }
    }

    /// 找出所有不在註解內、路徑以 `figures/` 開頭的 `\includegraphics` 呼叫。
    static func findFigureIncludeGraphics(in source: String) -> [IncludeGraphicsCall] {
        let units = Array(source.utf16)
        let name = Array("includegraphics".utf16)
        let backslash = UInt16(UInt8(ascii: "\\"))
        let percent = UInt16(UInt8(ascii: "%"))
        let newline = UInt16(UInt8(ascii: "\n"))

        func isLetter(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
        }

        var calls: [IncludeGraphicsCall] = []
        var line = 1
        var i = 0
        while i < units.count {
            let unit = units[i]
            if unit == newline {
                line += 1
                i += 1
            } else if unit == percent {
                while i < units.count && units[i] != newline { i += 1 }
            } else if unit == backslash {
                var j = i + 1
                guard j < units.count else { break }
                guard isLetter(units[j]) else {
                    // 控制符號（\%、\\、\{ …）：整組跳過，避免把 \% 當成註解開頭。
                    if units[j] == newline { line += 1 }
                    i = j + 1
                    continue
                }
                while j < units.count && isLetter(units[j]) { j += 1 }
                if Array(units[(i + 1)..<j]) == name,
                   let (call, end) = parseIncludeGraphics(units, start: i, nameEnd: j, line: line) {
                    if call.normalizedPath.hasPrefix("figures/") {
                        calls.append(call)
                    }
                    line += units[i..<end].filter { $0 == newline }.count
                    i = end
                } else {
                    i = j
                }
            } else {
                i += 1
            }
        }
        return calls
    }

    private static func parseIncludeGraphics(
        _ units: [UInt16], start: Int, nameEnd: Int, line: Int
    ) -> (IncludeGraphicsCall, end: Int)? {
        let backslash = UInt16(UInt8(ascii: "\\"))
        let openBracket = UInt16(UInt8(ascii: "["))
        let closeBracket = UInt16(UInt8(ascii: "]"))
        let openBrace = UInt16(UInt8(ascii: "{"))
        let closeBrace = UInt16(UInt8(ascii: "}"))
        let whitespace: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D]

        var k = nameEnd
        if k < units.count && units[k] == UInt16(UInt8(ascii: "*")) { k += 1 }
        let insertionPoint = k
        while k < units.count && whitespace.contains(units[k]) { k += 1 }

        var optionsRange: Range<Int>?
        if k < units.count && units[k] == openBracket {
            let open = k
            k += 1
            var depth = 0
            while k < units.count {
                let unit = units[k]
                if unit == backslash {
                    k += 2
                    continue
                }
                if unit == openBrace { depth += 1 }
                if unit == closeBrace { depth -= 1 }
                if unit == closeBracket && depth == 0 { break }
                k += 1
            }
            guard k < units.count else { return nil }
            optionsRange = (open + 1)..<k
            k += 1
            while k < units.count && whitespace.contains(units[k]) { k += 1 }
        }

        guard k < units.count && units[k] == openBrace else { return nil }
        let pathOpen = k
        k += 1
        var depth = 1
        while k < units.count {
            let unit = units[k]
            if unit == backslash {
                k += 2
                continue
            }
            if unit == openBrace { depth += 1 }
            if unit == closeBrace {
                depth -= 1
                if depth == 0 { break }
            }
            k += 1
        }
        guard k < units.count else { return nil }

        let call = IncludeGraphicsCall(
            start: start,
            nameEnd: insertionPoint,
            optionsRange: optionsRange,
            options: optionsRange.map { String(decoding: units[$0], as: UTF16.self) },
            path: String(decoding: units[(pathOpen + 1)..<k], as: UTF16.self),
            line: line
        )
        return (call, k + 1)
    }
}
