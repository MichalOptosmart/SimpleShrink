// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
//
// Entry point: refuse root, install signal handling, dispatch, map errors onto exit
// codes. Everything else lives in SimpleShrinkKit, which is what a host embedding the
// tool as a library would use.

import Foundation
import SimpleShrinkKit

// Nothing this tool does needs privileges — `hdiutil attach -nomount` exposes the
// slices to the invoking user — and running as root would let a bug reach the host
// system. Refusing is cheaper than being careful.
if geteuid() == 0 {
    FileHandle.standardError.write(
        Data(
            """
            error: simpleshrink must not run as root.
            Nothing it does requires privileges; run it as your normal user.

            """.utf8))
    exit(ExitCode.precondition.rawValue)
}

SignalHandling.install()

let invocation: Invocation
do {
    invocation = try CommandLineParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as ShrinkError {
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    exit(error.exitCode.rawValue)
}

switch invocation {
case .help:
    print(CommandLineParser.usage)
    exit(ExitCode.success.rawValue)

case .version:
    print("simpleshrink \(SimpleShrink.version) (protocol \(SimpleShrink.protocolVersion))")
    exit(ExitCode.success.rawValue)

case let .describe(protocolVersion):
    exit(DescribeCommand.run(protocolVersion: protocolVersion).rawValue)

case let .run(protocolVersion, capability):
    exit(RunCommand.run(protocolVersion: protocolVersion, capability: capability).rawValue)

case let .inspect(path, json, freeSpaceMiB):
    exit(InspectCommand.run(path: path, json: json, freeSpaceMiB: freeSpaceMiB).rawValue)

case let .shrink(path, options, json, verbose):
    exit(ShrinkCommand.run(path: path, options: options, json: json, verbose: verbose).rawValue)
}
