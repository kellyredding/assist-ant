module AssistAnt
  class CLI
    VERSION = "0.0.1"

    def self.run(args : Array(String))
      new.run(args)
    end

    def run(args : Array(String))
      show_help = false
      show_version = false

      parser = OptionParser.new do |p|
        p.banner = banner
        p.on("-h", "--help", "Show help") { show_help = true }
        p.on("-v", "--version", "Show version") { show_version = true }
        p.invalid_option do |flag|
          STDERR.puts "Error: unknown flag '#{flag}'"
          STDERR.puts p
          exit 1
        end
      end

      positional = [] of String
      parser.unknown_args { |a| positional = a }
      parser.parse(args)

      if show_version
        puts "assist-ant #{VERSION}"
        return
      end

      if show_help || positional.empty?
        puts parser
        return
      end

      command = positional.shift
      case command
      when "ping"
        Commands::Ping.new.run(positional)
      else
        STDERR.puts "Error: unknown command '#{command}'"
        STDERR.puts parser
        exit 1
      end
    end

    private def banner
      <<-BANNER
        Usage: assist-ant [options] <command> [args]

        Commands:
          ping [message]      Send a ping envelope to the running app.

        Options:
        BANNER
    end
  end
end
