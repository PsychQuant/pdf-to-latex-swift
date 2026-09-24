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

    /// 只有競爭（EWOULDBLOCK／EAGAIN）會輪詢、EINTR 立即重試；其他 flock
    /// 失敗必須立刻拋出並帶 errno，不能被當成競爭等到逾時（macdoc#204）。
    func testNonContentionFlockFailureThrowsImmediatelyWithItsErrno() throws {
        try withTempConfigPath { path in
            let started = DispatchTime.now().uptimeNanoseconds
            XCTAssertThrowsError(
                try ConfigFileLock.withLock(
                    forConfigAt: path, pollInterval: 0.05, timeout: 3,
                    acquire: { _, _ in errno = ENOLCK; return -1 }
                ) { XCTFail("沒拿到鎖不能執行 body") }
            ) { error in
                XCTAssertFalse(error is ConfigFileLock.TimeoutError, "非競爭失敗不能被當成逾時：\(error)")
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, "PDFToLaTeXCore.ConfigFileLock")
                XCTAssertEqual(nsError.code, Int(ENOLCK))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            XCTAssertLessThan(elapsed, 1, "不能等滿逾時時間")
        }
    }

    /// 鎖檔權限無法設為 0600 時，必須在任何取鎖之前帶原 errno 拋出（macdoc#204）。
    func testFailedFchmodThrowsWithItsErrnoBeforeLocking() throws {
        try withTempConfigPath { path in
            var attempts = 0
            XCTAssertThrowsError(
                try ConfigFileLock.withLock(
                    forConfigAt: path, pollInterval: 0.01, timeout: 1,
                    acquire: { fd, operation in attempts += 1; return flock(fd, operation) },
                    setMode: { _, _ in errno = EPERM; return -1 }
                ) { XCTFail("鎖檔權限無法確保時不能執行 body") }
            ) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, "PDFToLaTeXCore.ConfigFileLock")
                XCTAssertEqual(nsError.code, Int(EPERM))
            }
            XCTAssertEqual(attempts, 0, "權限失敗後不能再嘗試取鎖")
        }
    }

    func testInterruptedFlockIsRetriedAndContentionIsPolled() throws {
        try withTempConfigPath { path in
            var attempts = 0
            let results: [Int32] = [EINTR, EWOULDBLOCK, EAGAIN]
            let value = try ConfigFileLock.withLock(
                forConfigAt: path, pollInterval: 0.01, timeout: 3,
                acquire: { fd, operation in
                    defer { attempts += 1 }
                    if attempts < results.count { errno = results[attempts]; return -1 }
                    return flock(fd, operation)
                }
            ) { 42 }
            XCTAssertEqual(value, 42)
            XCTAssertEqual(attempts, 4)
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
