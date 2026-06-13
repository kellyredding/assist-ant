module AssistAnt
  module Commands
    # `actionable-item sync`: ingest a provider's issue list (Linear), compose
    # each item's body, and hand the app one batched envelope to upsert as
    # `todo` actionables and resolve the recently-completed. Mirrors
    # `calendar-item`: a pure, fire-and-forget sender — it parses
    # deterministically (no network; the agent/MCP did the fetch), writes the
    # batch to a temp file, and publishes an `actionable_item.sync` envelope
    # carrying that file's path. Works whether or not the app is up.
    class ActionableItem
      # Actionable kinds the `create` verb accepts. Calendar items are created
      # via `calendar-item sync`, not here.
      VALID_KINDS = {"todo", "reminder", "explore"}

      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?

        case sub
        when "sync"
          sync(rest)
        when "create"
          create(rest)
        when "list-names"
          list_names(rest)
        when nil, "-h", "--help", "help"
          puts group_help
        else
          STDERR.puts "Error: unknown actionable-item subcommand '#{sub}'"
          STDERR.puts "Run 'assist-ant actionable-item --help' for usage"
          exit 1
        end
      end

      private def group_help : String
        <<-HELP
        assist-ant actionable-item — manage actionable items

        USAGE:
          assist-ant actionable-item <subcommand> [options]

        SUBCOMMANDS:
          sync         Ingest a provider's issue list (Linear) and reconcile.
          create       Create one manual to-do / reminder / explore item.
          list-names   List the existing list names (JSON).

        Run 'assist-ant actionable-item <subcommand> --help' for details.
        HELP
      end

      private def sync(args : Array(String))
        provider = ""
        source = ""
        input_path : String? = nil
        reconcile = true

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant actionable-item sync [options]"
          p.on("-h", "--help", "Show this help") { puts sync_help; exit 0 }
          p.on("--provider=NAME", "Input format, e.g. linear (required)") { |v| provider = v }
          p.on("--source=SOURCE", "Item source id, e.g. linear (required)") { |v| source = v }
          p.on("--input=PATH", "Raw provider response file (default: stdin)") { |v| input_path = v }
          p.on("--no-reconcile", "Skip the orphan soft-delete (for a partial/manual fetch)") { reconcile = false }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant actionable-item sync") }
        end

        require_flag("--provider", provider)
        require_flag("--source", source)

        parser = LinearSync.parser_for(provider)
        unless parser
          STDERR.puts "Error: unknown --provider '#{provider}' " \
                      "(known: #{LinearSync.known_providers.join(", ")})"
          exit 1
        end

        raw =
          if path = input_path
            File.read(path)
          else
            STDIN.gets_to_end
          end

        issues =
          begin
            parser.parse(raw)
          rescue ex
            STDERR.puts "Error: failed to parse #{provider} response (#{ex.message})"
            exit 1
          end

        batch_json = build_batch_json(issues, source: source, reconcile: reconcile)
        tmp = File.tempfile("assist-ant-actionable", ".json")
        begin
          tmp.print(batch_json)
        ensure
          tmp.close
        end

        detail = {
          "batch_file" => JSON::Any.new(tmp.path),
          "source"     => JSON::Any.new(source),
          "count"      => JSON::Any.new(issues.size.to_i64),
        }
        AssistAnt::EventPublisher.publish(
          event: "actionable_item.sync",
          detail_data: detail,
        )

        completed = issues.count(&.completed?)
        open = issues.size - completed
        puts "Synced #{issues.size} actionable items " \
             "(source=#{source}, #{open} open, #{completed} completed, reconcile=#{reconcile})."
      end

      # Create ONE manual actionable (todo/reminder/explore) from flags + a
      # markdown body file. Deterministic and fire-and-forget like `sync` — no
      # network and no enrichment (the capture skill does that). Validates the
      # kind/title/date, then publishes an `actionable_item.create` envelope the
      # app persists via GRDBItemStore.create. The body comes from --body-file so
      # multi-line markdown survives intact.
      private def create(args : Array(String))
        kind = ""
        title = ""
        body_path : String? = nil
        scheduled_on : String? = nil
        url : String? = nil
        list_name : String? = nil
        icebox = false

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant actionable-item create [options]"
          p.on("-h", "--help", "Show this help") { puts create_help; exit 0 }
          p.on("--kind=KIND", "todo | reminder | explore (required)") { |v| kind = v }
          p.on("--title=TITLE", "Item title (required)") { |v| title = v }
          p.on("--body-file=PATH", "File with the markdown body (optional)") { |v| body_path = v }
          p.on("--scheduled-on=YYYY-MM-DD", "Schedule day (default: unscheduled → Today)") { |v| scheduled_on = v }
          p.on("--url=URL", "Primary external URL (optional)") { |v| url = v }
          p.on("--list=NAME", "Assign to a list (optional)") { |v| list_name = v }
          p.on("--icebox", "Capture straight to the Icebox instead of Today") { icebox = true }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant actionable-item create") }
        end

        require_flag("--kind", kind)
        require_flag("--title", title)
        unless VALID_KINDS.includes?(kind)
          STDERR.puts "Error: --kind must be one of #{VALID_KINDS.to_a.sort.join(", ")}"
          exit 1
        end
        if d = scheduled_on
          unless d =~ /\A\d{4}-\d{2}-\d{2}\z/
            STDERR.puts "Error: --scheduled-on must be YYYY-MM-DD"
            exit 1
          end
        end

        body =
          if path = body_path
            File.read(path)
          else
            ""
          end

        detail = {} of String => JSON::Any
        detail["kind"] = JSON::Any.new(kind)
        detail["title"] = JSON::Any.new(title)
        detail["body"] = JSON::Any.new(body) unless body.strip.empty?
        if d = scheduled_on
          detail["scheduled_on"] = JSON::Any.new(d)
        end
        if u = url
          detail["external_url"] = JSON::Any.new(u)
        end
        if l = list_name
          detail["list_name"] = JSON::Any.new(l)
        end
        detail["icebox"] = JSON::Any.new(true) if icebox

        AssistAnt::EventPublisher.publish(
          event: "actionable_item.create",
          detail_data: detail,
        )

        where =
          if icebox
            "→ Icebox"
          elsif scheduled_on
            "scheduled #{scheduled_on}"
          else
            "unscheduled → Today"
          end
        puts "Created #{kind} item: #{title} (#{where})."
      end

      # Read: ask the running app for the existing list names and print its JSON
      # reply (`{"lists":[...]}`) for the agent to parse. Mirrors `briefing` — a
      # request/reply over the socket, not fire-and-forget — so it needs the app
      # running. The fuzzy/semantic matching lives in the capture skill; the CLI
      # only surfaces the names.
      private def list_names(args : Array(String))
        if args.first? == "-h" || args.first? == "--help"
          puts list_names_help
          return
        end

        reply = AssistAnt::EventPublisher.request(event: "actionable_item.list_names")
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end

        puts reply
      end

      # Serialize the batch the app applies in one transaction: every issue as a
      # row (open or completed), the keep set (every external_id seen), and the
      # reconcile flag (soft-delete orphans not in keep).
      private def build_batch_json(
        issues : Array(LinearSync::NormalizedIssue),
        source : String, reconcile : Bool,
      ) : String
        JSON.build do |j|
          j.object do
            j.field "source", source
            j.field "reconcile", reconcile
            j.field "keep" do
              j.array { issues.each { |i| j.string i.external_id } }
            end
            j.field "items" do
              j.array do
                issues.each do |i|
                  j.object do
                    j.field "external_id", i.external_id
                    j.field "title", i.title
                    j.field "body", LinearSync.compose_body(i)
                    j.field "url", i.url
                    j.field "status_type", i.status_type
                    if c = i.completed_at
                      j.field "completed_at", c
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def sync_help : String
        <<-HELP
        assist-ant actionable-item sync — ingest a provider issue list

        USAGE:
          assist-ant actionable-item sync --provider NAME --source SOURCE [options]

        REQUIRED:
          --provider NAME        Input format, e.g. linear
          --source SOURCE        Item source id, e.g. linear

        OPTIONS:
          --input PATH           Raw provider response file (default: stdin)
          --no-reconcile         Skip the orphan soft-delete (partial/manual fetch)
          -h, --help             Show this help

        EXAMPLES:
          assist-ant actionable-item sync --provider linear --source linear \\
            --input /tmp/issues.json
          linear-mcp list_issues | assist-ant actionable-item sync \\
            --provider linear --source linear
        HELP
      end

      private def create_help : String
        <<-HELP
        assist-ant actionable-item create — create one manual item

        USAGE:
          assist-ant actionable-item create --kind KIND --title TITLE [options]

        REQUIRED:
          --kind KIND            One of: todo, reminder, explore
          --title TITLE          Item title

        OPTIONS:
          --body-file PATH       File with the markdown body (optional)
          --scheduled-on DATE    Schedule day, YYYY-MM-DD (default: unscheduled → Today)
          --url URL              Primary external URL (optional)
          --list LIST            Assign to a list (optional)
          --icebox               Capture straight to the Icebox instead of Today
          -h, --help             Show this help

        EXAMPLES:
          assist-ant actionable-item create --kind todo --title "Pick up milk"
          assist-ant actionable-item create --kind reminder --title "Call dentist" \\
            --scheduled-on 2026-06-20
          assist-ant actionable-item create --kind explore --title "Read the RFC" \\
            --url https://example.com/rfc --body-file /tmp/body.md
          assist-ant actionable-item create --kind todo --title "Research later" --icebox
          assist-ant actionable-item create --kind todo --title "Buy milk" --list Errands
        HELP
      end

      private def list_names_help : String
        <<-HELP
        assist-ant actionable-item list-names — list existing list names

        USAGE:
          assist-ant actionable-item list-names

        OPTIONS:
          -h, --help             Show this help

        DESCRIPTION:
          Prints the existing list names as JSON (`{"lists":[...]}`) so a capture
          can be matched to a list. A read, not a write: requires the app to be
          running.

        EXAMPLES:
          assist-ant actionable-item list-names
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

  # Provider-aware issue parsing + body composition. Parsers normalize to
  # `NormalizedIssue`; everything downstream works on that shape.
  module LinearSync
    # A normalized, provider-agnostic work item. `status_type` is the Linear
    # state category; `completed_at` is the provider's ISO-8601 string, present
    # only for completed issues.
    record NormalizedIssue,
      external_id : String, # human identifier, e.g. "FLEX-3304"
      title : String,
      description : String?,
      url : String,
      status_type : String,
      completed_at : String?,
      team : String,
      status : String,
      priority_name : String,
      project : String?,
      milestone : String?,
      labels : Array(String) do
      def completed? : Bool
        status_type == "completed"
      end
    end

    # State categories we mirror. Anything else (canceled, triage) is dropped:
    # it isn't an active todo and falls out of the keep set, so the app's
    # reconcile retires any stale copy.
    SYNCED_TYPES = {"started", "unstarted", "backlog", "completed"}

    abstract class Parser
      abstract def parse(raw : String) : Array(NormalizedIssue)
    end

    # Parses the Linear MCP `list_issues` response:
    #   {"issues":[{id,title,description,url,statusType,status,completedAt,
    #               priority:{value,name},team,project,projectMilestone:{name},
    #               labels:[...]}, …], "hasNextPage":false}
    class LinearParser < Parser
      def parse(raw : String) : Array(NormalizedIssue)
        doc = JSON.parse(raw)
        items = doc["issues"]?.try(&.as_a?) || [] of JSON::Any
        items.compact_map { |iss| normalize(iss) }
      end

      private def normalize(iss : JSON::Any) : NormalizedIssue?
        id = iss["id"]?.try(&.as_s?)
        return nil unless id

        status_type = iss["statusType"]?.try(&.as_s?) || ""
        return nil unless SYNCED_TYPES.includes?(status_type)

        labels = [] of String
        if list = iss["labels"]?.try(&.as_a?)
          list.each do |l|
            name = l.as_s? || l.as_h?.try { |h| h["name"]?.try(&.as_s?) }
            labels << name if name
          end
        end

        NormalizedIssue.new(
          external_id: id,
          title: (iss["title"]?.try(&.as_s?) || "(untitled)").strip,
          description: iss["description"]?.try(&.as_s?),
          url: iss["url"]?.try(&.as_s?) || "",
          status_type: status_type,
          completed_at: iss["completedAt"]?.try(&.as_s?),
          team: iss["team"]?.try(&.as_s?) || "",
          status: iss["status"]?.try(&.as_s?) || "",
          priority_name: iss["priority"]?.try(&.as_h?).try { |h| h["name"]?.try(&.as_s?) } || "",
          project: iss["project"]?.try(&.as_s?),
          milestone: iss["projectMilestone"]?.try(&.as_h?).try { |h| h["name"]?.try(&.as_s?) },
          labels: labels,
        )
      end
    end

    PARSERS = {
      "linear" => LinearParser.new.as(Parser),
    }

    def self.parser_for(name : String) : Parser?
      PARSERS[name]?
    end

    def self.known_providers : Array(String)
      PARSERS.keys
    end

    # The markdown body: a two-line header — the ticket reference hyperlinked
    # to the issue, then `project · milestone · status` (absent parts omitted)
    # — followed by the issue description. Team, priority, and labels are not
    # surfaced. Linear descriptions are already markdown, so the description is
    # NOT escaped — only bare URLs are linkified so they render and tap in the
    # viewer.
    def self.compose_body(i : NormalizedIssue) : String
      String.build do |io|
        # Line 1: the ticket reference, hyperlinked to the issue.
        if i.url.empty?
          io << i.external_id
        else
          io << "[#{i.external_id}](#{i.url})"
        end

        # Line 2: project · milestone · status (each only when present).
        parts = [] of String
        if proj = i.project
          parts << proj unless proj.empty?
        end
        if ms = i.milestone
          parts << ms unless ms.empty?
        end
        parts << i.status unless i.status.empty?
        # Blank line (own block) so the reader's block markdown renderer keeps
        # the metadata on its own line instead of folding it into the ticket.
        io << "\n\n#{parts.join("  ·  ")}" unless parts.empty?

        # Issue description (markdown; bare URLs linkified). Linear's list
        # response truncates a long description and appends a "(truncated …)"
        # marker inline with the last line; lift it onto its own block so the
        # reader's block renderer doesn't fold it into a trailing heading/list.
        if desc = i.description
          cleaned = lift_truncation_marker(linkify_bare_urls(desc.strip))
          io << "\n\n#{cleaned}" unless cleaned.empty?
        end
      end
    end

    # Bare http(s) URLs become `[url](url)` so they render. URLs already part of
    # a Markdown link `[text](url)`, an autolink `<url>`, or used as link text
    # `[url]` are left as-is; the surrounding Markdown is never escaped.
    URL_RE = /(?<!\]\()(?<!<)(?<!\[)https?:\/\/[^\s\)\]<>]+/

    def self.linkify_bare_urls(text : String) : String
      text.gsub(URL_RE) { |u| "[#{u}](#{u})" }
    end

    # Linear's list_issues truncates a long description and appends a trailing
    # "(truncated, use get_issue for full description)" parenthetical inline
    # with the last line of content. Under block markdown that styles the
    # marker as part of whatever the line was — a heading, a list item. Lift it
    # onto its own block, separated by a blank line, so it renders as its own
    # plain paragraph. A description without the marker is returned unchanged.
    TRUNCATION_RE = /\s*(\(truncated[^()]*\))\s*\z/i

    def self.lift_truncation_marker(text : String) : String
      return text unless m = TRUNCATION_RE.match(text)
      head = m.pre_match.rstrip
      marker = m[1]
      head.empty? ? marker : "#{head}\n\n#{marker}"
    end
  end
end
