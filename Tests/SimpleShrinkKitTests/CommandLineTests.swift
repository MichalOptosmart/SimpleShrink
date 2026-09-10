// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Testing

@testable import SimpleShrinkKit

@Suite("Command line")
struct CommandLineTests {
    @Test("shrink takes an image and the documented defaults")
    func parsesShrinkDefaults() throws {
        let invocation = try CommandLineParser.parse(["shrink", "/tmp/pi.img"])
        guard case let .shrink(path, options, json, verbose) = invocation else {
            Issue.record("expected a shrink invocation")
            return
        }
        #expect(path == "/tmp/pi.img")
        #expect(options.freeSpaceMiB == 64)
        #expect(options.expansion == .auto)
        #expect(!json)
        #expect(!verbose)
    }

    @Test("--name value and --name=value are both accepted", arguments: [
        ["shrink", "/tmp/pi.img", "--free-space", "256", "--expansion", "generic"],
        ["shrink", "/tmp/pi.img", "--free-space=256", "--expansion=generic"],
    ])
    func parsesBothOptionSpellings(arguments: [String]) throws {
        guard case let .shrink(_, options, _, _) = try CommandLineParser.parse(arguments) else {
            Issue.record("expected a shrink invocation")
            return
        }
        #expect(options.freeSpaceMiB == 256)
        #expect(options.expansion == .generic)
    }

    @Test("Flags are recognised wherever they appear")
    func parsesFlags() throws {
        let invocation = try CommandLineParser.parse([
            "shrink", "--json", "/tmp/pi.img", "--dry-run", "--extract-mode", "--verbose",
        ])
        guard case let .shrink(path, options, json, verbose) = invocation else {
            Issue.record("expected a shrink invocation")
            return
        }
        #expect(path == "/tmp/pi.img")
        #expect(options.dryRun)
        #expect(options.extractMode)
        #expect(json)
        #expect(verbose)
    }

    @Test("--output names the copy to shrink")
    func parsesOutput() throws {
        guard case let .shrink(_, options, _, _) = try CommandLineParser.parse([
            "shrink", "/tmp/pi.img", "--output", "/tmp/small.img",
        ]) else {
            Issue.record("expected a shrink invocation")
            return
        }
        #expect(options.outputPath == "/tmp/small.img")
    }

    @Test("A dry run writes nothing, so it cannot be combined with --output")
    func rejectsDryRunWithOutput() {
        #expect(throws: ShrinkError.self) {
            try CommandLineParser.parse(["shrink", "/tmp/pi.img", "--dry-run", "--output", "/tmp/o.img"])
        }
    }

    @Test("Bad input is refused with usage, not a partial run", arguments: [
        ["shrink"],
        ["shrink", "/tmp/a.img", "/tmp/b.img"],
        ["shrink", "/tmp/pi.img", "--free-space"],
        ["shrink", "/tmp/pi.img", "--free-space", "lots"],
        ["shrink", "/tmp/pi.img", "--expansion", "sideways"],
        ["shrink", "/tmp/pi.img", "--nonsense"],
        ["inspect"],
        ["fly", "/tmp/pi.img"],
        ["describe"],
        ["describe", "--protocol", "one"],
    ])
    func rejectsBadInput(arguments: [String]) {
        #expect(throws: ShrinkError.self) { try CommandLineParser.parse(arguments) }
    }

    @Test("inspect parses its own options")
    func parsesInspect() throws {
        guard case let .inspect(path, json, freeSpace) = try CommandLineParser.parse([
            "inspect", "/tmp/pi.img", "--json", "--free-space", "128",
        ]) else {
            Issue.record("expected an inspect invocation")
            return
        }
        #expect(path == "/tmp/pi.img")
        #expect(json)
        #expect(freeSpace == 128)
    }

    @Test("The host-facing verbs carry the protocol version")
    func parsesProtocolVerbs() throws {
        #expect(try CommandLineParser.parse(["describe", "--protocol", "1"]) == .describe(protocolVersion: 1))
        #expect(
            try CommandLineParser.parse(["run", "--protocol", "1", "--capability", "shrink"])
                == .run(protocolVersion: 1, capability: "shrink"))
        #expect(try CommandLineParser.parse(["run", "--protocol", "2"]) == .run(protocolVersion: 2, capability: "shrink"))
    }

    @Test("Help and version are reachable the usual ways", arguments: [
        (["--help"], Invocation.help), (["help"], .help), ([], .help),
        (["version"], .version), (["--version"], .version),
    ])
    func parsesHelpAndVersion(arguments: [String], expected: Invocation) throws {
        #expect(try CommandLineParser.parse(arguments) == expected)
    }
}
