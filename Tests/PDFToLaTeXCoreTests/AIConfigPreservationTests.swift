import Foundation
import XCTest
@testable import PDFToLaTeXCore

final class AIConfigPreservationTests: XCTestCase {
    func testSavePreservesDocumentAndUnknownNestedValues() throws {
        let document: NSDictionary = ["defaultProfile": "official", "officialSnapshot": "profiles/example.json"]
        let extensionValue: NSDictionary = ["enabled": true, "values": [1, 2, 3], "unset": NSNull()]
        let initial = try JSONSerialization.data(withJSONObject: ["document": document, "extension": extensionValue])
        try withConfigFile(initial) { url in
            var config = try AIConfig.load(from: url)
            config.agent = "codex"
            try config.save(to: url)
            let saved = try object(at: url)
            XCTAssertEqual(saved["document"] as? NSDictionary, document)
            XCTAssertEqual(saved["extension"] as? NSDictionary, extensionValue)
            XCTAssertEqual(saved["agent"] as? String, "codex")
        }
    }

    func testClearingKnownOptionalDoesNotRestoreOldValue() throws {
        let initial = Data(#"{"ocrDefaultHost":"remote","document":{"defaultProfile":"inherit"}}"#.utf8)
        try withConfigFile(initial) { url in
            var config = try AIConfig.load(from: url)
            config.ocrDefaultHost = nil
            try config.save(to: url)
            let saved = try object(at: url)
            XCTAssertNil(saved["ocrDefaultHost"])
            XCTAssertEqual((saved["document"] as? [String: String])?["defaultProfile"], "inherit")
        }
    }

    func testSavePreservesUnknownValuesWrittenAfterLoad() throws {
        try withConfigFile(Data(#"{"extension":{"generation":1}}"#.utf8)) { url in
            var config = try AIConfig.load(from: url)
            try Data(#"{"extension":{"generation":2},"document":{"defaultProfile":"official"}}"#.utf8).write(to: url)
            config.agent = "gemini"
            try config.save(to: url)
            let saved = try object(at: url)
            XCTAssertEqual((saved["extension"] as? [String: Int])?["generation"], 2)
            XCTAssertEqual((saved["document"] as? [String: String])?["defaultProfile"], "official")
        }
    }

    func testAlternatingAIAndOCRUpdatesPreserveDocumentConsumer() throws {
        try withConfigFile(Data(#"{"document":{"defaultProfile":"official"},"extension":[true,false]}"#.utf8)) { url in
            var ai = try AIConfig.load(from: url)
            ai.agent = "gemini"
            try ai.save(to: url)
            var ocr = try AIConfig.load(from: url)
            ocr.ocrDefaultModel = "test-model"
            ocr.ocrDefaultHost = "local"
            try ocr.save(to: url)
            var documentConsumer = try object(at: url)
            documentConsumer["document"] = ["defaultProfile": "inherit", "officialSnapshot": "profiles/snapshot.json"]
            try JSONSerialization.data(withJSONObject: documentConsumer).write(to: url, options: .atomic)
            ai = try AIConfig.load(from: url)
            ai.transcription = "claude"
            try ai.save(to: url)
            let saved = try object(at: url)
            XCTAssertEqual(saved["agent"] as? String, "gemini")
            XCTAssertEqual(saved["ocrDefaultModel"] as? String, "test-model")
            XCTAssertEqual(saved["ocrDefaultHost"] as? String, "local")
            XCTAssertEqual(saved["transcription"] as? String, "claude")
            XCTAssertEqual(saved["document"] as? NSDictionary,
                           ["defaultProfile": "inherit", "officialSnapshot": "profiles/snapshot.json"] as NSDictionary)
            XCTAssertEqual(saved["extension"] as? [Bool], [true, false])
        }
    }

    func testCorruptExistingJSONIsNotOverwritten() throws {
        let original = Data(#"{"document": invalid"#.utf8)
        try withConfigFile(original) { url in
            XCTAssertThrowsError(try AIConfig().save(to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testNonObjectRootsAreNotOverwritten() throws {
        for raw in ["[]", "null", "17", "\"string\""] {
            let original = Data(raw.utf8)
            try withConfigFile(original) { url in
                XCTAssertThrowsError(try AIConfig().save(to: url), raw)
                XCTAssertEqual(try Data(contentsOf: url), original, raw)
            }
        }
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func withConfigFile(_ initial: Data, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try initial.write(to: url)
        try body(url)
    }
}
