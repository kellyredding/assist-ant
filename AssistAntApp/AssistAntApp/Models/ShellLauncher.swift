import Foundation

/// Launch parameters for the shell pane: where its login shell starts, and
/// what environment it runs with. Pure functions, no state.
///
/// Mirrors Galaxy's `ShellLauncher` minus the login-shell lookup and
/// environment capture — `ShellEnvironment` already owns both here, and a
/// second copy would be free to drift from the one the agent session spawns
/// with. Call `ShellEnvironment.userLoginShell()` for the shell binary.
enum ShellLauncher {
    /// Directory the shell pane opens in: the user's home, like a fresh
    /// Terminal.app window.
    ///
    /// A deliberate divergence from Galaxy, which resolves a session's most
    /// recent Claude cwd, then its project root, then its persisted working
    /// directory. All three describe a per-session project context that has
    /// no equivalent here: the one embedded session runs in an app-owned
    /// workspace directory, and opening a general-purpose shell inside the
    /// agent's private scratch space would couple the two for no benefit.
    static func resolveCwd() -> String {
        NSHomeDirectory()
    }

    /// Build the environment for the shell.
    ///
    /// Base is this process's own environment rather than a login-shell
    /// capture: the shell is launched as an interactive login shell (`-il`)
    /// and sources the user's profile itself, so capturing that profile
    /// first would pay for a subprocess to compute what the shell is about
    /// to compute anyway.
    ///
    /// From that base it:
    /// - strips `TERM`, forced to `xterm-256color` below;
    /// - strips the Claude context variables, so a shell opened inside the
    ///   app doesn't look to its children like it is nested in a Claude
    ///   session. `CLAUDE_CODE_*` matters even though the app spawns the
    ///   shell directly, because launching the app from inside a Claude Code
    ///   session leaks that family into the app's own environment;
    /// - sets `LANG` to a UTF-8 locale when unset. GUI apps inherit no
    ///   locale from launchd, and without one `less` renders non-ASCII bytes
    ///   as `<HEX>` escapes. Terminal.app and iTerm2 set it themselves;
    /// - leaves everything else — `PATH`, `COLORTERM`, user variables — for
    ///   the profile to rebuild, and anything the user sets there wins.
    static func buildEnvironment() -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var env = inherited.map { "\($0.key)=\($0.value)" }
        env = env.filter {
            !$0.hasPrefix("TERM=") &&
                !$0.hasPrefix("CLAUDECODE=") &&
                !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=") &&
                !$0.hasPrefix("CLAUDE_CODE_")
        }
        env.append("TERM=xterm-256color")
        if inherited["LANG"]?.isEmpty ?? true {
            env.append("LANG=\(defaultUtf8Locale())")
        }
        return env
    }

    /// Pick a UTF-8 locale for `LANG` when nothing is inherited. Derives
    /// from `Locale.current` and appends `.UTF-8`, stripping any `@modifier`
    /// suffix (e.g. `en_US@rg=usc`) since `LANG` does not accept those.
    /// Falls back to `en_US.UTF-8` when the identifier is not a standard
    /// `xx_YY` locale.
    private static func defaultUtf8Locale() -> String {
        let id = Locale.current.identifier
        let core = id.split(separator: "@").first.map(String.init) ?? ""
        if core.contains("_") && !core.isEmpty {
            return "\(core).UTF-8"
        }
        return "en_US.UTF-8"
    }
}
