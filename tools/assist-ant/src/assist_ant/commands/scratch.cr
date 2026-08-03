module AssistAnt
  module Commands
    # `assist-ant scratch`: the agent's door into the Scratch feed — the parking
    # lot for notes that aren't shaped into work yet. Three verbs: `add` parks a
    # note, `list` reads the feed back with ids, `convert` promotes one note
    # into a shaped actionable item.
    #
    # Every subcommand is REQUEST/REPLY (`EventPublisher.request`), never
    # fire-and-forget: the CLI never touches the DB — it sends a `scratch.*`
    # envelope and the app replies with an ack or the feed JSON. Scratch
    # authoring always happens with the app up (the agent runs inside it), so an
    # absent reply is an error, not silence — unlike the `sync` senders.
    #
    # Prose arrives by FILE, not by flag (`--text-file`, `--body-file`): the
    # agent composes multi-line Markdown, and a backtick inside a shell argument
    # is command substitution — the shell would run it before the binary ever
    # saw it. The CLI reads the file locally and sends its CONTENTS in
    # `detail_data`; the app never sees a path.
    class Scratch
      include RequestAck

      # Actionable kinds `convert` can promote a note into. Mirrors
      # ActionableItem::VALID_KINDS — the conversion lands in the same store —
      # but kept as its own copy, as every command class keeps its own
      # constants.
      VALID_KINDS = {"todo", "reminder", "explore"}

      # The two disjoint feeds, matching the app's scratch toggle: `open` is the
      # working buffer, `completed` the reviewed set.
      VALID_STATES = {"open", "completed"}

      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?

        case sub
        when "add"     then add(rest)
        when "list"    then list(rest)
        when "convert" then convert(rest)
        when nil, "-h", "--help", "help"
          puts group_help
        else
          STDERR.puts "Error: unknown scratch subcommand '#{sub}'"
          STDERR.puts "Run 'assist-ant scratch --help' for usage"
          exit 1
        end
      end

      private def group_help : String
        <<-HELP
        assist-ant scratch — park and promote unshaped notes

        USAGE:
          assist-ant scratch <subcommand> [options]

        SUBCOMMANDS:
          add            Park one note in the Scratch feed.
          list           List notes with their ids (JSON; --state open|completed).
          convert        Promote one note into a to-do / reminder / explore item.

        All subcommands talk to the running app and require it to be up.
        Run 'assist-ant scratch <subcommand> --help' for details.
        HELP
      end

      # Park one note in the open feed. The note's text is the whole payload —
      # the app derives the title and stamps the time, exactly as the in-app
      # composer does, so the CLI must NOT invent a title. Request/reply so the
      # new id round-trips and a follow-up `convert` has a target without
      # re-listing.
      private def add(args : Array(String))
        # Handle help before OptionParser so an in-process `scratch add --help`
        # (the unit routing spec) returns cleanly instead of calling `exit`,
        # which would terminate the whole spec process.
        if args.first? == "-h" || args.first? == "--help"
          puts add_help
          return
        end

        text : String? = nil
        text_path : String? = nil

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant scratch add (--text TEXT | --text-file PATH)"
          p.on("-h", "--help", "Show this help") { puts add_help; exit 0 }
          p.on("--text=TEXT", "The note text (one of --text / --text-file)") { |v| text = v }
          p.on("--text-file=PATH", "File holding the note text (multi-line markdown)") { |v| text_path = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant scratch add") }
        end

        note = resolve_text(text, text_path)
        ack = request_ack("scratch.add", {"text" => JSON::Any.new(note)})
        puts "Added scratch note #{ack["id"]?.try(&.as_s?) || ""} " \
             "(#{note.lines.size} line(s))."
      end

      # Read: print the app's JSON reply verbatim (`{"items":[{id, title, body,
      # created_at, resolved_at}, …]}`) for the agent to parse — ids included so
      # `convert` has a target. Mirrors `actionable-item list`.
      private def list(args : Array(String))
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts list_help
          return
        end

        state = "open"
        OptionParser.parse(rest) do |p|
          p.banner = "Usage: assist-ant scratch list [options]"
          p.on("-h", "--help", "Show this help") { puts list_help; exit 0 }
          p.on("--state=STATE", "open | completed (default: open)") { |v| state = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant scratch list") }
        end

        unless VALID_STATES.includes?(state)
          STDERR.puts "Error: --state must be open or completed"
          exit 1
        end

        # Sent even when it's the default, so the envelope is self-describing
        # and the app never has to guess (same as `actionable-item list`).
        reply = AssistAnt::EventPublisher.request(
          event: "scratch.list",
          detail_data: {"state" => JSON::Any.new(state)},
        )
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end

        puts reply
      end

      # Promote one note into a shaped actionable. The CLI shapes nothing: the
      # agent supplies the kind, the title, the composed markdown body, and any
      # link it followed; the app rewrites the row in place and acks.
      #
      # --body-file is required and file-only — no `--body TEXT`. A converted
      # body is multi-line markdown with backticks, and those become command
      # substitution inside a shell argument.
      private def convert(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts convert_help
          return
        end

        id = ""
        kind = ""
        title = ""
        body_path = ""
        url : String? = nil

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant scratch convert --id ID --kind KIND " \
                     "--title TITLE --body-file PATH"
          p.on("-h", "--help", "Show this help") { puts convert_help; exit 0 }
          p.on("--id=ID", "Scratch note id (required; from 'scratch list')") { |v| id = v }
          p.on("--kind=KIND", "todo | reminder | explore (required)") { |v| kind = v }
          p.on("--title=TITLE", "Title for the new item (required)") { |v| title = v }
          p.on("--body-file=PATH", "File with the markdown body (required)") { |v| body_path = v }
          p.on("--url=URL", "Link the note referred to (optional)") { |v| url = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant scratch convert") }
        end

        require_flag("--id", id)
        require_flag("--kind", kind)
        require_flag("--title", title)
        require_flag("--body-file", body_path)
        unless VALID_KINDS.includes?(kind)
          STDERR.puts "Error: --kind must be one of #{VALID_KINDS.to_a.sort.join(", ")}"
          exit 1
        end

        body = read_file("--body-file", body_path)
        if body.strip.empty?
          STDERR.puts "Error: --body-file is empty: #{body_path}"
          exit 1
        end

        detail = {
          "id"    => JSON::Any.new(id),
          "kind"  => JSON::Any.new(kind),
          "title" => JSON::Any.new(title),
          "body"  => JSON::Any.new(body),
        }
        if u = url
          detail["url"] = JSON::Any.new(u) unless u.empty?
        end

        ack = request_ack("scratch.convert", detail)
        puts "Converted note #{id} → #{kind}: " \
             "#{ack["name"]?.try(&.as_s?) || title}."
      end

      # Resolve the note text from EXACTLY ONE of --text / --text-file. Shaped
      # like task's resolve_prompt, with one deliberate difference: task lets
      # the file win when both are passed; here both is an error. The agent
      # picks the channel on purpose — a file when the note has newlines or
      # backticks — so a silent preference would hide a mistake in whichever one
      # it dropped.
      private def resolve_text(text : String?, path : String?) : String
        if text && path
          STDERR.puts "Error: --text and --text-file are mutually exclusive"
          exit 1
        end
        if p = path
          body = read_file("--text-file", p)
          if body.strip.empty?
            STDERR.puts "Error: --text-file is empty: #{p}"
            exit 1
          end
          return body
        end
        if t = text
          return t unless t.strip.empty?
        end
        STDERR.puts "Error: note text is required (--text TEXT or --text-file PATH)"
        exit 1
      end

      # Read a flag's file, or print one clear line and exit. Checked rather
      # than letting File.read raise, so a bad path from the agent surfaces as
      # stderr + a non-zero exit, not a Crystal backtrace it has to interpret.
      private def read_file(flag : String, path : String) : String
        unless File.exists?(path)
          STDERR.puts "Error: #{flag} not found: #{path}"
          exit 1
        end
        begin
          File.read(path)
        rescue ex
          STDERR.puts "Error: could not read #{flag} #{path} (#{ex.message})"
          exit 1
        end
      end

      private def add_help : String
        <<-HELP
        assist-ant scratch add — park one note in the Scratch feed

        USAGE:
          assist-ant scratch add --text TEXT
          assist-ant scratch add --text-file PATH

        REQUIRED (exactly one):
          --text TEXT            The note text, as a single shell argument
          --text-file PATH       File holding the note text (multi-line markdown)

        OPTIONS:
          -h, --help             Show this help

        DESCRIPTION:
          The text is the whole note. The app derives the title from it and
          stamps the capture time, exactly as the in-app composer does — there
          is no --title.

          Prefer --text-file whenever the note contains newlines, backticks, or
          a '$': the shell runs backticks as command substitution and expands
          '$name' before the binary sees the argument.

        EXAMPLES:
          assist-ant scratch add --text 'ask about the retro doc'
          assist-ant scratch add --text-file /tmp/aa-note.md
        HELP
      end

      private def list_help : String
        <<-HELP
        assist-ant scratch list — list notes with their ids

        USAGE:
          assist-ant scratch list [--state open|completed]

        OPTIONS:
          --state STATE          open (default) | completed
          -h, --help             Show this help

        DESCRIPTION:
          Prints notes as JSON (`{"items":[{id, title, body, created_at,
          resolved_at}, …]}`) so `convert` has a target. `open` is the working
          buffer; `completed` is the reviewed set. The two are disjoint.

        EXAMPLES:
          assist-ant scratch list
          assist-ant scratch list --state completed
        HELP
      end

      private def convert_help : String
        <<-HELP
        assist-ant scratch convert — promote a note into an actionable item

        USAGE:
          assist-ant scratch convert --id ID --kind KIND --title TITLE \\
            --body-file PATH [--url URL]

        REQUIRED:
          --id ID                Scratch note id (run 'scratch list' to find it)
          --kind KIND            One of: todo, reminder, explore
          --title TITLE          Title for the new item
          --body-file PATH       File with the markdown body

        OPTIONS:
          --url URL              Link the note referred to
          -h, --help             Show this help

        DESCRIPTION:
          The note becomes a shaped item in place — same id, same capture time —
          and leaves the scratch feed.

          There is no --body: a converted body is multi-line markdown with
          backticks, and a backtick in a shell argument is command substitution.

        EXAMPLES:
          assist-ant scratch convert --id 0192abc --kind todo \\
            --title "Fix the retro doc" --body-file /tmp/aa-body.md
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
