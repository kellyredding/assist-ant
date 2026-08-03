module AssistAnt
  module Commands
    # `actionable-item sync`: fetch (or ingest) a provider's issue list (Linear),
    # compose each item's body, and hand the app one batched envelope to upsert as
    # `todo` actionables and resolve the recently-completed.
    #
    # Two input modes, mutually exclusive. `--fetch` queries Linear directly
    # through the `linear` CLI, which makes the projection code with spec
    # coverage instead of prose an agent re-derives on every run;
    # `--input`/stdin keeps the MCP path working while it exists. Everything
    # after the input is deterministic: normalize, compose each body, write the
    # batch to a temp file, send an `actionable_item.sync` envelope carrying
    # that file's path.
    #
    # Unlike `calendar-item sync`, this is REQUEST/REPLY. The app is the only
    # thing that knows whether reconcile actually ran — it withholds the
    # soft-delete half when the incoming set matches nothing already stored — so
    # the summary line comes from its ack rather than from the CLI's own intent.
    # A run with the app down therefore exits non-zero instead of publishing
    # into a void and reporting success.
    class ActionableItem
      include RequestAck

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
        when "list"
          list(rest)
        when "list-names"
          list_names(rest)
        when "update"
          update(rest)
        when "remove"
          remove(rest)
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
          sync           Ingest a provider's issue list (Linear) and reconcile.
          create         Create one manual to-do / reminder / explore item.
          list           List items with their ids (JSON; --state active|trashed).
          list-names     List the existing list names (JSON).
          update <id>    Edit a manual item in place.
          remove <id>    Soft-delete a manual item (→ Trash).

        Run 'assist-ant actionable-item <subcommand> --help' for details.
        HELP
      end

      private def sync(args : Array(String))
        provider = ""
        source = ""
        input_path : String? = nil
        reconcile = true
        allow_full_turnover = false
        fetch = false
        workspace = LinearSync::APIFetcher::DEFAULT_WORKSPACE

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant actionable-item sync [options]"
          p.on("-h", "--help", "Show this help") { puts sync_help; exit 0 }
          p.on("--provider=NAME", "Input format, e.g. linear (required)") { |v| provider = v }
          p.on("--source=SOURCE", "Item source id, e.g. linear (required)") { |v| source = v }
          p.on("--input=PATH", "Raw provider response file (default: stdin)") { |v| input_path = v }
          p.on("--fetch", "Fetch from Linear directly via the `linear` CLI") { fetch = true }
          p.on("--linear-workspace=NAME",
            "Linear workspace for --fetch (default: " \
            "#{LinearSync::APIFetcher::DEFAULT_WORKSPACE})") { |v| workspace = v }
          p.on("--no-reconcile", "Skip the orphan soft-delete (for a partial/manual fetch)") { reconcile = false }
          p.on("--allow-full-turnover",
            "Reconcile even when no incoming issue matches an existing one") do
            allow_full_turnover = true
          end
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

        # Two ways in, and only two. Silently preferring one would leave it
        # ambiguous which shape was applied, and an ambiguous payload shape is
        # exactly what --fetch exists to remove.
        if fetch && input_path
          STDERR.puts "Error: --fetch and --input are mutually exclusive"
          exit 1
        end

        issues =
          if fetch
            LinearSync::APIFetcher.new(workspace).fetch
          else
            raw =
              if path = input_path
                File.read(path)
              else
                STDIN.gets_to_end
              end

            begin
              parser.parse(raw)
            rescue ex
              STDERR.puts "Error: failed to parse #{provider} response (#{ex.message})"
              exit 1
            end
          end

        batch_json = build_batch_json(
          issues, source: source, reconcile: reconcile,
          allow_full_turnover: allow_full_turnover)
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

        # Request/reply, replacing the intent-only summary: `reconcile=true` used
        # to be printed whether or not reconcile ran, so a withheld retirement
        # was invisible. The app is the only thing that knows, so both the
        # warning and `retired=` now come from its ack.
        ack = request_ack("actionable_item.sync", detail)
        withheld = ack["reconcile_withheld"]?.try(&.as_bool?) || false
        if withheld
          reason = ack["withheld_reason"]?.try(&.as_s?)
          reason = "unknown" if reason.nil? || reason.empty?
          prior = ack["prior_candidates"]?.try(&.as_i?) || 0
          STDERR.puts "Warning: reconcile WITHHELD (#{reason}) — #{prior} existing " \
                      "issues were left in place. Re-run with " \
                      "--allow-full-turnover if the turnover is real."
        end

        completed = issues.count(&.completed?)
        open = issues.size - completed
        retired = ack["retired"]?.try(&.as_i?) || 0

        # State the reconcile outcome, don't leave it inferable. `retired=0` alone
        # reads the same whether reconcile ran and found nothing to retire or was
        # withheld before it looked — a reader has to notice the absence of a
        # stderr warning to tell them apart, and a reader who only has stdout
        # cannot. Naming it is what makes the summary answer the question on its
        # own.
        reconcile_state =
          if !reconcile
            "off"
          elsif withheld
            reason = ack["withheld_reason"]?.try(&.as_s?)
            reason = "unknown" if reason.nil? || reason.empty?
            "WITHHELD:#{reason}"
          else
            "applied"
          end

        puts "Synced #{issues.size} actionable items " \
             "(source=#{source}, #{open} open, #{completed} completed, " \
             "reconcile=#{reconcile_state}, retired=#{retired})."
      end

      # Create ONE manual actionable (todo/reminder/explore) from flags + a
      # markdown body file. Deterministic — no network and no enrichment (the
      # capture skill does that). Validates the kind/title/date, then
      # request/replies an `actionable_item.create` envelope the app persists via
      # GRDBItemStore.create, acking the new item's id so this can print it.
      # Request/reply (not fire-and-forget) so the id round-trips; capture always
      # runs with the app up. The body comes from --body-file so multi-line
      # markdown survives intact.
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

        ack = request_ack("actionable_item.create", detail)
        id = ack["id"]?.try(&.as_s?) || ""

        where =
          if icebox
            "→ Icebox"
          elsif scheduled_on
            "scheduled #{scheduled_on}"
          else
            "unscheduled → Today"
          end
        puts "Created #{kind} item: #{title} (#{id}, #{where})."
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

      # Read: enumerate items with their ids so update/remove have a target.
      # `--state active` (default) lists every non-deleted actionable (incl.
      # iceboxed/resolved), `source`-flagged so the agent sees which are manual
      # (editable) vs synced; `--state trashed` lists the soft-deleted set. Each
      # call returns one homogeneous set. A request/reply read — needs the app up.
      private def list(args : Array(String))
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts list_help
          return
        end

        state = "active"
        OptionParser.parse(rest) do |p|
          p.banner = "Usage: assist-ant actionable-item list [options]"
          p.on("-h", "--help", "Show this help") { puts list_help; exit 0 }
          p.on("--state=STATE", "active | trashed (default: active)") { |v| state = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant actionable-item list") }
        end

        unless {"active", "trashed"}.includes?(state)
          STDERR.puts "Error: --state must be active or trashed"
          exit 1
        end

        reply = AssistAnt::EventPublisher.request(
          event: "actionable_item.list",
          detail_data: {"state" => JSON::Any.new(state)},
        )
        if reply.nil? || reply.empty?
          STDERR.puts "Error: no reply from AssistAnt (is the app running?)"
          exit 1
        end

        puts reply
      end

      # Edit a manual item in place. Sends only the fields that were passed (set,
      # explicit-clear, or toggle); the app overlays them and refuses any item
      # that isn't manual. Local validation catches a bad date, the
      # mutually-exclusive set/clear pairs, and an empty change before sending.
      private def update(args : Array(String))
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts update_help
          return
        end
        id = rest.shift?
        if id.nil?
          STDERR.puts "Error: update requires an item id (run 'assist-ant actionable-item list' to find it)"
          exit 1
        end

        title : String? = nil
        body_path : String? = nil
        scheduled_on : String? = nil
        unschedule = false
        list_name : String? = nil
        clear_list = false
        url : String? = nil
        clear_url = false
        icebox : Bool? = nil
        trash : Bool? = nil

        OptionParser.parse(rest) do |p|
          p.banner = "Usage: assist-ant actionable-item update <id> [options]"
          p.on("-h", "--help", "Show this help") { puts update_help; exit 0 }
          p.on("--title=TITLE", "New title") { |v| title = v }
          p.on("--body-file=PATH", "File with the new markdown body") { |v| body_path = v }
          p.on("--scheduled-on=YYYY-MM-DD", "Reschedule to a day") { |v| scheduled_on = v }
          p.on("--unschedule", "Clear the schedule (→ Today)") { unschedule = true }
          p.on("--list=NAME", "Assign to a list") { |v| list_name = v }
          p.on("--clear-list", "Remove from its list") { clear_list = true }
          p.on("--url=URL", "Set the external URL") { |v| url = v }
          p.on("--clear-url", "Clear the external URL") { clear_url = true }
          p.on("--icebox", "Move to the Icebox") { icebox = true }
          p.on("--no-icebox", "Remove from the Icebox") { icebox = false }
          p.on("--trash", "Soft-delete (→ Trash)") { trash = true }
          p.on("--no-trash", "Restore from the Trash") { trash = false }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant actionable-item update") }
        end

        if d = scheduled_on
          unless d =~ /\A\d{4}-\d{2}-\d{2}\z/
            STDERR.puts "Error: --scheduled-on must be YYYY-MM-DD"
            exit 1
          end
        end
        if scheduled_on && unschedule
          STDERR.puts "Error: --scheduled-on and --unschedule are mutually exclusive"
          exit 1
        end
        if list_name && clear_list
          STDERR.puts "Error: --list and --clear-list are mutually exclusive"
          exit 1
        end
        if url && clear_url
          STDERR.puts "Error: --url and --clear-url are mutually exclusive"
          exit 1
        end

        detail = {} of String => JSON::Any
        detail["id"] = JSON::Any.new(id)
        if t = title
          detail["title"] = JSON::Any.new(t)
        end
        if bp = body_path
          unless File.exists?(bp)
            STDERR.puts "Error: --body-file not found: #{bp}"
            exit 1
          end
          detail["body"] = JSON::Any.new(File.read(bp))
        end
        if d = scheduled_on
          detail["scheduled_on"] = JSON::Any.new(d)
        end
        detail["unschedule"] = JSON::Any.new(true) if unschedule
        if l = list_name
          detail["list_name"] = JSON::Any.new(l)
        end
        detail["clear_list"] = JSON::Any.new(true) if clear_list
        if u = url
          detail["external_url"] = JSON::Any.new(u)
        end
        detail["clear_url"] = JSON::Any.new(true) if clear_url
        icebox_value = icebox
        unless icebox_value.nil?
          detail["icebox"] = JSON::Any.new(icebox_value)
        end
        trash_value = trash
        unless trash_value.nil?
          detail["trash"] = JSON::Any.new(trash_value)
        end

        if detail.size == 1 # only the id
          STDERR.puts "Error: update needs at least one field to change"
          exit 1
        end

        ack = request_ack("actionable_item.update", detail)
        puts "Updated item: #{ack["name"]?.try(&.as_s?) || id} (#{ack["id"]?.try(&.as_s?) || id})."
      end

      # Soft-delete a manual item (→ Trash, recoverable via `update --no-trash`).
      # The simple one-shot delete verb; `update --trash` does the same inline.
      private def remove(args : Array(String))
        rest = args.dup
        if rest.first? == "-h" || rest.first? == "--help"
          puts remove_help
          return
        end
        id = rest.shift?
        if id.nil?
          STDERR.puts "Error: remove requires an item id (run 'assist-ant actionable-item list' to find it)"
          exit 1
        end
        ack = request_ack("actionable_item.delete", {"id" => JSON::Any.new(id)})
        puts "Removed item #{ack["id"]?.try(&.as_s?) || id}."
      end

      # Serialize the batch the app applies in one transaction: every issue as a
      # row (open or completed), the keep set (every external_id seen), and the
      # reconcile flag (soft-delete orphans not in keep).
      #
      # `allow_full_turnover` is emitted ONLY when the flag was passed. The app
      # decodes it as optional and defaults it to false, so an omitted field and
      # a `false` one mean the same thing to the store — but omitting it keeps
      # the payload honest about what the operator actually asked for.
      private def build_batch_json(
        issues : Array(LinearSync::NormalizedIssue),
        source : String, reconcile : Bool, allow_full_turnover : Bool = false,
      ) : String
        JSON.build do |j|
          j.object do
            j.field "source", source
            j.field "reconcile", reconcile
            j.field "allow_full_turnover", true if allow_full_turnover
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
        assist-ant actionable-item sync — fetch or ingest a provider issue list

        USAGE:
          assist-ant actionable-item sync --provider NAME --source SOURCE [options]

        REQUIRED:
          --provider NAME        Input format, e.g. linear
          --source SOURCE        Item source id, e.g. linear

        OPTIONS:
          --fetch                Fetch from Linear directly via the `linear` CLI
          --linear-workspace N   Workspace for --fetch (default: #{LinearSync::APIFetcher::DEFAULT_WORKSPACE})
          --input PATH           Raw provider response file (default: stdin)
          --no-reconcile         Skip the orphan soft-delete (partial/manual fetch)
          --allow-full-turnover  Reconcile even when no incoming issue matches an
                                 existing one (a real Linear-side migration)
          -h, --help             Show this help

        DESCRIPTION:
          --fetch and --input are mutually exclusive: either the CLI queries
          Linear itself (assigned issues in started/unstarted/backlog/triage,
          plus completed within the last 7 days) or it reads a provider payload.

          The summary reports what the app DID, not what this command intended.
          If the app withheld the orphan soft-delete because the incoming set
          matched nothing already stored, a warning naming the reason goes to
          stderr and `retired=0`; re-run with --allow-full-turnover once you have
          confirmed the turnover is real.

        EXAMPLES:
          assist-ant actionable-item sync --provider linear --source linear --fetch
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

      private def list_help : String
        <<-HELP
        assist-ant actionable-item list — list items with their ids

        USAGE:
          assist-ant actionable-item list [--state active|trashed]

        OPTIONS:
          --state STATE          active (default) | trashed
          -h, --help             Show this help

        DESCRIPTION:
          Prints items as JSON (`{"items":[{id, kind, title, list_name,
          scheduled_on, source, iceboxed, resolved, url}, …]}`) so update/remove
          have a target. `active` is every non-deleted actionable (incl. iceboxed
          and resolved); `trashed` is the soft-deleted set. The `source` field
          flags which items are manual (editable) vs synced. A read: requires the
          app to be running.

        EXAMPLES:
          assist-ant actionable-item list
          assist-ant actionable-item list --state trashed
        HELP
      end

      private def update_help : String
        <<-HELP
        assist-ant actionable-item update — edit a manual item in place

        USAGE:
          assist-ant actionable-item update <id> [options]

        OPTIONS:
          --title TITLE          New title
          --body-file PATH       File with the new markdown body
          --scheduled-on DATE    Reschedule to a day, YYYY-MM-DD
          --unschedule           Clear the schedule (→ Today)
          --list NAME            Assign to a list
          --clear-list           Remove from its list
          --url URL              Set the external URL
          --clear-url            Clear the external URL
          --icebox               Move to the Icebox
          --no-icebox            Remove from the Icebox
          --trash                Soft-delete (→ Trash)
          --no-trash             Restore from the Trash
          -h, --help             Show this help

        Only the fields you pass change. The set/clear pairs (--scheduled-on /
        --unschedule, --list / --clear-list, --url / --clear-url) are mutually
        exclusive. Only manual items are editable; a synced (Linear/calendar)
        item is refused. Run 'assist-ant actionable-item list' for ids.

        EXAMPLES:
          assist-ant actionable-item update 0192abc --title "New title"
          assist-ant actionable-item update 0192abc --list Errands --scheduled-on 2026-06-20
          assist-ant actionable-item update 0192abc --clear-list --unschedule
          assist-ant actionable-item update 0192abc --trash
          assist-ant actionable-item update 0192abc --no-trash
        HELP
      end

      private def remove_help : String
        <<-HELP
        assist-ant actionable-item remove — soft-delete a manual item

        USAGE:
          assist-ant actionable-item remove <id>

        Soft-deletes the item to the Trash (recoverable via
        'update <id> --no-trash'). Only manual items can be removed. Run
        'assist-ant actionable-item list' to find the id.
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

    # State categories we mirror.
    #
    # `triage` is included because a triage ticket is live work: it is assigned,
    # unresolved, and therefore a reconcile candidate on every run — so omitting
    # it did not merely hide those issues, it retired them.
    #
    # `canceled` stays out deliberately. A canceled issue is not work, and
    # dropping it from both `items` and `keep` is how the mirror retires a stale
    # copy. That is a decision, not an oversight.
    SYNCED_TYPES = {"started", "unstarted", "backlog", "triage", "completed"}

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

    # Fetches assigned issues straight from Linear's GraphQL API by shelling out
    # to the `linear` CLI, which already holds the credential.
    #
    # This is the whole point of `--fetch`: the projection below — which field
    # becomes the store's key, which are flat, which are nested — was previously
    # re-derived in a subagent prompt on every run, and produced two different
    # shapes in one day. Here it is code, and the specs pin it.
    #
    # `identifier` is the key, NOT `id`. Linear's `id` is a UUID; the store keys
    # on the human reference and `compose_body` renders it as the ticket link, so
    # a UUID in that slot both re-keys the mirror and prints as the title link.
    #
    # Returns `NormalizedIssue` directly — there is no MCP-shaped intermediate on
    # this path, because that shape existed only so an agent could hand data
    # across a file boundary. With the CLI fetching, the boundary is gone, and
    # the flat-vs-nested trap survives only on `--input`.
    class APIFetcher
      # `triage` included, `canceled` excluded — see SYNCED_TYPES.
      BUCKETS = {"started", "unstarted", "backlog", "triage", "completed"}

      # Completed issues are windowed: the mirror keeps recent history, not the
      # whole archive. A wider window would grow the payload without changing
      # what Today shows.
      COMPLETED_WINDOW = "-P7D"

      # Linear caps a connection page at 250; 100 keeps each response small
      # enough to parse in one gulp while still finishing most buckets in one
      # round trip.
      PAGE_SIZE = 100

      DEFAULT_WORKSPACE = "kajabi"

      def initialize(@workspace : String = DEFAULT_WORKSPACE)
      end

      def fetch : Array(NormalizedIssue)
        issues = [] of NormalizedIssue
        BUCKETS.each { |bucket| issues.concat(fetch_bucket(bucket)) }
        issues
      end

      # The GraphQL document for one bucket, cursored. A plain string rather than
      # a parameterized operation so a spec can read exactly what goes over the
      # wire — the shape of this query is the thing that drifted.
      def query_for(bucket : String, after : String? = nil) : String
        filters = [
          %(assignee: { isMe: { eq: true } }),
          %(state: { type: { eq: "#{bucket}" } }),
        ]
        # Only the completed bucket is windowed; every other bucket is live work
        # and is taken whole.
        filters << %(updatedAt: { gt: "#{COMPLETED_WINDOW}" }) if bucket == "completed"

        args = [%(filter: { #{filters.join(", ")} }), %(first: #{PAGE_SIZE})]
        args << %(after: "#{after}") if after

        <<-GQL
        query {
          issues(#{args.join(", ")}) {
            pageInfo { hasNextPage endCursor }
            nodes {
              # `id` is deliberately NOT selected. Linear's `id` is a UUID and
              # the store keys on the human reference, so selecting the field at
              # all is what invites the mistake this fetcher exists to prevent:
              # it is absent rather than merely unused.
              identifier
              title
              description
              url
              state { type name }
              completedAt
              team { name }
              priorityLabel
              project { name }
              projectMilestone { name }
              labels { nodes { name } }
            }
          }
        }
        GQL
      end

      # THE projection: one GraphQL issue node → one `NormalizedIssue`.
      #
      # `identifier` lands in `external_id` — never `id`, which is not even
      # selected. `priorityLabel` is the human string; GraphQL's `priority` is a
      # number, where the MCP gave `{name}`. The `{ name }` sub-selections arrive
      # nested and are flattened here, because everything downstream is flat.
      #
      # Returns nil for a state category we do not mirror, so the bucket list and
      # SYNCED_TYPES cannot silently disagree.
      def normalize(node : JSON::Any) : NormalizedIssue?
        identifier = node["identifier"]?.try(&.as_s?)
        return nil unless identifier

        state = node["state"]?
        status_type = state.try { |s| s["type"]?.try(&.as_s?) } || ""
        return nil unless SYNCED_TYPES.includes?(status_type)

        labels = [] of String
        if list = node.dig?("labels", "nodes").try(&.as_a?)
          list.each do |l|
            name = l["name"]?.try(&.as_s?)
            labels << name if name
          end
        end

        NormalizedIssue.new(
          external_id: identifier,
          title: (node["title"]?.try(&.as_s?) || "(untitled)").strip,
          description: node["description"]?.try(&.as_s?),
          url: node["url"]?.try(&.as_s?) || "",
          status_type: status_type,
          completed_at: node["completedAt"]?.try(&.as_s?),
          team: nested_name(node, "team") || "",
          status: state.try { |s| s["name"]?.try(&.as_s?) } || "",
          priority_name: node["priorityLabel"]?.try(&.as_s?) || "",
          project: nested_name(node, "project"),
          milestone: nested_name(node, "projectMilestone"),
          labels: labels,
        )
      end

      # One bucket, paginated. A bucket that errors ABORTS the whole fetch (via
      # `run_query`) rather than returning what it got: a partial set is exactly
      # the degraded fetch the app's turnover guard exists to catch, and failing
      # loudly here is cheaper than relying on the guard downstream.
      private def fetch_bucket(bucket : String) : Array(NormalizedIssue)
        issues = [] of NormalizedIssue
        cursor : String? = nil
        loop do
          doc = run_query(query_for(bucket, after: cursor))
          nodes = doc.dig?("data", "issues", "nodes").try(&.as_a?) || [] of JSON::Any
          nodes.each do |n|
            if issue = normalize(n)
              issues << issue
            end
          end
          page = doc.dig?("data", "issues", "pageInfo")
          break unless page
          break unless page["hasNextPage"]?.try(&.as_bool?)
          cursor = page["endCursor"]?.try(&.as_s?)
          break unless cursor
        end
        issues
      end

      # The thin shell-out, kept separate from `query_for`/`normalize` so those
      # two are unit-testable without a network.
      private def run_query(gql : String) : JSON::Any
        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new
        status =
          begin
            Process.run("linear",
              ["--workspace", @workspace, "api", gql],
              output: stdout_io, error: stderr_io)
          rescue ex : IO::Error
            STDERR.puts "Error: could not run the `linear` CLI (#{ex.message}). " \
                        "Install it and authenticate with `linear auth login`."
            exit 1
          end

        unless status.success?
          STDERR.puts "Error: `linear` CLI failed (exit #{status.exit_code}). " \
                      "Is it installed and authenticated (`linear auth login`)? " \
                      "#{stderr_io.to_s.strip}"
          exit 1
        end

        doc =
          begin
            JSON.parse(stdout_io.to_s)
          rescue ex
            STDERR.puts "Error: could not parse the `linear` CLI response as JSON " \
                        "(#{ex.message})"
            exit 1
          end

        # GraphQL answers HTTP 200 with an `errors` array, so a zero exit is not
        # a successful query — an unauthenticated or mis-shaped request lands
        # here, not above.
        if (body = doc.as_h?) && (errs = body["errors"]?.try(&.as_a?)) && !errs.empty?
          STDERR.puts "Error: Linear API returned errors: #{errs.to_json}"
          exit 1
        end

        doc
      end

      # A `{ name }` sub-selection, flattened. A null object is a legitimate
      # answer (an issue with no project, no milestone), so this is nilable
      # rather than defaulted.
      private def nested_name(node : JSON::Any, key : String) : String?
        node[key]?.try(&.as_h?).try { |h| h["name"]?.try(&.as_s?) }
      end
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
