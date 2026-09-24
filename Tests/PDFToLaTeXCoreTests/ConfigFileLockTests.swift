import Darwin
import Foundation
import XCTest
@testable import PDFToLaTeXCore

/// Tests for `ConfigFileLock`, the cross-process advisory lock protecting
/// `~/.config/macdoc/config.json` (macdoc#204). The protocol under test
/// (lock file path, open flags/mode, poll interval, timeout, hold scope,
/// never-delete) must match `DocumentProfileStore.updateDocument` in
/// `ooxml-swift` — see the doc comment on `ConfigFileLock` itself.
final class ConfigFileLockTests: XCTestCase {
    func testWithLockRunsBodyAndReturnsItsValue() throws {
        try withTempConfigPath { path in
            let result = try ConfigFileLock.withLock(forConfigAt: path) { 42 }
            XCTAssertEqual(result, 42)
        }
    }

    func testLockFileIsCreatedWithMode0600() throws {
        try withTempConfigPath { path in
            _ = try ConfigFileLock.withLock(forConfigAt: path) { () }
            let lockPath = path + ".lock"
            let attrs = try FileManager.default.attributesOfItem(atPath: lockPath)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, 0o600, "鎖檔權限必須是 0600")
        }
    }

    func testLockFileIsNeverDeletedAfterUse() throws {
        try withTempConfigPath { path in
            _ = try ConfigFileLock.withLock(forConfigAt: path) { () }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
        }
    }

    func testTimesOutWhileAnotherFileDescriptorHoldsExclusiveLock() throws {
        try withTempConfigPath { path in
            let lockPath = path + ".lock"
            let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "測試自己應該能先拿到鎖")

            XCTAssertThrowsError(
                try ConfigFileLock.withLock(
                    forConfigAt: path, pollInterval: 0.02, timeout: 0.2
                ) { () }
            ) { error in
                XCTAssertTrue(error is ConfigFileLock.TimeoutError, "逾時應該拋出 ConfigFileLock.TimeoutError，實際是 \(error)")
            }
        }
    }

    func testSucceedsAfterAnotherFileDescriptorReleasesTheLock() throws {
        try withTempConfigPath { path in
            let lockPath = path + ".lock"
            let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

            let expectation = XCTestExpectation(description: "withLock succeeds once released")
            let start = Date()
            var elapsed: TimeInterval = 0
            DispatchQueue.global().async {
                _ = try? ConfigFileLock.withLock(forConfigAt: path, pollInterval: 0.02, timeout: 3.0) { () }
                elapsed = Date().timeIntervalSince(start)
                expectation.fulfill()
            }

            Thread.sleep(forTimeInterval: 0.2)
            flock(fd, LOCK_UN)
            close(fd)

            wait(for: [expectation], timeout: 4.0)
            XCTAssertGreaterThanOrEqual(elapsed, 0.2, "withLock 應該一直輪詢到鎖被釋放才成功，不能無視既有的鎖")
        }
    }

    func testBodyThrowingErrorStillReleasesTheLock() throws {
        struct Boom: Error {}
        try withTempConfigPath { path in
            XCTAssertThrowsError(
                try ConfigFileLock.withLock(forConfigAt: path) { throw Boom() }
            )
            // 鎖必須已被釋放，下一次取得不該逾時。
            let result = try ConfigFileLock.withLock(forConfigAt: path, timeout: 0.5) { 1 }
            XCTAssertEqual(result, 1)
        }
    }

    private func withTempConfigPath(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json").path
        try body(path)
    }
}
