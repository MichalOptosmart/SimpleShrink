// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// Turns `resize2fs -P`'s estimate into the size we actually ask for.
public enum Sizing {
    /// Below this, a shrink is not worth rewriting the image for.
    public static let minimumGainBytes: UInt64 = 32 * 1024 * 1024

    /// Target size in filesystem blocks.
    ///
    /// `resize2fs -P` is an estimate and a known optimistic one, and a filesystem left at
    /// 100 % occupancy is slow, awkward to check, and gives the target system nothing to
    /// write to before its own expansion runs. So the minimum always gets slack: the
    /// larger of the requested free space and 5 % of the minimum.
    public static func targetBlocks(
        minimumBlocks: UInt64, blockSize: UInt64, freeSpaceMiB: UInt64, attempt: Int = 0
    ) -> UInt64 {
        let minimumBytes = minimumBlocks * blockSize
        let requested = freeSpaceMiB * 1024 * 1024
        let proportional = UInt64(Double(minimumBytes) * 0.05)
        var margin = max(requested, proportional)
        // Each retry after "New size smaller than minimum" grows the margin by half.
        for _ in 0..<attempt { margin = UInt64(Double(margin) * 1.5) }
        let marginBlocks = (margin + blockSize - 1) / blockSize
        return minimumBlocks + marginBlocks
    }

    /// Whether a shrink to `targetBlocks` buys enough to be worth doing.
    public static func isWorthwhile(
        currentBlocks: UInt64, targetBlocks: UInt64, blockSize: UInt64
    ) -> Bool {
        guard targetBlocks < currentBlocks else { return false }
        return (currentBlocks - targetBlocks) * blockSize >= minimumGainBytes
    }

    /// Sector count for the rewritten partition entry.
    /// Computed from the filesystem size `dumpe2fs` reports after the resize — never
    /// from the size we requested, because resize2fs rounds.
    public static func sectorCount(
        blockCount: UInt64, blockSize: UInt64, sectorSize: UInt64 = 512
    ) -> UInt64 {
        let bytes = blockCount * blockSize
        return (bytes + sectorSize - 1) / sectorSize
    }

    /// Formats a byte count the way the human report quotes it.
    public static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? "\(bytes) B" : String(format: "%.2f %@", value, units[unit])
    }
}
