import Foundation
import OSLog

/// What Diktaf says about itself.
///
/// An accessory application has no window to complain in and no terminal to
/// print to, so without this a dictation that fails does so in total silence —
/// which is indistinguishable from the hotkey never having arrived. Every state
/// the session reaches and every failure goes here, and it can be read back
/// afterwards with:
///
/// ```sh
/// log show --last 5m --predicate 'subsystem == "com.mdikcinar.diktaf"' --info
/// log stream --predicate 'subsystem == "com.mdikcinar.diktaf"' --info
/// ```
///
/// The unified log rather than a file: it costs nothing when nobody is looking,
/// it survives a crash, and it does not need somewhere to put a log file.
enum Diagnostics {
    private static let log = Logger(subsystem: "com.mdikcinar.diktaf", category: "diktaf")

    static func state(_ description: String) {
        log.info("state: \(description, privacy: .public)")
        write("state: \(description)")
    }

    static func event(_ description: String) {
        log.info("\(description, privacy: .public)")
        write(description)
    }

    static func failure(_ description: String) {
        log.error("\(description, privacy: .public)")
        write("failed: \(description)")
    }

    /// And to stderr, which is where the launch agent points its log file.
    ///
    /// Both, rather than one: the unified log keeps info-level messages in memory
    /// and drops them, so a failure from ten minutes ago is often no longer there
    /// to read — and ten minutes ago is exactly when the thing being investigated
    /// happened.
    private static func write(_ line: String) {
        guard let data = "diktaf: \(line)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
