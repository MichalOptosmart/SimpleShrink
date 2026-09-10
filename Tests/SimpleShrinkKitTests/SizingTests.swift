// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Testing

@testable import SimpleShrinkKit

@Suite("Target size")
struct SizingTests {
    @Test("The requested free space is added to the estimated minimum")
    func addsRequestedMargin() {
        // 1 GiB minimum in 4 KiB blocks; 5 % of that is 52 MiB, so 64 MiB wins.
        let target = Sizing.targetBlocks(
            minimumBlocks: 262_144, blockSize: 4096, freeSpaceMiB: 64)
        #expect(target == 262_144 + 16_384)
    }

    @Test("On a large filesystem the proportional 5 % margin wins instead")
    func proportionalMarginWins() {
        // 8 GiB minimum: 5 % is 409 MiB, well past the 64 MiB default.
        let target = Sizing.targetBlocks(
            minimumBlocks: 2_097_152, blockSize: 4096, freeSpaceMiB: 64)
        #expect(target > 2_097_152 + 100_000)
    }

    @Test("Each retry grows the margin by half")
    func retriesGrowTheMargin() {
        let first = Sizing.targetBlocks(minimumBlocks: 262_144, blockSize: 4096, freeSpaceMiB: 64)
        let second = Sizing.targetBlocks(
            minimumBlocks: 262_144, blockSize: 4096, freeSpaceMiB: 64, attempt: 1)
        let third = Sizing.targetBlocks(
            minimumBlocks: 262_144, blockSize: 4096, freeSpaceMiB: 64, attempt: 2)
        #expect(second > first)
        #expect(third > second)
        #expect(second - 262_144 == (first - 262_144) * 3 / 2)
    }

    @Test("A gain under 32 MiB is not worth rewriting the image for")
    func skipsTinyGains() {
        #expect(
            !Sizing.isWorthwhile(currentBlocks: 100_000, targetBlocks: 99_000, blockSize: 4096))
        #expect(
            Sizing.isWorthwhile(currentBlocks: 100_000, targetBlocks: 80_000, blockSize: 4096))
        #expect(
            !Sizing.isWorthwhile(currentBlocks: 100_000, targetBlocks: 120_000, blockSize: 4096))
    }

    @Test("Sector counts round up, so the partition always covers the whole filesystem")
    func sectorCountRoundsUp() {
        #expect(Sizing.sectorCount(blockCount: 10, blockSize: 4096) == 80)
        #expect(Sizing.sectorCount(blockCount: 1, blockSize: 1024) == 2)
        #expect(Sizing.sectorCount(blockCount: 3, blockSize: 1000) == 6)
    }

    @Test("Byte counts are formatted the way the report quotes them")
    func formatsBytes() {
        #expect(Sizing.humanBytes(512) == "512 B")
        #expect(Sizing.humanBytes(2 * 1024 * 1024) == "2.00 MiB")
        #expect(Sizing.humanBytes(13_286_604_800) == "12.37 GiB")
    }
}
