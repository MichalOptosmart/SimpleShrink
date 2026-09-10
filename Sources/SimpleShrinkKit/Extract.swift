// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// Copies a partition out of an image and back again.
///
/// This is the fallback path (`--extract-mode`): instead of running e2fsprogs against
/// the attached slice, the partition is copied to scratch space, resized there, and
/// copied back. It costs the partition's size in temporary space and two extra passes,
/// but it takes `hdiutil` out of the resize entirely — which also makes it the easiest
/// way to reproduce a suspected I/O bug outside the attach path.
public enum PartitionExtractor {
    static let chunkSize = 8 * 1024 * 1024

    /// Copies `sectorCount` sectors starting at `startLBA` into a new scratch file.
    public static func extract(
        from image: URL, startLBA: UInt32, sectorCount: UInt32, sectorSize: UInt64 = 512,
        to scratch: URL, onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let offset = UInt64(startLBA) * sectorSize
        let length = UInt64(sectorCount) * sectorSize

        guard FileManager.default.createFile(atPath: scratch.path, contents: nil) else {
            throw ShrinkError.precondition("Cannot create the scratch file \(scratch.path).")
        }
        let source = try FileHandle(forReadingFrom: image)
        let destination = try FileHandle(forWritingTo: scratch)
        defer {
            try? source.close()
            try? destination.close()
        }

        try source.seek(toOffset: offset)
        var copied: UInt64 = 0
        while copied < length {
            try Cancellation.shared.check()
            let want = Int(min(UInt64(chunkSize), length - copied))
            guard let chunk = try source.read(upToCount: want), !chunk.isEmpty else { break }
            try destination.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            onProgress?(Double(copied) / Double(length))
        }
        try destination.synchronize()
    }

    /// Copies a resized partition back into the image at its original offset.
    ///
    /// Only `byteCount` bytes are written — the filesystem is smaller than the file it
    /// was resized in, and the tail is no longer part of the partition.
    public static func writeBack(
        from scratch: URL, to image: URL, startLBA: UInt32, byteCount: UInt64,
        sectorSize: UInt64 = 512, onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let offset = UInt64(startLBA) * sectorSize
        let source = try FileHandle(forReadingFrom: scratch)
        let destination = try FileHandle(forUpdating: image)
        defer {
            try? source.close()
            try? destination.close()
        }

        try destination.seek(toOffset: offset)
        var copied: UInt64 = 0
        while copied < byteCount {
            let want = Int(min(UInt64(chunkSize), byteCount - copied))
            guard let chunk = try source.read(upToCount: want), !chunk.isEmpty else { break }
            try destination.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            onProgress?(Double(copied) / Double(byteCount))
        }
        try destination.synchronize()
    }

    /// A scratch directory that removes itself.
    public static func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "simpleshrink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}
