module AssistAnt
  module Commands
    # The reply half of every authoring command: send a request envelope, then
    # turn the app's ack into either a parsed reply or a clean exit.
    #
    # A mixin rather than a method on `EventPublisher`, which is deliberately
    # pure I/O — it never writes to STDERR and never exits, so its callers stay
    # free to branch on what it returns. Presenting a failure and ending the
    # process is a CLI concern, and every authoring group had independently
    # arrived at the same nine lines for it.
    module RequestAck
      # Send `event` with `detail` and return the parsed ack, or print one line
      # and exit non-zero.
      #
      # A nil or empty reply means the app isn't running. Authoring always
      # happens with the app up — the agent runs inside it — so silence is a
      # failure to report rather than something to shrug at, unlike the `sync`
      # senders that publish and move on.
      #
      # `{"ok":false}` means the app refused the write and said why, and the
      # reason is relayed verbatim: the app knows whether an id was unknown, an
      # item was synced, or a note was already converted, and the CLI does not.
      # The fallback text only surfaces for an ack that reports failure without
      # naming one, which the app does not currently produce.
      private def request_ack(
        event : String, detail : Hash(String, JSON::Any),
      ) : JSON::Any
        reply = AssistAnt::EventPublisher.request(event: event, detail_data: detail)
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end
        ack = JSON.parse(reply)
        unless ack["ok"]?.try(&.as_bool?)
          STDERR.puts "Error: #{ack["error"]?.try(&.as_s?) || "request failed"}"
          exit 1
        end
        ack
      end
    end
  end
end
