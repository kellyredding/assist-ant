module AssistAnt
  module Commands
    # `assist-ant briefing`: ask the running app for the persona's startup
    # briefing snapshot — today list + through-end-of-next-week lookahead +
    # icebox summary — and print the JSON reply to stdout for the agent to
    # consume. A read, not a write: it requires the app to be running (the
    # persona always runs inside it).
    class Briefing
      def run(args : Array(String))
        unless args.empty?
          STDERR.puts "Error: briefing takes no arguments"
          exit 1
        end

        reply = EventPublisher.request(event: "briefing.query")
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end

        puts reply
      end
    end
  end
end
