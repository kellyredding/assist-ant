module AssistAnt
  module Commands
    # `calendar-item` subcommands: `upsert` and `prune`. Each builds an event
    # envelope and publishes it to the running app over the socket. The CLI is
    # a pure, fire-and-forget sender that carries the full payload; the app is
    # the sole writer to the item store. Works whether or not the app is up.
    class CalendarItem
      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?

        case sub
        when "upsert"
          upsert(rest)
        when "prune"
          prune(rest)
        else
          STDERR.puts "Error: unknown calendar-item subcommand '#{sub}'"
          STDERR.puts "Subcommands: upsert, prune"
          exit 1
        end
      end

      # The local civil date (YYYY-MM-DD) of an ISO-8601 instant. Dates are
      # scheduled in local time, never UTC. Exposed for unit testing.
      def self.scheduled_on(start_iso : String) : String
        Time.parse_rfc3339(start_iso).to_local.to_s("%Y-%m-%d")
      end

      private def upsert(args : Array(String))
        external_id = ""
        title = ""
        start_at = ""
        source = ""
        end_at : String? = nil
        time_zone : String? = nil
        body : String? = nil

        OptionParser.parse(args) do |p|
          p.on("--external-id=ID", "Source's stable event id (required)") { |v| external_id = v }
          p.on("--title=TITLE", "Item title (required)") { |v| title = v }
          p.on("--start=ISO8601", "Start instant, ISO-8601 (required)") { |v| start_at = v }
          p.on("--source=SOURCE", "Source id, e.g. gcal (required)") { |v| source = v }
          p.on("--end=ISO8601", "End instant, ISO-8601") { |v| end_at = v }
          p.on("--time-zone=TZ", "IANA time zone id") { |v| time_zone = v }
          p.on("--body=MARKDOWN", "Markdown body") { |v| body = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'") }
        end

        require_flag("--external-id", external_id)
        require_flag("--title", title)
        require_flag("--start", start_at)
        require_flag("--source", source)

        scheduled_on = derive_scheduled_on(start_at)

        detail = {} of String => JSON::Any
        detail["external_id"] = JSON::Any.new(external_id)
        detail["title"] = JSON::Any.new(title)
        detail["start_at"] = JSON::Any.new(start_at)
        detail["source"] = JSON::Any.new(source)
        detail["scheduled_on"] = JSON::Any.new(scheduled_on)
        detail["end_at"] = JSON::Any.new(end_at.not_nil!) if end_at
        detail["time_zone"] = JSON::Any.new(time_zone.not_nil!) if time_zone
        detail["body"] = JSON::Any.new(body.not_nil!) if body

        AssistAnt::EventPublisher.publish(
          event: "calendar_item.upsert",
          detail_data: detail,
        )
      end

      private def prune(args : Array(String))
        source = ""
        from = ""
        to = ""
        keep = [] of String
        allow_empty = false

        OptionParser.parse(args) do |p|
          p.on("--source=SOURCE", "Source id, e.g. gcal (required)") { |v| source = v }
          p.on("--from=YYYY-MM-DD", "Window start date (required)") { |v| from = v }
          p.on("--to=YYYY-MM-DD", "Window end date (required)") { |v| to = v }
          p.on("--keep=ID", "External id to keep (repeatable)") { |v| keep << v }
          p.on("--allow-empty", "Permit an empty keep set (retires the whole window)") { allow_empty = true }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'") }
        end

        require_flag("--source", source)
        require_flag("--from", from)
        require_flag("--to", to)

        if keep.empty? && !allow_empty
          STDERR.puts "Error: refusing to prune with an empty --keep set (would retire the whole window). Pass --allow-empty to override."
          exit 1
        end

        detail = {
          "source"      => JSON::Any.new(source),
          "from"        => JSON::Any.new(from),
          "to"          => JSON::Any.new(to),
          "keep"        => JSON::Any.new(keep.map { |k| JSON::Any.new(k) }),
          "allow_empty" => JSON::Any.new(allow_empty),
        }

        AssistAnt::EventPublisher.publish(
          event: "calendar_item.prune",
          detail_data: detail,
        )
      end

      private def derive_scheduled_on(start_at : String) : String
        self.class.scheduled_on(start_at)
      rescue ex
        STDERR.puts "Error: invalid --start '#{start_at}' (#{ex.message})"
        exit 1
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
end
