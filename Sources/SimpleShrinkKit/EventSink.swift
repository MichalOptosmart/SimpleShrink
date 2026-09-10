// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// Where the pipeline reports to. One implementation writes NDJSON for a host, the
/// other writes prose for a person; the pipeline itself knows neither.
public protocol EventSink: AnyObject, Sendable {
    func emit(_ event: Event)
}

extension EventSink {
    public func log(_ level: LogLevel, _ message: String) {
        emit(.log(level: level, message: message))
    }

    public func progress(_ stage: Stage, _ fraction: Double, _ message: String? = nil) {
        emit(.progress(stage: stage, fraction: fraction, message: message))
    }
}

/// Serialises writes to a file descriptor. Progress arrives from the pipe reader
/// threads, so a half-written line is a real possibility without this.
final class SynchronizedWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}

/// NDJSON on stdout, one object per line: the machine-facing form of a run.
public final class JSONEventSink: EventSink {
    private let writer: SynchronizedWriter
    private let encoder: JSONEncoder
    private let terminated = Locked(false)

    public init(handle: FileHandle = .standardOutput) {
        writer = SynchronizedWriter(handle)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    public func emit(_ event: Event) {
        // The contract promises exactly one terminal event; drop anything after it
        // rather than letting a late progress line follow the result.
        let alreadyTerminated = terminated.withLock { done -> Bool in
            if done { return true }
            if event.isTerminal { done = true }
            return false
        }
        guard !alreadyTerminated else { return }
        guard let data = try? encoder.encode(event) else { return }
        writer.write(String(decoding: data, as: UTF8.self) + "\n")
    }
}

/// Human output: a progress line and the log on stderr, the summary on stdout.
public final class ConsoleEventSink: EventSink {
    private let out: SynchronizedWriter
    private let err: SynchronizedWriter
    private let verbose: Bool
    private let isTTY: Bool
    private let lastStage = Locked<Stage?>(nil)

    public init(verbose: Bool = false) {
        out = SynchronizedWriter(.standardOutput)
        err = SynchronizedWriter(.standardError)
        self.verbose = verbose
        isTTY = isatty(STDERR_FILENO) == 1
    }

    public func emit(_ event: Event) {
        switch event {
        case let .progress(stage, fraction, message):
            let changed = lastStage.withLock { last -> Bool in
                defer { last = stage }
                return last != stage
            }
            let percent = Int((fraction * 100).rounded())
            let label = message ?? ConsoleEventSink.label(for: stage)
            if isTTY {
                err.write("\u{1B}[2K\r[\(String(format: "%3d", percent))%] \(label)")
                if stage == .done { err.write("\n") }
            } else if changed {
                err.write("[\(String(format: "%3d", percent))%] \(label)\n")
            }

        case let .log(level, message):
            guard verbose || level != .debug else { return }
            if isTTY { err.write("\u{1B}[2K\r") }
            err.write("\(level.rawValue): \(message)\n")

        case let .result(report):
            out.write(ConsoleEventSink.summary(of: report))

        case let .failure(_, message):
            if isTTY { err.write("\u{1B}[2K\r") }
            err.write("error: \(message)\n")
        }
    }

    static func label(for stage: Stage) -> String {
        switch stage {
        case .open: "Opening the image"
        case .attach: "Attaching"
        case .probe: "Probing the filesystem"
        case .check: "Checking the filesystem"
        case .resize: "Resizing the filesystem"
        case .verify: "Verifying"
        case .arm: "Arming first-boot expansion"
        case .detach: "Detaching"
        case .partition: "Rewriting the partition table"
        case .truncate: "Truncating the image"
        case .done: "Done"
        }
    }

    static func summary(of report: ShrinkReport) -> String {
        var lines: [String] = []
        switch report.status {
        case .ok:
            lines.append("Shrunk \(report.imagePath)")
            lines.append(
                "  \(Sizing.humanBytes(report.bytesBefore)) → \(Sizing.humanBytes(report.bytesAfter))"
                    + " (saved \(Sizing.humanBytes(report.bytesSaved)))")
        case .skipped:
            lines.append("Nothing to do for \(report.imagePath)")
            lines.append("  The filesystem is already as small as it usefully gets.")
        case .planned:
            lines.append("Plan for \(report.imagePath) (dry run, nothing was changed)")
            lines.append(
                "  \(Sizing.humanBytes(report.bytesBefore)) → about "
                    + "\(Sizing.humanBytes(report.bytesAfter))")
        }
        if report.expansionArmed != .none {
            lines.append("  First-boot expansion: \(report.expansionArmed.rawValue)")
        }
        for warning in report.warnings {
            lines.append("  warning: \(warning)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Keeps every event for assertions. Used by the tests.
public final class RecordingEventSink: EventSink {
    private let storage = Locked<[Event]>([])
    public init() {}
    public func emit(_ event: Event) { storage.withLock { $0.append(event) } }
    public var events: [Event] { storage.current }
}
