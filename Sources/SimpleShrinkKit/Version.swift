// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

public enum SimpleShrink {
    /// Product version. `Scripts/package.sh` checks that this matches the git tag.
    public static let version = "1.0.0"

    /// Version of the host integration protocol implemented by `describe` and `run`.
    public static let protocolVersion = 1

    /// Reverse-DNS identifier used by hosts to address this integration.
    public static let identifier = "cz.optosmart.simpleshrink"
}
