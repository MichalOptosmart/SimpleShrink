// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
//
// The order of the stages is the safety property of this tool. Everything that can
// fail happens while the image is still fully valid; the partition table is rewritten
// and the file truncated only after a clean detach, and those two steps — the only
// destructive ones — are separated by an fsync and covered by a rollback.

import Foundation

public final class ShrinkPipeline: @unchecked Sendable {
    private let tools: E2fsprogs
    private let sink: any EventSink
    private let progress = Locked(ProgressModel())

    public init(tools: E2fsprogs, sink: any EventSink) {
        self.tools = tools
        self.sink = sink
    }

    /// Runs a request end to end. Throws `ShrinkError`; the caller turns that into the
    /// terminal event and the exit code.
    public func run(_ request: ShrinkRequest) throws -> ShrinkReport {
        try request.validate()
        let options = request.options

        // MARK: open
        report(.open, 0, "Opening the image")
        let source = URL(filePath: request.input.path).standardizedFileURL
        var target = source
        if let outputPath = options.outputPath, !options.dryRun {
            target = URL(filePath: outputPath).standardizedFileURL
            sink.log(.info, "Copying \(source.path) to \(target.path)")
            try DiskImage.copy(from: source, to: target)
        }

        // One run per image. The lock is held for the whole pipeline, so the stale
        // attachment found below can only be one nobody is using any more.
        let lock = try ImageLock(image: target)
        defer { lock.release() }

        // A run that was killed rather than asked to stop leaves an attachment behind.
        try HDIUtil.detachStaleAttachment(of: target)

        let image = try DiskImage(path: target, readOnly: options.dryRun)
        defer { image.closeFile() }
        let bytesBefore = image.fileSize
        let layout = try PartitionLayout.resolve(image.mbr, imageBytes: bytesBefore)
        sink.log(
            .debug,
            "Root partition \(layout.root.index) at LBA \(layout.root.startLBA), "
                + "\(layout.root.sectorCount) sectors")

        // MARK: attach
        try Cancellation.shared.check()
        report(.attach, 0, "Attaching the image")
        let attachment = try HDIUtil.attach(image: target, readOnly: options.dryRun)
        defer { attachment.close() }
        AttachmentRegistry.shared.register(attachment)
        defer { AttachmentRegistry.shared.forget(attachment) }

        guard let rootDevice = attachment.device(forPartition: layout.root.index) else {
            throw ShrinkError.failed(
                "macOS did not expose partition \(layout.root.index) as a device node.")
        }

        // MARK: probe
        try Cancellation.shared.check()
        report(.probe, 0, "Reading the filesystem")
        let before = try tools.superblock(device: rootDevice)
        try refuseUnsupported(before)

        if options.dryRun {
            return try plan(
                image: target, superblock: before, layout: layout, options: options,
                rootDevice: rootDevice, bytesBefore: bytesBefore)
        }

        // MARK: check
        try Cancellation.shared.check()
        report(.check, 0, "Checking the filesystem")
        let outcome = try tools.check(device: rootDevice) { [weak self] fraction in
            self?.report(.check, fraction)
        }
        if outcome.errorsCorrected {
            sink.log(.warning, "e2fsck corrected errors on the root filesystem.")
        }

        // MARK: minimum size
        report(.probe, 1, "Estimating the minimum size")
        let minimumBlocks = try tools.minimumBlocks(device: rootDevice)
        let firstTarget = Sizing.targetBlocks(
            minimumBlocks: minimumBlocks, blockSize: before.blockSize,
            freeSpaceMiB: options.freeSpaceMiB)

        guard
            Sizing.isWorthwhile(
                currentBlocks: before.blockCount, targetBlocks: firstTarget,
                blockSize: before.blockSize)
        else {
            sink.log(.info, "The filesystem is already close to its minimum; nothing to do.")
            report(.done, 1, "Nothing to do")
            return ShrinkReport(
                status: .skipped, imagePath: target.path, bytesBefore: bytesBefore,
                bytesAfter: bytesBefore, filesystemBlocksBefore: before.blockCount,
                filesystemBlocksAfter: before.blockCount, blockSize: before.blockSize,
                expansionArmed: .none)
        }

        // MARK: resize
        try Cancellation.shared.check()
        report(.resize, 0, "Resizing the filesystem")
        try resize(
            device: rootDevice, image: target, layout: layout, superblock: before,
            minimumBlocks: minimumBlocks, options: options)

        // MARK: verify
        try Cancellation.shared.check()
        report(.verify, 0, "Verifying the filesystem")
        try tools.check(device: rootDevice) { [weak self] fraction in
            self?.report(.verify, fraction)
        }
        let after = try tools.superblock(device: rootDevice)
        guard after.blockCount < before.blockCount else {
            throw ShrinkError.failed(
                "The filesystem did not shrink (still \(after.blockCount) blocks).")
        }

        // MARK: arm
        var warnings: [String] = []
        var armed = ExpansionStrategy.none
        if options.expansion != .none {
            try Cancellation.shared.check()
            report(.arm, 0, "Arming first-boot expansion")
            if let boot = layout.boot, let bootDevice = attachment.device(forPartition: boot.index) {
                let expansion = Expansion(tools: tools, sink: sink)
                do {
                    let result = try expansion.arm(
                        strategy: options.expansion, bootDevice: bootDevice, rootDevice: rootDevice)
                    armed = result.armed
                    warnings += result.warnings
                } catch let error as ShrinkError {
                    // A shrunk image is still useful; not arming it is a warning, not a failure.
                    warnings.append("First-boot expansion could not be armed: \(error.message)")
                    sink.log(.warning, warnings.last!)
                }
            } else {
                warnings.append(
                    "No FAT boot partition found, so first-boot expansion could not be armed. "
                        + "Expand the root filesystem yourself after writing the image.")
                sink.log(.warning, warnings.last!)
            }
        }

        // MARK: detach
        report(.detach, 0, "Detaching")
        attachment.close()
        AttachmentRegistry.shared.forget(attachment)

        // MARK: partition, truncate
        // Past this point the image is briefly inconsistent, so both steps are wrapped
        // in a rollback that restores the partition table exactly as it was found.
        let sectors = Sizing.sectorCount(blockCount: after.blockCount, blockSize: after.blockSize)
        guard sectors <= UInt64(UInt32.max), sectors <= UInt64(layout.root.sectorCount) else {
            throw ShrinkError.failed(
                "Refusing to write an implausible sector count (\(sectors)) to the partition table.")
        }

        report(.partition, 0, "Rewriting the partition table")
        do {
            try image.writeSectorCount(UInt32(sectors), forPartition: layout.root.index)
            report(.truncate, 0, "Truncating the image")
            let newLength = (UInt64(layout.root.startLBA) + sectors) * 512
            try image.truncate(to: newLength)
        } catch {
            sink.log(.error, "Rolling back the partition table.")
            try? image.restoreOriginalMBR()
            throw error
        }

        let bytesAfter = image.fileSize
        report(.done, 1, "Done")
        return ShrinkReport(
            status: .ok, imagePath: target.path, bytesBefore: bytesBefore, bytesAfter: bytesAfter,
            filesystemBlocksBefore: before.blockCount, filesystemBlocksAfter: after.blockCount,
            blockSize: after.blockSize, expansionArmed: armed, warnings: warnings)
    }

    // MARK: - Steps

    /// Asks for the target size, and answers an optimistic `resize2fs -P` estimate by
    /// retrying with a larger margin rather than giving up.
    private func resize(
        device: String, image: URL, layout: PartitionLayout, superblock: Ext2Superblock,
        minimumBlocks: UInt64, options: ShrinkOptions
    ) throws {
        for attempt in 0..<3 {
            try Cancellation.shared.check()
            let target = Sizing.targetBlocks(
                minimumBlocks: minimumBlocks, blockSize: superblock.blockSize,
                freeSpaceMiB: options.freeSpaceMiB, attempt: attempt)
            guard target < superblock.blockCount else {
                throw ShrinkError.failed(
                    "The margin has grown past the current filesystem size; nothing to shrink.")
            }
            sink.log(.info, "Resizing to \(target) blocks (attempt \(attempt + 1) of 3).")

            let succeeded: Bool
            if options.extractMode {
                succeeded = try resizeViaScratchFile(
                    image: image, layout: layout, superblock: superblock, toBlocks: target)
            } else {
                succeeded = try tools.resize(device: device, toBlocks: target) {
                    [weak self] fraction in
                    self?.report(.resize, fraction)
                }
            }
            if succeeded { return }
            sink.log(.warning, "resize2fs refused that size; retrying with a larger margin.")
        }
        throw ShrinkError.failed(
            "resize2fs would not shrink the filesystem after three attempts.",
            recovery: "Try again with a larger --free-space value.")
    }

    /// `--extract-mode`: copy the partition out, resize it as a plain file, copy it back.
    private func resizeViaScratchFile(
        image: URL, layout: PartitionLayout, superblock: Ext2Superblock, toBlocks target: UInt64
    ) throws -> Bool {
        try PartitionExtractor.withScratchDirectory { directory in
            let scratch = directory.appending(path: "root.img")
            sink.log(.info, "Extracting partition \(layout.root.index) to scratch space.")
            try PartitionExtractor.extract(
                from: image, startLBA: layout.root.startLBA, sectorCount: layout.root.sectorCount,
                to: scratch
            ) { [weak self] fraction in self?.report(.resize, fraction * 0.3) }

            guard
                try tools.resize(device: scratch.path, toBlocks: target, onProgress: {
                    [weak self] fraction in self?.report(.resize, 0.3 + fraction * 0.4)
                })
            else { return false }

            try tools.check(device: scratch.path)
            let resized = try tools.superblock(device: scratch.path)
            try PartitionExtractor.writeBack(
                from: scratch, to: image, startLBA: layout.root.startLBA,
                byteCount: resized.blockCount * resized.blockSize
            ) { [weak self] fraction in self?.report(.resize, 0.7 + fraction * 0.3) }
            return true
        }
    }

    /// `--dry-run`: everything up to the first write, reported as a plan.
    private func plan(
        image: URL, superblock: Ext2Superblock, layout: PartitionLayout, options: ShrinkOptions,
        rootDevice: String, bytesBefore: UInt64
    ) throws -> ShrinkReport {
        var warnings: [String] = []
        var targetBlocks = superblock.blockCount

        if superblock.isClean, let minimum = try? tools.minimumBlocks(device: rootDevice) {
            targetBlocks = Sizing.targetBlocks(
                minimumBlocks: minimum, blockSize: superblock.blockSize,
                freeSpaceMiB: options.freeSpaceMiB)
        } else {
            warnings.append(
                "The filesystem needs a check before its minimum size can be estimated; "
                    + "a real run would run e2fsck first.")
        }

        let expansion = Expansion(tools: tools, sink: sink)
        let strategy = options.expansion == .auto
            ? expansion.detectStrategy(rootDevice: rootDevice) : options.expansion
        let bytesAfter = (UInt64(layout.root.startLBA) * 512)
            + Sizing.sectorCount(blockCount: targetBlocks, blockSize: superblock.blockSize) * 512

        report(.done, 1, "Planned")
        return ShrinkReport(
            status: .planned, imagePath: image.path, bytesBefore: bytesBefore,
            bytesAfter: min(bytesAfter, bytesBefore), filesystemBlocksBefore: superblock.blockCount,
            filesystemBlocksAfter: targetBlocks, blockSize: superblock.blockSize,
            expansionArmed: strategy, warnings: warnings)
    }

    /// Everything we refuse before touching the filesystem, each with its own message.
    private func refuseUnsupported(_ superblock: Ext2Superblock) throws {
        if superblock.hasExternalJournal {
            throw ShrinkError.unsupported(
                "The root filesystem uses an external journal, which cannot be resized here.")
        }
        let unknown = superblock.unknownFeatures
        if !unknown.isEmpty {
            throw ShrinkError.unsupported(
                "The filesystem uses features this build does not know how to resize: "
                    + unknown.joined(separator: ", "),
                recovery: "Shrink the image on a Linux host with a newer e2fsprogs.")
        }
    }

    private func report(_ stage: Stage, _ within: Double, _ message: String? = nil) {
        let fraction = progress.withLock { $0.fraction(for: stage, within: within) }
        sink.progress(stage, fraction, message)
    }
}

/// Every live attachment, so the signal handler can detach what the pipeline owns.
///
/// A leaked attachment is the worst failure mode this tool has: it holds the image
/// open, confuses the next run, and outlives the process that made it.
public final class AttachmentRegistry: @unchecked Sendable {
    public static let shared = AttachmentRegistry()
    private let attachments = Locked<[AttachedImage]>([])

    func register(_ attachment: AttachedImage) {
        attachments.withLock { $0.append(attachment) }
    }

    func forget(_ attachment: AttachedImage) {
        attachments.withLock { $0.removeAll { $0 === attachment } }
    }

    /// Detaches everything. Called from the SIGTERM/SIGINT handler.
    public func detachAll() {
        let live = attachments.withLock { current -> [AttachedImage] in
            defer { current = [] }
            return current
        }
        for attachment in live { attachment.close() }
    }
}
