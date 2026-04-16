import Foundation

/// LaTeX 環境配對問題。
public struct EnvIssue: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case unclosed     // \begin{X} 沒有對應的 \end{X}
        case extraClose   // \end{X} 沒有對應的 \begin{X}
        case mismatch     // \begin{X} 被 \end{Y} 關閉
    }

    public let kind: Kind
    public let environment: String
    public let line: Int

    public init(kind: Kind, environment: String, line: Int) {
        self.kind = kind
        self.environment = environment
        self.line = line
    }
}

/// 偵測並修復 LaTeX 環境（\begin{X} / \end{X}）配對問題。
public struct LaTeXEnvChecker: Sendable {
    public init() {}

    // MARK: - Check

    /// 回傳所有環境配對問題。
    public func check(_ source: String) -> [EnvIssue] {
        let lines = source.components(separatedBy: "\n")
        var stack: [(env: String, line: Int)] = []
        var issues: [EnvIssue] = []

        let beginPattern = #"\\begin\{([^}]+)\}"#
        let endPattern = #"\\end\{([^}]+)\}"#
        let beginRegex = try! NSRegularExpression(pattern: beginPattern)
        let endRegex = try! NSRegularExpression(pattern: endPattern)

        for (lineIndex, line) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            // 收集此行所有 \begin 和 \end，按位置排序
            var events: [(position: Int, isBegin: Bool, env: String)] = []

            for match in beginRegex.matches(in: line, range: range) {
                let envRange = match.range(at: 1)
                let env = nsLine.substring(with: envRange)
                events.append((match.range.location, true, env))
            }

            for match in endRegex.matches(in: line, range: range) {
                let envRange = match.range(at: 1)
                let env = nsLine.substring(with: envRange)
                events.append((match.range.location, false, env))
            }

            events.sort { $0.position < $1.position }

            for event in events {
                if event.isBegin {
                    stack.append((event.env, lineNumber))
                } else {
                    if stack.isEmpty {
                        issues.append(EnvIssue(kind: .extraClose, environment: event.env, line: lineNumber))
                    } else if stack.last!.env != event.env {
                        let opened = stack.removeLast()
                        issues.append(EnvIssue(kind: .mismatch, environment: opened.env, line: opened.line))
                    } else {
                        stack.removeLast()
                    }
                }
            }
        }

        // 剩餘未關閉的環境
        for opened in stack {
            issues.append(EnvIssue(kind: .unclosed, environment: opened.env, line: opened.line))
        }

        return issues
    }

    // MARK: - Fix

    /// 自動修復環境配對問題。
    /// - 未關閉的環境：在檔案末尾加上 \end{X}
    /// - 多餘的 \end{X}：移除該行
    /// - 不匹配：修正 \end 的環境名稱
    public func fix(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        let issues = check(source)

        // 先處理需要移除的行（extraClose），從後往前刪
        let extraCloseLines = issues
            .filter { $0.kind == .extraClose }
            .map { $0.line }
            .sorted()
            .reversed()

        for lineNumber in extraCloseLines {
            let idx = lineNumber - 1
            guard idx >= 0 && idx < lines.count else { continue }
            // 只移除 \end{X} 部分，如果該行只有 \end{X} 則整行移除
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^\\end\{[^}]+\}$"#, options: .regularExpression) != nil {
                lines.remove(at: idx)
            }
        }

        // 重新檢查未關閉的環境，在末尾追加
        let rechecked = check(lines.joined(separator: "\n"))
        let unclosed = rechecked.filter { $0.kind == .unclosed }

        for issue in unclosed.reversed() {
            lines.append("\\end{\(issue.environment)}")
        }

        return lines.joined(separator: "\n")
    }
}
