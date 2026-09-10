// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// Process exit codes. These are part of the integration interface: a host may
/// rely on them alone when it does not parse the event stream.
public enum ExitCode: Int32, Sendable {
    /// The run completed. The image was shrunk, or was already tight enough.
    case success = 0
    /// Something went wrong that is neither of the more specific cases below.
    case failure = 1
    /// The input is not something this tool can process, and never will be.
    case unsupported = 2
    /// The environment is not fit to run: missing tool, locked file, root, stale attachment.
    case precondition = 3
    /// The run was cancelled by SIGINT or SIGTERM.
    case cancelled = 4
    /// The caller asked for a protocol version this build does not implement.
    case protocolMismatch = 5
}

/// Machine-readable error codes carried by the terminal `error` event.
public enum ErrorCode: String, Sendable {
    case failed = "FAILED"
    case unsupportedImage = "UNSUPPORTED_IMAGE"
    case preconditionFailed = "PRECONDITION_FAILED"
    case cancelled = "CANCELLED"
    case protocolMismatch = "PROTOCOL_MISMATCH"

    public var exitCode: ExitCode {
        switch self {
        case .failed: .failure
        case .unsupportedImage: .unsupported
        case .preconditionFailed: .precondition
        case .cancelled: .cancelled
        case .protocolMismatch: .protocolMismatch
        }
    }
}

/// Every error this tool reports, carrying the exit code it maps to.
public struct ShrinkError: Error, CustomStringConvertible, Sendable {
    public let code: ErrorCode
    public let message: String
    /// What the caller can do about it, when there is something.
    public let recovery: String?

    public init(_ code: ErrorCode, _ message: String, recovery: String? = nil) {
        self.code = code
        self.message = message
        self.recovery = recovery
    }

    public var description: String {
        guard let recovery else { return message }
        return "\(message)\n\(recovery)"
    }

    public var exitCode: ExitCode { code.exitCode }

    public static func unsupported(_ message: String, recovery: String? = nil) -> ShrinkError {
        ShrinkError(.unsupportedImage, message, recovery: recovery)
    }

    public static func precondition(_ message: String, recovery: String? = nil) -> ShrinkError {
        ShrinkError(.preconditionFailed, message, recovery: recovery)
    }

    public static func failed(_ message: String, recovery: String? = nil) -> ShrinkError {
        ShrinkError(.failed, message, recovery: recovery)
    }

    public static let cancelled = ShrinkError(.cancelled, "Cancelled.")
}
