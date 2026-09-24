import XCTest
@testable import PDFToLaTeXCore

final class AIConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = AIConfig()
        XCTAssertEqual(config.available, [])
        XCTAssertEqual(config.transcription, "codex")
        XCTAssertEqual(config.agent, "claude")
        // OCR defaults
        XCTAssertEqual(config.ocrHosts, [:])
        XCTAssertNil(config.ocrDefaultHost)
        XCTAssertEqual(config.ocrDefaultModel, "glm-ocr")
        XCTAssertEqual(config.ocrDefaultBackend, "ollama")
        // 使用者從未設定過 backend：override 欄位是 nil（PsychQuant/pdf-to-latex-swift#11）。
        XCTAssertNil(config.ocrDefaultBackendOverride)
    }

    func testEncodeDecodeCycle() throws {
        var config = AIConfig()
        config.available = ["codex", "claude"]
        config.transcription = "codex"
        config.agent = "claude"
        config.ocrHosts = ["kyle": "localhost:11435", "local": "localhost:11434"]
        config.ocrDefaultHost = "kyle"
        config.ocrDefaultModel = "glm-ocr"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)
        XCTAssertEqual(decoded.available, ["codex", "claude"])
        XCTAssertEqual(decoded.transcription, "codex")
        XCTAssertEqual(decoded.agent, "claude")
        XCTAssertEqual(decoded.ocrHosts, ["kyle": "localhost:11435", "local": "localhost:11434"])
        XCTAssertEqual(decoded.ocrDefaultHost, "kyle")
        XCTAssertEqual(decoded.ocrDefaultModel, "glm-ocr")
    }

    func testSaveAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let configURL = tmpDir.appendingPathComponent("config.json")

        var config = AIConfig()
        config.available = ["codex", "gemini"]
        config.transcription = "codex"
        config.agent = "gemini"
        config.ocrHosts = ["kyle": "localhost:11435"]
        config.ocrDefaultHost = "kyle"

        try config.save(to: configURL)
        let loaded = try AIConfig.load(from: configURL)
        XCTAssertEqual(loaded.available, ["codex", "gemini"])
        XCTAssertEqual(loaded.agent, "gemini")
        XCTAssertEqual(loaded.ocrHosts["kyle"], "localhost:11435")
        XCTAssertEqual(loaded.ocrDefaultHost, "kyle")
    }

    func testLoadMissingFileReturnsDefault() throws {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        let config = try AIConfig.load(from: missing)
        XCTAssertEqual(config.transcription, "codex")
        XCTAssertEqual(config.agent, "claude")
        XCTAssertEqual(config.ocrDefaultModel, "glm-ocr")
    }

    func testBackwardCompatLoadOldConfig() throws {
        // 模擬舊版 config.json（沒有 OCR 欄位）
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let configURL = tmpDir.appendingPathComponent("config.json")

        let oldJSON = """
        {
          "available": ["codex"],
          "transcription": "codex",
          "agent": "claude"
        }
        """
        try oldJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let loaded = try AIConfig.load(from: configURL)
        XCTAssertEqual(loaded.available, ["codex"])
        XCTAssertEqual(loaded.transcription, "codex")
        XCTAssertEqual(loaded.agent, "claude")
        // 新欄位應該有預設值
        XCTAssertEqual(loaded.ocrHosts, [:])
        XCTAssertNil(loaded.ocrDefaultHost)
        XCTAssertEqual(loaded.ocrDefaultModel, "glm-ocr")
        XCTAssertEqual(loaded.ocrDefaultBackend, "ollama")
        // 舊 config.json 沒有這個 key：override 是 nil，不會被 ocrDefaultBackend 的預設值污染。
        XCTAssertNil(loaded.ocrDefaultBackendOverride)
    }

    // MARK: - ocrDefaultBackendOverride（PsychQuant/pdf-to-latex-swift#11）

    /// #11 的根因情境：某個與 OCR 無關的命令呼叫過 save()，把 ocrDefaultBackend 的
    /// struct 預設值 "ollama" 寫進了 config.json。讀這種「被污染」的舊檔時，
    /// override 欄位必須是 nil —— 不能從舊的 ocrDefaultBackend key 推斷出「使用者設定過」。
    func testOverrideNotInferredFromPollutedOldKey() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let configURL = tmpDir.appendingPathComponent("config.json")

        // 模擬「config ai detect」這類與 OCR 無關的命令寫出的檔案：
        // 沒有 ocrDefaultBackendOverride key，但 ocrDefaultBackend 已被預設值污染。
        let pollutedJSON = """
        {
          "available": ["codex"],
          "transcription": "codex",
          "agent": "claude",
          "ocrDefaultBackend": "ollama"
        }
        """
        try pollutedJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let loaded = try AIConfig.load(from: configURL)
        XCTAssertEqual(loaded.ocrDefaultBackend, "ollama", "舊欄位照常解碼，不受影響")
        XCTAssertNil(loaded.ocrDefaultBackendOverride, "不可從被污染的舊 key 推斷使用者設定過")
    }

    /// setOCRDefaultBackend 要同時更新新舊兩個欄位（同 repo #11 的「決定與理由」）。
    func testSetOCRDefaultBackendUpdatesBothFields() {
        var config = AIConfig()
        XCTAssertNil(config.ocrDefaultBackendOverride)

        config.setOCRDefaultBackend("mlx")

        XCTAssertEqual(config.ocrDefaultBackendOverride, "mlx")
        XCTAssertEqual(config.ocrDefaultBackend, "mlx")
    }

    /// 設定過的 override 要能存檔、重新讀回。
    func testSetOCRDefaultBackendPersistsAcrossSaveAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let configURL = tmpDir.appendingPathComponent("config.json")

        var config = AIConfig()
        config.setOCRDefaultBackend("ollama")
        try config.save(to: configURL)

        let loaded = try AIConfig.load(from: configURL)
        XCTAssertEqual(loaded.ocrDefaultBackendOverride, "ollama")
        XCTAssertEqual(loaded.ocrDefaultBackend, "ollama")
    }

    /// override 是 nil 時不寫進 JSON（比照既有 ocrDefaultHost 的慣例：
    /// AIConfigPreservationTests.testClearingKnownOptionalDoesNotRestoreOldValue）。
    func testOverrideNilIsOmittedFromSavedJSON() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let configURL = tmpDir.appendingPathComponent("config.json")

        try AIConfig().save(to: configURL)

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        XCTAssertNil(raw?["ocrDefaultBackendOverride"])
    }

    func testDetectReturnsNonEmpty() {
        let config = AIConfig.detect()
        XCTAssertNotNil(config)
        // detect() 不該 crash，但具體 available 取決於本機環境
    }

    func testEquatable() {
        let a = AIConfig(available: ["codex"], transcription: "codex", agent: "claude")
        let b = AIConfig(available: ["codex"], transcription: "codex", agent: "claude")
        XCTAssertEqual(a, b)
    }

    // MARK: - OCR Host Resolution

    func testResolveOCRHostWithProfileName() {
        var config = AIConfig()
        config.ocrHosts = ["kyle": "localhost:11435", "local": "localhost:11434"]
        XCTAssertEqual(config.resolveOCRHost("kyle"), "localhost:11435")
        XCTAssertEqual(config.resolveOCRHost("local"), "localhost:11434")
    }

    func testResolveOCRHostWithRawAddress() {
        let config = AIConfig()
        // 沒有任何 profile，傳入的當原始地址
        XCTAssertEqual(config.resolveOCRHost("192.168.1.50:11434"), "192.168.1.50:11434")
    }

    func testResolveOCRHostFallbackToProfileNotFound() {
        var config = AIConfig()
        config.ocrHosts = ["kyle": "localhost:11435"]
        // 不存在的 profile 名 → 當原始地址
        XCTAssertEqual(config.resolveOCRHost("unknown"), "unknown")
    }

    func testResolveOCRHostUsesDefault() {
        var config = AIConfig()
        config.ocrHosts = ["kyle": "localhost:11435"]
        config.ocrDefaultHost = "kyle"
        XCTAssertEqual(config.resolveOCRHost(nil), "localhost:11435")
    }

    func testResolveOCRHostNoDefault() {
        let config = AIConfig()
        // 沒設 default，沒傳 host → fallback 到 localhost:11434
        XCTAssertEqual(config.resolveOCRHost(nil), "localhost:11434")
    }

    func testResolveOCRHostDefaultProfileMissing() {
        var config = AIConfig()
        // ocrDefaultHost 設了但 profile 不存在 → fallback
        config.ocrDefaultHost = "ghost"
        XCTAssertEqual(config.resolveOCRHost(nil), "localhost:11434")
    }
}
