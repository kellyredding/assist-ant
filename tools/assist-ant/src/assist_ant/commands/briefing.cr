module AssistAnt
  module Commands
    # `assist-ant briefing`: ask the running app for the persona's startup
    # briefing snapshot — today list + through-end-of-next-week lookahead +
    # icebox summary — and print the JSON reply to stdout for the agent to
    # consume. A read, not a write: it requires the app to be running (the
    # persona always runs inside it).
    class Briefing
      def run(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts briefing_help
          return
        end

        unless args.empty?
          STDERR.puts "Error: briefing takes no arguments"
          STDERR.puts "Run 'assist-ant briefing --help' for usage"
          exit 1
        end

        reply = EventPublisher.request(event: "briefing.query")
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end

        puts reply
      end

      private def briefing_help : String
        <<-HELP
        assist-ant briefing — print the app's startup briefing snapshot

        USAGE:
          assist-ant briefing

        OPTIONS:
          -h, --help             Show this help

        DESCRIPTION:
          Asks the running app for the persona's startup briefing — today's
          list, the through-end-of-next-week lookahead, and an icebox summary —
          and prints the JSON reply to stdout. A read, not a write: requires the
          app to be running.

        EXAMPLES:
          assist-ant briefing
        HELP
      end
    end
  end
end
