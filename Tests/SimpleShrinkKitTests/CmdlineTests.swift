// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation
import Testing

@testable import SimpleShrinkKit

@Suite("cmdline.txt editing")
struct CmdlineTests {
    let raspberryPi =
        "console=serial0,115200 console=tty1 root=PARTUUID=0a1b2c3d-02 rootfstype=ext4 fsck.repair=yes rootwait\n"

    @Test("Arming for Raspberry Pi OS appends init= and keeps one line")
    func armsRaspi() {
        let armed = Cmdline(contents: raspberryPi).armedForRaspi()
        #expect(armed.tokens.last == "init=/usr/lib/raspi-config/init_resize.sh")
        #expect(!armed.rendered.dropLast().contains("\n"))
        #expect(armed.rendered.hasSuffix("\n"))
        #expect(armed.isArmed)
    }

    @Test("An existing init= is replaced, not duplicated")
    func replacesExistingInit() {
        let cmdline = Cmdline(contents: "rootwait init=/sbin/other quiet\n").armedForRaspi()
        #expect(cmdline.tokens.filter { $0.hasPrefix("init=") }.count == 1)
        #expect(cmdline.tokens.contains("init=/usr/lib/raspi-config/init_resize.sh"))
        #expect(cmdline.tokens.contains("quiet"))
    }

    @Test("A file with no trailing newline keeps having none")
    func preservesMissingNewline() {
        let cmdline = Cmdline(contents: "rootwait")
        #expect(cmdline.lineEnding.isEmpty)
        #expect(cmdline.armedForRaspi().rendered.hasSuffix("init_resize.sh"))
    }

    @Test("CRLF survives the edit")
    func preservesCRLF() {
        let cmdline = Cmdline(contents: "rootwait\r\n")
        #expect(cmdline.lineEnding == "\r\n")
        #expect(cmdline.armedForRaspi().rendered.hasSuffix("\r\n"))
        #expect(!cmdline.armedForRaspi().rendered.dropLast(2).contains("\r"))
    }

    @Test("A stray second line is folded into the single line the bootloader expects")
    func foldsMultipleLines() {
        let cmdline = Cmdline(contents: "rootwait\nquiet splash\n")
        #expect(cmdline.tokens == ["rootwait", "quiet", "splash"])
        #expect(cmdline.rendered == "rootwait quiet splash\n")
    }

    @Test("The generic strategy points systemd at the boot path the running system will use")
    func armsGeneric() {
        let armed = Cmdline(contents: raspberryPi).armedForGeneric(bootPath: "/boot/firmware")
        #expect(armed.tokens.contains("systemd.run=/boot/firmware/simpleshrink-expand.sh"))
        #expect(armed.tokens.contains("systemd.run_success_action=reboot"))
        #expect(armed.tokens.contains("systemd.unit=kernel-command-line.target"))
        #expect(armed.isArmed)
    }

    @Test("Arming twice does not stack tokens")
    func genericIsIdempotent() {
        let once = Cmdline(contents: raspberryPi).armedForGeneric(bootPath: "/boot")
        let twice = once.armedForGeneric(bootPath: "/boot")
        #expect(once.tokens == twice.tokens)
    }

    @Test("An unarmed command line is not reported as armed")
    func detectsUnarmed() {
        #expect(!Cmdline(contents: raspberryPi).isArmed)
    }

    @Test("The embedded expansion script is byte-identical to the one in Resources")
    func embeddedScriptMatchesResource() throws {
        // The script ships twice: as a file a reader can review, and as a string the
        // binary writes to the boot partition. They must not drift apart.
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()  // SimpleShrinkKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        let onDisk = try String(
            contentsOf: repositoryRoot.appending(path: "Resources/simpleshrink-expand.sh"),
            encoding: .utf8)
        #expect(Expansion.genericScript + "\n" == onDisk)
    }
}
