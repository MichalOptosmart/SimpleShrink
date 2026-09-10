// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Dispatch
import Foundation
import SimpleShrinkKit

/// SIGINT and SIGTERM ask the pipeline to stop; they never leave a device attached.
///
/// A host that decides this tool is unresponsive will follow SIGTERM with SIGKILL, so
/// the shutdown has a deadline of its own: if the pipeline has not unwound in time, the
/// handler detaches whatever is live and exits, which is still better than being killed
/// with an image attached.
enum SignalHandling {
    /// How long the pipeline gets to unwind on its own after a signal.
    static let gracePeriod: TimeInterval = 20

    private nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []

    static func install() {
        for number in [SIGINT, SIGTERM] {
            // The default disposition must go, or the process dies before the handler runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { handle() }
            source.resume()
            sources.append(source)
        }
    }

    private static func handle() {
        Cancellation.shared.cancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
            AttachmentRegistry.shared.detachAll()
            exit(ExitCode.cancelled.rawValue)
        }
    }
}
