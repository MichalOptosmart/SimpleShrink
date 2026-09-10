// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
//
// Argument parsing is hand-written on purpose. The whole repository is GPL-2.0-only
// to match e2fsprogs, and Apache-2.0 libraries — swift-argument-parser included — add
// restrictions GPLv2 does not permit. The CLI surface is small; this is the cost.

import Foundation

public enum Invocation: Sendable, Equatable {
    case shrink(path: String, options: ShrinkOptions, json: Bool, verbose: Bool)
    case inspect(path: String, json: Bool, freeSpaceMiB: UInt64)
    case describe(protocolVersion: Int)
    case run(protocolVersion: Int, capability: String)
    case version
    case help
}

public enum CommandLineParser {
    public static let usage = """
        simpleshrink — shrink a Linux disk image on macOS, and let it grow back on first boot.

        USAGE
          simpleshrink shrink <image> [options]
          simpleshrink inspect <image> [--json] [--free-space <MiB>]
          simpleshrink describe --protocol 1
          simpleshrink run --protocol 1 --capability shrink
          simpleshrink version

        SHRINK OPTIONS
          --free-space <MiB>       Slack left in the shrunk filesystem (default 64)
          --output <path>          Shrink a copy; leave the input untouched
          --expansion <strategy>   auto | raspi | generic | none (default auto)
          --extract-mode           Resize via scratch space instead of the attached slice
          --dry-run                Report the plan; change nothing
          --json                   NDJSON events on stdout instead of human output
          --verbose                Include e2fsprogs output on stderr

        EXIT CODES
          0 success   1 failure   2 unsupported image
          3 precondition failed   4 cancelled   5 protocol mismatch

        Full documentation: docs/SPEC.md, docs/INTEGRATION.md
        """

    public static func parse(_ arguments: [String]) throws -> Invocation {
        var arguments = arguments
        guard let verb = arguments.first else { return .help }
        arguments.removeFirst()

        switch verb {
        case "-h", "--help", "help": return .help
        case "--version", "version": return .version
        case "shrink": return try parseShrink(arguments)
        case "inspect": return try parseInspect(arguments)
        case "describe": return .describe(protocolVersion: try protocolVersion(from: arguments))
        case "run":
            return .run(
                protocolVersion: try protocolVersion(from: arguments),
                capability: try value(of: "--capability", in: arguments) ?? "shrink")
        default:
            throw usageError("Unknown command: \(verb)")
        }
    }

    // MARK: - Verbs

    private static func parseShrink(_ arguments: [String]) throws -> Invocation {
        var options = ShrinkOptions()
        var json = false
        var verbose = false
        var path: String?

        var iterator = Tokens(arguments)
        while let token = iterator.next() {
            switch token.name {
            case "--free-space":
                options.freeSpaceMiB = try unsigned(token.value ?? iterator.takeValue(for: token.name), token.name)
            case "--output":
                options.outputPath = try requireValue(token.value ?? iterator.takeValue(for: token.name), token.name)
            case "--expansion":
                let raw = try requireValue(token.value ?? iterator.takeValue(for: token.name), token.name)
                guard let strategy = ExpansionStrategy(rawValue: raw) else {
                    throw usageError(
                        "Unknown expansion strategy: \(raw). "
                            + "Use one of \(ExpansionStrategy.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                options.expansion = strategy
            case "--extract-mode": options.extractMode = true
            case "--dry-run": options.dryRun = true
            case "--json": json = true
            case "--verbose": verbose = true
            case "-h", "--help": return .help
            default:
                if token.isOption { throw usageError("Unknown option: \(token.name)") }
                guard path == nil else { throw usageError("More than one image given.") }
                path = token.name
            }
        }

        guard let path else { throw usageError("shrink needs the path to an image file.") }
        if options.dryRun, options.outputPath != nil {
            throw usageError("--dry-run and --output cannot be combined; a dry run writes nothing.")
        }
        return .shrink(path: path, options: options, json: json, verbose: verbose)
    }

    private static func parseInspect(_ arguments: [String]) throws -> Invocation {
        var json = false
        var freeSpace: UInt64 = 64
        var path: String?

        var iterator = Tokens(arguments)
        while let token = iterator.next() {
            switch token.name {
            case "--json": json = true
            case "--free-space":
                freeSpace = try unsigned(token.value ?? iterator.takeValue(for: token.name), token.name)
            case "-h", "--help": return .help
            default:
                if token.isOption { throw usageError("Unknown option: \(token.name)") }
                guard path == nil else { throw usageError("More than one image given.") }
                path = token.name
            }
        }
        guard let path else { throw usageError("inspect needs the path to an image file.") }
        return .inspect(path: path, json: json, freeSpaceMiB: freeSpace)
    }

    // MARK: - Token plumbing

    private struct Token {
        let name: String
        let value: String?
        var isOption: Bool { name.hasPrefix("-") }
    }

    private struct Tokens {
        private var items: [String]
        private var index = 0

        init(_ items: [String]) { self.items = items }

        mutating func next() -> Token? {
            guard index < items.count else { return nil }
            let raw = items[index]
            index += 1
            // --name=value and --name value are both accepted.
            if raw.hasPrefix("--"), let equals = raw.firstIndex(of: "=") {
                return Token(name: String(raw[..<equals]), value: String(raw[raw.index(after: equals)...]))
            }
            return Token(name: raw, value: nil)
        }

        mutating func takeValue(for option: String) -> String? {
            guard index < items.count, !items[index].hasPrefix("--") else { return nil }
            defer { index += 1 }
            return items[index]
        }
    }

    private static func protocolVersion(from arguments: [String]) throws -> Int {
        guard let raw = try value(of: "--protocol", in: arguments) else {
            throw usageError("--protocol is required; this build implements version \(SimpleShrink.protocolVersion).")
        }
        guard let version = Int(raw) else { throw usageError("--protocol takes a number.") }
        return version
    }

    private static func value(of option: String, in arguments: [String]) throws -> String? {
        var iterator = Tokens(arguments)
        while let token = iterator.next() {
            guard token.name == option else { continue }
            return try requireValue(token.value ?? iterator.takeValue(for: option), option)
        }
        return nil
    }

    private static func requireValue(_ value: String?, _ option: String) throws -> String {
        guard let value, !value.isEmpty else { throw usageError("\(option) needs a value.") }
        return value
    }

    private static func unsigned(_ value: String?, _ option: String) throws -> UInt64 {
        guard let number = UInt64(try requireValue(value, option)) else {
            throw usageError("\(option) takes a non-negative whole number.")
        }
        return number
    }

    private static func usageError(_ message: String) -> ShrinkError {
        ShrinkError(.failed, message, recovery: "Run `simpleshrink --help` for usage.")
    }
}
