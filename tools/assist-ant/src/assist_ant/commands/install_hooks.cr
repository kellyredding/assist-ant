module AssistAnt
  module Commands
    # Installs AssistAnt's hooks into the workspace settings.json.
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
          puts ok ? "Removed AssistAnt hooks." : "Nothing to remove."
          return
        end

        if AssistAnt::HooksManager.install
          events = AssistAnt::HooksManager::HOOKS.keys.join(", ")
          puts "Installed AssistAnt hooks (#{events}) → " \
               "#{AssistAnt::HooksManager.settings_file}"
        else
          # A missing workspace is expected on non-agent machines; not an error.
          puts "Skipped: workspace not present."
        end
      end

      private def help : String
        <<-HELP
        assist-ant install-hooks — install AssistAnt's hooks in the workspace

        USAGE:
          assist-ant install-hooks [uninstall]

        DESCRIPTION:
          Marker-merges AssistAnt's hooks into the embedded agent's workspace
          .claude/settings.json, preserving any other hooks and keys:

            SessionStart      the app learns the current session id on
                              startup/resume/clear/compact
            UserPromptSubmit  the app learns that a prompt it submitted was
                              actually taken, which is the only signal that
                              confirms an automated send

          Idempotent. Pass `uninstall` to remove only AssistAnt's hooks.
        HELP
      end
    end
  end
end
