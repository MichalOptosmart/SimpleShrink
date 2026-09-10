// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// One device node produced by attaching an image.
public struct AttachedEntity: Sendable, Equatable {
    public let devEntry: String
    public let contentHint: String?
    public let mountPoint: String?

    /// `/dev/disk4s2` → 2. Nil for the whole-disk node.
    public var sliceIndex: Int? {
        guard let range = devEntry.range(of: "s", options: .backwards),
            range.lowerBound > devEntry.startIndex,
            let value = Int(devEntry[range.upperBound...]),
            devEntry.hasPrefix("/dev/disk")
        else { return nil }
        // Reject "/dev/disk4" — the "s" of "disk" must not be mistaken for a slice marker.
        let beforeS = devEntry[devEntry.index(before: range.lowerBound)]
        return beforeS.isNumber ? value : nil
    }
}

/// A live `hdiutil attach`. Detaches on `close()`; the pipeline owns exactly one and
/// guarantees a detach on every path, including the signal handler.
public final class AttachedImage: @unchecked Sendable {
    public let imagePath: URL
    public let entities: [AttachedEntity]
    /// False for an attachment this process did not make — the tests build one by hand.
    private let detachesOnClose: Bool
    private let detached = Locked(false)

    init(imagePath: URL, entities: [AttachedEntity], detachesOnClose: Bool = true) {
        self.imagePath = imagePath
        self.entities = entities
        self.detachesOnClose = detachesOnClose
    }

    /// The whole-disk node, e.g. `/dev/disk4`.
    public var wholeDisk: String? {
        entities.first { $0.sliceIndex == nil }?.devEntry
    }

    /// The buffered block device for a partition table slot, e.g. `/dev/disk4s2`.
    /// The buffered node, not `/dev/rdisk…`: raw I/O on macOS must be sector aligned
    /// and not every access e2fsprogs makes is guaranteed to be.
    public func device(forPartition index: Int) -> String? {
        entities.first { $0.sliceIndex == index }?.devEntry
    }

    /// Detaches, retrying before it resorts to force. Safe to call twice.
    public func close() {
        let alreadyDone = detached.withLock { done -> Bool in
            if done { return true }
            done = true
            return false
        }
        guard !alreadyDone, detachesOnClose, let disk = wholeDisk else { return }
        HDIUtil.detach(device: disk)
    }

    deinit { close() }
}

public enum HDIUtil {
    // MARK: - Attach

    /// Attaches an image as a raw disk, without mounting anything.
    ///
    /// `-nomount` is mandatory: left to itself macOS mounts the FAT partition and
    /// writes to it, which is both a surprise and a corruption risk mid-shrink.
    public static func attach(image: URL, readOnly: Bool = false) throws -> AttachedImage {
        var arguments = [
            "attach", "-imagekey", "diskimage-class=CRawDiskImage",
            "-nomount", "-plist", image.path,
        ]
        if readOnly { arguments.insert("-readonly", at: 1) }

        let result = try Shell.run(Shell.hdiutil, arguments)
        guard result.succeeded else {
            throw ShrinkError.precondition(
                "hdiutil could not attach the image (exit \(result.status)).",
                recovery: result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let entities = try parseSystemEntities(plist: result.standardOutput)
        guard !entities.isEmpty else {
            throw ShrinkError.failed("hdiutil attached the image but reported no device nodes.")
        }
        return AttachedImage(imagePath: image, entities: entities)
    }

    static func detach(device: String) {
        for _ in 0..<3 {
            if let result = try? Shell.run(Shell.hdiutil, ["detach", device]), result.succeeded {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        _ = try? Shell.run(Shell.hdiutil, ["detach", "-force", device])
    }

    // MARK: - Stale attachments

    /// A previous run that was killed rather than asked to stop leaves its attachment
    /// behind. Startup is therefore idempotent: find it, detach it, or refuse to run.
    public static func detachStaleAttachment(of image: URL) throws {
        let target = image.resolvingSymlinksInPath().path
        let result = try Shell.run(Shell.hdiutil, ["info", "-plist"])
        guard result.succeeded else { return }
        let devices = try parseAttachedDisks(plist: result.standardOutput, imagePath: target)
        for device in devices {
            detach(device: device)
        }
        guard devices.isEmpty else {
            if try isAttached(image: image) {
                throw ShrinkError.precondition(
                    "The image is still attached from an earlier run and cannot be detached.",
                    recovery: "Run `hdiutil detach -force <device>` and try again."
                )
            }
            return
        }
    }

    public static func isAttached(image: URL) throws -> Bool {
        let result = try Shell.run(Shell.hdiutil, ["info", "-plist"])
        guard result.succeeded else { return false }
        return try !parseAttachedDisks(
            plist: result.standardOutput, imagePath: image.resolvingSymlinksInPath().path
        ).isEmpty
    }

    // MARK: - Plist decoding

    private struct AttachPlist: Decodable {
        let systemEntities: [Entity]

        enum CodingKeys: String, CodingKey { case systemEntities = "system-entities" }

        struct Entity: Decodable {
            let devEntry: String?
            let contentHint: String?
            let mountPoint: String?

            enum CodingKeys: String, CodingKey {
                case devEntry = "dev-entry"
                case contentHint = "content-hint"
                case mountPoint = "mount-point"
            }
        }
    }

    private struct InfoPlist: Decodable {
        let images: [Image]

        struct Image: Decodable {
            let imagePath: String?
            let systemEntities: [AttachPlist.Entity]?

            enum CodingKeys: String, CodingKey {
                case imagePath = "image-path"
                case systemEntities = "system-entities"
            }
        }
    }

    /// Decodes `hdiutil attach -plist` output. The human-readable table is never parsed;
    /// its column layout is not contractual, the plist keys are.
    static func parseSystemEntities(plist: String) throws -> [AttachedEntity] {
        guard let data = plist.data(using: .utf8) else {
            throw ShrinkError.failed("hdiutil returned output that is not valid UTF-8.")
        }
        do {
            let decoded = try PropertyListDecoder().decode(AttachPlist.self, from: data)
            return decoded.systemEntities.compactMap { entity in
                guard let dev = entity.devEntry else { return nil }
                return AttachedEntity(
                    devEntry: dev, contentHint: entity.contentHint, mountPoint: entity.mountPoint)
            }
        } catch {
            throw ShrinkError.failed(
                "Cannot read hdiutil's plist output: \(error.localizedDescription)")
        }
    }

    /// Whole-disk device nodes currently backing the given image path.
    static func parseAttachedDisks(plist: String, imagePath: String) throws -> [String] {
        guard let data = plist.data(using: .utf8) else { return [] }
        guard let decoded = try? PropertyListDecoder().decode(InfoPlist.self, from: data) else {
            return []
        }
        return decoded.images
            .filter { ($0.imagePath.map { URL(filePath: $0).resolvingSymlinksInPath().path }) == imagePath }
            .compactMap { image in
                image.systemEntities?
                    .compactMap(\.devEntry)
                    .first { AttachedEntity(devEntry: $0, contentHint: nil, mountPoint: nil).sliceIndex == nil }
            }
    }
}
