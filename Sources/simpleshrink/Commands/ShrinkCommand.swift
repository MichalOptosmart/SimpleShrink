// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation
import SimpleShrinkKit

enum ShrinkCommand {
    static func run(path: String, options: ShrinkOptions, json: Bool, verbose: Bool) -> ExitCode {
        let sink: any EventSink = json ? JSONEventSink() : ConsoleEventSink(verbose: verbose)
        let request = ShrinkRequest(input: .init(path: path), options: options)
        return execute(request, sink: sink)
    }

    /// Shared by `shrink` and `run`: the two differ only in where the request comes
    /// from and how the events are rendered.
    static func execute(_ request: ShrinkRequest, sink: any EventSink) -> ExitCode {
        do {
            let tools = try E2fsprogs.locate()
            let report = try ShrinkPipeline(tools: tools, sink: sink).run(request)
            sink.emit(.result(report))
            return .success
        } catch let error as ShrinkError {
            AttachmentRegistry.shared.detachAll()
            sink.emit(.failure(code: error.code, message: error.description))
            return error.exitCode
        } catch {
            AttachmentRegistry.shared.detachAll()
            sink.emit(.failure(code: .failed, message: error.localizedDescription))
            return .failure
        }
    }
}
