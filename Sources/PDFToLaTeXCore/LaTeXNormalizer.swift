import Foundation
import PDFKit

// MARK: - Report & Model Types

/// 專案層級清理結果報告。
///
/// `Equatable` 是自動合成的，所以 `figureWidthResolutions`、`unreadableResponseFiles`、
/// `pageCounterNotes`（PsychQuant/macdoc#9、#10 新增）與 `chapterOpening`（#210 新增）也參與比較：
/// 拿一份用預設值建構的報告去和 `normalizeProject` 的結果比較，只要有頁碼、圖片或 openany 紀錄就會不相等。
public struct NormalizeProjectReport: Sendable, Equatable {
    public let mainFileChanged: Bool
    public let preambleFileChanged: Bool
    public let preambleURL: URL?
    public let documentClassFixed: Bool
    public let mathOperatorsAdded: [String]
    public let currencyDollarsEscaped: Int
    public let paperSizeFixed: Bool
    public let fontPackageFixed: Bool
    public let fontSizeFixed: Bool
    public let marginsFixed: Bool
    /// 每個 `\includegraphics{figures/...}` 的寬度還原結果（含未改寫的原因）。
    /// `line` 以步驟 14 的中間原始碼為準；定位請以 `path` + `page` 為主。
    public let figureWidthResolutions: [FigureWidthResolution]
    /// 讀不到或無法解碼的 `responses/*.json`（相對於專案目錄）。
    public let unreadableResponseFiles: [String]
    /// 頁碼還原的紀錄（插入、舊版 counter 移動、衝突、找不到章名）。
    /// `line` 以步驟 13 的中間原始碼為準。
    public let pageCounterNotes: [PageCounterNote]
    /// 章節從偶數頁開始時的 `openany` 處理結果（PsychQuant/macdoc#210）。
    public let chapterOpening: ChapterOpeningOutcome

    public init(
        mainFileChanged: Bool, preambleFileChanged: Bool,
        preambleURL: URL?, documentClassFixed: Bool,
        mathOperatorsAdded: [String], currencyDollarsEscaped: Int,
        paperSizeFixed: Bool = false, fontPackageFixed: Bool = false,
        fontSizeFixed: Bool = false, marginsFixed: Bool = false,
        figureWidthResolutions: [FigureWidthResolution] = [],
        unreadableResponseFiles: [String] = [],
        pageCounterNotes: [PageCounterNote] = [],
        chapterOpening: ChapterOpeningOutcome = .notNeeded
    ) {
        self.mainFileChanged = mainFileChanged
        self.preambleFileChanged = preambleFileChanged
        self.preambleURL = preambleURL
        self.documentClassFixed = documentClassFixed
        self.mathOperatorsAdded = mathOperatorsAdded
        self.currencyDollarsEscaped = currencyDollarsEscaped
        self.paperSizeFixed = paperSizeFixed
        self.fontPackageFixed = fontPackageFixed
        self.fontSizeFixed = fontSizeFixed
        self.marginsFixed = marginsFixed
        self.figureWidthResolutions = figureWidthResolutions
        self.unreadableResponseFiles = unreadableResponseFiles
        self.pageCounterNotes = pageCounterNotes
        self.chapterOpening = chapterOpening
    }
}

/// 數學運算子定義。
public struct MathOperatorDef: Sendable, Equatable {
    public let command: String
    public let isBuiltIn: Bool

    public init(command: String, isBuiltIn: Bool = false) {
        self.command = command
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - LaTeXNormalizer

/// 機械式 LaTeX 清理器。
/// 處理 document class 修正、符號正規化、跨頁重複刪除、頁面標記清除、
/// 外部 preamble 解析、數學運算子偵測、貨幣符號跳脫。
public struct LaTeXNormalizer: Sendable {
    /// 符號替換規則（key → value）。
    public let symbolRules: [String: String]
    /// 是否移除 %% === Page N === 標記。
    public let stripPageMarkers: Bool

    public init(symbolRules: [String: String] = [:], stripPageMarkers: Bool = false) {
        self.symbolRules = symbolRules
        self.stripPageMarkers = stripPageMarkers
    }

    // MARK: - String-Level Normalization (Original API)

    /// 對輸入的 LaTeX 原始碼執行所有清理步驟，回傳清理後的文字。
    public func normalize(_ source: String) -> String {
        var result = source
        result = fixDocumentClass(result)
        result = applySymbolRules(result)
        result = removeCrossPageDuplicates(result)
        if stripPageMarkers {
            result = removePageMarkers(result)
        }
        return result
    }

    // MARK: - Core Normalization Methods

    /// 修正 document class：若內容含 \chapter 但 class 是 article，改為 book。
    func fixDocumentClass(_ source: String) -> String {
        let hasChapters = source.contains("\\chapter{") || source.contains("\\chapter*{")
        return Self.fixDocumentClassInSource(source, hasChapters: hasChapters)
    }

    /// 套用自訂符號替換規則。
    func applySymbolRules(_ source: String) -> String {
        var result = source
        for (key, value) in symbolRules {
            result = result.replacingOccurrences(of: key, with: value)
        }
        return result
    }

    /// 移除跨頁邊界的重複行。AI 逐頁轉寫時常把前一頁最後幾行在下一頁開頭又寫一次。
    ///
    /// ## 分頁邊界（PsychQuant/macdoc#215）
    ///
    /// 只認 `LaTeXSourceScan.markerLines`：整行恰好是 `%% === Page N ===`，且那個 `%` 是註解起點、
    /// 不在巨集定義內。verbatim 類環境、`\verb`、其他註解中間長得像 marker 的文字不是邊界。
    ///
    /// ## 比對（PsychQuant/macdoc#3）
    ///
    /// 每個邊界比較前一頁的「頁尾」與下一頁的「頁首」：頁尾是邊界之前、上一個邊界之後最後
    /// `windowSize` 個可比對行；頁首是邊界之後、下一個邊界之前最前面 `windowSize` 個可比對行。
    /// 頁尾的最後 k 行與頁首的前 k 行逐行相同（去掉頭尾空格、tab 與 CR 後比較），而且頁首那 k 行自身的
    /// 結構配對完整（`LaTeXSourceScan.linesAreSelfBalanced`）時，取最大的 k，刪除頁首那 k 行，再重新
    /// 比較，直到沒有重疊。只有「連續的一段」重疊才算重複：頁首某一行只是在頁尾出現過（例如
    /// `\centering`、`\end{table}`）不刪。配對不完整的段落不刪：巢狀列表的內層與外層結尾都是
    /// `\end{itemize}`，文字相同卻不是重複，刪掉外層結尾就讓列表不再關閉。
    ///
    /// 每一行屬於以下三類之一（封閉列舉）：
    /// 1. **阻隔**：碰到 verbatim 的行（`LaTeXSourceScan.lineTouchesVerbatim`：`\begin{verbatim}` 那一行、
    ///    verbatim 內容、`\end{verbatim}` 那一行、含 `\verb` 的行）。頁尾往前、頁首往後遇到它就停；
    ///    它不比對、不刪，也不能被跳過（跳過整個 verbatim 區塊去比它後面的正文，會刪掉只是碰巧與
    ///    頁尾相同的正文）。刪掉其中任何一行都可能讓 verbatim 提早結束或吞掉後文。
    /// 2. **略過**：去掉頭尾空格、tab 與 CR 後是空的，或以 `%%` 開頭（marker 與轉寫註記）。不比對、
    ///    不刪，也不打斷比對（夾在重複行之間的空行與註記保留在原位）。
    /// 3. **可比對**：其他行。
    ///
    /// ## 冪等
    ///
    /// 只刪頁首的行，邊界依序處理：處理某個邊界時，前一頁（頁尾所在）已經定案，而每個邊界都刪到
    /// 沒有重疊為止，所以第二輪不會再刪。
    func removeCrossPageDuplicates(_ source: String, windowSize: Int = 5) -> String {
        guard windowSize > 0, source.contains("===") else { return source }
        let scan = LaTeXSourceScan(source)
        let boundaries = scan.markerLines
        guard !boundaries.isEmpty else { return source }

        // scan 的行與以 LF 切開的行一一對應（lineStarts 也只以 LF 分行）。
        let lines = source.components(separatedBy: "\n")
        let blanks = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))
        let keys = lines.map { $0.trimmingCharacters(in: blanks) }
        let barrier = lines.indices.map { scan.lineTouchesVerbatim($0) }
        let skipped = keys.map { $0.isEmpty || $0.hasPrefix("%%") }

        var removed = Set<Int>()
        for (position, boundary) in boundaries.enumerated() {
            let pageStart = position > 0 ? boundaries[position - 1] + 1 : 0
            let nextBoundary = position + 1 < boundaries.count ? boundaries[position + 1] : lines.count
            var tail: [Int] = []
            var back = boundary - 1
            while back >= pageStart && tail.count < windowSize && !barrier[back] {
                if !skipped[back] && !removed.contains(back) { tail.append(back) }
                back -= 1
            }
            tail.reverse()

            while true {
                var head: [Int] = []
                var forward = boundary + 1
                while forward < nextBoundary && head.count < windowSize && !barrier[forward] {
                    if !skipped[forward] && !removed.contains(forward) { head.append(forward) }
                    forward += 1
                }
                let overlap = stride(from: min(tail.count, head.count), through: 1, by: -1).first { k in
                    zip(tail.suffix(k), head.prefix(k)).allSatisfy { keys[$0] == keys[$1] }
                        && scan.linesAreSelfBalanced(Array(head.prefix(k)))
                } ?? 0
                guard overlap > 0 else { break }
                removed.formUnion(head.prefix(overlap))
            }
        }

        guard !removed.isEmpty else { return source }
        let result = lines.enumerated()
            .filter { !removed.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
        // 安全網：刪掉的行都不碰到 verbatim，但刪行仍可能改變後文的判定（例如 `\begin% c` 那一行被刪，
        // 下一行的 `{verbatim}` 就不再是環境名稱）。verbatim 有任何變化就整份不動。
        guard LaTeXSourceScan(result).verbatimSegments == scan.verbatimSegments else { return source }
        return result
    }

    /// 跳脫貨幣符號 $（非數學模式的 $）。
    /// 回傳修正後的文字和跳脫的數量。
    public static func escapeCurrencyDollars(_ source: String) -> (result: String, count: Int) {
        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var totalCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳過已在數學模式中的行
            if trimmed.hasPrefix("$") || trimmed.hasPrefix("\\(") || trimmed.hasPrefix("\\[") {
                result.append(line)
                continue
            }
            // 找 $ 後面接數字的模式（如 $100）
            let pattern = #"\$(\d)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                result.append(line)
                continue
            }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = regex.numberOfMatches(in: line, range: range)
            if matches > 0 {
                let replaced = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "\\\\\\$$1")
                result.append(replaced)
                totalCount += matches
            } else {
                result.append(line)
            }
        }

        return (result.joined(separator: "\n"), totalCount)
    }

    // MARK: - Project-Level Normalization

    /// 已知的數學運算子（常見於經濟學/統計學教科書）。
    public static let knownMathOperators: [(command: String, isBuiltIn: Bool)] = [
        ("E", false),
        ("var", false),
        ("cov", false),
        ("corr", false),
        ("avar", false),
        ("rank", false),
        ("tr", false),
        ("diag", false),
        ("vec", true),     // 覆蓋 LaTeX 內建的 \vec (arrow)
        ("plim", false),
        ("argmin", false),
        ("argmax", false),
        ("sgn", false),
        ("supp", false),
        ("med", false),
    ]

    /// 對完整的 LaTeX 專案（主檔 + 外部 preamble）執行所有清理步驟。
    /// 所有操作皆為冪等，重複執行不會覆蓋已修正的內容。
    ///
    /// - Parameters:
    ///   - mainTexURL: 主 .tex 檔案路徑
    ///   - sourcePDFURL: 原始 PDF 路徑（可選），用於提取紙張大小和字型 metadata
    public func normalizeProject(
        mainTexURL: URL,
        sourcePDFURL: URL? = nil
    ) throws -> NormalizeProjectReport {
        let originalMain = try String(contentsOf: mainTexURL, encoding: .utf8)
        var mainSource = originalMain

        // 0. 從原始 PDF 提取排版 metadata（紙張大小、字型）
        let pdfMetadata: PDFTypographyMetadata?
        if let pdfURL = sourcePDFURL {
            pdfMetadata = PDFMetadataExtractor().extract(from: pdfURL)
        } else {
            pdfMetadata = nil
        }

        // 1. 解析外部 preamble
        let preambleURL = Self.resolvePreambleURL(from: mainSource, relativeTo: mainTexURL)
        var preambleSource = preambleURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let originalPreamble = preambleSource

        // 2. 修正 document class
        let hasChapters = mainSource.contains("\\chapter")
        var documentClassFixed = false

        if let preamble = preambleSource {
            let fixed = Self.fixDocumentClassInSource(preamble, hasChapters: hasChapters)
            if fixed != preamble {
                preambleSource = fixed
                documentClassFixed = true
            }
        } else {
            // documentclass 在主檔內
            let fixed = Self.fixDocumentClassInSource(mainSource, hasChapters: hasChapters)
            if fixed != mainSource {
                mainSource = fixed
                documentClassFixed = true
            }
        }

        // 2.5 修正紙張大小（從原始 PDF metadata）
        var paperSizeFixed = false
        if let metadata = pdfMetadata {
            if let preamble = preambleSource {
                let fixed = Self.fixPaperSize(preamble, targetSize: metadata.paperSize)
                if fixed != preamble {
                    preambleSource = fixed
                    paperSizeFixed = true
                }
            } else {
                let fixed = Self.fixPaperSize(mainSource, targetSize: metadata.paperSize)
                if fixed != mainSource {
                    mainSource = fixed
                    paperSizeFixed = true
                }
            }
        }

        // 2.6 修正字型套件和編碼（從原始 PDF metadata）
        var fontPackageFixed = false
        if let metadata = pdfMetadata {
            if let preamble = preambleSource {
                let fixed = Self.fixFontPackage(
                    preamble,
                    targetFamily: metadata.dominantFontFamily,
                    targetEncoding: metadata.fontEncoding
                )
                if fixed != preamble {
                    preambleSource = fixed
                    fontPackageFixed = true
                }
            } else {
                let fixed = Self.fixFontPackage(
                    mainSource,
                    targetFamily: metadata.dominantFontFamily,
                    targetEncoding: metadata.fontEncoding
                )
                if fixed != mainSource {
                    mainSource = fixed
                    fontPackageFixed = true
                }
            }
        }

        // 2.7 修正字型大小（從原始 PDF metadata）
        var fontSizeFixed = false
        if let metadata = pdfMetadata {
            if let preamble = preambleSource {
                let fixed = Self.fixFontSize(preamble, targetSize: metadata.bodyFontSizePt)
                if fixed != preamble {
                    preambleSource = fixed
                    fontSizeFixed = true
                }
            } else {
                let fixed = Self.fixFontSize(mainSource, targetSize: metadata.bodyFontSizePt)
                if fixed != mainSource {
                    mainSource = fixed
                    fontSizeFixed = true
                }
            }
        }

        // 2.8 修正邊距（從原始 PDF metadata）
        var marginsFixed = false
        if let metadata = pdfMetadata, let margins = metadata.margins {
            if let preamble = preambleSource {
                let fixed = Self.fixMargins(preamble, targetMargins: margins)
                if fixed != preamble {
                    preambleSource = fixed
                    marginsFixed = true
                }
            } else {
                let fixed = Self.fixMargins(mainSource, targetMargins: margins)
                if fixed != mainSource {
                    mainSource = fixed
                    marginsFixed = true
                }
            }
        }

        // 2.9 修正標題頁字型大小（從原始 PDF 標題頁比對）
        var titlePageFontsFixed = false
        if let pdfURL = sourcePDFURL,
           let doc = PDFDocument(url: pdfURL) {
            let titleElements = PDFMetadataExtractor.extractPageFontDetails(
                doc: doc, pageIndex: 0
            )
            if !titleElements.isEmpty {
                let fixed = Self.fixTitlePageFontSizes(
                    mainSource, titlePageElements: titleElements
                )
                if fixed != mainSource {
                    mainSource = fixed
                    titlePageFontsFixed = true
                }
            }
        }

        // 3. 偵測並新增缺少的數學運算子
        let definitionSource = preambleSource ?? mainSource
        let missingOps = Self.detectMissingMathOperators(
            mainSource: mainSource, preambleSource: definitionSource
        )
        var mathOperatorsAdded: [String] = []
        if !missingOps.isEmpty {
            if var preamble = preambleSource {
                preamble = Self.addMathOperatorDefinitions(missingOps, to: preamble)
                preambleSource = preamble
                mathOperatorsAdded = missingOps.map { $0.command }
            } else {
                // 沒有外部 preamble，在 \begin{document} 前插入
                mainSource = Self.addMathOperatorsBeforeDocument(missingOps, in: mainSource)
                mathOperatorsAdded = missingOps.map { $0.command }
            }
        }

        // 4. 偵測並新增缺少的套件
        let missingPkgs = Self.detectMissingPackages(
            mainSource: mainSource, preambleSource: preambleSource ?? mainSource
        )
        if !missingPkgs.isEmpty {
            if var preamble = preambleSource {
                preamble = Self.addPackages(missingPkgs, to: preamble)
                preambleSource = preamble
            }
        }

        // 4.5 移除 AI 轉寫的假換行（\\）
        var spuriousLineBreaksRemoved = 0
        if let metadata = pdfMetadata {
            let (fixed, count) = Self.fixSpuriousLineBreaks(
                mainSource,
                margins: metadata.margins,
                paperWidthPt: metadata.paperSize == .letter ? 612.0 : 595.28,
                bodyFontSizePt: metadata.bodyFontSizePt
            )
            if count > 0 {
                mainSource = fixed
                spuriousLineBreaksRemoved = count
            }
        }

        // 5. 修正常見 AI 轉錄錯誤
        mainSource = Self.fixCommonTranscriptionArtifacts(mainSource)

        // 5.5 修正手動章節格式（\textbf{Chapter N} → \chapter{Title}）
        mainSource = Self.fixManualChapterFormatting(mainSource)

        // 5.6 移除重複的 \chapter（AI 幻覺產生的重複章節起始）
        mainSource = Self.removeDuplicateChapters(mainSource)

        // 6. 修正 verbatim-in-fbox（LaTeX 不支援）
        mainSource = Self.fixVerbatimInFbox(mainSource)

        // 7. 修正 equation 內的 \]...\[ 拆分
        mainSource = Self.fixEquationSplits(mainSource)

        // 8. 修正 \tag 在 aligned 環境內部的錯誤
        mainSource = Self.fixTagInAligned(mainSource)

        // 9. 修正跨頁列表環境拆分
        mainSource = Self.fixSplitListEnvironments(mainSource)

        // 10. 修正被誤逃脫的數學模式 $
        let (unescapedMain, unescapeCount) = Self.fixMisescapedMathDollars(mainSource)
        mainSource = unescapedMain
        _ = unescapeCount

        // 11. 跳脫貨幣 $ 符號
        let (escapedMain, currencyCount) = Self.escapeCurrencyDollars(mainSource)
        mainSource = escapedMain

        // 12. 確保 \end{document} 存在
        mainSource = Self.ensureEndDocument(mainSource)

        // 13. 還原原始頁碼（第一個 page marker、章節邊界、切回 arabic）。
        //     依賴 %% === Page N === 標記，必須在步驟 15 移除標記之前執行，
        //     也必須在 5.5／5.6 章節修正之後執行（才看得到修正後的 \chapter）。
        //     manifest 有 PDF page labels 時依 label 決定樣式與值（PsychQuant/macdoc#211）。
        let pageLabels = Self.manifestPageLabels(projectDir: mainTexURL.deletingLastPathComponent())
        let pageCounters = Self.applyPageCounters(mainSource, pageLabels: pageLabels)
        mainSource = pageCounters.result

        // 13.5 有章節頁的頁碼是偶數時改用 openany（PsychQuant/macdoc#210）：book 預設的 openright
        //      會在它前面補一張同頁碼的空白頁。依章名之後的 counter 判斷（marker 已移除時也認得），
        //      所以要在步驟 13 之後；改的是 \documentclass 所在的檔案（外部 preamble 或主檔）。
        var chapterOpening = ChapterOpeningOutcome.notNeeded
        if Self.chapterPageCounterValues(mainSource).contains(where: { $0.isMultiple(of: 2) }) {
            if let preamble = preambleSource {
                let opened = Self.ensureOpenAny(preamble)
                preambleSource = opened.result
                chapterOpening = opened.outcome
            } else {
                let opened = Self.ensureOpenAny(mainSource)
                mainSource = opened.result
                chapterOpening = opened.outcome
            }
        }

        // 14. 依 FigureRegion.bbox 還原圖片寬度（需要 manifest + responses + page marker；
        //     必須在步驟 15 移除標記之前）。未改寫者連同原因記入報告，不套任何 fallback 比例。
        let projectDir = mainTexURL.deletingLastPathComponent()
        let figureWidths = Self.applyFigureWidths(mainSource, projectDir: projectDir)
        mainSource = figureWidths.result

        // 15. 套用既有的字串級清理（符號替換、跨頁重複、頁面標記）
        mainSource = applySymbolRules(mainSource)
        mainSource = removeCrossPageDuplicates(mainSource)
        if stripPageMarkers {
            mainSource = removePageMarkers(mainSource)
        }

        // 寫回修改過的檔案
        let mainChanged = (mainSource != originalMain)
        let preambleChanged = (preambleSource != nil && preambleSource != originalPreamble)

        if mainChanged {
            try mainSource.write(to: mainTexURL, atomically: true, encoding: .utf8)
        }
        if preambleChanged, let preambleURL, let preamble = preambleSource {
            try preamble.write(to: preambleURL, atomically: true, encoding: .utf8)
        }

        return NormalizeProjectReport(
            mainFileChanged: mainChanged,
            preambleFileChanged: preambleChanged,
            preambleURL: preambleURL,
            documentClassFixed: documentClassFixed,
            mathOperatorsAdded: mathOperatorsAdded,
            currencyDollarsEscaped: currencyCount,
            paperSizeFixed: paperSizeFixed,
            fontPackageFixed: fontPackageFixed,
            fontSizeFixed: fontSizeFixed,
            marginsFixed: marginsFixed,
            figureWidthResolutions: figureWidths.resolutions,
            unreadableResponseFiles: figureWidths.unreadableResponseFiles,
            pageCounterNotes: pageCounters.notes,
            chapterOpening: chapterOpening
        )
    }

    // MARK: - Math Operator Detection

    /// 偵測主文件中使用但未在 preamble 定義的數學運算子。
    public static func detectMissingMathOperators(
        mainSource: String,
        preambleSource: String
    ) -> [MathOperatorDef] {
        var missing: [MathOperatorDef] = []
        for (cmd, isBuiltIn) in knownMathOperators {
            // 檢查主文件是否使用了 \cmd（後面不接字母）
            let usePattern = "\\\\\(cmd)(?![a-zA-Z])"
            guard let useRegex = try? NSRegularExpression(pattern: usePattern) else { continue }
            let mainNS = mainSource as NSString
            let mainRange = NSRange(location: 0, length: mainNS.length)
            guard useRegex.firstMatch(in: mainSource, range: mainRange) != nil else { continue }

            // 檢查 preamble 是否已定義
            if isOperatorDefined(cmd, in: preambleSource) { continue }
            // 也檢查主檔本身（以防定義在主檔裡）
            if isOperatorDefined(cmd, in: mainSource) { continue }

            missing.append(MathOperatorDef(command: cmd, isBuiltIn: isBuiltIn))
        }
        return missing
    }

    /// 檢查運算子是否已在原始碼中定義。
    private static func isOperatorDefined(_ cmd: String, in source: String) -> Bool {
        let patterns = [
            "\\\\DeclareMathOperator\\*?\\{?\\\\\(cmd)\\}?",
            "\\\\newcommand\\*?\\{?\\\\\(cmd)\\}?",
            "\\\\renewcommand\\*?\\{?\\\\\(cmd)\\}?",
            "\\\\def\\\\\(cmd)[^a-zA-Z]",
        ]
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))
                .flatMap { $0.firstMatch(in: source, range: range) } != nil
        }
    }

    // MARK: - Add Math Operators

    /// 在 preamble 末尾加入 \DeclareMathOperator 定義。
    public static func addMathOperatorDefinitions(
        _ operators: [MathOperatorDef],
        to preamble: String
    ) -> String {
        guard !operators.isEmpty else { return preamble }
        var lines = ["\n% Math operators (auto-detected)"]
        for op in operators {
            if op.isBuiltIn {
                lines.append("\\let\\\(op.command)\\relax")
            }
            lines.append("\\DeclareMathOperator{\\\(op.command)}{\(op.command)}")
        }
        return preamble.trimmingCharacters(in: .newlines) + "\n" + lines.joined(separator: "\n") + "\n"
    }

    /// 在主檔的 \begin{document} 前插入運算子定義（當沒有外部 preamble 時使用）。
    static func addMathOperatorsBeforeDocument(
        _ operators: [MathOperatorDef],
        in source: String
    ) -> String {
        guard !operators.isEmpty else { return source }
        var lines: [String] = ["% Math operators (auto-detected)"]
        for op in operators {
            if op.isBuiltIn {
                lines.append("\\let\\\(op.command)\\relax")
            }
            lines.append("\\DeclareMathOperator{\\\(op.command)}{\(op.command)}")
        }
        let block = lines.joined(separator: "\n") + "\n"

        if let range = source.range(of: "\\begin{document}") {
            return String(source[..<range.lowerBound]) + block + String(source[range.lowerBound...])
        }
        // 找不到 \begin{document}，附加到開頭
        return block + source
    }

    // MARK: - Package Detection

    /// 常見需要偵測的套件。
    /// 當文件使用特定功能但 preamble 未載入對應套件時，自動新增。
    static let packageRules: [(package: String, triggers: [String])] = [
        ("xcolor", ["\\begin{figure}", "\\begin{table}", "\\includegraphics"]),
    ]

    /// 偵測文件內容所需但 preamble 中缺少的套件。
    public static func detectMissingPackages(
        mainSource: String,
        preambleSource: String
    ) -> [String] {
        var missing: [String] = []
        for (pkg, triggers) in packageRules {
            let usePkg = "\\usepackage{" + pkg + "}"
            let usePkgOpts = "\\usepackage[" // partial match for options variant
            let hasPkg = preambleSource.contains(usePkg)
                || (preambleSource.contains(usePkgOpts) && preambleSource.contains(pkg))
            guard !hasPkg else { continue }
            let used = triggers.contains { mainSource.contains($0) }
            if used { missing.append(pkg) }
        }
        return missing
    }

    /// 在 preamble 的 \usepackage 區塊後面插入缺少的套件。
    public static func addPackages(_ packages: [String], to preamble: String) -> String {
        guard !packages.isEmpty else { return preamble }
        var lines = ["\n% Auto-detected packages"]
        for pkg in packages {
            lines.append("\\usepackage{\(pkg)}")
        }
        return preamble.trimmingCharacters(in: .newlines) + "\n" + lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Verbatim-in-Fbox Fix

    /// 移除 \fbox{%...} wrapper 包裹的 minipage+verbatim 區塊。
    /// LaTeX 的 verbatim 環境不支援在 \fbox{} 內使用，會導致 \@xverbatim 錯誤。
    /// 修正方式：移除 \fbox{%} 外框，保留 minipage+verbatim 內容。
    public static func fixVerbatimInFbox(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var fboxRanges: [(fboxLine: Int, closingLine: Int)] = []

        // Find \fbox{% lines with verbatim content inside
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "\\fbox{%" else { continue }

            // Look ahead for standalone } — the closing brace of \fbox{%}
            var hasVerbatim = false
            for j in (i + 1)..<lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.contains("\\begin{verbatim}") { hasVerbatim = true }
                if t == "}" {
                    // Found the closing brace
                    if hasVerbatim {
                        fboxRanges.append((i, j))
                    }
                    break
                }
            }
        }

        guard !fboxRanges.isEmpty else { return source }

        let fboxLines = Set(fboxRanges.map { $0.fboxLine })
        let closingLines = Set(fboxRanges.map { $0.closingLine })
        let skipLines = fboxLines.union(closingLines)

        var result: [String] = []
        for (idx, line) in lines.enumerated() {
            if skipLines.contains(idx) { continue }
            // Strip trailing % from \end{minipage}% when its closing } was removed
            if closingLines.contains(idx + 1) {
                result.append(line.replacingOccurrences(of: "\\end{minipage}%", with: "\\end{minipage}"))
            } else {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Equation Split Fix

    /// 移除 equation/equation* 環境內的 \]...\[ 拆分。
    /// AI 轉錄時常把多行公式拆成 \]...\[ 而不是正確的換行/對齊。
    public static func fixEquationSplits(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var inEquation = false
        var skipNext = false

        for (idx, line) in lines.enumerated() {
            if skipNext { skipNext = false; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("\\begin{equation") {
                inEquation = true
            }
            if trimmed.hasPrefix("\\end{equation") {
                inEquation = false
            }

            if inEquation && trimmed == "\\]" {
                // Check if next non-empty line is \[
                let nextIdx = idx + 1
                if nextIdx < lines.count {
                    let nextTrimmed = lines[nextIdx].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed == "\\[" {
                        // Skip both \] and \[
                        skipNext = true
                        continue
                    }
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Common Transcription Artifacts

    /// 修正常見的 AI 轉錄錯誤。冪等操作。
    /// - `$\copyright$` 或 `$\copyright\$` → `\textcopyright{}`
    ///   AI 經常把 © 轉錄成被數學模式包裹的 \copyright。
    public static func fixCommonTranscriptionArtifacts(_ source: String) -> String {
        var result = source
        // $\copyright\$ → \textcopyright{}  (e.g. $\copyright\$2000)
        result = result.replacingOccurrences(of: "$\\copyright\\$", with: "\\textcopyright{}")
        // $\copyright$ → \textcopyright{}
        result = result.replacingOccurrences(of: "$\\copyright$", with: "\\textcopyright{}")
        return result
    }

    // MARK: - Spurious Line Break Fix

    /// 不應移除 `\\` 的環境（`\\` 在這些環境中有結構意義）。
    private static let structuralEnvironments: Set<String> = [
        "tabular", "tabularx", "array", "matrix", "pmatrix", "bmatrix",
        "vmatrix", "Vmatrix", "cases", "align", "align*", "aligned",
        "gather", "gather*", "gathered", "eqnarray", "eqnarray*",
        "split", "multline", "multline*", "flalign", "flalign*",
    ]

    /// 移除 AI 轉寫時從 PDF 視覺換行複製來的假 `\\`。
    ///
    /// 判斷邏輯：如果 `\\` 前的文字長度 ≈ 一行的寬度（碰到 textwidth），
    /// 表示 AI 只是複製了 PDF 的版面換行，不是原始 LaTeX 語意上的強制換行。
    ///
    /// - Parameters:
    ///   - source: LaTeX 原始碼
    ///   - margins: 從原始 PDF 偵測的邊距（用於計算 textwidth）
    ///   - paperWidthPt: 紙張寬度（pt），letterpaper = 612
    ///   - bodyFontSizePt: 本文字級（pt），用於估算平均字元寬度
    /// - Returns: 修正後的原始碼與移除數量
    public static func fixSpuriousLineBreaks(
        _ source: String,
        margins: PDFMargins?,
        paperWidthPt: Double = 612.0,
        bodyFontSizePt: Double = 11.0
    ) -> (result: String, count: Int) {
        // 計算 textwidth（pt）
        let leftPt = (margins?.left ?? 1.0) * 72.0
        let rightPt = (margins?.right ?? 1.0) * 72.0
        let textwidthPt = paperWidthPt - leftPt - rightPt

        // 估算平均字元寬度（CM font 大約 0.48 * fontSize）
        let avgCharWidth = bodyFontSizePt * 0.48
        let charsPerLine = textwidthPt / avgCharWidth

        // 容許範圍：如果 `\\` 前的可見字元數在 [0.75 * charsPerLine, 1.2 * charsPerLine] → 假換行
        // 上界放寬到 1.2 因為 estimateVisibleLength 是粗略估計，
        // 且 LaTeX commands 的實際渲染寬度比純字元計數窄
        let minChars = Int(charsPerLine * 0.75)
        let maxChars = Int(charsPerLine * 1.2)

        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var removeCount = 0

        // 追蹤環境巢套
        var envStack: [String] = []

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 追蹤 \begin{env} / \end{env}
            updateEnvStack(trimmed, stack: &envStack)

            // 在結構性環境中不處理
            let inStructural = envStack.contains(where: { structuralEnvironments.contains($0) })

            // 檢查這行是否以 \\ 結尾（且不在結構性環境中）
            if !inStructural && trimmed.hasSuffix("\\\\") && !trimmed.hasSuffix("\\\\[") {
                // 排除特殊模式
                let beforeBreak = String(trimmed.dropLast(2))
                    .trimmingCharacters(in: .whitespaces)

                // 排除 TOC 格式（\dotfill + 頁碼）
                if beforeBreak.contains("\\dotfill") {
                    result.append(line)
                    i += 1
                    continue
                }
                // 排除 minipage/fbox 內的換行（theorem/definition 標題分隔）
                if envStack.contains("minipage") || envStack.contains("fbox") {
                    result.append(line)
                    i += 1
                    continue
                }
                // 排除只有 \\ 的空行
                if beforeBreak.isEmpty {
                    result.append(line)
                    i += 1
                    continue
                }

                // 估算 \\ 前的可見字元數（去掉 LaTeX commands 的粗略估計）
                let visibleLen = estimateVisibleLength(beforeBreak)

                // 如果可見字元數落在「剛好一行」的範圍 → 假換行
                if visibleLen >= minChars && visibleLen <= maxChars {
                    // 移除 \\，把這行和下一行合併
                    let cleaned = line.replacingOccurrences(
                        of: "\\\\", with: "",
                        options: .backwards,
                        range: line.range(of: "\\\\", options: .backwards)
                    ).trimmingCharacters(in: .init(charactersIn: " "))

                    // 與下一行合併（如果下一行存在且是延續文字）
                    if i + 1 < lines.count {
                        let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        // 下一行是普通文字（不是空行、不是指令開頭）
                        if !nextTrimmed.isEmpty &&
                           !nextTrimmed.hasPrefix("\\") &&
                           !nextTrimmed.hasPrefix("%") {
                            result.append(cleaned + " " + nextTrimmed)
                            removeCount += 1
                            i += 2
                            continue
                        } else if !nextTrimmed.isEmpty && isProseCommand(nextTrimmed) {
                            // 下一行以文字指令開頭（如 "printed for..."）
                            result.append(cleaned + " " + nextTrimmed)
                            removeCount += 1
                            i += 2
                            continue
                        }
                    }
                    // 無法合併，但仍移除多餘的 \\
                    result.append(cleaned)
                    removeCount += 1
                    i += 1
                    continue
                }
            }

            result.append(line)
            i += 1
        }

        return (result.joined(separator: "\n"), removeCount)
    }

    /// 追蹤 \begin{env} / \end{env} 巢套。
    private static func updateEnvStack(_ line: String, stack: inout [String]) {
        // \begin{envName} 或 \begin{envName*}
        let beginPattern = try! NSRegularExpression(pattern: #"\\begin\{(\w+\*?)\}"#)
        let endPattern = try! NSRegularExpression(pattern: #"\\end\{(\w+\*?)\}"#)
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)

        for match in beginPattern.matches(in: line, range: range) {
            let env = nsLine.substring(with: match.range(at: 1))
            stack.append(env)
        }
        for match in endPattern.matches(in: line, range: range) {
            let env = nsLine.substring(with: match.range(at: 1))
            if let idx = stack.lastIndex(of: env) {
                stack.remove(at: idx)
            }
        }
    }

    /// 粗略估算一行 LaTeX 的可見字元數（去掉 command names、braces）。
    /// 粗略估算一行 LaTeX 的可見字元數（去掉 command names、braces）。
    public static func estimateVisibleLength(_ line: String) -> Int {
        var s = line
        // 移除 \command{...} 型指令的 command 部分，保留內容
        // 例如 \textbf{bold text} → bold text
        let cmdPattern = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+\{([^}]*)\}"#)
        while let match = cmdPattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            let content = (s as NSString).substring(with: match.range(at: 1))
            s = (s as NSString).replacingCharacters(in: match.range, with: content)
        }
        // 移除剩餘的 \command（無 braces）
        let bareCmd = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+"#)
        s = bareCmd.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        // 移除 { }
        s = s.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        return s.trimmingCharacters(in: .whitespaces).count
    }

    /// 判斷一行是否以「文字性指令」開頭（非結構性，只是 inline formatting）。
    private static func isProseCommand(_ line: String) -> Bool {
        // 小寫字母開頭 = 普通文字
        if let first = line.first, first.isLowercase { return true }
        // 常見文字起始
        let proseStarts = ["printed", "but ", "and ", "or ", "the ", "a ", "an ",
                           "for ", "to ", "of ", "in ", "on ", "with ", "that ",
                           "this ", "is ", "are ", "was ", "were ", "not "]
        let lower = line.lowercased()
        return proseStarts.contains(where: { lower.hasPrefix($0) })
    }

    // MARK: - Manual Chapter Formatting Fix

    /// AI 轉錄時，有時會把章節標題頁轉錄為手動格式（如 \noindent{\Large\textbf{Chapter 10}}），
    /// 而非正確的 \chapter{Title}。此方法偵測這些模式並轉換為 \chapter{Title}。
    ///
    /// 偵測的模式（"Chapter N" 行）：
    /// - `\noindent{\Large\textbf{Chapter N}}`
    /// - `{\centering\noindent{\Large\textbf{Chapter N}}\par}`
    /// - `\noindent{\Large\bfseries Chapter N}`
    /// - `\noindent\textbf{Chapter N}`
    ///
    /// 標題行（"Chapter N" 行之後的下一個非空非間距行）：
    /// - `\noindent{\LARGE\textbf{Title}}`
    /// - `\noindent{\LARGE\bfseries Title}`
    /// - `\noindent\textbf{Title}`
    ///
    /// 冪等：已經是 \chapter{} 格式的不受影響。
    public static func fixManualChapterFormatting(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // 跳過已經正確的 \chapter 指令
            if trimmed.hasPrefix("\\chapter") {
                result.append(lines[i])
                i += 1
                continue
            }

            // 偵測手動 "Chapter N" 格式
            if isManualChapterLine(trimmed) {
                // 向後尋找標題行（跳過空行和間距指令）
                var j = i + 1
                var titleLine: String?
                var titleLineIndex = -1

                while j < lines.count && j <= i + 8 {
                    let nextTrimmed = lines[j].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty || isSpacingCommand(nextTrimmed) {
                        j += 1
                        continue
                    }

                    // 下一個非空非間距行應該是標題
                    let extracted = extractChapterTitle(from: nextTrimmed)
                    // 確保不是章節編號（如 "5.1 Introduction"）
                    if !extracted.isEmpty && !looksLikeSectionNumber(extracted) {
                        titleLine = extracted
                        titleLineIndex = j
                    }
                    break
                }

                if let title = titleLine {
                    result.append("\\chapter{\(title)}")
                    i = titleLineIndex + 1
                    // 跳過標題後的間距指令
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || isSpacingCommand(t) {
                            i += 1
                        } else {
                            break
                        }
                    }
                    continue
                }
            }

            result.append(lines[i])
            i += 1
        }

        return result.joined(separator: "\n")
    }

    /// 判斷一行是否為手動格式的 "Chapter N" 標題。
    /// 核心條件："Chapter N" 必須是 \textbf{...} 的內容或 \bfseries 後的文字，
    /// 而非長段落中偶然出現的引用（如 "see Chapter 1 of Hayashi"）。
    private static func isManualChapterLine(_ trimmed: String) -> Bool {
        // 不能是已有的 \chapter{} 指令
        guard !trimmed.hasPrefix("\\chapter{") && !trimmed.hasPrefix("\\chapter*{") else {
            return false
        }

        // 檢查特定模式："Chapter N" 是粗體格式的直接內容
        let patterns = [
            #"\\textbf\{Chapter\s+\d+\}"#,     // \textbf{Chapter N}
            #"\\bfseries\s+Chapter\s+\d+"#,     // \bfseries Chapter N
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return true
            }
        }

        return false
    }

    /// 判斷一行是否為間距指令（\bigskip, \vspace{...} 等）。
    private static func isSpacingCommand(_ trimmed: String) -> Bool {
        if trimmed == "\\bigskip" || trimmed == "\\medskip" || trimmed == "\\smallskip" { return true }
        if trimmed.hasPrefix("\\vspace") { return true }
        if trimmed == "\\newpage" || trimmed == "\\clearpage" { return true }
        if trimmed == "\\noindent" { return true }
        return false
    }

    /// 從含格式的標題行提取純標題文字。
    /// 處理各種 LaTeX 格式包裝：size commands, \textbf{}, \bfseries, \centering 等。
    private static func extractChapterTitle(from line: String) -> String {
        var text = line

        // 移除 {\centering ... \par} 包裝
        if text.hasPrefix("{") && text.hasSuffix("\\par}") {
            text = String(text.dropFirst())
            text = String(text.dropLast(5))  // 移除 \par}
            text = text.replacingOccurrences(of: "\\centering", with: "")
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // 移除 \noindent
        text = text.replacingOccurrences(of: "\\noindent", with: "")
        text = text.trimmingCharacters(in: .whitespaces)

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        // 模式: {\SIZE\textbf{TITLE}}
        if let regex = try? NSRegularExpression(
            pattern: #"^\{\\(?:LARGE|Large|Huge|huge|large|normalsize)\s*\\textbf\{(.+)\}\}$"#
        ), let match = regex.firstMatch(in: text, range: range) {
            return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }

        // 模式: {\SIZE\bfseries TITLE}
        if let regex = try? NSRegularExpression(
            pattern: #"^\{\\(?:LARGE|Large|Huge|huge|large|normalsize)\s*\\bfseries\s+(.+)\}$"#
        ), let match = regex.firstMatch(in: text, range: range) {
            return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }

        // 模式: \textbf{TITLE}
        if let regex = try? NSRegularExpression(pattern: #"^\\textbf\{(.+)\}$"#),
           let match = regex.firstMatch(in: text, range: range) {
            return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }

        // 模式: \bfseries TITLE
        if text.hasPrefix("\\bfseries ") {
            return String(text.dropFirst(10)).trimmingCharacters(in: .whitespaces)
        }

        return text
    }

    /// 判斷提取的文字是否像章節編號（如 "5.1 Introduction"）。
    private static func looksLikeSectionNumber(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^\d+\.\d+"#) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Duplicate Chapter Removal

    /// 移除重複的 \chapter{Same Title}。
    /// 當兩個 \chapter{} 有相同標題且之間沒有其他 \chapter 時，移除第一個 \chapter 行。
    /// 內容保留（可能包含有效的章節段落），只移除 \chapter 指令本身。
    /// 冪等：沒有重複則不動。
    public static func removeDuplicateChapters(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var chapterIndices: [(index: Int, title: String)] = []

        // 找出所有 \chapter{Title} 的位置和標題
        let chapterRegex = try! NSRegularExpression(pattern: #"^\\chapter\{(.+)\}$"#)
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = chapterRegex.firstMatch(in: trimmed, range: range) {
                let title = ns.substring(with: match.range(at: 1))
                chapterIndices.append((i, title))
            }
        }

        // 找出重複：連續兩個 \chapter 有相同標題
        guard chapterIndices.count >= 2 else { return source }
        var linesToRemove: Set<Int> = []
        for k in 0..<chapterIndices.count - 1 {
            if chapterIndices[k].title == chapterIndices[k + 1].title {
                // 移除第一個（通常是 AI 幻覺產生的錯誤章節起始）
                linesToRemove.insert(chapterIndices[k].index)
            }
        }

        guard !linesToRemove.isEmpty else { return source }

        var result: [String] = []
        for (i, line) in lines.enumerated() {
            if linesToRemove.contains(i) {
                continue  // 跳過重複的 \chapter 行
            }
            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Mis-escaped Math Dollar Fix

    /// 修正 OCR 轉錄時把數學模式開頭的 $ 誤標為 \$（貨幣符號）。
    /// 偵測邏輯：\$ 後接數字，若同一行後方有匹配的閉合 $（構成 inline math），
    /// 且 \$ 不在已有的數學模式內部，則移除反斜線還原為 $。
    /// 冪等：已正確的 $ 或真正的貨幣 \$ 不會被修改。
    public static func fixMisescapedMathDollars(_ source: String) -> (result: String, count: Int) {
        let lines = source.components(separatedBy: "\n")
        var resultLines: [String] = []
        var totalCount = 0

        for line in lines {
            let (fixed, count) = fixMisescapedMathDollarsInLine(line)
            resultLines.append(fixed)
            totalCount += count
        }

        return (resultLines.joined(separator: "\n"), totalCount)
    }

    /// 在單行中修正被誤逃脫的數學 $。
    private static func fixMisescapedMathDollarsInLine(_ line: String) -> (result: String, count: Int) {
        let chars = Array(line)
        guard chars.count >= 3 else { return (line, 0) }

        var result: [Character] = []
        var count = 0
        var i = 0

        while i < chars.count {
            // 尋找 \$ 後接數字的模式
            if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "$" {
                let dollarPos = i + 1

                // 檢查 $ 後是否接數字
                if dollarPos + 1 < chars.count && chars[dollarPos + 1].isNumber {
                    // 基於已處理的結果計算未逃脫 $ 數量（判斷是否在數學模式內）
                    let priorMathDollars = countUnescapedDollarsInArray(result)

                    if priorMathDollars % 2 == 0 {
                        // 文本模式：檢查同行後方是否有閉合 $
                        // 先跳過數字部分（. 只在後面有數字時才算小數點）
                        var j = dollarPos + 1
                        while j < chars.count && chars[j].isNumber { j += 1 }
                        if j < chars.count && chars[j] == "." && j + 1 < chars.count && chars[j + 1].isNumber {
                            j += 1
                            while j < chars.count && chars[j].isNumber { j += 1 }
                        }

                        // 從數字結尾往後找閉合 $
                        if hasClosingDollar(in: chars, from: j) {
                            // 有閉合 $ → 這是數學模式，移除反斜線
                            result.append("$")
                            count += 1
                            i += 2 // 跳過 \$
                            continue
                        }
                    }
                    // 在數學模式內部或無閉合 $ → 保留 \$（正確的貨幣符號）
                }
            }

            result.append(chars[i])
            i += 1
        }

        return (String(result), count)
    }

    /// 計算字元陣列中的未逃脫 $ 數量。
    private static func countUnescapedDollarsInArray(_ chars: [Character]) -> Int {
        var count = 0
        for (k, ch) in chars.enumerated() {
            if ch == "$" && (k == 0 || chars[k - 1] != "\\") {
                count += 1
            }
        }
        return count
    }

    /// 檢查從指定位置開始，同行中是否有未逃脫的閉合 $。
    private static func hasClosingDollar(in chars: [Character], from start: Int) -> Bool {
        var k = start
        while k < chars.count {
            if chars[k] == "\n" { return false }
            if chars[k] == "$" && (k == 0 || chars[k - 1] != "\\") {
                return true
            }
            k += 1
        }
        return false
    }

    // MARK: - Tag in Aligned Fix

    /// 修正 \tag{} 出現在 aligned 環境內部的問題。
    /// 將 \tag 移到 \end{aligned} 之後、\] 之前。
    /// 冪等：已正確放置的 \tag 不會被重複移動。
    public static func fixTagInAligned(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var inAligned = false
        var pendingTag: String? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("\\begin{aligned") {
                inAligned = true
            }

            // 在 aligned 內找到 \tag{...}，暫存並跳過此行
            if inAligned && trimmed.range(of: #"^\\tag\{[^}]*\}$"#, options: .regularExpression) != nil {
                pendingTag = trimmed
                continue
            }

            if trimmed.hasPrefix("\\end{aligned") {
                inAligned = false
                result.append(line)
                // 在 \end{aligned} 後插入暫存的 \tag
                if let tag = pendingTag {
                    result.append(tag)
                    pendingTag = nil
                }
                continue
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Split List Environment Fix

    /// 修正跨頁時列表環境被過早關閉的問題。
    /// 偵測 \end{enumerate/itemize} 後接頁面標記再接 \item 的模式，
    /// 移除過早的 \end{...} 並在孤立 items 後補上正確的結束標記。
    /// 冪等：已正確配對的環境不會被修改。
    ///
    /// 頁面標記只認 `LaTeXSourceScan.markerLines`（PsychQuant/macdoc#215）；verbatim 類環境與
    /// `\verb` 裡長得像 marker 的文字不是分頁。verbatim 的位元組一律不動：
    /// - 過早的 `\end{...}` 那一行、以及判定「已有結束標記」的 `\end{...}` 那一行，都必須不碰到
    ///   verbatim（`LaTeXSourceScan.lineTouchesVerbatim`）；
    /// - 略過的空行必須不碰到 verbatim；
    /// - 需要補上 `\end{...}` 而最後一個孤立 item 的行尾換行是 verbatim（例如該行以 `\verb` 結尾，
    ///   下一行是它的內容）時，插入會落進 verbatim 內容：這一處整個不修正（也不刪過早的 `\end`）。
    public static func fixSplitListEnvironments(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        // scan 的行與以 LF 切開的行一一對應。
        let scan = LaTeXSourceScan(source)
        let markerLines = Set(scan.markerLines)
        /// 空行或 page marker 行，且不碰到 verbatim。
        func isSkippable(_ index: Int) -> Bool {
            guard !scan.lineTouchesVerbatim(index) else { return false }
            return markerLines.contains(index) || lines[index].trimmingCharacters(in: .whitespaces).isEmpty
        }

        // 第一遍：找出需要移除的 \end{...} 行索引和需要插入 \end{...} 的位置
        struct SplitFix {
            let removeEndLine: Int
            let envType: String  // "enumerate" 或 "itemize"
            let insertEndAfterLine: Int?  // 若後方沒有 \end{...} 則需插入
        }

        var fixes: [SplitFix] = []
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // 偵測 \end{enumerate} 或 \end{itemize}（不碰到 verbatim 的那一行才算）
            var envType: String? = nil
            if trimmed == "\\end{enumerate}" { envType = "enumerate" }
            else if trimmed == "\\end{itemize}" { envType = "itemize" }

            if let env = envType, !scan.lineTouchesVerbatim(i) {
                // 往後掃描：跳過空行和頁面標記
                var j = i + 1
                while j < lines.count && isSkippable(j) {
                    j += 1
                }

                // 下一個非空行是否以 \item 開頭？
                if j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("\\item") {
                    // 找到跨頁拆分！找出孤立 items 的結尾
                    var lastItemLine = j
                    var k = j + 1
                    while k < lines.count {
                        let kTrimmed = lines[k].trimmingCharacters(in: .whitespaces)
                        if kTrimmed.hasPrefix("\\item") {
                            lastItemLine = k
                            k += 1
                        } else if isSkippable(k) {
                            k += 1
                        } else {
                            break
                        }
                    }

                    // 檢查孤立 items 後是否已有 \end{...}
                    var hasClosingEnd = false
                    var checkLine = lastItemLine + 1
                    while checkLine < lines.count {
                        if isSkippable(checkLine) {
                            checkLine += 1
                            continue
                        }
                        let check = lines[checkLine].trimmingCharacters(in: .whitespaces)
                        if check == "\\end{\(env)}" && !scan.lineTouchesVerbatim(checkLine) {
                            hasClosingEnd = true
                        }
                        break
                    }

                    // 補上的 \end{...} 會落在最後一個孤立 item 的行尾換行之後；那個換行若是 verbatim，
                    // 插入就改到 verbatim 內容：整處不修正。
                    if !hasClosingEnd && scan.lineEndIsVerbatim(lastItemLine) {
                        i += 1
                        continue
                    }

                    fixes.append(SplitFix(
                        removeEndLine: i,
                        envType: env,
                        insertEndAfterLine: hasClosingEnd ? nil : lastItemLine
                    ))
                }
            }
            i += 1
        }

        guard !fixes.isEmpty else { return source }

        // 套用修正（從後往前以免索引偏移）
        var resultLines = lines
        for fix in fixes.reversed() {
            // 插入 \end{...}（若需要）
            if let insertAfter = fix.insertEndAfterLine {
                resultLines.insert("\\end{\(fix.envType)}", at: insertAfter + 1)
            }
            // 移除過早的 \end{...}
            resultLines.remove(at: fix.removeEndLine)
        }

        let result = resultLines.joined(separator: "\n")
        // 安全網：與 removeCrossPageDuplicates 相同，verbatim 有任何變化就整份不動。
        guard LaTeXSourceScan(result).verbatimSegments == scan.verbatimSegments else { return source }
        return result
    }

    // MARK: - End Document

    /// 確保文件結尾有 \end{document}。
    /// OCR 轉錄常遺漏結尾標記。冪等：已有 \end{document} 則不動。
    public static func ensureEndDocument(_ source: String) -> String {
        guard source.contains("\\begin{document}") else { return source }
        guard !source.contains("\\end{document}") else { return source }
        return source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n\\end{document}\n"
    }

    // MARK: - Page Markers

    /// 移除 %% === Page N === 標記行。
    /// 只移除「整行恰好是 marker」的行（`LaTeXSourceScan.markerLines`），連同該行的換行一起移除，
    /// 不動其他行、不合併行：其他註解中間的 marker 文字（`% 例：%% === Page 12 ===`）、marker
    /// 後面接說明的行、verbatim 類環境與 `\verb` 內的文字、巨集定義內的註解都保留原樣。
    func removePageMarkers(_ source: String) -> String {
        guard source.contains("===") else { return source }
        let scan = LaTeXSourceScan(source)
        guard !scan.markerLines.isEmpty else { return source }
        var units = scan.units
        for line in scan.markerLines.reversed() {
            let start = scan.lineStarts[line]
            let end = line + 1 < scan.lineStarts.count ? scan.lineStarts[line + 1] : units.count
            units.removeSubrange(start..<end)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
