import Darwin
import Foundation

/// Cross-process advisory lock protecting `~/.config/macdoc/config.json`
/// from concurrent read-modify-write races between its multiple writers
/// (macdoc#204).
///
/// The **other writer** of this same file is `DocumentProfileStore.updateDocument`
/// in `ooxml-swift` (`Sources/OOXMLSwift/Models/DocumentProfileStore.swift`).
/// That type persists document-formatting-profile settings into the very
/// same `~/.config/macdoc/config.json` that `AIConfig.save()` (this
/// package) persists AI-CLI/OCR settings into. Both do a
/// read-existing-file -> merge-in-own-fields -> atomic-write cycle; without
/// a shared lock those two cycles can interleave and one writer's atomic
/// write can silently discard the other's concurrently-written update.
///
/// **Protocol — this MUST stay byte-for-byte identical between the two
/// implementations, or the lock stops protecting anything:**
/// - Lock file path: `<config path>.lock` (sibling of the config file).
/// - Open with `O_CREAT | O_RDWR | O_CLOEXEC`, mode `0o600`.
/// - Acquire with `flock(fd, LOCK_EX | LOCK_NB)`, polled every 50 ms.
/// - Give up and throw after 5 seconds of polling, measured on a monotonic
///   clock. Only EWOULDBLOCK/EAGAIN (contention) is polled and EINTR
///   retried at once; any other errno is thrown immediately with that errno.
/// - Hold the lock across the *entire* read -> merge -> atomic-write
///   critical section, not just the write.
/// - Release with `flock(fd, LOCK_UN)`, then close the file descriptor.
/// - Never delete the lock file. A deleted-then-recreated lock file would
///   be a different inode, breaking the invariant that every writer is
///   flocking the same file.
enum ConfigFileLock {
    /// Thrown when the exclusive lock could not be acquired before `timeout`
    /// elapsed because another writer is still holding it.
    struct TimeoutError: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "無法在時限內取得設定檔鎖（另一個程序持有鎖）: \(path)"
        }
    }

    /// Default poll interval while waiting for the lock, per protocol.
    static let defaultPollInterval: TimeInterval = 0.05
    /// Default time to wait before giving up, per protocol.
    static let defaultTimeout: TimeInterval = 5.0

    /// Acquires an exclusive advisory lock on `<path>.lock`, runs `body`
    /// while holding it, then releases the lock (the lock file itself is
    /// never deleted). `pollInterval`/`timeout`/`acquire` are injectable for
    /// tests; production callers should use the defaults.
    static func withLock<T>(
        forConfigAt path: String,
        pollInterval: TimeInterval = ConfigFileLock.defaultPollInterval,
        timeout: TimeInterval = ConfigFileLock.defaultTimeout,
        acquire: (Int32, Int32) -> Int32 = { flock($0, $1) },
        _ body: () throws -> T
    ) throws -> T {
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            throw NSError(
                domain: "PDFToLaTeXCore.ConfigFileLock", code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "無法開啟鎖檔: \(lockPath)（errno \(err)）"])
        }
        defer { close(fd) }
        // Guarantee 0600 regardless of the caller's umask; the mode passed
        // to open() above is only a request, not a guarantee.
        _ = fchmod(fd, 0o600)

        // The budget runs on a monotonic clock: a wall-clock change cannot
        // stretch or cut the wait.
        let start = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(max(0, timeout) * 1_000_000_000)
        while acquire(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            // Only contention is waited out; EINTR is retried at once. Any
            // other failure is not contention and is reported immediately.
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw NSError(
                    domain: "PDFToLaTeXCore.ConfigFileLock", code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "無法鎖定鎖檔: \(lockPath)（errno \(code)）"])
            }
            if DispatchTime.now().uptimeNanoseconds - start >= budget {
                throw TimeoutError(path: lockPath)
            }
            if code != EINTR { Thread.sleep(forTimeInterval: pollInterval) }
        }
        defer { flock(fd, LOCK_UN) }

        return try body()
    }
}
