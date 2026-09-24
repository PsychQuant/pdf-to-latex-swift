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
    /// 預設 OCR 後端（ollama / mlx）。`init()` 給它非 nil 的 struct 預設值 `"ollama"`，
    /// 所以**光看這個欄位分不出「使用者設定過」還是「只是預設值」**——任何呼叫過
    /// `save()` 的命令（即使與 OCR 完全無關，例如 `config ai detect`）都會把 `"ollama"`
    /// 寫進 config.json。要問「使用者是否明確設定過」請讀 `ocrDefaultBackendOverride`，
    /// 不要讀這個欄位（PsychQuant/pdf-to-latex-swift#11）。這個欄位本身繼續保留、繼續更新，
    /// 只為了相容既有讀取端（如 `config ocr list` 印出的 backend）。
    public var ocrDefaultBackend: String
    /// 使用者透過 `setOCRDefaultBackend(_:)` 明確設定過的後端；`nil` 表示從未設定過。
    /// 與 `ocrDefaultBackend` 不同，這個欄位沒有非 nil 的 struct 預設值，也**不會**從舊的
    /// `ocrDefaultBackend` key 推斷（那個 key 可能只是無關命令寫入的預設值，不代表使用者的
    /// 選擇）。讀取端要判斷「使用者是否設定過 OCR 後端」應該讀這個欄位，不是
    /// `ocrDefaultBackend`（PsychQuant/pdf-to-latex-swift#11）。
    public var ocrDefaultBackendOverride: String?

    public init(
        available: [String] = [],
        transcription: String = "codex",
        agent: String = "claude",
        ocrHosts: [String: String] = [:],
        ocrDefaultHost: String? = nil,
        ocrDefaultModel: String = "glm-ocr",
        ocrDefaultBackend: String = "ollama",
        ocrDefaultBackendOverride: String? = nil
    ) {
        self.available = available
        self.transcription = transcription
        self.agent = agent
        self.ocrHosts = ocrHosts
        self.ocrDefaultHost = ocrDefaultHost
        self.ocrDefaultModel = ocrDefaultModel
        self.ocrDefaultBackend = ocrDefaultBackend
        self.ocrDefaultBackendOverride = ocrDefaultBackendOverride
    }

    // MARK: - Backward-compatible Decoding

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case available, transcription, agent
        case ocrHosts, ocrDefaultHost, ocrDefaultModel, ocrDefaultBackend
        case ocrDefaultBackendOverride
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
        // 刻意不 fallback 到 .ocrDefaultBackend：那個 key 可能是無關命令寫入的預設值，
        // 不代表使用者真的設定過（#11 的根因）。
        self.ocrDefaultBackendOverride = try c.decodeIfPresent(String.self, forKey: .ocrDefaultBackendOverride)
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

    /// Persists this config, merging it into whatever is currently on disk
    /// so that fields owned by other writers (such as `document`, owned by
    /// ooxml-swift's `DocumentProfileStore`) are preserved.
    ///
    /// The read -> merge -> atomic-write critical section is wrapped in
    /// `ConfigFileLock` (macdoc#204) so a concurrent writer to the same
    /// `~/.config/macdoc/config.json` cannot interleave with this one and
    /// have its update silently discarded. See `ConfigFileLock` for the
    /// cross-process protocol, which must stay identical to the one used
    /// by ooxml-swift's `DocumentProfileStore.updateDocument`.
    public func save(to url: URL? = nil) throws {
        let configURL = url ?? AIConfig.defaultConfigURL
        let known = try Self.configurationObject(from: JSONEncoder().encode(self))

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        try ConfigFileLock.withLock(forConfigAt: configURL.path) {
            var merged: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: configURL.path) {
                // Read at save time: other consumers own fields such as document.
                // Invalid existing data must fail before any replacement occurs.
                //
                // Known limitation (macdoc#194): this read follows symlinks
                // (Foundation's `Data(contentsOf:)` has no O_NOFOLLOW option),
                // so a symlink planted at configURL's path could redirect the
                // read to an attacker-chosen file. Doing this safely would
                // need a hand-rolled open(O_NOFOLLOW)+fstat+read instead of
                // `Data(contentsOf:)`; deferred as out of scope here since
                // `~/.config/macdoc/` is a single-user, non-multi-tenant
                // directory and the subsequent atomic write (rename()) does
                // not follow a symlink at the destination path — it replaces
                // the link itself, so the write side is not similarly exposed.
                merged = try Self.configurationObject(from: Data(contentsOf: configURL))
            }
            // Removing every owned key first also honors optional fields cleared
            // to nil; merging only encoded values would resurrect the old value.
            for key in CodingKeys.allCases {
                merged.removeValue(forKey: key.rawValue)
            }
            merged.merge(known) { _, updated in updated }
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
            // .atomic writes via a temp file + rename, whose permissions
            // follow the process umask rather than the config's own
            // 0600 contract, so set it explicitly afterwards (macdoc#194).
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
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

    // MARK: - OCR Backend Setting

    /// 使用者明確設定 OCR 預設後端的入口（PsychQuant/pdf-to-latex-swift#11）。
    /// 同時更新 `ocrDefaultBackendOverride`（讓讀取端能區分「使用者設定過」與「只是預設值」）
    /// 與舊欄位 `ocrDefaultBackend`（維持與依賴舊欄位的既有讀取端相容，例如 `config ocr list`）。
    /// 呼叫端（如 macdoc 的 `config ocr set-backend`）應該先 `AIConfig.load()`、呼叫本方法、
    /// 再 `save()`——本方法只改記憶體中的值，不做任何驗證或落地。
    public mutating func setOCRDefaultBackend(_ backend: String) {
        ocrDefaultBackendOverride = backend
        ocrDefaultBackend = backend
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
