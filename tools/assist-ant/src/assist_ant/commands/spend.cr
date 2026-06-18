module AssistAnt
  module Commands
    # `assist-ant spend set`: replace the title-bar spend state in one call.
    # Generic + prompt-driven: two free-form pill strings (--primary/--secondary)
    # and any number of labeled report-block cards (--variant LABEL=PATH, the file
    # holding the raw monospaced block). The app stores it verbatim — this command
    # knows nothing about where the numbers came from. Request/reply so the agent
    # gets a clear ack; authoring always runs with the app up (the heartbeat task).
    class Spend
      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?
        case sub
        when "set"
          set(rest)
        when nil, "-h", "--help", "help"
          puts group_help
        else
          STDERR.puts "Error: unknown spend subcommand '#{sub}'"
          STDERR.puts "Run 'assist-ant spend --help' for usage"
          exit 1
        end
      end

      private def group_help : String
        <<-HELP
        assist-ant spend — capture spend snapshots for the title-bar widget

        USAGE:
          assist-ant spend <subcommand> [options]

        SUBCOMMANDS:
          set    Replace the title-bar spend state (pill strings + variant cards).

        Run 'assist-ant spend set --help' for details.
        HELP
      end

      private def set(args : Array(String))
        # Handle help before OptionParser so an in-process `spend set --help`
        # (the unit routing spec) returns cleanly instead of calling `exit`,
        # which would terminate the whole spec process. Mirrors the other
        # subcommands.
        if args.first? == "-h" || args.first? == "--help"
          puts set_help
          return
        end

        primary = ""
        secondary = ""
        variants = [] of {label: String, path: String}

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant spend set [--primary S] [--secondary S] --variant LABEL=PATH ..."
          p.on("-h", "--help", "Show this help") { puts set_help; exit 0 }
          p.on("--primary=S", "Left pill string (e.g. '$392 today')") { |v| primary = v }
          p.on("--secondary=S", "Right pill string (e.g. '$2.7k mo')") { |v| secondary = v }
          p.on("--variant=ENTRY", "A card as LABEL=PATH: label + a file with the raw block (repeatable)") do |v|
            label, _, path = v.partition("=")
            if label.empty? || path.empty?
              abort_flag("--variant must be LABEL=PATH", "assist-ant spend set")
            end
            variants << {label: label, path: path}
          end
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant spend set") }
        end

        if primary.empty? && secondary.empty? && variants.empty?
          STDERR.puts "Error: nothing to set (need --primary/--secondary or a --variant)"
          exit 1
        end

        variant_json = variants.map do |v|
          unless File.exists?(v[:path])
            STDERR.puts "Error: --variant file not found: #{v[:path]}"
            exit 1
          end
          JSON::Any.new({
            "label" => JSON::Any.new(v[:label]),
            "body"  => JSON::Any.new(File.read(v[:path])),
          } of String => JSON::Any)
        end

        detail = {} of String => JSON::Any
        detail["primary"] = JSON::Any.new(primary) unless primary.empty?
        detail["secondary"] = JSON::Any.new(secondary) unless secondary.empty?
        detail["variants"] = JSON::Any.new(variant_json)

        request_ack("spend.set", detail)
        puts "Captured spend: #{variants.size} variant(s)."
      end

      private def set_help : String
        <<-HELP
        assist-ant spend set — replace the title-bar spend state

        USAGE:
          assist-ant spend set [--primary S] [--secondary S] \\
            --variant "Label=/path/to/block.txt" [--variant ...]

        OPTIONS:
          --primary S            Left pill string (free-form, e.g. '$392 today')
          --secondary S          Right pill string (free-form, e.g. '$2.7k mo')
          --variant LABEL=PATH   A popover card: its label + a file holding the raw
                                 monospaced report block. Repeatable; order is kept.
          -h, --help             Show this help

        The call REPLACES the whole spend state, so pass every variant you want
        shown each time. The app stores it verbatim and parses nothing.

        Single-quote the pill strings: a '$' inside double quotes is expanded by
        the shell (so "$392 today" reaches the binary as "92 today"). Single
        quotes pass it through literally.

        EXAMPLE:
          assist-ant spend set --primary '$392 today' --secondary '$2.7k mo' \\
            --variant "Month to Date=/tmp/mtd.txt" \\
            --variant "Rolling 30 days=/tmp/30d.txt" \\
            --variant "Year to Date=/tmp/ytd.txt"
        HELP
      end

      # Send a request envelope, return the parsed ack, or print an error + exit.
      # A nil/empty reply means the app isn't running; `{"ok":false}` means the
      # app refused the write. (Same shape as the actionable-item / task commands.)
      private def request_ack(event : String, detail : Hash(String, JSON::Any)) : JSON::Any
        reply = AssistAnt::EventPublisher.request(event: event, detail_data: detail)
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end
        ack = JSON.parse(reply)
        unless ack["ok"]?.try(&.as_bool?)
          STDERR.puts "Error: #{ack["error"]?.try(&.as_s?) || "spend request failed"}"
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
