module AssistAnt
  module Commands
    # SessionStart hook target. Publishes a `session:ready` event carrying the
    # current session id + source so the app can keep its resume target current
    # across resumes, /clear, and /compact. Fire-and-forget; silent on failure
    # (a hook must never surface noise or a non-zero exit).
    class SessionEvent
      def run(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts help
          return
        end

        if detail = self.class.detail_from(STDIN.gets_to_end)
          AssistAnt::EventPublisher.publish(event: "session:ready", detail_data: detail)
        end
      rescue
        # Silent: hooks must never disrupt the session.
      end

      # Pure: hook JSON string -> publish detail, or nil when there's no
      # session_id to report. Unit-testable without a socket.
      def self.detail_from(input : String) : Hash(String, JSON::Any)?
        return nil if input.empty?
        data = JSON.parse(input)
        sid = data["session_id"]?.try(&.as_s?)
        return nil unless sid
        detail = {"session_id" => JSON::Any.new(sid)}
        if src = data["source"]?.try(&.as_s?)
          detail["source"] = JSON::Any.new(src)
        end
        detail
      rescue
        nil
      end

      private def help : String
        <<-HELP
        assist-ant session-event — publish a session:ready event (SessionStart hook)

        USAGE:
          <SessionStart hook JSON on stdin> | assist-ant session-event

        DESCRIPTION:
          Reads the Claude Code SessionStart hook JSON from stdin and publishes a
          `session:ready` event (session_id + source) to the running app so it can
          keep its resume target current across resumes, /clear, and /compact.
          Installed automatically by `assist-ant install-hooks`. Exits 0 always.
        HELP
      end
    end
  end
end
