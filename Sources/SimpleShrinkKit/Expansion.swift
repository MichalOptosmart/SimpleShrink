// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
//
// First-boot expansion. The point of shrinking an image is to write it to a smaller
// card; the point of arming expansion is that it still fills whatever card it lands on.
//
// Nothing here writes to the ext4 root filesystem. Both strategies are configured from
// the FAT boot partition, which macOS mounts natively.

import Foundation

/// `cmdline.txt` as the Raspberry Pi bootloader wants it: one line, whitespace-separated
/// tokens, and whatever line ending it already had.
///
/// Every edit goes through this type so the "single line" rule is enforced in one place
/// and can be tested without an image.
public struct Cmdline: Equatable, Sendable {
    public private(set) var tokens: [String]
    /// "" , "\n" or "\r\n" — preserved exactly, never added where there was none.
    public let lineEnding: String

    public init(contents: String) {
        var body = contents
        var ending = ""
        if body.hasSuffix("\r\n") {
            ending = "\r\n"
            body.removeLast(2)
        } else if body.hasSuffix("\n") {
            ending = "\n"
            body.removeLast()
        }
        // A stray second line would silently disable everything after it; fold it in.
        tokens = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map(String.init)
        lineEnding = ending
    }

    public var rendered: String { tokens.joined(separator: " ") + lineEnding }

    public func contains(prefix: String) -> Bool {
        tokens.contains { $0.hasPrefix(prefix) }
    }

    public func removing(prefixes: [String]) -> Cmdline {
        var copy = self
        copy.tokens = tokens.filter { token in !prefixes.contains(where: { token.hasPrefix($0) }) }
        return copy
    }

    public func appending(_ newTokens: [String]) -> Cmdline {
        var copy = self
        copy.tokens.append(contentsOf: newTokens)
        return copy
    }

    /// Raspberry Pi OS: hand the kernel raspi-config's own resize script as init.
    public func armedForRaspi() -> Cmdline {
        removing(prefixes: ["init="]).appending(["init=\(Expansion.raspiInitPath)"])
    }

    /// Everything else: a systemd one-shot that grows the partition and reboots.
    public func armedForGeneric(bootPath: String) -> Cmdline {
        removing(prefixes: ["systemd.run=", "systemd.run_success_action=", "systemd.unit="])
            .appending([
                "systemd.run=\(bootPath)/\(Expansion.genericScriptName)",
                "systemd.run_success_action=reboot",
                "systemd.unit=kernel-command-line.target",
            ])
    }

    /// True if either mechanism is already configured.
    public var isArmed: Bool {
        tokens.contains("init=\(Expansion.raspiInitPath)")
            || contains(prefix: "systemd.run=")
    }
}

/// Detects and arms first-boot expansion on an attached image.
public struct Expansion {
    public static let raspiInitPath = "/usr/lib/raspi-config/init_resize.sh"
    public static let genericScriptName = "simpleshrink-expand.sh"
    public static let backupSuffix = ".simpleshrink.bak"

    /// The script written to the boot partition by the generic strategy.
    /// Kept byte-identical to `Resources/simpleshrink-expand.sh`, which a test asserts.
    public static let genericScript = #"""
#!/bin/sh
# SimpleShrink first-boot expansion — generic systemd strategy.
# Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
#
# Run once by systemd.run= from the kernel command line, before the system is up.
# Grows the root partition to fill the medium, grows the filesystem into it, then
# removes itself from cmdline.txt and deletes itself.
set -eu
exec >>/var/log/simpleshrink-expand.log 2>&1
echo "simpleshrink-expand: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_NAME=$(basename "$ROOT_SRC")
DISK="/dev/$(lsblk -no pkname "$ROOT_SRC")"
PARTNUM=$(cat "/sys/class/block/$ROOT_NAME/partition")

echo ',+,' | sfdisk -N "$PARTNUM" --force "$DISK"
partx -u "$DISK" || partprobe "$DISK" || true
resize2fs "$ROOT_SRC"

BOOTDIR=$(dirname "$0")
sed -i \
    -e 's| systemd\.run=[^ ]*||g' \
    -e 's| systemd\.run_success_action=[^ ]*||g' \
    -e 's| systemd\.unit=kernel-command-line\.target||g' \
    "$BOOTDIR/cmdline.txt"

rm -f "$0"
sync
echo "simpleshrink-expand: done"
"""#

    let tools: E2fsprogs
    let sink: any EventSink

    public init(tools: E2fsprogs, sink: any EventSink) {
        self.tools = tools
        self.sink = sink
    }

    /// Picks a strategy by looking inside the root filesystem with `debugfs` — no mount,
    /// no writes.
    public func detectStrategy(rootDevice: String) -> ExpansionStrategy {
        if tools.fileExists(Expansion.raspiInitPath, device: rootDevice) {
            return .raspi
        }
        return .generic
    }

    /// Where the running system will have the boot partition mounted. Bookworm and newer
    /// moved it from /boot to /boot/firmware, and the systemd.run= path must match.
    public func bootPath(rootDevice: String) -> String {
        tools.fileExists("/boot/firmware", device: rootDevice) ? "/boot/firmware" : "/boot"
    }

    /// Mounts the FAT boot partition, applies the strategy, unmounts.
    ///
    /// - Returns: the strategy actually armed, and any warning worth surfacing.
    public func arm(
        strategy requested: ExpansionStrategy, bootDevice: String, rootDevice: String
    ) throws -> (armed: ExpansionStrategy, warnings: [String]) {
        guard requested != .none else { return (.none, []) }
        let strategy = requested == .auto ? detectStrategy(rootDevice: rootDevice) : requested

        return try Mount.withBootPartition(device: bootDevice) { mountPoint in
            let cmdlineURL = mountPoint.appending(path: "cmdline.txt")
            guard let original = try? String(contentsOf: cmdlineURL, encoding: .utf8) else {
                return (
                    .none,
                    [
                        "No cmdline.txt on the boot partition, so first-boot expansion could not be "
                            + "armed. The image is shrunk; expand the root filesystem yourself after writing it."
                    ]
                )
            }

            let cmdline = Cmdline(contents: original)
            if cmdline.isArmed {
                sink.log(.info, "First-boot expansion is already armed; leaving cmdline.txt alone.")
                return (strategy, [])
            }

            // Always keep the original within reach of the user, once.
            let backupURL = mountPoint.appending(path: "cmdline.txt\(Expansion.backupSuffix)")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try original.write(to: backupURL, atomically: false, encoding: .utf8)
            }

            var warnings: [String] = []
            let updated: Cmdline
            switch strategy {
            case .raspi:
                updated = cmdline.armedForRaspi()
            case .generic:
                let path = bootPath(rootDevice: rootDevice)
                updated = cmdline.armedForGeneric(bootPath: path)
                let scriptURL = mountPoint.appending(path: Expansion.genericScriptName)
                try (Expansion.genericScript + "\n").write(
                    to: scriptURL, atomically: false, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
                warnings.append(
                    "The generic systemd expansion strategy is experimental in this release; "
                        + "verify the first boot before relying on it.")
            case .auto, .none:
                return (.none, [])
            }

            try updated.rendered.write(to: cmdlineURL, atomically: false, encoding: .utf8)
            sink.log(.info, "Armed first-boot expansion (\(strategy.rawValue)).")
            return (strategy, warnings)
        }
    }
}

/// Mounting the FAT slice, explicitly and briefly.
public enum Mount {
    /// Mounts `device` on a temporary directory for the duration of `body`, and
    /// unmounts on every path out.
    public static func withBootPartition<T>(
        device: String, _ body: (URL) throws -> T
    ) throws -> T {
        let mountPoint = URL(filePath: NSTemporaryDirectory())
            .appending(path: "simpleshrink-boot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }

        let mount = try Shell.run(
            Shell.diskutil, ["mount", "-mountPoint", mountPoint.path, device])
        guard mount.succeeded else {
            throw ShrinkError.failed(
                "Cannot mount the boot partition \(device).\n"
                    + mount.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer { unmount(mountPoint) }
        return try body(mountPoint)
    }

    /// Unmounts, retrying before it resorts to force. A boot partition left mounted
    /// would keep the image busy for the next step.
    private static func unmount(_ mountPoint: URL) {
        for _ in 0..<3 {
            if let result = try? Shell.run(Shell.diskutil, ["unmount", mountPoint.path]),
                result.succeeded
            {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        _ = try? Shell.run(Shell.diskutil, ["unmount", "force", mountPoint.path])
    }
}
