// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// The image file itself: the partition table, and the two destructive operations
/// (rewrite the table, truncate the file).
///
/// No `flock` is taken on the image. `hdiutil attach` wants exclusive access to it and
/// refuses to attach a file anyone else has locked, so mutual exclusion between runs
/// lives in `ImageLock` instead, keyed by the image path.
public final class DiskImage {
    public let url: URL
    private let fd: Int32
    private var closed = false

    /// The partition table as it was when the file was opened. The pipeline restores
    /// this if anything between the first write and the truncation fails.
    public private(set) var originalMBRBytes: [UInt8]
    public private(set) var mbr: MBR

    public init(path: URL, readOnly: Bool = false) throws {
        url = path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ShrinkError.precondition("No such image file: \(path.path)")
        }

        let flags = readOnly ? O_RDONLY : O_RDWR
        let descriptor = open(path.path, flags)
        guard descriptor >= 0 else {
            throw ShrinkError.precondition(
                "Cannot open \(path.path): \(String(cString: strerror(errno)))")
        }
        fd = descriptor

        let sector = try DiskImage.read(fd: fd, offset: 0, count: MBR.sectorSize)
        originalMBRBytes = sector
        mbr = try MBR(raw: sector)
    }

    deinit { if !closed { close(fd) } }

    public var fileSize: UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        return UInt64(st.st_size)
    }

    /// Bytes actually allocated on disk. Images are usually sparse, so this is what
    /// the user gets back, and it is what the human report quotes.
    public var allocatedSize: UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        return UInt64(st.st_blocks) * 512
    }

    /// Rewrites one partition entry's sector count and flushes it to the platter.
    public func writeSectorCount(_ sectors: UInt32, forPartition index: Int) throws {
        let bytes = mbr.settingSectorCount(sectors, forPartition: index)
        try write(sector: bytes)
        mbr = try MBR(raw: bytes)
    }

    /// Puts the partition table back exactly as it was found.
    public func restoreOriginalMBR() throws {
        try write(sector: originalMBRBytes)
        mbr = try MBR(raw: originalMBRBytes)
    }

    public func truncate(to length: UInt64) throws {
        guard ftruncate(fd, off_t(length)) == 0 else {
            throw ShrinkError.failed(
                "Cannot truncate the image to \(length) bytes: \(String(cString: strerror(errno)))")
        }
        try flush()
    }

    public func flush() throws {
        guard fsync(fd) == 0 else {
            throw ShrinkError.failed("fsync failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Closes the descriptor. Safe to call twice.
    public func closeFile() {
        guard !closed else { return }
        close(fd)
        closed = true
    }

    private func write(sector bytes: [UInt8]) throws {
        precondition(bytes.count == MBR.sectorSize)
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, MBR.sectorSize, 0) }
        guard written == MBR.sectorSize else {
            throw ShrinkError.failed(
                "Cannot write the partition table: \(String(cString: strerror(errno)))")
        }
        try flush()
    }

    private static func read(fd: Int32, offset: off_t, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        guard got == count else {
            throw ShrinkError.unsupported("The image is too short to hold a partition table.")
        }
        return buffer
    }

    /// Copies an image before shrinking it, so an interrupted run cannot damage the source.
    /// On APFS this is a clone: instant, and it costs nothing until the copy diverges.
    public static func copy(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ShrinkError.precondition("The output file already exists: \(destination.path)")
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ShrinkError.failed(
                "Cannot copy \(source.path) to \(destination.path): \(error.localizedDescription)")
        }
    }
}
