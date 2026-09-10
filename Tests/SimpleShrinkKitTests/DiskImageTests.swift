// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation
import Testing

@testable import SimpleShrinkKit

@Suite("Image file")
struct DiskImageTests {
    /// A sparse file with a real partition table and nothing else — enough to exercise
    /// everything SimpleShrink does to the file itself.
    static func makeImage(_ name: String = "image.img") throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "simpleshrink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(MBRBuilder.raspberryPi))
        try handle.truncate(atOffset: MBRBuilder.imageBytes)
        try handle.close()
        return url
    }

    @Test("Opening an image reads its partition table")
    func opensAndParses() throws {
        let url = try DiskImageTests.makeImage()
        let image = try DiskImage(path: url)
        defer { image.closeFile() }
        #expect(image.fileSize == MBRBuilder.imageBytes)
        #expect(image.mbr.usedPartitions.count == 2)
    }

    @Test("A second run cannot start on an image that is already being worked on")
    func locksExclusively() throws {
        let url = try DiskImageTests.makeImage()
        let first = try ImageLock(image: url)
        #expect(throws: ShrinkError.self) { try ImageLock(image: url) }
        first.release()
        // Once the first run is done the next one may start.
        let second = try ImageLock(image: url)
        second.release()
    }

    @Test("The lock lives beside the caches, not beside the user's image")
    func lockFileIsOutOfTheWay() throws {
        let url = try DiskImageTests.makeImage()
        let lock = try ImageLock(image: url)
        defer { lock.release() }
        // hdiutil refuses to attach an image anyone holds an flock on, so the lock must
        // not be the image file — and it should not litter the user's directory either.
        #expect(lock.lockFileURL.deletingLastPathComponent() != url.deletingLastPathComponent())
        #expect(ImageLock.key(for: url) == ImageLock.key(for: url))
        #expect(ImageLock.key(for: url) != ImageLock.key(for: url.deletingLastPathComponent()))
    }

    @Test("Opening an image does not lock the file itself")
    func doesNotLockTheImageFile() throws {
        let url = try DiskImageTests.makeImage()
        let image = try DiskImage(path: url)
        defer { image.closeFile() }
        let fd = open(url.path, O_RDWR)
        defer { close(fd) }
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        flock(fd, LOCK_UN)
    }

    @Test("A missing file is a precondition failure, not a crash")
    func refusesMissingFile() {
        #expect(throws: ShrinkError.self) {
            try DiskImage(path: URL(filePath: "/tmp/simpleshrink-does-not-exist.img"))
        }
    }

    @Test("Shrinking rewrites the entry and truncates the file")
    func writesAndTruncates() throws {
        let url = try DiskImageTests.makeImage()
        let image = try DiskImage(path: url)
        let newSectors: UInt32 = 4_000_000
        try image.writeSectorCount(newSectors, forPartition: 2)
        try image.truncate(to: (532_480 + UInt64(newSectors)) * 512)
        image.closeFile()

        let reopened = try DiskImage(path: url)
        defer { reopened.closeFile() }
        #expect(reopened.mbr.partitions[1].sectorCount == newSectors)
        #expect(reopened.fileSize == (532_480 + 4_000_000) * 512)
    }

    @Test("Rollback puts the table back exactly as it was found")
    func rollsBack() throws {
        let url = try DiskImageTests.makeImage()
        let image = try DiskImage(path: url)
        let original = image.originalMBRBytes
        try image.writeSectorCount(1234, forPartition: 2)
        try image.restoreOriginalMBR()
        image.closeFile()

        let reopened = try DiskImage(path: url)
        defer { reopened.closeFile() }
        #expect(reopened.originalMBRBytes == original)
    }

    @Test("Copying for --output refuses to overwrite an existing file")
    func copyRefusesToOverwrite() throws {
        let source = try DiskImageTests.makeImage("source.img")
        let destination = source.deletingLastPathComponent().appending(path: "copy.img")
        try DiskImage.copy(from: source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(throws: ShrinkError.self) { try DiskImage.copy(from: source, to: destination) }
    }
}
