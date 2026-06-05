import Foundation

/// Centralized file logging for the AssistAnt app.
///
/// Writes to ~/.assist-ant/assist-ant-app.log — a file we can always read
/// regardless of how the app was launched. macOS unified logging (NSLog /
/// os.Logger) redacts or drops messages from ad-hoc-signed builds, so a
/// plain log file is the only reliable option outside an Xcode debug
/// session. Mirrors Galaxy's GalaxyLog.
///
/// View live:  tail -f ~/.assist-ant/assist-ant-app.log
/// Search:     grep "AssistAnt/dbg/cursor" ~/.assist-ant/assist-ant-app.log
enum AssistAntLog {
    private static let logURL =
        AssistAntPaths.root.appendingPathComponent("assist-ant-app.log")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Serializes writes (and the non-thread-safe DateFormatter) so logging
    /// from any thread stays consistent.
    private static let queue =
        DispatchQueue(label: "com.kellyredding.AssistAnt.log")

    /// A general app log line.
    static func info(_ message: String) {
        write("[AssistAnt] \(message)")
    }

    /// Diagnostic logging for transient bug investigations. `tag`
    /// categorizes the subsystem (e.g. "cursor"). Remove the call sites
    /// once a bug is resolved; this method itself can stay.
    static func dbg(_ tag: String, _ message: String) {
        write("[AssistAnt/dbg/\(tag)] \(message)")
    }

    private static func write(_ message: String) {
        let now = Date()
        let url = logURL
        queue.async {
            let timestamp = dateFormatter.string(from: now)
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            let fm = FileManager.default
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
