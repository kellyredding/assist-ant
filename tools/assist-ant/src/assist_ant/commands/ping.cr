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
        message = args.first? || "ping"
        detail = {"message" => JSON::Any.new(message)}
        AssistAnt::EventPublisher.publish(
          event: "ping",
          detail_data: detail,
        )
      end
    end
  end
end
