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
      when "-v", "--version"
        puts "assist-ant #{VERSION}"
      when "ping"
        Commands::Ping.new.run(rest)
      when "calendar-item"
        Commands::CalendarItem.new.run(rest)
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
        Usage: assist-ant [options] <command> [args]

        Commands:
          ping [message]                Send a ping envelope to the running app.
          calendar-item upsert [flags]  Upsert a calendar item.
          calendar-item prune [flags]   Reconcile (prune) calendar items in a window.

        Options:
          -h, --help       Show help
          -v, --version    Show version
        USAGE
    end
  end
end
