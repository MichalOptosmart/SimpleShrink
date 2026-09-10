// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
//
// The host integration interface: the JSON request `run` reads, the NDJSON events it
// writes, and the manifest `describe` prints. docs/INTEGRATION.md is the normative
// description of all three; this file is its implementation.

import Foundation

// MARK: - Request

/// Which first-boot expansion mechanism to arm.
public enum ExpansionStrategy: String, Codable, Sendable, CaseIterable {
    /// Pick by inspecting the root filesystem.
    case auto
    /// `init=/usr/lib/raspi-config/init_resize.sh`, for Raspberry Pi OS.
    case raspi
    /// A `systemd.run` one-shot script, for images without raspi-config.
    case generic
    /// Shrink only; the image will not grow back on its own.
    case none
}

/// Everything a caller can vary about a run.
public struct ShrinkOptions: Codable, Sendable, Equatable {
    /// Slack left in the shrunk filesystem, in MiB.
    public var freeSpaceMiB: UInt64
    /// Which expansion mechanism to arm.
    public var expansion: ExpansionStrategy
    /// When set, the source is copied here first and the copy is shrunk.
    public var outputPath: String?
    /// Copy the partition to scratch space instead of resizing the attached slice.
    public var extractMode: Bool
    /// Probe and report the plan; change nothing.
    public var dryRun: Bool

    public init(
        freeSpaceMiB: UInt64 = 64,
        expansion: ExpansionStrategy = .auto,
        outputPath: String? = nil,
        extractMode: Bool = false,
        dryRun: Bool = false
    ) {
        self.freeSpaceMiB = freeSpaceMiB
        self.expansion = expansion
        self.outputPath = outputPath
        self.extractMode = extractMode
        self.dryRun = dryRun
    }

    /// Hosts that only know about "expand it or don't" send `armExpansion` instead of
    /// naming a strategy; both spellings decode, and `expansion` wins if both appear.
    private enum CodingKeys: String, CodingKey {
        case freeSpaceMiB, expansion, armExpansion, outputPath, extractMode, dryRun
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(freeSpaceMiB, forKey: .freeSpaceMiB)
        try container.encode(expansion, forKey: .expansion)
        try container.encodeIfPresent(outputPath, forKey: .outputPath)
        try container.encode(extractMode, forKey: .extractMode)
        try container.encode(dryRun, forKey: .dryRun)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        freeSpaceMiB = try container.decodeIfPresent(UInt64.self, forKey: .freeSpaceMiB) ?? 64
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
        extractMode = try container.decodeIfPresent(Bool.self, forKey: .extractMode) ?? false
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false

        if let named = try container.decodeIfPresent(ExpansionStrategy.self, forKey: .expansion) {
            expansion = named
        } else if let arm = try container.decodeIfPresent(Bool.self, forKey: .armExpansion) {
            expansion = arm ? .auto : .none
        } else {
            expansion = .auto
        }
    }
}

/// The single JSON object `simpleshrink run` reads from standard input.
public struct ShrinkRequest: Codable, Sendable {
    public struct Input: Codable, Sendable {
        public var path: String
        public init(path: String) { self.path = path }
    }

    /// Interface version the host is speaking. Must match `SimpleShrink.protocolVersion`.
    public var version: Int
    /// Capability being invoked; version 1 declares exactly one, `shrink`.
    public var capability: String
    /// Opaque host identifier, echoed back on every event.
    public var requestId: String?
    public var input: Input
    public var options: ShrinkOptions

    private enum CodingKeys: String, CodingKey {
        case version = "protocol", capability, requestId, input, options
    }

    public init(
        version: Int = SimpleShrink.protocolVersion,
        capability: String = "shrink",
        requestId: String? = nil,
        input: Input,
        options: ShrinkOptions = ShrinkOptions()
    ) {
        self.version = version
        self.capability = capability
        self.requestId = requestId
        self.input = input
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? SimpleShrink.protocolVersion
        capability = try container.decodeIfPresent(String.self, forKey: .capability) ?? "shrink"
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        input = try container.decode(Input.self, forKey: .input)
        options = try container.decodeIfPresent(ShrinkOptions.self, forKey: .options) ?? ShrinkOptions()
    }

    /// Checks the request against what this build implements, before anything is touched.
    public func validate() throws {
        guard version == SimpleShrink.protocolVersion else {
            throw ShrinkError(
                .protocolMismatch,
                "This build implements protocol version \(SimpleShrink.protocolVersion), "
                    + "the request asks for \(version)."
            )
        }
        guard capability == "shrink" else {
            throw ShrinkError(.protocolMismatch, "Unknown capability: \(capability)")
        }
    }
}

// MARK: - Result

/// The outcome of a run, carried by the terminal `result` event and printed by `shrink`.
public struct ShrinkReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The image was shrunk.
        case ok
        /// Nothing was changed because there was nothing worth gaining.
        case skipped
        /// `--dry-run`: this is what a real run would have done.
        case planned
    }

    public var status: Status
    public var imagePath: String
    public var bytesBefore: UInt64
    public var bytesAfter: UInt64
    public var filesystemBlocksBefore: UInt64
    public var filesystemBlocksAfter: UInt64
    public var blockSize: UInt64
    /// The expansion mechanism that was armed, if any.
    public var expansionArmed: ExpansionStrategy
    public var warnings: [String]

    public var bytesSaved: UInt64 { bytesBefore > bytesAfter ? bytesBefore - bytesAfter : 0 }

    public init(
        status: Status,
        imagePath: String,
        bytesBefore: UInt64,
        bytesAfter: UInt64,
        filesystemBlocksBefore: UInt64,
        filesystemBlocksAfter: UInt64,
        blockSize: UInt64,
        expansionArmed: ExpansionStrategy,
        warnings: [String] = []
    ) {
        self.status = status
        self.imagePath = imagePath
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.filesystemBlocksBefore = filesystemBlocksBefore
        self.filesystemBlocksAfter = filesystemBlocksAfter
        self.blockSize = blockSize
        self.expansionArmed = expansionArmed
        self.warnings = warnings
    }
}

// MARK: - Events

public enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

/// One line of the NDJSON stream. Exactly one `result` or `error` is emitted, last.
public enum Event: Encodable, Sendable {
    case progress(stage: Stage, fraction: Double, message: String?)
    case log(level: LogLevel, message: String)
    case result(ShrinkReport)
    case failure(code: ErrorCode, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, stage, fraction, message, level, code, result
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .progress(stage, fraction, message):
            try container.encode("progress", forKey: .type)
            try container.encode(stage, forKey: .stage)
            try container.encode((fraction * 10000).rounded() / 10000, forKey: .fraction)
            try container.encodeIfPresent(message, forKey: .message)
        case let .log(level, message):
            try container.encode("log", forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(message, forKey: .message)
        case let .result(report):
            try container.encode("result", forKey: .type)
            try container.encode(report, forKey: .result)
        case let .failure(code, message):
            try container.encode("error", forKey: .type)
            try container.encode(code.rawValue, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .result, .failure: true
        case .progress, .log: false
        }
    }
}

// MARK: - Manifest

/// What `describe` prints, and what `integration/manifest.json.in` is generated from:
/// enough for a host to install, address and invoke this tool without prior knowledge.
public struct Manifest: Encodable, Sendable {
    public struct Capability: Encodable, Sendable {
        public var id: String
        public var verb: String
        public var appliesTo: [String]
        public var titles: [String: String]
        public var options: [String]
    }

    public var identifier = SimpleShrink.identifier
    public var name = "SimpleShrink"
    public var version = SimpleShrink.version
    public var protocolVersion = SimpleShrink.protocolVersion
    public var license = "GPL-2.0-only"
    public var homepage = "https://github.com/optosmart/simpleshrink"
    public var platform = "macOS 15+, universal (arm64, x86_64)"
    public var requiresPrivileges = false
    public var capabilities: [Capability]

    private enum CodingKeys: String, CodingKey {
        case identifier, name, version, license, homepage, platform, requiresPrivileges,
            capabilities
        case protocolVersion = "protocol"
    }

    public static let current = Manifest(capabilities: [
        Capability(
            id: "shrink",
            verb: "transform",
            appliesTo: ["image"],
            titles: [
                "en": "Shrink disk image",
                "cs": "Zmenšit obraz disku",
                "de": "Datenträgerabbild verkleinern",
                "sk": "Zmenšiť obraz disku",
            ],
            options: ["freeSpaceMiB", "expansion", "armExpansion", "outputPath", "extractMode", "dryRun"]
        )
    ])
}
