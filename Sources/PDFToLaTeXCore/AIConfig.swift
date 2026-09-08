import Foundation

/// AI CLI 工具設定（codex / claude / gemini）+ OCR Ollama host 設定。
/// 儲存在 ~/.config/macdoc/config.json。
public struct AIConfig: Codable, Sendable, Equatable {
    /// 本機偵測到的 CLI 工具名稱。
    public var available: [String]
    /// 預設用於 one-shot 轉寫的後端。
    public var transcription: String
    /// 預設用於 agentic consolidation 的後端。
    public var agent: String

    // MARK: - OCR Settings

    /// 具名 Ollama host profiles（如 ["kyle": "localhost:11435"]）。
    public var ocrHosts: [String: String]
    /// 預設使用的 host profile 名稱。沒設則 fallback 到 localhost:11434。
    public var ocrDefaultHost: String?
    /// 預設 OCR 模型名稱（ollama 後端）。
    public var ocrDefaultModel: String
    /// 預設 OCR 後端（ollama / mlx）。
    public var ocrDefaultBackend: String

    public init(
        available: [String] = [],
        transcription: String = "codex",
        agent: String = "claude",
        ocrHosts: [String: String] = [:],
        ocrDefaultHost: String? = nil,
        ocrDefaultModel: String = "glm-ocr",
        ocrDefaultBackend: String = "ollama"
    ) {
        self.available = available
        self.transcription = transcription
        self.agent = agent
        self.ocrHosts = ocrHosts
        self.ocrDefaultHost = ocrDefaultHost
        self.ocrDefaultModel = ocrDefaultModel
        self.ocrDefaultBackend = ocrDefaultBackend
    }

    // MARK: - Backward-compatible Decoding

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case available, transcription, agent
        case ocrHosts, ocrDefaultHost, ocrDefaultModel, ocrDefaultBackend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.available = try c.decodeIfPresent([String].self, forKey: .available) ?? []
        self.transcription = try c.decodeIfPresent(String.self, forKey: .transcription) ?? "codex"
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        self.ocrHosts = try c.decodeIfPresent([String: String].self, forKey: .ocrHosts) ?? [:]
        self.ocrDefaultHost = try c.decodeIfPresent(String.self, forKey: .ocrDefaultHost)
        self.ocrDefaultModel = try c.decodeIfPresent(String.self, forKey: .ocrDefaultModel) ?? "glm-ocr"
        self.ocrDefaultBackend = try c.decodeIfPresent(String.self, forKey: .ocrDefaultBackend) ?? "ollama"
    }

    // MARK: - Default Config Path

    public static var defaultConfigURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("macdoc", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    // MARK: - Load

    public static func load(from url: URL? = nil) throws -> AIConfig {
        let configURL = url ?? defaultConfigURL
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return AIConfig()
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(AIConfig.self, from: data)
    }

    // MARK: - Save

    public func save(to url: URL? = nil) throws {
        let configURL = url ?? AIConfig.defaultConfigURL
        let known = try Self.configurationObject(from: JSONEncoder().encode(self))
        var merged: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            // Read at save time: other consumers own fields such as document.
            // Invalid existing data must fail before any replacement occurs.
            merged = try Self.configurationObject(from: Data(contentsOf: configURL))
        }
        // Removing every owned key first also honors optional fields cleared
        // to nil; merging only encoded values would resurrect the old value.
        for key in CodingKeys.allCases {
            merged.removeValue(forKey: key.rawValue)
        }
        merged.merge(known) { _, updated in updated }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
    }

    private static func configurationObject(from data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        guard let object = value as? [String: Any] else {
            throw NSError(
                domain: "PDFToLaTeXCore.AIConfig", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "設定檔的根節點必須是 JSON object。"])
        }
        return object
    }

    // MARK: - Detect

    /// 自動偵測本機已安裝的 CLI 工具。
    public static func detect() -> AIConfig {
        let tools = ["codex", "claude", "gemini"]
        let found = tools.filter { isCommandAvailable($0) }

        var config = AIConfig()
        config.available = found

        // 設定預設 transcription：優先 codex，其次 claude，其次 gemini
        if let first = ["codex", "claude", "gemini"].first(where: { found.contains($0) }) {
            config.transcription = first
        }

        // 設定預設 agent：優先 claude，其次 codex，其次 gemini
        if let first = ["claude", "codex", "gemini"].first(where: { found.contains($0) }) {
            config.agent = first
        }

        return config
    }

    private static func isCommandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - OCR Host Resolution

    /// 解析 `--host` 參數：先當 profile 名查 ocrHosts，找不到才當原始地址。
    /// 沒傳 hostArg 時：用 ocrDefaultHost 對應的 profile，再 fallback 到 "localhost:11434"。
    public func resolveOCRHost(_ hostArg: String?) -> String {
        if let hostArg {
            // 優先當 profile 名查
            if let profile = ocrHosts[hostArg] {
                return profile
            }
            // 找不到就當原始地址
            return hostArg
        }
        // 沒傳：用 default profile
        if let defaultName = ocrDefaultHost, let profile = ocrHosts[defaultName] {
            return profile
        }
        return "localhost:11434"
    }
}
