import Foundation
import PDFKit

// MARK: - Preamble Resolution & Editing

extension LaTeXNormalizer {

    // MARK: - Preamble Resolution

    /// 在主檔前 20 行搜尋 \input{...}，找到包含 \documentclass 的外部 preamble。
    public static func resolvePreambleURL(from source: String, relativeTo mainURL: URL) -> URL? {
        let lines = source.components(separatedBy: "\n")
        let inputPattern = try! NSRegularExpression(pattern: #"\\input\{([^}]+)\}"#)
        let dir = mainURL.deletingLastPathComponent()

        for line in lines.prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("%") else { continue }
            let nsLine = trimmed as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            if let match = inputPattern.firstMatch(in: trimmed, range: range) {
                let name = nsLine.substring(with: match.range(at: 1))
                let candidate = name.hasSuffix(".tex") ? name : name + ".tex"
                let url = dir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path),
                   let content = try? String(contentsOf: url, encoding: .utf8),
                   content.contains("\\documentclass") {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - Document Class Fix (with options support)

    /// 修正 documentclass: 若 hasChapters 為 true 且 class 是 article，改為 book。
    /// 支援帶選項的格式，如 \documentclass[11pt,a4paper]{article}。
    public static func fixDocumentClassInSource(_ source: String, hasChapters: Bool) -> String {
        guard hasChapters else { return source }
        let pattern = #"\\documentclass(\[[^\]]*\])?\{article\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        guard let match = regex.firstMatch(in: source, range: range) else { return source }

        let options: String
        if match.range(at: 1).location != NSNotFound {
            options = nsSource.substring(with: match.range(at: 1))
        } else {
            options = ""
        }
        let replacement = "\\documentclass\(options){book}"
        return nsSource.replacingCharacters(in: match.range, with: replacement)
    }

    // MARK: - Paper Size Fix

    /// 修正 preamble 中 `\documentclass` 的紙張大小選項。
    /// 若 metadata 指定 letter 但 preamble 寫 a4paper，則替換。冪等。
    public static func fixPaperSize(
        _ source: String,
        targetSize: PDFTypographyMetadata.PaperSize
    ) -> String {
        guard targetSize != .unknown else { return source }
        let target = targetSize.rawValue

        // 已經是正確的紙張大小 → 不修改（冪等）
        if source.contains(target) { return source }

        let allPaperSizes = ["a4paper", "letterpaper", "legalpaper", "b5paper"]
        var result = source
        for size in allPaperSizes where size != target {
            result = result.replacingOccurrences(of: size, with: target)
        }
        return result
    }

    // MARK: - Font Size Fix

    /// 修正 \documentclass 的字型大小選項。冪等。
    /// 例如：`\documentclass[11pt,letterpaper]{book}` → `\documentclass[10pt,letterpaper]{book}`
    public static func fixFontSize(_ source: String, targetSize: Double) -> String {
        let targetOpt: String
        switch targetSize {
        case 10.0: targetOpt = "10pt"
        case 11.0: targetOpt = "11pt"
        case 12.0: targetOpt = "12pt"
        default: return source  // 非標準大小，不修改
        }

        // 已經是正確的大小 → 不修改（冪等）
        let docClassPattern = #"\\documentclass\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: docClassPattern),
              let match = regex.firstMatch(in: source,
                                           range: NSRange(location: 0, length: (source as NSString).length))
        else { return source }

        let optionsStr = (source as NSString).substring(with: match.range(at: 1))
        if optionsStr.contains(targetOpt) { return source }

        // 替換現有的字型大小選項
        let sizePattern = #"\b(10|11|12)pt\b"#
        guard let sizeRegex = try? NSRegularExpression(pattern: sizePattern) else { return source }

        let nsOptions = optionsStr as NSString
        let optRange = NSRange(location: 0, length: nsOptions.length)

        if sizeRegex.firstMatch(in: optionsStr, range: optRange) != nil {
            // 替換現有的 Xpt
            let newOptions = sizeRegex.stringByReplacingMatches(
                in: optionsStr, range: optRange, withTemplate: targetOpt)
            return source.replacingOccurrences(
                of: "\\documentclass[\(optionsStr)]",
                with: "\\documentclass[\(newOptions)]")
        } else {
            // 沒有字型大小選項，新增
            let newOptions = targetOpt + (optionsStr.isEmpty ? "" : ",\(optionsStr)")
            return source.replacingOccurrences(
                of: "\\documentclass[\(optionsStr)]",
                with: "\\documentclass[\(newOptions)]")
        }
    }

    // MARK: - Title Page Font Size Fix

    /// LaTeX size command 對應表（在 11pt book class 下的實際 pt 值）。
    private static var latexSizeCommands: [(command: String, pt11: Double)] {
        [
            ("\\Huge", 24.88),
            ("\\huge", 20.74),
            ("\\LARGE", 17.28),
            ("\\Large", 14.40),
            ("\\large", 12.0),
            ("\\normalsize", 10.95),
            ("\\small", 9.0),
            ("\\footnotesize", 8.0),
            ("\\scriptsize", 7.0),
            ("\\tiny", 5.0),
        ]
    }

    /// 修正 titlepage 內的字型大小 command，使其匹配原始 PDF 的實際字型大小。
    /// 從 PDF pt 值反推最接近的 LaTeX size command（如 `\Huge`），而非硬編碼 `\fontsize`。
    /// 只有當標準 size command 無法匹配（誤差 > 1.5pt）時才 fallback 到 `\fontsize`。
    public static func fixTitlePageFontSizes(
        _ source: String,
        titlePageElements: [PDFMetadataExtractor.TitlePageElement]
    ) -> String {
        guard let startRange = source.range(of: "\\begin{titlepage}"),
              let endRange = source.range(of: "\\end{titlepage}") else {
            return source
        }

        let significantElements = titlePageElements.filter { $0.text.count >= 3 }
        guard !significantElements.isEmpty else { return source }

        let titleBlock = String(source[startRange.upperBound..<endRange.lowerBound])
        var lines = titleBlock.components(separatedBy: "\n")
        var changed = false

        let sizeCommands = ["\\Huge", "\\huge", "\\LARGE", "\\Large", "\\large",
                            "\\normalsize", "\\small", "\\footnotesize", "\\scriptsize", "\\tiny"]

        for (i, line) in lines.enumerated() {
            guard let foundCmd = sizeCommands.first(where: { line.contains($0) }) else { continue }

            let cleanedLine = cleanLatexForMatching(line)
            guard cleanedLine.count >= 3 else { continue }

            guard let matchedElement = findMatchingElement(
                cleanedLine, in: significantElements
            ) else { continue }

            let targetSize = matchedElement.fontSize

            // 現有 size command 的 pt 值
            let currentSize = latexSizeCommands.first { $0.command == foundCmd }?.pt11 ?? 0
            if abs(currentSize - targetSize) < 0.5 { continue }

            // 反推最接近的 LaTeX size command
            let bestMatch = latexSizeCommands.min(by: {
                abs($0.pt11 - targetSize) < abs($1.pt11 - targetSize)
            })!

            let replacement: String
            if abs(bestMatch.pt11 - targetSize) <= 1.5 {
                // 標準 size command 足夠接近 → 用它
                replacement = bestMatch.command
            } else {
                // 差距太大 → fallback 到 \fontsize
                let leading = (targetSize * 1.2).rounded()
                replacement = "\\fontsize{\(formatPt(targetSize))}{\(formatPt(leading))}\\selectfont"
            }

            if replacement == foundCmd { continue }

            lines[i] = line.replacingOccurrences(of: foundCmd, with: replacement)
            changed = true
        }

        guard changed else { return source }

        let fixedBlock = lines.joined(separator: "\n")
        var result = source
        let rangeToReplace = startRange.upperBound..<endRange.lowerBound
        result.replaceSubrange(rangeToReplace, with: fixedBlock)
        return result
    }

    /// 從 LaTeX 行中提取純文字內容（去掉 commands、braces 等）。
    private static func cleanLatexForMatching(_ line: String) -> String {
        var result = line
        // 替換有語義的 commands
        result = result.replacingOccurrences(of: "\\textcopyright{}", with: "©")
        result = result.replacingOccurrences(of: "\\textcopyright", with: "©")
        // 移除常見 LaTeX commands
        let commands = ["\\bfseries", "\\textsc", "\\textbf",
                        "\\textsuperscript", "\\par", "\\vspace", "\\hspace",
                        "\\Huge", "\\huge", "\\LARGE", "\\Large", "\\large",
                        "\\normalsize", "\\small", "\\footnotesize", "\\scriptsize", "\\tiny",
                        "\\fontsize", "\\selectfont", "\\centering"]
        for cmd in commands {
            result = result.replacingOccurrences(of: cmd, with: "")
        }
        // 移除 {...} 中的參數（如 \vspace{1cm}）但保留文字
        result = result.replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: "\\\\", with: "")
        // 壓縮空白
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 在 PDF 元素中找與 tex 文字最匹配的元素。
    private static func findMatchingElement(
        _ texText: String,
        in elements: [PDFMetadataExtractor.TitlePageElement]
    ) -> PDFMetadataExtractor.TitlePageElement? {
        // 只保留字母和數字做比對，避免 ©/c°/symbols 不匹配
        func alphanumOnly(_ s: String) -> String {
            s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                .map { String($0) }.joined().uppercased()
        }
        let texAlpha = alphanumOnly(texText)
        guard texAlpha.count >= 3 else { return nil }

        for el in elements {
            let pdfAlpha = alphanumOnly(el.text)
            guard pdfAlpha.count >= 3 else { continue }
            let texPrefix = String(texAlpha.prefix(8))
            let pdfPrefix = String(pdfAlpha.prefix(8))
            if texAlpha.hasPrefix(pdfPrefix) || pdfAlpha.hasPrefix(texPrefix) {
                return el
            }
        }
        return nil
    }

    /// 格式化 pt 值：整數不帶小數，否則帶 1 位小數。
    private static func formatPt(_ val: Double) -> String {
        if val == val.rounded() {
            return "\(Int(val))"
        }
        return String(format: "%.1f", val)
    }

    // MARK: - Margins Fix

    /// 修正 preamble 中 geometry 套件的邊距設定。冪等。
    public static func fixMargins(_ source: String, targetMargins: PDFMargins) -> String {
        let targetGeo = targetMargins.geometryString

        // 檢查是否已有 geometry 套件
        let geoPattern = #"\\usepackage\[([^\]]*)\]\{geometry\}"#
        guard let regex = try? NSRegularExpression(pattern: geoPattern) else { return source }

        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)

        if let match = regex.firstMatch(in: source, range: fullRange) {
            let currentOptions = nsSource.substring(with: match.range(at: 1))

            // 已經是正確的設定 → 不修改（冪等）
            if currentOptions == targetGeo { return source }

            // 替換現有的 geometry 選項
            let oldLine = nsSource.substring(with: match.range)
            let newLine = "\\usepackage[\(targetGeo)]{geometry}"
            return source.replacingOccurrences(of: oldLine, with: newLine)
        } else if source.contains("\\usepackage{geometry}") {
            // 無選項的 geometry，加入選項
            return source.replacingOccurrences(
                of: "\\usepackage{geometry}",
                with: "\\usepackage[\(targetGeo)]{geometry}")
        }
        // 沒有 geometry 套件，不自動加入（避免與其他 layout 設定衝突）
        return source
    }

    // MARK: - Font Package Fix

    /// 修正 preamble 的字型套件和編碼，使其匹配原始 PDF 的字型。冪等。
    public static func fixFontPackage(
        _ source: String,
        targetFamily: PDFTypographyMetadata.FontFamily,
        targetEncoding: PDFTypographyMetadata.FontEncoding = .t1
    ) -> String {
        guard targetFamily != .unknown else { return source }
        var result = source

        // 1. 修正字型編碼
        result = fixFontEncoding(result, targetEncoding: targetEncoding)

        // 2. 修正字型套件
        switch targetFamily {
        case .computerModern:
            // DC/EC/CM/SF fonts：只用 fontenc，移除其他字型套件
            result = removeFontPackageLine(result, package: "lmodern")
            result = removeFontPackageLine(result, package: "newtxtext")
            result = removeFontPackageLine(result, package: "newtxmath")
            result = removeFontPackageLine(result, package: "newpxtext")
            result = removeFontPackageLine(result, package: "newpxmath")
            result = removeFontPackageLine(result, package: "times")
            result = removeFontPackageLine(result, package: "palatino")

        case .latinModern:
            if !result.contains("\\usepackage{lmodern}") {
                result = addFontPackage(result, line: "\\usepackage{lmodern}")
            }

        case .times:
            result = removeFontPackageLine(result, package: "lmodern")
            if !result.contains("newtxtext") && !result.contains("\\usepackage{times}") {
                result = addFontPackage(result, line: "\\usepackage{newtxtext,newtxmath}")
            }

        case .palatino:
            result = removeFontPackageLine(result, package: "lmodern")
            if !result.contains("newpxtext") && !result.contains("\\usepackage{palatino}") {
                result = addFontPackage(result, line: "\\usepackage{newpxtext,newpxmath}")
            }

        case .helvetica, .unknown:
            break
        }
        return result
    }

    /// 修正字型編碼設定。冪等。
    /// - T1：確保有 `\usepackage[T1]{fontenc}`
    /// - OT1：移除 T1 fontenc（LaTeX 預設即為 OT1）
    private static func fixFontEncoding(
        _ source: String,
        targetEncoding: PDFTypographyMetadata.FontEncoding
    ) -> String {
        let hasT1 = source.contains("\\usepackage[T1]{fontenc}")

        switch targetEncoding {
        case .t1:
            if hasT1 { return source }
            // 需要 T1 但沒有 → 在 \documentclass 後加入
            let lines = source.components(separatedBy: "\n")
            var result: [String] = []
            var inserted = false
            for l in lines {
                result.append(l)
                if !inserted && l.contains("\\documentclass") {
                    result.append("\\usepackage[T1]{fontenc}")
                    inserted = true
                }
            }
            return result.joined(separator: "\n")

        case .ot1:
            if !hasT1 { return source }
            // 有 T1 但原始是 OT1 → 移除
            let lines = source.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.contains("\\usepackage[T1]{fontenc}") }
            return collapseBlankLines(filtered.joined(separator: "\n"))

        case .unknown:
            return source
        }
    }

    /// 移除 preamble 中包含指定套件的 `\usepackage` 行。
    private static func removeFontPackageLine(_ source: String, package: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 精確匹配 \usepackage{pkg} 或 \usepackage{pkg1,pkg2}（包含 pkg）
            if trimmed == "\\usepackage{\(package)}" { return false }
            // 也匹配逗號分隔的如 \usepackage{newtxtext,newtxmath}
            if trimmed.hasPrefix("\\usepackage{") && trimmed.contains(package) &&
               !trimmed.contains("fontenc") { return false }
            return true
        }
        // 清理連續空行
        return collapseBlankLines(filtered.joined(separator: "\n"))
    }

    /// 在 `\usepackage[T1]{fontenc}` 之後插入字型套件行。
    private static func addFontPackage(_ source: String, line: String) -> String {
        // 在 fontenc 之後插入
        if let range = source.range(of: "\\usepackage[T1]{fontenc}") {
            let insertionPoint = source[range.upperBound...]
            if let newlineIdx = insertionPoint.firstIndex(of: "\n") {
                let before = String(source[...newlineIdx])
                let after = String(source[source.index(after: newlineIdx)...])
                return before + line + "\n" + after
            } else {
                // fontenc 是最後一行，直接在末尾加入
                return source + "\n" + line
            }
        }
        // fallback: 在 \documentclass 行之後，或附加到末尾
        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var inserted = false
        for l in lines {
            result.append(l)
            if !inserted && l.contains("\\documentclass") {
                result.append(line)
                inserted = true
            }
        }
        if !inserted {
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    /// 將連續三個以上空行壓縮為兩個。
    static func collapseBlankLines(_ source: String) -> String {
        let pattern = #"\n{4,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let nsSource = source as NSString
        return regex.stringByReplacingMatches(
            in: source, range: NSRange(location: 0, length: nsSource.length),
            withTemplate: "\n\n\n"
        )
    }
}
