module AssistAnt
  module Commands
    # The smallest possible subcommand. Publishes a `ping` event
    # with an optional message. Used to verify the CLI ↔ app
    # pipeline is alive.
    #
    # Always exits 0 — the CLI must work whether or not the app is
    # running.
    class Ping
      def run(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts ping_help
          return
        end

        message = args.first? || "ping"
        detail = {"message" => JSON::Any.new(message)}
        AssistAnt::EventPublisher.publish(
          event: "ping",
          detail_data: detail,
        )
      end

      private def ping_help : String
        <<-HELP
        assist-ant ping — send a ping envelope to the running app

        USAGE:
          assist-ant ping [MESSAGE]

        ARGUMENTS:
          MESSAGE                Optional text to include (default: "ping")

        OPTIONS:
          -h, --help             Show this help

        DESCRIPTION:
          Publishes a `ping` event to verify the CLI ↔ app pipeline is alive.
          Exits 0 whether or not the app is running.

        EXAMPLES:
          assist-ant ping
          assist-ant ping "hello from the CLI"
        HELP
      end
    end
  end
end
