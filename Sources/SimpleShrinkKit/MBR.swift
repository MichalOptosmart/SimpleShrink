// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// A cylinder/head/sector triple. Stored, never interpreted: modern images carry
/// the 0xFE 0xFF 0xFF overflow marker and every consumer that matters ignores CHS.
public struct CHS: Equatable, Sendable {
    public var bytes: (UInt8, UInt8, UInt8)

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8) { bytes = (a, b, c) }

    public static func == (lhs: CHS, rhs: CHS) -> Bool { lhs.bytes == rhs.bytes }
}

/// One 16-byte entry of a master boot record.
public struct MBRPartition: Equatable, Sendable {
    /// 1-based slot in the table, matching the `sN` suffix macOS gives the slice.
    public let index: Int
    public var bootFlag: UInt8
    public var chsStart: CHS
    public var type: UInt8
    public var chsEnd: CHS
    public var startLBA: UInt32
    public var sectorCount: UInt32

    public var isEmpty: Bool { type == 0 && sectorCount == 0 }
    public var endLBA: UInt64 { UInt64(startLBA) + UInt64(sectorCount) }

    public var isFAT: Bool { [0x01, 0x04, 0x06, 0x0B, 0x0C, 0x0E].contains(type) }
    public var isLinux: Bool { type == 0x83 }
    public var isExtended: Bool { [0x05, 0x0F, 0x85].contains(type) }
    public var isGPTProtective: Bool { type == 0xEE }

    /// Human label for the type byte, for `inspect` output and messages.
    public var typeName: String {
        switch type {
        case 0x00: "empty"
        case 0x01: "fat12"
        case 0x04, 0x06: "fat16"
        case 0x05, 0x0F, 0x85: "extended"
        case 0x0B, 0x0C: "fat32"
        case 0x0E: "fat16-lba"
        case 0x82: "linux-swap"
        case 0x83: "linux"
        case 0xEE: "gpt-protective"
        default: String(format: "0x%02x", type)
        }
    }
}

/// A parsed master boot record. Keeps the original 512 bytes so a rewrite touches
/// only the fields we mean to change — bootstrap code and disk signature included.
public struct MBR: Equatable, Sendable {
    public static let sectorSize = 512
    public static let firstEntryOffset = 0x1BE
    public static let entrySize = 16

    public let raw: [UInt8]
    public let partitions: [MBRPartition]

    public init(raw bytes: [UInt8]) throws {
        guard bytes.count >= MBR.sectorSize else {
            throw ShrinkError.unsupported("The file is shorter than one 512-byte sector.")
        }
        let sector = Array(bytes.prefix(MBR.sectorSize))
        guard sector[0x1FE] == 0x55, sector[0x1FF] == 0xAA else {
            throw ShrinkError.unsupported(
                "No MBR signature (0x55AA) at offset 0x1FE — this is not an MBR-partitioned image.",
                recovery: "SimpleShrink 1.x handles MBR images only; GPT images are not supported."
            )
        }
        raw = sector
        partitions = (0..<4).map { slot in
            let base = MBR.firstEntryOffset + slot * MBR.entrySize
            return MBRPartition(
                index: slot + 1,
                bootFlag: sector[base],
                chsStart: CHS(sector[base + 1], sector[base + 2], sector[base + 3]),
                type: sector[base + 4],
                chsEnd: CHS(sector[base + 5], sector[base + 6], sector[base + 7]),
                startLBA: MBR.readLE32(sector, base + 8),
                sectorCount: MBR.readLE32(sector, base + 12)
            )
        }
    }

    public var usedPartitions: [MBRPartition] { partitions.filter { !$0.isEmpty } }

    /// A copy of the record with one entry's sector count replaced. Nothing else moves.
    public func settingSectorCount(_ count: UInt32, forPartition index: Int) -> [UInt8] {
        precondition((1...4).contains(index))
        var bytes = raw
        let field = MBR.firstEntryOffset + (index - 1) * MBR.entrySize + 12
        MBR.writeLE32(&bytes, field, count)
        return bytes
    }

    static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func writeLE32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

/// The two partitions SimpleShrink cares about, once the table has been vetted.
public struct PartitionLayout: Sendable {
    /// FAT partition holding the boot configuration, when the image has one.
    public let boot: MBRPartition?
    /// The Linux partition that will be shrunk: the last one on the medium.
    public let root: MBRPartition

    /// Vets a partition table and picks the boot and root partitions.
    ///
    /// Everything ambiguous is refused rather than guessed at — this tool truncates
    /// files, and a wrong guess costs the user their image.
    public static func resolve(_ mbr: MBR, imageBytes: UInt64, sectorSize: Int = 512) throws -> PartitionLayout {
        let used = mbr.usedPartitions

        if used.count == 1, used[0].isGPTProtective {
            throw ShrinkError.unsupported(
                "This is a GPT image (the MBR is protective only).",
                recovery: "GPT support is not part of version 1."
            )
        }
        if let extended = used.first(where: { $0.isExtended }) {
            throw ShrinkError.unsupported(
                "Partition \(extended.index) is an extended partition, which is not supported."
            )
        }
        guard !used.isEmpty else {
            throw ShrinkError.unsupported("The partition table is empty.")
        }

        for (a, b) in pairs(of: used) where a.startLBA < b.endLBA && b.startLBA < a.endLBA {
            throw ShrinkError.unsupported(
                "Partitions \(a.index) and \(b.index) overlap; refusing to touch this table."
            )
        }

        let linux = used.filter(\.isLinux)
        guard let root = linux.max(by: { $0.startLBA < $1.startLBA }) else {
            throw ShrinkError.unsupported(
                "No Linux partition (type 0x83) found.",
                recovery: "SimpleShrink shrinks the ext2/3/4 root filesystem of a Linux image."
            )
        }

        let lastByLBA = used.max(by: { $0.startLBA < $1.startLBA })!
        guard lastByLBA.index == root.index else {
            throw ShrinkError.unsupported(
                "The Linux partition is not the last partition on the medium "
                    + "(partition \(lastByLBA.index) starts after it).",
                recovery: "Shrinking would leave the following partition stranded past the end of the file."
            )
        }

        let neededBytes = root.endLBA * UInt64(sectorSize)
        guard neededBytes <= imageBytes else {
            throw ShrinkError.unsupported(
                "Partition \(root.index) claims to end at \(neededBytes) bytes but the image is "
                    + "only \(imageBytes) bytes — the image is truncated or the table is wrong."
            )
        }

        return PartitionLayout(boot: used.first(where: { $0.isFAT }), root: root)
    }

    private static func pairs(of items: [MBRPartition]) -> [(MBRPartition, MBRPartition)] {
        var result: [(MBRPartition, MBRPartition)] = []
        for i in items.indices {
            for j in items.index(after: i)..<items.endIndex {
                result.append((items[i], items[j]))
            }
        }
        return result
    }
}
