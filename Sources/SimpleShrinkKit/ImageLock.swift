// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import CryptoKit
import Foundation

/// Mutual exclusion between SimpleShrink runs working on the same image.
///
/// The lock is held on a file in the user's cache directory, **not on the image**:
/// `hdiutil attach` needs exclusive access to the image file and fails with
/// "Resource temporarily unavailable" if anyone else — us included — holds an `flock`
/// on it. Keying the lock by the resolved image path gives the same guarantee without
/// standing in hdiutil's way, and leaves no stray file next to the user's image.
public final class ImageLock {
    private let fd: Int32
    private var released = false

    public let lockFileURL: URL

    public init(image: URL) throws {
        let directory = ImageLock.lockDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockFileURL = directory.appending(path: ImageLock.key(for: image) + ".lock")

        fd = open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw ShrinkError.precondition(
                "Cannot create the lock file \(lockFileURL.path): "
                    + String(cString: strerror(errno)))
        }
        // Non-blocking: a busy image is a precondition failure, not something to wait on.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ShrinkError.precondition(
                "Another SimpleShrink run is already working on this image.",
                recovery: "Wait for it to finish, then try again."
            )
        }
    }

    deinit { release() }

    public func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
    }

    static var lockDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        return caches.appending(path: "\(SimpleShrink.identifier)/locks")
    }

    /// A stable name for an image path. Stable across processes and machines, which
    /// `hashValue` is not — Swift's hashing is seeded per process.
    static func key(for image: URL) -> String {
        let path = image.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
