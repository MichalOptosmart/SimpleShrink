// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation
import Testing

@testable import SimpleShrinkKit

@Suite("Integration protocol")
struct ProtocolTests {
    func decode(_ json: String) throws -> ShrinkRequest {
        try JSONDecoder().decode(ShrinkRequest.self, from: Data(json.utf8))
    }

    func encode(_ event: Event) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A minimal request is enough; everything else has a documented default")
    func decodesMinimalRequest() throws {
        let request = try decode(#"{"protocol":1,"input":{"path":"/tmp/pi.img"}}"#)
        #expect(request.version == 1)
        #expect(request.capability == "shrink")
        #expect(request.input.path == "/tmp/pi.img")
        #expect(request.options.freeSpaceMiB == 64)
        #expect(request.options.expansion == .auto)
        #expect(!request.options.extractMode)
    }

    @Test("Options are read as sent")
    func decodesOptions() throws {
        let request = try decode(
            """
            {"protocol":1,"capability":"shrink","requestId":"job-7",
             "input":{"path":"/tmp/pi.img"},
             "options":{"freeSpaceMiB":128,"expansion":"generic","outputPath":"/tmp/out.img",
                        "extractMode":true,"dryRun":false}}
            """)
        #expect(request.requestId == "job-7")
        #expect(request.options.freeSpaceMiB == 128)
        #expect(request.options.expansion == .generic)
        #expect(request.options.outputPath == "/tmp/out.img")
        #expect(request.options.extractMode)
    }

    @Test("A host that only knows armExpansion still gets what it asked for")
    func acceptsArmExpansionBoolean() throws {
        #expect(
            try decode(#"{"protocol":1,"input":{"path":"/x"},"options":{"armExpansion":false}}"#)
                .options.expansion == .none)
        #expect(
            try decode(#"{"protocol":1,"input":{"path":"/x"},"options":{"armExpansion":true}}"#)
                .options.expansion == .auto)
    }

    @Test("A request for another protocol version is refused before anything is touched")
    func rejectsWrongProtocol() throws {
        #expect(throws: ShrinkError.self) {
            try decode(#"{"protocol":99,"input":{"path":"/x"}}"#).validate()
        }
        #expect(throws: ShrinkError.self) {
            try decode(#"{"protocol":1,"capability":"grow","input":{"path":"/x"}}"#).validate()
        }
    }

    @Test("A request without an input path is rejected")
    func rejectsMissingInput() {
        #expect(throws: (any Error).self) { try decode(#"{"protocol":1}"#) }
    }

    @Test("Progress events carry the stage token a host labels its UI with")
    func encodesProgress() throws {
        let object = try encode(.progress(stage: .resize, fraction: 0.5, message: "Resizing"))
        #expect(object["type"] as? String == "progress")
        #expect(object["stage"] as? String == "resize")
        #expect(object["fraction"] as? Double == 0.5)
        #expect(object["message"] as? String == "Resizing")
    }

    @Test("The terminal events are shaped as documented")
    func encodesTerminalEvents() throws {
        let report = ShrinkReport(
            status: .ok, imagePath: "/tmp/pi.img", bytesBefore: 100, bytesAfter: 40,
            filesystemBlocksBefore: 10, filesystemBlocksAfter: 4, blockSize: 4096,
            expansionArmed: .raspi, warnings: ["experimental"])
        let result = try encode(.result(report))
        #expect(result["type"] as? String == "result")
        let payload = try #require(result["result"] as? [String: Any])
        #expect(payload["status"] as? String == "ok")
        #expect(payload["expansionArmed"] as? String == "raspi")

        let failure = try encode(.failure(code: .unsupportedImage, message: "GPT"))
        #expect(failure["type"] as? String == "error")
        #expect(failure["code"] as? String == "UNSUPPORTED_IMAGE")
    }

    @Test("Every error code maps to the exit code the interface documents")
    func mapsExitCodes() {
        #expect(ErrorCode.failed.exitCode == .failure)
        #expect(ErrorCode.unsupportedImage.exitCode == .unsupported)
        #expect(ErrorCode.preconditionFailed.exitCode == .precondition)
        #expect(ErrorCode.cancelled.exitCode == .cancelled)
        #expect(ErrorCode.protocolMismatch.exitCode == .protocolMismatch)
    }

    @Test("Exactly one terminal event is written, and nothing follows it")
    func emitsOneTerminalEvent() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "simpleshrink-ndjson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "events.ndjson")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        let sink = JSONEventSink(handle: handle)
        sink.progress(.check, 0.1)
        sink.emit(.failure(code: .failed, message: "boom"))
        sink.progress(.resize, 0.5)
        sink.emit(.result(
            ShrinkReport(
                status: .ok, imagePath: "/x", bytesBefore: 1, bytesAfter: 1,
                filesystemBlocksBefore: 1, filesystemBlocksAfter: 1, blockSize: 4096,
                expansionArmed: .none)))
        try handle.close()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(lines.count == 2)
        #expect(lines.last!.contains("\"type\":\"error\""))
    }

    @Test("The manifest tells a host everything it needs to invoke this tool")
    func describesItself() throws {
        let data = try JSONEncoder().encode(Manifest.current)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["identifier"] as? String == "cz.optosmart.simpleshrink")
        #expect(object["protocol"] as? Int == SimpleShrink.protocolVersion)
        #expect(object["license"] as? String == "GPL-2.0-only")
        #expect(object["requiresPrivileges"] as? Bool == false)
        let capabilities = try #require(object["capabilities"] as? [[String: Any]])
        #expect(capabilities.count == 1)
        #expect(capabilities[0]["id"] as? String == "shrink")
        let titles = try #require(capabilities[0]["titles"] as? [String: String])
        #expect(titles["en"] != nil)
        #expect(titles["cs"] != nil)
    }
}
