module AssistAnt
  module Commands
    # `assist-ant priority set`: replace the title-bar priority state in one call.
    # Generic + prompt-driven: a single free-form monospaced body block
    # (--body PATH, the file holding the raw block). The app stores it verbatim
    # and stamps the capture time — this command knows nothing about where the
    # summary came from. Request/reply so the agent gets a clear ack; authoring
    # always runs with the app up (the capture task or a direct ask). Mirrors the
    # `spend set` command, minus the pill strings and multi-card variants.
    class Priority
      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?
        case sub
        when "set"
          set(rest)
        when nil, "-h", "--help", "help"
          puts group_help
        else
          STDERR.puts "Error: unknown priority subcommand '#{sub}'"
          STDERR.puts "Run 'assist-ant priority --help' for usage"
          exit 1
        end
      end

      private def group_help : String
        <<-HELP
        assist-ant priority — capture a priority snapshot for the title-bar widget

        USAGE:
          assist-ant priority <subcommand> [options]

        SUBCOMMANDS:
          set    Replace the title-bar priority state (one monospaced body block).

        Run 'assist-ant priority set --help' for details.
        HELP
      end

      private def set(args : Array(String))
        # Handle help before OptionParser so an in-process `priority set --help`
        # (the unit routing spec) returns cleanly instead of calling `exit`,
        # which would terminate the whole spec process. Mirrors `spend set`.
        if args.first? == "-h" || args.first? == "--help"
          puts set_help
          return
        end

        body_path = ""

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant priority set --body PATH"
          p.on("-h", "--help", "Show this help") { puts set_help; exit 0 }
          p.on("--body=PATH", "A file holding the raw monospaced summary block") do |v|
            body_path = v
          end
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant priority set") }
        end

        if body_path.empty?
          STDERR.puts "Error: nothing to set (need --body PATH)"
          exit 1
        end

        unless File.exists?(body_path)
          STDERR.puts "Error: --body file not found: #{body_path}"
          exit 1
        end

        body = File.read(body_path)
        if body.strip.empty?
          STDERR.puts "Error: --body file is empty: #{body_path}"
          exit 1
        end

        detail = {} of String => JSON::Any
        detail["body"] = JSON::Any.new(body)

        request_ack("priority.set", detail)
        puts "Captured priority snapshot (#{body.lines.size} line(s))."
      end

      private def set_help : String
        <<-HELP
        assist-ant priority set — replace the title-bar priority state

        USAGE:
          assist-ant priority set --body /path/to/block.txt

        OPTIONS:
          --body PATH    A file holding the raw monospaced summary block (the
                         prioritized progress snapshot). Stored verbatim.
          -h, --help     Show this help

        The call REPLACES the whole priority state. The app stores the block
        verbatim, stamps the capture time, and parses nothing.

        EXAMPLE:
          assist-ant priority set --body /tmp/aa-progress.md
        HELP
      end

      # Send a request envelope, return the parsed ack, or print an error + exit.
      # A nil/empty reply means the app isn't running; `{"ok":false}` means the
      # app refused the write. (Same shape as the spend / task commands.)
      private def request_ack(event : String, detail : Hash(String, JSON::Any)) : JSON::Any
        reply = AssistAnt::EventPublisher.request(event: event, detail_data: detail)
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end
        ack = JSON.parse(reply)
        unless ack["ok"]?.try(&.as_bool?)
          STDERR.puts "Error: #{ack["error"]?.try(&.as_s?) || "priority request failed"}"
          exit 1
        end
        ack
      end

      private def abort_flag(message : String, command : String)
        STDERR.puts "Error: #{message}"
        STDERR.puts "Run '#{command} --help' for usage"
        exit 1
      end
    end
  end
end
