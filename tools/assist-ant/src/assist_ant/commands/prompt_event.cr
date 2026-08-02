module AssistAnt
  module Commands
    # UserPromptSubmit hook target. Publishes `agent:prompt-accepted` so the
    # app can tell that a prompt it typed was actually taken.
    #
    # This is the only honest answer to that question. Everything observable
    # from the terminal side — the keyboard protocol flag, bytes received,
    # screen content, output silence — reports ready against a prompt that
    # does not exist, so the agent reporting receipt in its own words is what
    # the app waits on. Fire-and-forget; silent on failure (a hook must never
    # surface noise or a non-zero exit).
    class PromptEvent
      def run(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts help
          return
        end

        if detail = self.class.detail_from(STDIN.gets_to_end)
          AssistAnt::EventPublisher.publish(
            event: "agent:prompt-accepted", detail_data: detail)
        end
      rescue
        # Silent: hooks must never disrupt the session.
      end

      # Pure: hook JSON string -> publish detail, or nil when there's no
      # session_id to report. Unit-testable without a socket.
      #
      # The prompt text itself is deliberately not carried. The app only needs
      # to know that *a* prompt landed — it matches against its own send, and
      # forwarding the text would put whatever the user typed onto the socket
      # for no benefit.
      def self.detail_from(input : String) : Hash(String, JSON::Any)?
        return nil if input.empty?
        data = JSON.parse(input)
        sid = data["session_id"]?.try(&.as_s?)
        return nil unless sid
        {"session_id" => JSON::Any.new(sid)}
      rescue
        nil
      end

      private def help : String
        <<-HELP
        assist-ant prompt-event — publish an agent:prompt-accepted event

        USAGE:
          <UserPromptSubmit hook JSON on stdin> | assist-ant prompt-event

        DESCRIPTION:
          Reads the Claude Code UserPromptSubmit hook JSON from stdin and
          publishes an `agent:prompt-accepted` event (session_id) to the running
          app, which uses it to confirm that a prompt it submitted was taken.
          Installed automatically by `assist-ant install-hooks`. Exits 0 always.
        HELP
      end
    end
  end
end
