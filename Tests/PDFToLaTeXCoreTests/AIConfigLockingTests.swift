import Darwin
import Foundation
import XCTest
@testable import PDFToLaTeXCore

/// macdoc#204: `AIConfig.save()`'s internal read -> merge -> atomic-write
/// critical section must be serialized against other writers of the same
/// `~/.config/macdoc/config.json` (notably ooxml-swift's
/// `DocumentProfileStore.updateDocument`) via `ConfigFileLock`, so neither
/// side's update is silently dropped by the other's overlapping write.
final class AIConfigLockingTests: XCTestCase {
    func testSaveBlocksWhileAnotherWriterHoldsTheConfigLockAndPreservesBothFields() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        // 模擬 ooxml-swift DocumentProfileStore 已經寫過的、AIConfig 不擁有的欄位。
        try Data(#"{"document":{"defaultProfile":"official","officialSnapshot":"profiles/v0.json"}}"#.utf8).write(to: url)

        let lockPath = url.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "測試自己應該能先拿到鎖，模擬另一個正在寫入的行程")

        var config = AIConfig()
        config.agent = "codex"

        let expectation = XCTestExpectation(description: "save() completes only after the external lock is released")
        let start = Date()
        var elapsed: TimeInterval = 0
        var saveError: Error?
        DispatchQueue.global().async {
            do {
                try config.save(to: url)
            } catch {
                saveError = error
            }
            elapsed = Date().timeIntervalSince(start)
            expectation.fulfill()
        }

        // 給背景的 save() 一點時間真的進入等待鎖的迴圈。
        Thread.sleep(forTimeInterval: 0.3)
        flock(fd, LOCK_UN)
        close(fd)

        wait(for: [expectation], timeout: 6.0)
        XCTAssertNil(saveError)
        XCTAssertGreaterThanOrEqual(
            elapsed, 0.3,
            "save() 必須被另一個持有鎖的寫入者擋住，不能在鎖仍被持有時搶先完成讀取→合併→寫入"
        )

        let saved = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["agent"] as? String, "codex", "AIConfig 自己擁有的欄位必須寫入成功")
        XCTAssertEqual(
            saved?["document"] as? NSDictionary,
            ["defaultProfile": "official", "officialSnapshot": "profiles/v0.json"] as NSDictionary,
            "另一個寫入者（ooxml-swift DocumentProfileStore）擁有的欄位不能被 save() 蓋掉"
        )
    }

    func testConcurrentAIConfigAndSimulatedDocumentProfileWritesBothPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"document":{"defaultProfile":"official","officialSnapshot":"profiles/v0.json"}}"#.utf8).write(to: url)

        let iterations = 25
        for i in 0..<iterations {
            let group = DispatchGroup()
            let queue = DispatchQueue.global()

            group.enter()
            queue.async {
                // 模擬 ooxml-swift DocumentProfileStore.updateDocument：走同一把鎖，
                // 只讀改寫 "document" 欄位。
                try? ConfigFileLock.withLock(forConfigAt: url.path) {
                    var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
                    object["document"] = ["defaultProfile": "official", "officialSnapshot": "profiles/v\(i).json"]
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    try data.write(to: url, options: .atomic)
                }
                group.leave()
            }

            group.enter()
            queue.async {
                var config = (try? AIConfig.load(from: url)) ?? AIConfig()
                config.agent = i % 2 == 0 ? "codex" : "claude"
                try? config.save(to: url)
                group.leave()
            }

            group.wait()
        }

        // 每一輪結束後檔案都必須是合法、完整的 JSON，且雙方各自擁有的欄位都還在——
        // 不會因為兩邊交錯的 read→merge→write 而互相蓋掉、也不會寫出半個檔案。
        let data = try Data(contentsOf: url)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(saved["agent"])
        let document = try XCTUnwrap(saved["document"] as? [String: String])
        XCTAssertEqual(document["defaultProfile"], "official")
        XCTAssertNotNil(document["officialSnapshot"])

        // 鎖釋放後緊接著各自再存一次，驗證最後一次寫入不會遺失對方剛寫入的欄位。
        try ConfigFileLock.withLock(forConfigAt: url.path) {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["document"] = ["defaultProfile": "official", "officialSnapshot": "profiles/final.json"]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        }
        var finalConfig = try AIConfig.load(from: url)
        finalConfig.transcription = "gemini"
        try finalConfig.save(to: url)

        let finalSaved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(finalSaved["transcription"] as? String, "gemini")
        XCTAssertEqual(
            (finalSaved["document"] as? [String: String])?["officialSnapshot"],
            "profiles/final.json",
            "AIConfig 的最後一次 save() 不能遺失另一個寫入者剛完成的 document 更新"
        )
    }
}
