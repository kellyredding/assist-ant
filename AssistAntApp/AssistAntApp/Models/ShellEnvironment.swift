import Foundation

/// Captures the user's login-shell environment so the embedded agent
/// session matches what a terminal gets — profile-exported secrets, the
/// full PATH, locale. AssistAnt spawns claude-persona directly (not via a
/// shell), so without this it inherits launchd's minimal environment and
/// misses everything the login profile exports. There is no Shell pane here
/// (unlike Galaxy), so this is the app's only login-shell touchpoint.
///
/// Pure functions, no state. The environment capture runs a subprocess
/// synchronously — call it OFF the main thread.
enum ShellEnvironment {
    /// Resolve the user's login shell from the passwd database. Falls back
    /// to `/bin/zsh` if the lookup fails for any reason (extremely unlikely
    /// on a normally-configured macOS install).
    static func userLoginShell() -> String {
        let uid = getuid()
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil
        var buffer = [CChar](repeating: 0, count: 1024)
        let rc = getpwuid_r(uid, &pwd, &buffer, buffer.count, &result)
        if rc == 0, result != nil, let shellPtr = pwd.pw_shell {
            let shell = String(cString: shellPtr)
            if !shell.isEmpty {
                return shell
            }
        }
        return "/bin/zsh"
    }

    /// Capture the environment of the user's login shell as an array of
    /// "KEY=VALUE" strings — the same environment a terminal would have.
    ///
    /// Delegates entirely to the login shell (resolved from the passwd DB)
    /// run as an INTERACTIVE LOGIN shell — `-i -l` — so the capture works
    /// across shells regardless of which startup files hold what (notably
    /// zsh, whose `.zshrc` is interactive-only). AssistAnt makes no
    /// assumptions about which shell or dotfiles the user runs; it just asks
    /// the shell what its environment is.
    ///
    /// `env -0` emits NUL-delimited records so values containing newlines
    /// survive intact. Returns nil on any failure (launch failure, non-zero
    /// exit, timeout, undecodable output) so callers fall back to the
    /// process's own environment.
    ///
    /// Runs a subprocess synchronously — call OFF the main thread.
    static func loginShellEnvironment(timeout: TimeInterval = 10) -> [String]? {
        let shell = userLoginShell()
        guard let data = runCapturing(
            shell, ["-i", "-l", "-c", "env -0"], timeout: timeout
        ) else {
            return nil
        }

        // Split on NUL; keep only well-formed, decodable KEY=VALUE records.
        let entries = data
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .filter { $0.contains("=") }

        return entries.isEmpty ? nil : entries
    }

    /// Run `executable args` and return stdout, or nil on launch failure,
    /// non-zero exit, or timeout.
    ///
    /// stdin is `/dev/null` so an interactive shell gets EOF immediately and
    /// never blocks waiting for input. stdout is drained on a background
    /// queue so output larger than the pipe buffer can't deadlock against
    /// the exit wait. The wait is bounded by `timeout` and escalates to
    /// SIGKILL, so a wedged profile can't park the caller forever.
    private static func runCapturing(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval
    ) -> Data? {
        let task = Process()
        let outPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        do {
            try task.run()
        } catch {
            return nil
        }

        // Drain stdout concurrently (after a successful launch, so a launch
        // failure can't leak a thread parked on a never-closing pipe).
        var outData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Hard-kill a wedged shell; SIGTERM-ignoring profiles still die.
            // Killing closes its stdout, which drives the drain to EOF.
            kill(task.processIdentifier, SIGKILL)
            return nil
        }

        // The process has exited, so its stdout EOF is imminent — bounded.
        _ = drained.wait(timeout: .now() + 2)
        guard task.terminationStatus == 0 else { return nil }
        return outData
    }
}
