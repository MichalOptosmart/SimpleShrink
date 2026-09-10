// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation
import SimpleShrinkKit

enum InspectCommand {
    static func run(path: String, json: Bool, freeSpaceMiB: UInt64) -> ExitCode {
        do {
            let tools = try E2fsprogs.locate()
            let report = try Inspector(tools: tools)
                .inspect(image: URL(filePath: path), freeSpaceMiB: freeSpaceMiB)
            print(json ? try encode(report) : describe(report))
            return report.supported ? .success : .unsupported
        } catch let error as ShrinkError {
            AttachmentRegistry.shared.detachAll()
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            return error.exitCode
        } catch {
            AttachmentRegistry.shared.detachAll()
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return .failure
        }
    }

    private static func encode(_ report: ImageReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    private static func describe(_ report: ImageReport) -> String {
        var lines = [
            "Scheme:      \(report.scheme), \(report.sectorSize)-byte sectors",
            "Image size:  \(Sizing.humanBytes(report.imageBytes))",
            "Partitions:",
        ]
        for partition in report.partitions {
            lines.append(
                "  \(partition.index). \(partition.fs) (\(partition.type)) "
                    + "at LBA \(partition.startLBA), \(Sizing.humanBytes(partition.bytes))")
        }
        if let root = report.root {
            lines.append(
                "Root:        partition \(root.index), \(root.blockCount) × \(root.blockSize) B blocks"
                    + ", \(root.clean ? "clean" : "needs checking")")
            if let minimum = root.minimumBlocks {
                lines.append("Minimum:     \(Sizing.humanBytes(minimum * root.blockSize))")
            }
        }
        if let after = report.estimatedBytesAfter {
            lines.append("Estimate:    about \(Sizing.humanBytes(after)) after shrinking")
        }
        if report.requiresCheck {
            lines.append(
                "Note:        the filesystem needs a check before its minimum can be estimated")
        }
        if let strategy = report.expansionStrategy {
            lines.append("Expansion:   \(strategy.rawValue)")
        }
        if let reason = report.reason {
            lines.append("Unsupported: \(reason)")
        }
        return lines.joined(separator: "\n")
    }
}
