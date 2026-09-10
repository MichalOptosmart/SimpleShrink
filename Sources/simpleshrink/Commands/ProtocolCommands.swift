// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.
//
// `describe` and `run` are the host-facing half of the tool: one says what this build
// can do, the other does it. docs/INTEGRATION.md describes both normatively.

import Foundation
import SimpleShrinkKit

enum DescribeCommand {
    static func run(protocolVersion: Int) -> ExitCode {
        guard protocolVersion == SimpleShrink.protocolVersion else {
            let message = "error: this build implements protocol version "
                + "\(SimpleShrink.protocolVersion), not \(protocolVersion).\n"
            FileHandle.standardError.write(Data(message.utf8))
            return .protocolMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Manifest.current) else { return .failure }
        print(String(decoding: data, as: UTF8.self))
        return .success
    }
}

enum RunCommand {
    static func run(protocolVersion: Int, capability: String) -> ExitCode {
        let sink = JSONEventSink()

        guard protocolVersion == SimpleShrink.protocolVersion else {
            sink.emit(
                .failure(
                    code: .protocolMismatch,
                    message: "This build implements protocol version "
                        + "\(SimpleShrink.protocolVersion), not \(protocolVersion)."))
            return .protocolMismatch
        }

        // One JSON object, read to EOF: the host closes stdin when the request is complete.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard !input.isEmpty else {
            sink.emit(.failure(code: .failed, message: "No request on standard input."))
            return .failure
        }

        let request: ShrinkRequest
        do {
            request = try JSONDecoder().decode(ShrinkRequest.self, from: input)
        } catch {
            sink.emit(
                .failure(
                    code: .failed,
                    message: "The request is not a valid protocol \(SimpleShrink.protocolVersion) "
                        + "object: \(error.localizedDescription)"))
            return .failure
        }

        guard request.capability == capability else {
            sink.emit(
                .failure(
                    code: .protocolMismatch,
                    message: "The request asks for capability '\(request.capability)' but the "
                        + "command line names '\(capability)'."))
            return .protocolMismatch
        }

        return ShrinkCommand.execute(request, sink: sink)
    }
}
