module AssistAnt
  class CLI
    VERSION = "0.0.1"

    def self.run(args : Array(String))
      new.run(args)
    end

    # Split the command off the front and let each command parse its own flags
    # (mirrors the Galaxy CLIs). A global option parser would reject a
    # subcommand's flags like `--external-id` as unknown.
    def run(args : Array(String))
      if args.empty?
        puts usage
        return
      end

      command = args.first
      rest = args[1..]

      case command
      when "-h", "--help", "help"
        puts usage
      when "-v", "--version", "version"
        puts "assist-ant #{VERSION}"
      when "ping"
        Commands::Ping.new.run(rest)
      when "calendar-item"
        Commands::CalendarItem.new.run(rest)
      when "actionable-item"
        Commands::ActionableItem.new.run(rest)
      when "briefing"
        Commands::Briefing.new.run(rest)
      else
        if command.starts_with?("-")
          STDERR.puts "Error: unknown flag '#{command}'"
        else
          STDERR.puts "Error: unknown command '#{command}'"
        end
        STDERR.puts usage
        exit 1
      end
    end

    private def usage : String
      <<-USAGE
        assist-ant — companion CLI for the Assist Ant app

        Usage: assist-ant [options] <command> [args]

        Commands:
          ping [message]                Send a ping envelope to the running app.
          calendar-item sync            Ingest a provider's calendar response and
                                        atomically upsert + prune the window.
          actionable-item sync          Ingest a provider's issue list (Linear),
                                        upsert as todos + resolve completed.
          actionable-item create        Create one manual to-do / reminder /
                                        explore item (unscheduled → Today).
          actionable-item list-names    List existing list names (JSON).
          briefing                      Ask the running app for the startup
                                        briefing snapshot (JSON: today, upcoming,
                                        icebox).

        Options:
          -h, --help       Show this help
          -v, --version    Show version

        Run 'assist-ant <command> --help' for detailed command usage.
        USAGE
    end
  end
end
