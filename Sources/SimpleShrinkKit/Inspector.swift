// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// What `inspect` reports: enough for a host to decide whether to offer a shrink at
/// all, and what it would gain, without changing a byte.
public struct ImageReport: Encodable, Sendable {
    public struct Partition: Encodable, Sendable {
        public var index: Int
        public var type: String
        public var fs: String
        public var startLBA: UInt32
        public var sectors: UInt32
        public var bytes: UInt64
    }

    public struct Root: Encodable, Sendable {
        public var index: Int
        public var blockSize: UInt64
        public var blockCount: UInt64
        public var freeBlocks: UInt64
        public var minimumBlocks: UInt64?
        public var clean: Bool
        public var features: [String]
    }

    public var supported: Bool
    public var scheme: String
    public var sectorSize: Int
    public var imageBytes: UInt64
    public var partitions: [Partition]
    public var root: Root?
    public var estimatedBytesAfter: UInt64?
    public var expansionStrategy: ExpansionStrategy?
    public var alreadyArmed: Bool?
    /// True when the minimum size could not be estimated without repairing first.
    public var requiresCheck: Bool
    public var reason: String?
}

/// Read-only examination of an image.
///
/// `inspect` never modifies anything: it attaches read-only, asks `dumpe2fs` and
/// `resize2fs -P` — both of which only read — and detaches. If the filesystem is dirty
/// it reports `requiresCheck` rather than running a repair behind the user's back.
public struct Inspector {
    let tools: E2fsprogs

    public init(tools: E2fsprogs) { self.tools = tools }

    public func inspect(image path: URL, freeSpaceMiB: UInt64 = 64) throws -> ImageReport {
        let lock = try ImageLock(image: path)
        defer { lock.release() }

        let image = try DiskImage(path: path, readOnly: true)
        defer { image.closeFile() }
        let imageBytes = image.fileSize

        let partitions = image.mbr.usedPartitions.map { partition in
            ImageReport.Partition(
                index: partition.index,
                type: String(format: "0x%02x", partition.type),
                fs: partition.typeName,
                startLBA: partition.startLBA,
                sectors: partition.sectorCount,
                bytes: UInt64(partition.sectorCount) * 512)
        }

        let layout: PartitionLayout
        do {
            layout = try PartitionLayout.resolve(image.mbr, imageBytes: imageBytes)
        } catch let error as ShrinkError {
            return ImageReport(
                supported: false, scheme: "mbr", sectorSize: 512, imageBytes: imageBytes,
                partitions: partitions, root: nil, estimatedBytesAfter: nil,
                expansionStrategy: nil, alreadyArmed: nil, requiresCheck: false,
                reason: error.message)
        }

        try HDIUtil.detachStaleAttachment(of: path)
        let attachment = try HDIUtil.attach(image: path, readOnly: true)
        defer { attachment.close() }
        AttachmentRegistry.shared.register(attachment)
        defer { AttachmentRegistry.shared.forget(attachment) }

        guard let rootDevice = attachment.device(forPartition: layout.root.index) else {
            throw ShrinkError.failed(
                "macOS did not expose partition \(layout.root.index) as a device node.")
        }

        let superblock = try tools.superblock(device: rootDevice)
        let minimum = superblock.isClean ? try? tools.minimumBlocks(device: rootDevice) : nil

        var estimatedAfter: UInt64?
        if let minimum {
            let target = Sizing.targetBlocks(
                minimumBlocks: minimum, blockSize: superblock.blockSize,
                freeSpaceMiB: freeSpaceMiB)
            estimatedAfter =
                UInt64(layout.root.startLBA) * 512
                + Sizing.sectorCount(blockCount: target, blockSize: superblock.blockSize) * 512
        }

        let expansion = Expansion(tools: tools, sink: RecordingEventSink())
        let strategy = expansion.detectStrategy(rootDevice: rootDevice)

        return ImageReport(
            supported: superblock.unknownFeatures.isEmpty
                && !superblock.hasExternalJournal,
            scheme: "mbr",
            sectorSize: 512,
            imageBytes: imageBytes,
            partitions: partitions,
            root: ImageReport.Root(
                index: layout.root.index,
                blockSize: superblock.blockSize,
                blockCount: superblock.blockCount,
                freeBlocks: superblock.freeBlocks,
                minimumBlocks: minimum,
                clean: superblock.isClean,
                features: superblock.features),
            estimatedBytesAfter: estimatedAfter.map { min($0, imageBytes) },
            expansionStrategy: strategy,
            alreadyArmed: nil,
            requiresCheck: minimum == nil,
            reason: nil)
    }
}
