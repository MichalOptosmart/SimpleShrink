// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation
import Testing

@testable import SimpleShrinkKit

/// Builds a partition table by hand, the way the fixtures do.
enum MBRBuilder {
    struct Entry {
        var type: UInt8
        var startLBA: UInt32
        var sectors: UInt32
        var bootFlag: UInt8 = 0
    }

    static func sector(_ entries: [Entry], signature: Bool = true) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        // Something recognisable in the bootstrap area, so rewrites can be shown not to touch it.
        for index in 0..<440 { bytes[index] = UInt8(index % 251) }
        for (slot, entry) in entries.prefix(4).enumerated() {
            let base = MBR.firstEntryOffset + slot * MBR.entrySize
            bytes[base] = entry.bootFlag
            bytes[base + 1] = 0xFE
            bytes[base + 2] = 0xFF
            bytes[base + 3] = 0xFF
            bytes[base + 4] = entry.type
            bytes[base + 5] = 0xFE
            bytes[base + 6] = 0xFF
            bytes[base + 7] = 0xFF
            MBR.writeLE32(&bytes, base + 8, entry.startLBA)
            MBR.writeLE32(&bytes, base + 12, entry.sectors)
        }
        if signature {
            bytes[0x1FE] = 0x55
            bytes[0x1FF] = 0xAA
        }
        return bytes
    }

    /// A typical Raspberry Pi image: 256 MiB FAT32 boot, ext4 root filling the rest.
    static let raspberryPi = sector([
        Entry(type: 0x0C, startLBA: 8192, sectors: 524_288),
        Entry(type: 0x83, startLBA: 532_480, sectors: 25_417_728),
    ])

    static let imageBytes: UInt64 = (532_480 + 25_417_728) * 512
}

@Suite("Partition table")
struct MBRTests {
    @Test("A well-formed table parses into four slots, two of them used")
    func parsesEntries() throws {
        let mbr = try MBR(raw: MBRBuilder.raspberryPi)
        #expect(mbr.partitions.count == 4)
        #expect(mbr.usedPartitions.count == 2)

        let boot = mbr.partitions[0]
        #expect(boot.isFAT)
        #expect(boot.typeName == "fat32")
        #expect(boot.startLBA == 8192)

        let root = mbr.partitions[1]
        #expect(root.isLinux)
        #expect(root.sectorCount == 25_417_728)
        #expect(root.endLBA == 25_950_208)
    }

    @Test("A missing 0x55AA signature is refused, not guessed at")
    func requiresSignature() {
        let bytes = MBRBuilder.sector([.init(type: 0x83, startLBA: 2048, sectors: 1000)], signature: false)
        #expect(throws: ShrinkError.self) { try MBR(raw: bytes) }
    }

    @Test("Rewriting a sector count touches those four bytes and nothing else")
    func rewriteIsSurgical() throws {
        let mbr = try MBR(raw: MBRBuilder.raspberryPi)
        let updated = mbr.settingSectorCount(1_000_000, forPartition: 2)

        let differing = zip(mbr.raw, updated).enumerated().filter { $1.0 != $1.1 }.map(\.offset)
        let field = MBR.firstEntryOffset + MBR.entrySize + 12
        #expect(differing.allSatisfy { (field..<(field + 4)).contains($0) })

        let reparsed = try MBR(raw: updated)
        #expect(reparsed.partitions[1].sectorCount == 1_000_000)
        #expect(reparsed.partitions[1].startLBA == 532_480)
        #expect(reparsed.partitions[0] == mbr.partitions[0])
    }

    @Test("The last Linux partition is the root, and the FAT one is the boot partition")
    func resolvesLayout() throws {
        let mbr = try MBR(raw: MBRBuilder.raspberryPi)
        let layout = try PartitionLayout.resolve(mbr, imageBytes: MBRBuilder.imageBytes)
        #expect(layout.root.index == 2)
        #expect(layout.boot?.index == 1)
    }

    @Test("A GPT protective MBR is refused")
    func refusesGPT() throws {
        let mbr = try MBR(raw: MBRBuilder.sector([.init(type: 0xEE, startLBA: 1, sectors: 100)]))
        #expect(throws: ShrinkError.self) {
            try PartitionLayout.resolve(mbr, imageBytes: 512 * 101)
        }
    }

    @Test("An extended partition is refused")
    func refusesExtended() throws {
        let mbr = try MBR(
            raw: MBRBuilder.sector([
                .init(type: 0x0C, startLBA: 2048, sectors: 1000),
                .init(type: 0x05, startLBA: 4096, sectors: 1000),
                .init(type: 0x83, startLBA: 8192, sectors: 1000),
            ]))
        #expect(throws: ShrinkError.self) { try PartitionLayout.resolve(mbr, imageBytes: 512 * 9192) }
    }

    @Test("A root partition that is not last is refused — truncating would strand the one after it")
    func refusesRootNotLast() throws {
        let mbr = try MBR(
            raw: MBRBuilder.sector([
                .init(type: 0x83, startLBA: 2048, sectors: 1000),
                .init(type: 0x0C, startLBA: 8192, sectors: 1000),
            ]))
        #expect(throws: ShrinkError.self) { try PartitionLayout.resolve(mbr, imageBytes: 512 * 9192) }
    }

    @Test("Overlapping partitions are refused")
    func refusesOverlap() throws {
        let mbr = try MBR(
            raw: MBRBuilder.sector([
                .init(type: 0x0C, startLBA: 2048, sectors: 8000),
                .init(type: 0x83, startLBA: 4096, sectors: 8000),
            ]))
        #expect(throws: ShrinkError.self) { try PartitionLayout.resolve(mbr, imageBytes: 512 * 20000) }
    }

    @Test("A table claiming more sectors than the file holds is refused")
    func refusesTruncatedImage() throws {
        let mbr = try MBR(raw: MBRBuilder.raspberryPi)
        #expect(throws: ShrinkError.self) { try PartitionLayout.resolve(mbr, imageBytes: 1024 * 1024) }
    }

    @Test("An image with no Linux partition is refused")
    func refusesFATOnly() throws {
        let mbr = try MBR(raw: MBRBuilder.sector([.init(type: 0x0C, startLBA: 2048, sectors: 1000)]))
        #expect(throws: ShrinkError.self) { try PartitionLayout.resolve(mbr, imageBytes: 512 * 4000) }
    }
}
