module AssistAnt
  module Commands
    # `assist-ant task`: the agentic authoring surface for AssistAnt tasks. A
    # task is a named prompt plus a trigger; the agent (taught by the
    # assist-ant-manage-tasks skill) turns a natural-language request into the
    # right invocation here.
    #
    # Every subcommand is REQUEST/REPLY (`EventPublisher.request`), never
    # fire-and-forget: the CLI doesn't write the DB — it sends a `task.*`
    # envelope and the app replies with an ack (`{"ok":…,"id":…,"name":…}`). Task
    # management always happens with the app up (the agent runs inside it), so an
    # absent reply is an error, not silence — unlike the `sync`/`create` senders.
    class Task
      VALID_TRIGGERS = {"recurring", "one_shot", "manual"}
      VALID_CADENCES = {"interval", "daily"}

      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?

        case sub
        when "add"
          add(rest)
        when "list"
          list(rest)
        when "update"
          update(rest)
        when "remove"
          remove(rest)
        when "enable"
          set_enabled(rest, true)
        when "disable"
          set_enabled(rest, false)
        when nil, "-h", "--help", "help"
          puts group_help
        else
          STDERR.puts "Error: unknown task subcommand '#{sub}'"
          STDERR.puts "Run 'assist-ant task --help' for usage"
          exit 1
        end
      end

      private def group_help : String
        <<-HELP
        assist-ant task — manage AssistAnt tasks (named prompt + trigger)

        USAGE:
          assist-ant task <subcommand> [options]

        SUBCOMMANDS:
          add            Create a task (recurring, one-shot, or manual).
          list           List all tasks (JSON).
          update <id>    Change fields on an existing task.
          remove <id>    Delete a task.
          enable <id>    Enable a task.
          disable <id>   Disable a task.

        All subcommands talk to the running app and require it to be up.
        Run 'assist-ant task <subcommand> --help' for details.
        HELP
      end

      # Create one task. Validates the trigger/cadence combination locally before
      # sending, then request/replies `task.create` and relays the ack.
      private def add(args : Array(String))
        name = ""
        trigger = ""
        cadence : String? = nil
        interval_seconds : Int64? = nil
        daily_time : String? = nil
        run_at : String? = nil
        manual_key : String? = nil
        prompt : String? = nil
        prompt_path : String? = nil
        enabled = true

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant task add [options]"
          p.on("-h", "--help", "Show this help") { puts add_help; exit 0 }
          p.on("--name=NAME", "Task name (required)") { |v| name = v }
          p.on("--trigger=TYPE", "recurring | one_shot | manual (required)") { |v| trigger = v }
          p.on("--cadence=KIND", "recurring: interval | daily") { |v| cadence = v }
          p.on("--interval-seconds=N", "recurring+interval: seconds between runs") { |v| interval_seconds = v.to_i64? }
          p.on("--daily-time=HH:MM", "recurring+daily: local time of day") { |v| daily_time = v }
          p.on("--run-at=ISO8601", "one_shot: fire time (omit → next tick)") { |v| run_at = v }
          p.on("--manual-key=KEY", "manual: built-in trigger key") { |v| manual_key = v }
          p.on("--prompt=TEXT", "The prompt sent to the agent") { |v| prompt = v }
          p.on("--prompt-file=PATH", "Read the prompt from a file (multi-line)") { |v| prompt_path = v }
          p.on("--disabled", "Create disabled (default: enabled)") { enabled = false }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant task add") }
        end

        require_flag("--name", name)
        require_flag("--trigger", trigger)
        unless VALID_TRIGGERS.includes?(trigger)
          STDERR.puts "Error: --trigger must be one of #{VALID_TRIGGERS.to_a.sort.join(", ")}"
          exit 1
        end
        resolved_prompt = resolve_prompt(prompt, prompt_path)
        validate_trigger(trigger, cadence, interval_seconds, daily_time)

        detail = {} of String => JSON::Any
        detail["name"] = JSON::Any.new(name)
        detail["trigger_type"] = JSON::Any.new(trigger)
        detail["prompt"] = JSON::Any.new(resolved_prompt)
        detail["enabled"] = JSON::Any.new(enabled)
        if c = cadence
          detail["cadence_kind"] = JSON::Any.new(c)
        end
        if s = interval_seconds
          detail["interval_seconds"] = JSON::Any.new(s)
        end
        if t = daily_time
          detail["daily_time"] = JSON::Any.new(t)
        end
        if r = run_at
          detail["run_at"] = JSON::Any.new(r)
        end
        if k = manual_key
          detail["manual_key"] = JSON::Any.new(k)
        end

        ack = request_ack("task.create", detail)
        puts "Created task: #{ack["name"]?.try(&.as_s?) || name} (#{ack["id"]?.try(&.as_s?)})."
      end

      # List all tasks: print the app's JSON reply (`{"tasks":[…]}`) for the
      # agent to parse and fuzzy-match against. A read — requires the app up.
      private def list(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts list_help
          return
        end

        reply = AssistAnt::EventPublisher.request(event: "task.list")
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end
        puts reply
      end

      # Change fields on an existing task. Sends only the fields that were
      # passed; the app overlays them onto the stored row.
      private def update(args : Array(String))
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts update_help
          return
        end
        id = rest.shift?
        if id.nil?
          STDERR.puts "Error: update requires a task id (run 'assist-ant task list' to find it)"
          exit 1
        end

        name : String? = nil
        trigger : String? = nil
        cadence : String? = nil
        interval_seconds : Int64? = nil
        daily_time : String? = nil
        run_at : String? = nil
        manual_key : String? = nil
        prompt : String? = nil
        prompt_path : String? = nil

        OptionParser.parse(rest) do |p|
          p.banner = "Usage: assist-ant task update <id> [options]"
          p.on("-h", "--help", "Show this help") { puts update_help; exit 0 }
          p.on("--name=NAME", "New task name") { |v| name = v }
          p.on("--trigger=TYPE", "recurring | one_shot | manual") { |v| trigger = v }
          p.on("--cadence=KIND", "recurring: interval | daily") { |v| cadence = v }
          p.on("--interval-seconds=N", "recurring+interval: seconds between runs") { |v| interval_seconds = v.to_i64? }
          p.on("--daily-time=HH:MM", "recurring+daily: local time of day") { |v| daily_time = v }
          p.on("--run-at=ISO8601", "one_shot: fire time") { |v| run_at = v }
          p.on("--manual-key=KEY", "manual: built-in trigger key") { |v| manual_key = v }
          p.on("--prompt=TEXT", "New prompt") { |v| prompt = v }
          p.on("--prompt-file=PATH", "Read the new prompt from a file") { |v| prompt_path = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant task update") }
        end

        detail = {} of String => JSON::Any
        detail["id"] = JSON::Any.new(id)
        if n = name
          detail["name"] = JSON::Any.new(n)
        end
        if tr = trigger
          unless VALID_TRIGGERS.includes?(tr)
            STDERR.puts "Error: --trigger must be one of #{VALID_TRIGGERS.to_a.sort.join(", ")}"
            exit 1
          end
          detail["trigger_type"] = JSON::Any.new(tr)
        end
        if c = cadence
          detail["cadence_kind"] = JSON::Any.new(c)
        end
        if s = interval_seconds
          detail["interval_seconds"] = JSON::Any.new(s)
        end
        if t = daily_time
          detail["daily_time"] = JSON::Any.new(t)
        end
        if r = run_at
          detail["run_at"] = JSON::Any.new(r)
        end
        if k = manual_key
          detail["manual_key"] = JSON::Any.new(k)
        end
        if prompt || prompt_path
          detail["prompt"] = JSON::Any.new(resolve_prompt(prompt, prompt_path))
        end

        if detail.size == 1 # only the id
          STDERR.puts "Error: update needs at least one field to change"
          exit 1
        end

        ack = request_ack("task.update", detail)
        puts "Updated task: #{ack["name"]?.try(&.as_s?)} (#{ack["id"]?.try(&.as_s?)})."
      end

      private def remove(args : Array(String))
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts remove_help
          return
        end
        id = rest.shift?
        if id.nil?
          STDERR.puts "Error: remove requires a task id"
          exit 1
        end
        ack = request_ack("task.delete", {"id" => JSON::Any.new(id)})
        puts "Removed task #{ack["id"]?.try(&.as_s?) || id}."
      end

      # enable / disable are sugar over update with just the `enabled` field.
      private def set_enabled(args : Array(String), enabled : Bool)
        verb = enabled ? "enable" : "disable"
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts enabled_help(verb)
          return
        end
        id = rest.shift?
        if id.nil?
          STDERR.puts "Error: #{verb} requires a task id"
          exit 1
        end
        detail = {
          "id"      => JSON::Any.new(id),
          "enabled" => JSON::Any.new(enabled),
        }
        ack = request_ack("task.update", detail)
        puts "#{enabled ? "Enabled" : "Disabled"} task: " \
             "#{ack["name"]?.try(&.as_s?)} (#{ack["id"]?.try(&.as_s?)})."
      end

      # Send a request envelope and return the parsed ack, or print an error and
      # exit. A nil/empty reply means the app isn't running; `{"ok":false}` means
      # the app refused the write.
      private def request_ack(event : String, detail : Hash(String, JSON::Any)) : JSON::Any
        reply = AssistAnt::EventPublisher.request(event: event, detail_data: detail)
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end
        ack = JSON.parse(reply)
        unless ack["ok"]?.try(&.as_bool?)
          STDERR.puts "Error: #{ack["error"]?.try(&.as_s?) || "task request failed"}"
          exit 1
        end
        ack
      end

      # Resolve the prompt from --prompt or --prompt-file (file preferred for
      # multi-line). Exits if neither yields a non-empty prompt.
      private def resolve_prompt(text : String?, path : String?) : String
        if p = path
          unless File.exists?(p)
            STDERR.puts "Error: --prompt-file not found: #{p}"
            exit 1
          end
          body = File.read(p)
          if body.strip.empty?
            STDERR.puts "Error: --prompt-file is empty"
            exit 1
          end
          return body
        end
        if t = text
          return t unless t.strip.empty?
        end
        STDERR.puts "Error: a prompt is required (--prompt TEXT or --prompt-file PATH)"
        exit 1
      end

      # Validate the trigger/cadence combination before sending (the app
      # re-validates, but a local check gives a clear, fast error).
      private def validate_trigger(
        trigger : String, cadence : String?,
        interval_seconds : Int64?, daily_time : String?,
      )
        case trigger
        when "recurring"
          unless (c = cadence) && VALID_CADENCES.includes?(c)
            STDERR.puts "Error: --trigger recurring requires --cadence interval|daily"
            exit 1
          end
          case cadence
          when "interval"
            if (s = interval_seconds).nil? || s <= 0
              STDERR.puts "Error: --cadence interval requires a positive --interval-seconds"
              exit 1
            end
          when "daily"
            unless (dt = daily_time) && dt =~ /\A\d{2}:\d{2}\z/
              STDERR.puts "Error: --cadence daily requires --daily-time HH:MM"
              exit 1
            end
          end
        when "manual", "one_shot"
          # No required cadence fields. one_shot's --run-at is optional (omit →
          # next tick); manual fires on demand.
        end
      end

      private def add_help : String
        <<-HELP
        assist-ant task add — create a task

        USAGE:
          assist-ant task add --name NAME --trigger TYPE --prompt TEXT [options]

        REQUIRED:
          --name NAME            Task name
          --trigger TYPE         recurring | one_shot | manual
          --prompt TEXT          The prompt sent to the agent
                                 (or --prompt-file PATH for multi-line)

        TRIGGER OPTIONS:
          recurring:  --cadence interval --interval-seconds N
                      --cadence daily --daily-time HH:MM
          one_shot:   --run-at ISO8601   (omit → fire on the next tick)
          manual:     --manual-key KEY   (built-in trigger binding)

        OTHER OPTIONS:
          --prompt-file PATH     Read the prompt from a file (multi-line)
          --disabled             Create disabled (default: enabled)
          -h, --help             Show this help

        EXAMPLES:
          assist-ant task add --name "Linear sync" --trigger recurring \\
            --cadence interval --interval-seconds 900 --prompt "Sync my Linear issues"
          assist-ant task add --name "Morning brief" --trigger recurring \\
            --cadence daily --daily-time 07:00 --prompt "Summarize today's calendar"
          assist-ant task add --name "EOD wrap" --trigger one_shot \\
            --run-at 2026-06-15T17:00:00 --prompt "Wrap up the day"
        HELP
      end

      private def list_help : String
        <<-HELP
        assist-ant task list — list all tasks

        USAGE:
          assist-ant task list

        DESCRIPTION:
          Prints all tasks as JSON (`{"tasks":[...]}`) so a request can be
          matched to a task by name. A read: requires the app to be running.
        HELP
      end

      private def update_help : String
        <<-HELP
        assist-ant task update — change fields on a task

        USAGE:
          assist-ant task update <id> [options]

        OPTIONS:
          --name NAME            New task name
          --trigger TYPE         recurring | one_shot | manual
          --cadence KIND         interval | daily
          --interval-seconds N   recurring+interval seconds
          --daily-time HH:MM     recurring+daily local time
          --run-at ISO8601       one_shot fire time
          --manual-key KEY       manual trigger key
          --prompt TEXT          New prompt (or --prompt-file PATH)
          --prompt-file PATH     Read the new prompt from a file
          -h, --help             Show this help

        Only the fields you pass are changed. Run 'assist-ant task list' for ids.
        HELP
      end

      private def remove_help : String
        <<-HELP
        assist-ant task remove — delete a task

        USAGE:
          assist-ant task remove <id>

        Run 'assist-ant task list' to find the id. The run history stays in the
        log.
        HELP
      end

      private def enabled_help(verb : String) : String
        <<-HELP
        assist-ant task #{verb} — #{verb} a task

        USAGE:
          assist-ant task #{verb} <id>

        Run 'assist-ant task list' to find the id.
        HELP
      end

      private def require_flag(name : String, value : String)
        return unless value.empty?
        STDERR.puts "Error: #{name} is required"
        exit 1
      end

      private def abort_flag(message : String, command : String)
        STDERR.puts "Error: #{message}"
        STDERR.puts "Run '#{command} --help' for usage"
        exit 1
      end
    end
  end
end
