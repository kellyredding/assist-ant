module AssistAnt
  # Installs/removes AssistAnt's hooks in the embedded agent's workspace
  # settings.json. Marker-based surgical merge (mirrors Galaxy's
  # GalaxyLedger::HooksManager): touches only our own hooks, preserves any
  # other hooks and top-level keys. Idempotent and drift-correcting.
  module HooksManager
    extend self

    # `~` is expanded by Claude Code; the ~/.local/bin symlink is created by
    # `make install`.
    BIN = "~/.local/bin/assist-ant"

    # Hook event => the subcommand its hook runs. The subcommand doubles as the
    # marker that identifies our own entry for strip-and-replace, so
    # re-installs never duplicate and other hooks survive.
    #
    # SessionStart fires on startup, resume, clear, and compact, each carrying
    # the current session id — it keeps the resume target current.
    #
    # UserPromptSubmit fires when the agent takes a prompt. It is the only
    # evidence that an automated prompt actually landed: nothing observable
    # from the terminal answers that question, and every signal on that side
    # reports ready against a prompt that does not exist. Without this hook the
    # app can send prompts but never know whether they arrived — which matters
    # most here, because this agent works unattended.
    HOOKS = {
      "SessionStart"     => "session-event",
      "UserPromptSubmit" => "prompt-event",
    }

    # The workspace settings file the agent loads (project scope).
    def settings_file : Path
      Paths.workspace_dir / ".claude" / "settings.json"
    end

    # Install every hook. Returns false (no-op) when the workspace symlink is
    # absent — expected on a machine that doesn't run the agent.
    def install : Bool
      return false unless Dir.exists?(Paths.workspace_dir.to_s)

      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any

      HOOKS.each do |event, subcommand|
        existing = hooks[event]?.try(&.as_a?) || [] of JSON::Any
        filtered = existing.reject { |h| ours?(h, subcommand) }
        filtered << JSON.parse(entry_for(subcommand).to_json)
        hooks[event] = JSON.parse(filtered.to_json)
      end

      doc = settings.as_h
      doc["hooks"] = JSON.parse(hooks.to_json)
      save_settings(JSON.parse(doc.to_json))
      true
    rescue ex
      STDERR.puts "install-hooks: #{ex.message}"
      false
    end

    # Remove our hooks, preserving others; drop empty containers.
    def uninstall : Bool
      return true unless File.exists?(settings_file)
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any
      return true if hooks.empty?

      HOOKS.each do |event, subcommand|
        next unless existing = hooks[event]?.try(&.as_a?)
        kept = existing.reject { |h| ours?(h, subcommand) }
        if kept.empty?
          hooks.delete(event)
        else
          hooks[event] = JSON.parse(kept.to_json)
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

    # True only when every hook we own is present. A partial install reads as
    # not installed, so a version that added a hook self-heals on next launch
    # rather than reporting done with one of them missing.
    def installed? : Bool
      return false unless File.exists?(settings_file)
      settings = load_settings
      hooks = settings["hooks"]?.try(&.as_h?) || {} of String => JSON::Any
      HOOKS.all? do |event, subcommand|
        entries = hooks[event]?.try(&.as_a?) || [] of JSON::Any
        entries.any? { |h| ours?(h, subcommand) }
      end
    rescue
      false
    end

    private def entry_for(subcommand : String)
      {
        "hooks" => [
          {
            "type"    => "command",
            "command" => "#{BIN} #{subcommand}",
            "timeout" => 10,
          },
        ],
      }
    end

    private def ours?(entry : JSON::Any, subcommand : String) : Bool
      arr = entry["hooks"]?.try(&.as_a?) || [] of JSON::Any
      arr.any? do |h|
        cmd = h["command"]?.try(&.as_s?)
        !cmd.nil? && cmd.includes?("assist-ant #{subcommand}")
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
