module AssistAnt
  # Installs/removes AssistAnt's SessionStart hook in the embedded agent's
  # workspace settings.json. Marker-based surgical merge (mirrors Galaxy's
  # GalaxyLedger::HooksManager): touches only our own hook, preserves any other
  # hooks and top-level keys. Idempotent and drift-correcting.
  module HooksManager
    extend self

    # The hook command. `~` is expanded by Claude Code; the ~/.local/bin
    # symlink is created by `make install`. MARKER identifies our own hook for
    # strip-and-replace so re-installs never duplicate and other hooks survive.
    HOOK_COMMAND = "~/.local/bin/assist-ant session-event"
    MARKER       = "assist-ant session-event"

    # One SessionStart hook, no matcher — fires on startup, resume, clear, and
    # compact, each carrying the current session id.
    SESSION_START = [
      {
        "hooks" => [
          {"type" => "command", "command" => HOOK_COMMAND, "timeout" => 10},
        ],
      },
    ]

    # The workspace settings file the agent loads (project scope).
    def settings_file : Path
      Paths.workspace_dir / ".claude" / "settings.json"
    end

    # Install the hook. Returns false (no-op) when the workspace symlink is
    # absent — expected on a machine that doesn't run the agent.
    def install : Bool
      return false unless Dir.exists?(Paths.workspace_dir.to_s)

      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any

      existing = hooks["SessionStart"]?.try(&.as_a?) || [] of JSON::Any
      filtered = existing.reject { |h| ours?(h) }
      SESSION_START.each { |h| filtered << JSON.parse(h.to_json) }
      hooks["SessionStart"] = JSON.parse(filtered.to_json)

      doc = settings.as_h
      doc["hooks"] = JSON.parse(hooks.to_json)
      save_settings(JSON.parse(doc.to_json))
      true
    rescue ex
      STDERR.puts "install-hooks: #{ex.message}"
      false
    end

    # Remove our hook, preserving others; drop empty containers.
    def uninstall : Bool
      return true unless File.exists?(settings_file)
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any
      return true if hooks.empty?

      if existing = hooks["SessionStart"]?.try(&.as_a?)
        kept = existing.reject { |h| ours?(h) }
        if kept.empty?
          hooks.delete("SessionStart")
        else
          hooks["SessionStart"] = JSON.parse(kept.to_json)
        end
      end

      doc = settings.as_h
      if hooks.empty?
        doc.delete("hooks")
      else
        doc["hooks"] = JSON.parse(hooks.to_json)
      end
      save_settings(JSON.parse(doc.to_json))
      true
    rescue ex
      STDERR.puts "install-hooks: #{ex.message}"
      false
    end

    def installed? : Bool
      return false unless File.exists?(settings_file)
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any
      starts = hooks["SessionStart"]?.try(&.as_a?) || [] of JSON::Any
      starts.any? { |h| ours?(h) }
    rescue
      false
    end

    private def ours?(entry : JSON::Any) : Bool
      arr = entry["hooks"]?.try(&.as_a?) || [] of JSON::Any
      arr.any? do |h|
        cmd = h["command"]?.try(&.as_s?)
        !cmd.nil? && cmd.includes?(MARKER)
      end
    end

    private def load_settings : JSON::Any
      File.exists?(settings_file) ? JSON.parse(File.read(settings_file)) : JSON.parse("{}")
    end

    private def save_settings(settings : JSON::Any)
      FileUtils.mkdir_p(settings_file.parent.to_s)
      File.write(settings_file, settings.to_pretty_json + "\n")
    end
  end
end
