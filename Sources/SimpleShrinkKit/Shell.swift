// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// A small mutable box that is safe to touch from the pipe reader threads.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// Set from the signal handler; every long-running step polls it.
public final class Cancellation: @unchecked Sendable {
    public static let shared = Cancellation()
    private let flag = Locked(false)

    public var isCancelled: Bool { flag.current }
    public func cancel() { flag.withLock { $0 = true } }
    public func reset() { flag.withLock { $0 = false } }

    /// Throws if the run has been cancelled. Called at every stage boundary.
    public func check() throws {
        if isCancelled { throw ShrinkError.cancelled }
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { status == 0 }
    public var combined: String { standardOutput + standardError }
}

/// Runs a child process and collects its output.
///
/// Everything SimpleShrink shells out to — `hdiutil`, `diskutil`, e2fsprogs — goes
/// through here, with an absolute executable path. Nothing is resolved via `PATH`.
public enum Shell {
    /// - Parameter onOutputLine: called for each line as it arrives, on a background
    ///   thread, so progress can be reported while the tool is still running.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ShrinkError.precondition("Not executable: \(executable.path)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = Locked((out: Data(), err: Data(), partialLine: ""))

        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.withLock { state in
                state.out.append(chunk)
                guard let onOutputLine else { return }
                state.partialLine += String(decoding: chunk, as: UTF8.self)
                // e2fsprogs draws progress with \b and \r; treat both as line breaks.
                let separators: Set<Character> = ["\n", "\r"]
                while let idx = state.partialLine.firstIndex(where: { separators.contains($0) }) {
                    let line = String(state.partialLine[..<idx])
                    state.partialLine = String(state.partialLine[state.partialLine.index(after: idx)...])
                    if !line.isEmpty { onOutputLine(line) }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.withLock { $0.err.append(chunk) }
            if let onOutputLine {
                for line in String(decoding: chunk, as: UTF8.self)
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                {
                    onOutputLine(String(line))
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw ShrinkError.precondition(
                "Cannot run \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        // Drain whatever the handlers have not picked up yet.
        let restOut = out.fileHandleForReading.readDataToEndOfFile()
        let restErr = err.fileHandleForReading.readDataToEndOfFile()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        let state = collected.current
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: state.out + restOut, as: UTF8.self),
            standardError: String(decoding: state.err + restErr, as: UTF8.self)
        )
    }

    public static let hdiutil = URL(filePath: "/usr/bin/hdiutil")
    public static let diskutil = URL(filePath: "/usr/sbin/diskutil")
}
