import Foundation
import XCTest
@testable import PDFToLaTeXCore

/// macdoc#194: `AIConfig.save()` must create `~/.config/macdoc/` at 0700
/// and write `config.json` at 0600, instead of leaving the mode to whatever
/// the calling process's umask happens to be.
final class AIConfigPermissionsTests: XCTestCase {
    func testSaveCreatesConfigDirectoryWithRestrictedPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent("nested-config-dir", isDirectory: true)
        let url = configDir.appendingPathComponent("config.json")

        try AIConfig().save(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: configDir.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o700, "設定目錄權限必須是 0700")
    }

    func testSaveWritesConfigFileWithRestrictedPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        try AIConfig().save(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600, "config.json 權限必須是 0600")
    }

    func testResavingExistingWorldReadableConfigTightensPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try AIConfig().save(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600, "重新儲存既有、權限過寬的設定檔時，權限必須被收緊到 0600")
    }
}
