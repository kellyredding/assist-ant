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
      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?

        case sub
        when "sync"
          sync(rest)
        else
          STDERR.puts "Error: unknown actionable-item subcommand '#{sub}'"
          STDERR.puts "Subcommands: sync"
          exit 1
        end
      end

      private def sync(args : Array(String))
        provider = ""
        source = ""
        input_path : String? = nil
        reconcile = true

        OptionParser.parse(args) do |p|
          p.on("--provider=NAME", "Input format, e.g. linear (required)") { |v| provider = v }
          p.on("--source=SOURCE", "Item source id, e.g. linear (required)") { |v| source = v }
          p.on("--input=PATH", "Raw provider response file (default: stdin)") { |v| input_path = v }
          p.on("--no-reconcile", "Skip the orphan soft-delete (for a partial/manual fetch)") { reconcile = false }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'") }
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

      private def require_flag(name : String, value : String)
        return unless value.empty?
        STDERR.puts "Error: #{name} is required"
        exit 1
      end

      private def abort_flag(message : String)
        STDERR.puts "Error: #{message}"
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
        io << "\n#{parts.join("  ·  ")}" unless parts.empty?

        # Issue description (markdown; bare URLs linkified).
        if desc = i.description
          cleaned = linkify_bare_urls(desc.strip)
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
  end
end
