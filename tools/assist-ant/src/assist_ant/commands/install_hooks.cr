module AssistAnt
  module Commands
    # Installs AssistAnt's SessionStart hook into the workspace settings.json.
    # Idempotent + drift-correcting. Run by `make install` and by the app on
    # launch (before the agent spawns).
    class InstallHooks
      def run(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts help
          return
        end

        if args.first? == "uninstall"
          ok = AssistAnt::HooksManager.uninstall
          puts ok ? "Removed AssistAnt SessionStart hook." : "Nothing to remove."
          return
        end

        if AssistAnt::HooksManager.install
          puts "Installed AssistAnt SessionStart hook → #{AssistAnt::HooksManager.settings_file}"
        else
          # A missing workspace is expected on non-agent machines; not an error.
          puts "Skipped: workspace not present."
        end
      end

      private def help : String
        <<-HELP
        assist-ant install-hooks — install the SessionStart hook in the workspace

        USAGE:
          assist-ant install-hooks [uninstall]

        DESCRIPTION:
          Marker-merges a SessionStart hook into the embedded agent's workspace
          .claude/settings.json so the app learns the current session id on
          startup/resume/clear/compact. Preserves any other hooks/keys.
          Idempotent. Pass `uninstall` to remove only AssistAnt's hook.
        HELP
      end
    end
  end
end
