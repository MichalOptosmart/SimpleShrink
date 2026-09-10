// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// What `dumpe2fs -h` says about a filesystem. Only the fields we act on are kept.
public struct Ext2Superblock: Sendable, Equatable {
    public var blockSize: UInt64
    public var blockCount: UInt64
    public var freeBlocks: UInt64
    public var filesystemState: String
    public var features: [String]
    public var volumeName: String?
    public var uuid: String?
    public var journalUUID: String?

    public var byteSize: UInt64 { blockSize * blockCount }
    public var isClean: Bool { filesystemState.contains("clean") }
    public var hasExternalJournal: Bool { journalUUID != nil }

    /// Every feature name the pinned e2fsprogs release knows how to print and handle.
    ///
    /// `dumpe2fs` prints compat, incompat and ro_compat features on one line, so this
    /// is one flat set. A name that is not in it means the image was made by something
    /// newer than the tools we ship, which is a refusal rather than a guess.
    public static let knownFeatures: Set<String> = [
        // compat
        "dir_prealloc", "imagic_inodes", "has_journal", "ext_attr", "resize_inode",
        "dir_index", "sparse_super2", "fast_commit", "stable_inodes", "orphan_file",
        // incompat
        "compression", "filetype", "recover", "needs_recovery", "journal_dev", "meta_bg",
        "extent", "extents", "64bit", "mmp", "flex_bg", "ea_inode", "dirdata", "csum_seed",
        "metadata_csum_seed", "large_dir", "inline_data", "encrypt", "casefold",
        // ro_compat
        "sparse_super", "large_file", "huge_file", "btree_dir", "uninit_bg", "gdt_csum",
        "dir_nlink", "extra_isize", "quota", "bigalloc", "metadata_csum", "replica",
        "readonly", "project", "shared_blocks", "verity", "orphan_present", "test_fs",
    ]

    public var unknownFeatures: [String] {
        features.filter { !Ext2Superblock.knownFeatures.contains($0) }
    }
}

/// Outcome of a filesystem check. `e2fsck` exit codes are a bitmask, not an enum.
public struct CheckOutcome: Sendable {
    public let status: Int32
    public var errorsCorrected: Bool { status & 1 != 0 || status & 2 != 0 }
}

/// The vendored e2fsprogs binaries and the invocations SimpleShrink makes of them.
public struct E2fsprogs: Sendable {
    public let directory: URL

    public enum Tool: String, Sendable, CaseIterable {
        case e2fsck, resize2fs, dumpe2fs, debugfs
    }

    public func url(of tool: Tool) -> URL { directory.appending(path: tool.rawValue) }

    /// Locates the vendored binaries.
    ///
    /// `PATH` is never searched: a hijacked `resize2fs` running against a user's image
    /// is exactly the failure mode this tool must not have. The lookup is, in order,
    /// the `SIMPLESHRINK_E2FSPROGS_DIR` override (development and CI), then
    /// `../libexec/e2fsprogs` and `libexec/e2fsprogs` relative to this executable.
    public static func locate(
        executable: URL = URL(filePath: CommandLine.arguments.first ?? "/usr/local/bin/simpleshrink"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> E2fsprogs {
        var candidates: [URL] = []
        if let override = environment["SIMPLESHRINK_E2FSPROGS_DIR"], !override.isEmpty {
            candidates.append(URL(filePath: override))
        }
        let base = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(base.appending(path: "../libexec/e2fsprogs").standardizedFileURL)
        candidates.append(base.appending(path: "libexec/e2fsprogs").standardizedFileURL)

        for candidate in candidates {
            let tools = E2fsprogs(directory: candidate)
            if Tool.allCases.allSatisfy({
                FileManager.default.isExecutableFile(atPath: tools.url(of: $0).path)
            }) {
                return tools
            }
        }
        throw ShrinkError.precondition(
            "The bundled e2fsprogs tools were not found next to the executable.",
            recovery: "Run Scripts/build-e2fsprogs.sh, or point SIMPLESHRINK_E2FSPROGS_DIR at a "
                + "directory containing e2fsck, resize2fs, dumpe2fs and debugfs."
        )
    }

    // MARK: - Invocations

    /// `e2fsck -f -y -C 0`. Maps the exit bitmask onto our own error codes.
    ///
    /// `-C 0` asks e2fsck to print completion percentages to stdout, which is the only
    /// thing in the pipeline that reports progress at all.
    @discardableResult
    public func check(device: String, onProgress: (@Sendable (Double) -> Void)? = nil) throws -> CheckOutcome {
        let result = try Shell.run(url(of: .e2fsck), ["-f", "-y", "-C", "0", device]) { line in
            if let fraction = E2fsprogs.parseProgress(line) { onProgress?(fraction) }
        }
        let status = result.status
        if status & 16 != 0 {
            throw ShrinkError.failed("e2fsck usage error — this is a SimpleShrink bug.\n\(result.combined)")
        }
        if status & 128 != 0 {
            throw ShrinkError.precondition("e2fsck could not load its shared libraries.")
        }
        if status & 32 != 0 { throw ShrinkError.cancelled }
        if status & 8 != 0 {
            throw ShrinkError.failed("e2fsck failed with an operational error.\n\(result.combined)")
        }
        if status & 4 != 0 {
            throw ShrinkError.unsupported(
                "The filesystem has errors that e2fsck could not correct.",
                recovery: "Repair the image on a Linux host before shrinking it."
            )
        }
        return CheckOutcome(status: status)
    }

    /// `resize2fs -P` — the estimated minimum size, in filesystem blocks.
    public func minimumBlocks(device: String) throws -> UInt64 {
        let result = try Shell.run(url(of: .resize2fs), ["-P", device])
        guard result.succeeded, let blocks = E2fsprogs.parseMinimumBlocks(result.combined) else {
            throw ShrinkError.failed(
                "resize2fs could not estimate the minimum size.\n\(result.combined)")
        }
        return blocks
    }

    /// `resize2fs <device> <blocks>`. Returns false when the filesystem refuses to go
    /// that small, which the caller answers by retrying with a bigger margin.
    public func resize(
        device: String, toBlocks blocks: UInt64, onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Bool {
        let result = try Shell.run(url(of: .resize2fs), [device, String(blocks)]) { line in
            if let fraction = E2fsprogs.parseProgress(line) { onProgress?(fraction) }
        }
        if result.succeeded { return true }
        if result.combined.lowercased().contains("new size smaller than minimum") { return false }
        throw ShrinkError.failed("resize2fs failed (exit \(result.status)).\n\(result.combined)")
    }

    /// `dumpe2fs -h` — the authoritative post-resize size, never the value we asked for.
    public func superblock(device: String) throws -> Ext2Superblock {
        let result = try Shell.run(url(of: .dumpe2fs), ["-h", device])
        guard let superblock = E2fsprogs.parseSuperblock(result.combined) else {
            throw ShrinkError.unsupported(
                "No ext2/ext3/ext4 filesystem found on \(device).",
                recovery: "SimpleShrink shrinks ext2, ext3 and ext4 only; btrfs, f2fs and XFS are not supported."
            )
        }
        return superblock
    }

    /// Whether a path exists inside the filesystem, without mounting it.
    public func fileExists(_ path: String, device: String) -> Bool {
        guard let result = try? Shell.run(url(of: .debugfs), ["-R", "stat \(path)", device]) else {
            return false
        }
        let text = result.combined
        if text.contains("File not found") || text.contains("not found by ext2_lookup") {
            return false
        }
        return text.contains("Inode:")
    }

    // MARK: - Output parsing (pure, covered by tests)

    static func parseMinimumBlocks(_ text: String) -> UInt64? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("minimum size of the filesystem") else { continue }
            let digits = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
                .prefix { $0.isNumber }
            if let digits, let value = UInt64(digits) { return value }
        }
        return nil
    }

    /// e2fsprogs prints progress as a bare percentage inside its status line.
    static func parseProgress(_ line: String) -> Double? {
        guard let percentRange = line.range(of: "%") else { return nil }
        let head = line[..<percentRange.lowerBound]
        let number = head.reversed().prefix { $0.isNumber || $0 == "." }.reversed()
        guard !number.isEmpty, let value = Double(String(number)), value >= 0, value <= 100 else {
            return nil
        }
        return value / 100
    }

    static func parseSuperblock(_ text: String) -> Ext2Superblock? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let blockSize = fields["Block size"].flatMap(UInt64.init),
            let blockCount = fields["Block count"].flatMap(UInt64.init)
        else { return nil }

        let features = (fields["Filesystem features"] ?? "")
            .split(separator: " ").map(String.init)

        return Ext2Superblock(
            blockSize: blockSize,
            blockCount: blockCount,
            freeBlocks: fields["Free blocks"].flatMap(UInt64.init) ?? 0,
            filesystemState: fields["Filesystem state"] ?? "unknown",
            features: features,
            volumeName: fields["Filesystem volume name"].flatMap {
                $0 == "<none>" ? nil : $0
            },
            uuid: fields["Filesystem UUID"],
            journalUUID: fields["Journal UUID"].flatMap { $0 == "<none>" ? nil : $0 }
        )
    }
}
