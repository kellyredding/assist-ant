require "html"

module AssistAnt
  module Commands
    # `calendar-item sync`: ingest a provider's raw calendar response, filter to
    # the qualifying set, compose item bodies, and hand the app one batched
    # upsert+prune payload (via a temp file) for a single atomic transaction.
    #
    # The CLI is a pure, fire-and-forget sender: it does the parsing/filtering
    # deterministically (no LLM), writes the batch to a temp file, and publishes
    # a small `calendar_item.sync` envelope carrying that file's path. Works
    # whether or not the app is up.
    class CalendarItem
      def run(args : Array(String))
        rest = args.dup
        sub = rest.shift?

        case sub
        when "sync"
          sync(rest)
        when nil, "-h", "--help", "help"
          puts group_help
        else
          STDERR.puts "Error: unknown calendar-item subcommand '#{sub}'"
          STDERR.puts "Run 'assist-ant calendar-item --help' for usage"
          exit 1
        end
      end

      private def group_help : String
        <<-HELP
        assist-ant calendar-item — manage calendar items

        USAGE:
          assist-ant calendar-item <subcommand> [options]

        SUBCOMMANDS:
          sync      Ingest a provider's calendar response; upsert + prune the window.

        Run 'assist-ant calendar-item <subcommand> --help' for details.
        HELP
      end

      # The local civil date (YYYY-MM-DD) of an ISO-8601 instant. Dates are
      # scheduled in local time, never UTC. Reused per-event during sync and
      # unit-tested directly.
      def self.scheduled_on(start_iso : String) : String
        Time.parse_rfc3339(start_iso).to_local.to_s("%Y-%m-%d")
      end

      private def sync(args : Array(String))
        provider = ""
        source = ""
        from = ""
        to = ""
        input_path : String? = nil

        OptionParser.parse(args) do |p|
          p.banner = "Usage: assist-ant calendar-item sync [options]"
          p.on("-h", "--help", "Show this help") { puts sync_help; exit 0 }
          p.on("--provider=NAME", "Input format, e.g. google-calendar (required)") { |v| provider = v }
          p.on("--source=SOURCE", "Item source id, e.g. gcal (required)") { |v| source = v }
          p.on("--from=YYYY-MM-DD", "Window start date (required)") { |v| from = v }
          p.on("--to=YYYY-MM-DD", "Window end date (required)") { |v| to = v }
          p.on("--input=PATH", "Raw provider response file (default: stdin)") { |v| input_path = v }
          p.invalid_option { |f| abort_flag("unknown flag '#{f}'", "assist-ant calendar-item sync") }
        end

        require_flag("--provider", provider)
        require_flag("--source", source)
        require_flag("--from", from)
        require_flag("--to", to)

        parser = CalendarSync.parser_for(provider)
        unless parser
          STDERR.puts "Error: unknown --provider '#{provider}' " \
                      "(known: #{CalendarSync.known_providers.join(", ")})"
          exit 1
        end

        raw =
          if path = input_path
            File.read(path)
          else
            STDIN.gets_to_end
          end

        events =
          begin
            parser.parse(raw)
          rescue ex
            STDERR.puts "Error: failed to parse #{provider} response (#{ex.message})"
            exit 1
          end

        qualifying = CalendarSync.filter(events, from: from, to: to)

        batch_json = build_batch_json(qualifying, source: source, from: from, to: to)
        tmp = File.tempfile("assist-ant-sync", ".json")
        begin
          tmp.print(batch_json)
        ensure
          tmp.close
        end

        detail = {
          "batch_file" => JSON::Any.new(tmp.path),
          "source"     => JSON::Any.new(source),
          "count"      => JSON::Any.new(qualifying.size.to_i64),
        }
        AssistAnt::EventPublisher.publish(
          event: "calendar_item.sync",
          detail_data: detail,
        )

        if qualifying.empty?
          puts "No qualifying events in #{from}..#{to} — skipped prune " \
               "(treated as a degraded fetch). Nothing changed."
        else
          puts "Synced #{qualifying.size} calendar items " \
               "(source=#{source}, #{from}..#{to})."
        end
      end

      # Serialize the batch the app applies in one transaction: the qualifying
      # items plus the prune window + keep set. `prune` is false when nothing
      # qualified, so a degraded/empty fetch never retires the window.
      private def build_batch_json(
        events : Array(CalendarSync::NormalizedEvent),
        source : String, from : String, to : String,
      ) : String
        # Segment every event once (a multi-day timed event fans out to one row
        # per covered local day); both `keep` and `items` read from this so the
        # prune set always matches the rows we emit.
        segmented = events.map { |e| {e, CalendarSync.segments(e, from, to)} }

        JSON.build do |j|
          j.object do
            j.field "source", source
            j.field "from", from
            j.field "to", to
            j.field "prune", !events.empty?
            j.field "keep" do
              j.array do
                segmented.each do |_, segs|
                  segs.each { |s| j.string s.external_id }
                end
              end
            end
            j.field "items" do
              j.array do
                segmented.each do |e, segs|
                  body = CalendarSync.compose_body(e)
                  url = CalendarSync.external_url(e)
                  segs.each do |s|
                    j.object do
                      j.field "external_id", s.external_id
                      j.field "title", e.title
                      j.field "start_at", s.start_at
                      j.field "scheduled_on", s.scheduled_on
                      if ea = s.end_at
                        j.field "end_at", ea
                      end
                      if tz = e.time_zone
                        j.field "time_zone", tz
                      end
                      j.field "body", body
                      if url
                        j.field "external_url", url
                      end
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
        assist-ant calendar-item sync — ingest a provider calendar response

        USAGE:
          assist-ant calendar-item sync --provider NAME --source SOURCE \\
            --from YYYY-MM-DD --to YYYY-MM-DD [options]

        REQUIRED:
          --provider NAME        Input format, e.g. google-calendar
          --source SOURCE        Item source id, e.g. gcal
          --from YYYY-MM-DD      Window start date
          --to YYYY-MM-DD        Window end date

        OPTIONS:
          --input PATH           Raw provider response file (default: stdin)
          -h, --help             Show this help

        EXAMPLES:
          assist-ant calendar-item sync --provider google-calendar --source gcal \\
            --from 2026-06-13 --to 2026-06-20 --input /tmp/events.json
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

  # Provider-aware calendar parsing + filtering + body composition. Kept
  # provider-agnostic past the parser: parsers normalize to `NormalizedEvent`,
  # and everything downstream (filter, body) works on that shape.
  module CalendarSync
    # A normalized, provider-agnostic calendar event. `start_raw`/`end_raw` are
    # the provider's ISO-8601 strings verbatim — never converted here (the app
    # derives the local day from the instant).
    record NormalizedEvent,
      external_id : String,
      title : String,
      start_raw : String,
      end_raw : String?,
      calendar_name : String,
      self_response : String?, # responseStatus of your own attendee entry, if any
      is_owner : Bool,
      location : String?,
      meet_link : String?,
      html_link : String?,
      attendees : Array(String),
      description : String?,
      time_zone : String?

    # calendarId -> friendly display name for the body's 📅 line. Baked in;
    # an unknown id falls back to the organizer display name, then the id.
    ROSTER = {
      "kelly.redding@kajabi.com"                                    => "Work",
      "kdredding@gmail.com"                                         => "Kelly",
      "se33hek3vjmu5k3dhdqbvcq348@group.calendar.google.com"        => "Family",
      "76g7qc6v4csb7c31lagle78cs2e5or7l@import.calendar.google.com" => "Travis Troop 226",
      "85mkf4bsi8jo2bd4vggnnk0mu0@group.calendar.google.com"        => "Important Dates",
      "en.usa#holiday@group.v.calendar.google.com"                  => "US Holidays",
    }

    abstract class Parser
      abstract def parse(raw : String) : Array(NormalizedEvent)
    end

    # Parses the `@cocal/google-calendar-mcp` list-events response:
    #   {"events":[{id,summary,start:{dateTime|date,timeZone},end,attendees,
    #               organizer,location,hangoutLink,conferenceData,description,
    #               calendarId}, …], "totalCount":N, "calendars":[…]}
    class GoogleCalendarParser < Parser
      def parse(raw : String) : Array(NormalizedEvent)
        doc = JSON.parse(raw)
        items = doc["events"]?.try(&.as_a?) || [] of JSON::Any
        items.compact_map { |ev| normalize(ev) }
      end

      private def normalize(ev : JSON::Any) : NormalizedEvent?
        id = ev["id"]?.try(&.as_s?)
        return nil unless id

        start = ev["start"]?
        return nil unless start
        # Timed-only: all-day events carry `start.date`, not `start.dateTime`.
        start_raw = start["dateTime"]?.try(&.as_s?)
        return nil unless start_raw

        end_raw = ev["end"]?.try { |e| e["dateTime"]?.try(&.as_s?) }
        tz = start["timeZone"]?.try(&.as_s?)

        cal_id = ev["calendarId"]?.try(&.as_s?) || ""
        cal_name = ROSTER[cal_id]? ||
                   ev["organizer"]?.try { |o| o["displayName"]?.try(&.as_s?) } ||
                   cal_id

        is_owner = ev["organizer"]?.try { |o| o["self"]?.try(&.as_bool?) } || false

        self_response : String? = nil
        attendees = [] of String
        if list = ev["attendees"]?.try(&.as_a?)
          list.each do |a|
            if a["self"]?.try(&.as_bool?) == true
              self_response = a["responseStatus"]?.try(&.as_s?)
            end
            name = a["displayName"]?.try(&.as_s?) || a["email"]?.try(&.as_s?)
            attendees << name if name
          end
        end

        NormalizedEvent.new(
          external_id: id,
          title: (ev["summary"]?.try(&.as_s?) || "(no title)").strip,
          start_raw: start_raw,
          end_raw: end_raw,
          calendar_name: cal_name,
          self_response: self_response,
          is_owner: is_owner,
          location: ev["location"]?.try(&.as_s?),
          meet_link: ev["hangoutLink"]?.try(&.as_s?) || conference_link(ev),
          html_link: ev["htmlLink"]?.try(&.as_s?),
          attendees: attendees,
          description: ev["description"]?.try(&.as_s?),
          time_zone: tz,
        )
      end

      private def conference_link(ev : JSON::Any) : String?
        eps = ev["conferenceData"]?.try { |cd| cd["entryPoints"]?.try(&.as_a?) }
        return nil unless eps
        video = eps.find { |e| e["entryPointType"]?.try(&.as_s?) == "video" }
        video.try { |e| e["uri"]?.try(&.as_s?) }
      end
    end

    PARSERS = {
      "google-calendar" => GoogleCalendarParser.new.as(Parser),
    }

    def self.parser_for(name : String) : Parser?
      PARSERS[name]?
    end

    def self.known_providers : Array(String)
      PARSERS.keys
    end

    # One emitted calendar row: its per-day external id, local day, and the
    # segment's start/end instants (ISO-8601 with local offset).
    record Segment,
      external_id : String,
      scheduled_on : String,
      start_at : String,
      end_at : String?

    # The first and last LOCAL day an event covers. A no-end event covers only
    # its start day. A timed event ending exactly at local midnight does NOT
    # cover that final day (zero-length), so the last day is the day before.
    def self.covered_days(start_raw : String, end_raw : String?) : {Time, Time}
      start_day = Time.parse_rfc3339(start_raw).to_local.at_beginning_of_day
      return {start_day, start_day} unless er = end_raw

      end_t = Time.parse_rfc3339(er).to_local
      last =
        if end_t == end_t.at_beginning_of_day       # exact local midnight
          end_t.shift(days: -1).at_beginning_of_day # calendar-aware (DST-safe)
        else
          end_t.at_beginning_of_day
        end
      last = start_day if last < start_day # clamp degenerate spans
      {start_day, last}
    end

    # One Segment per local day in [from, to] the event covers. A single-day (or
    # midnight-bounded same-day) event returns ONE segment with the bare event id
    # and the raw instants — byte-for-byte as before. A multi-day event emits one
    # segment per covered in-window day, keyed "<id>#<YYYY-MM-DD>": the true start
    # day carries the real start instant and the true last day the real end; other
    # days open at 00:00:00 and close at 23:59:59. Emission is clamped to the
    # window (a longer-than-window tail fills in as the window advances).
    def self.segments(e : NormalizedEvent, from : String, to : String) : Array(Segment)
      first_day, last_day = covered_days(e.start_raw, e.end_raw)

      if last_day == first_day
        return [Segment.new(
          external_id: e.external_id,
          scheduled_on: Commands::CalendarItem.scheduled_on(e.start_raw),
          start_at: e.start_raw,
          end_at: e.end_raw,
        )]
      end

      start_day_str = first_day.to_s("%Y-%m-%d")
      # The raw end's local day — where the real end instant belongs. For an
      # exact-midnight end this is the day AFTER last_day, so it's never emitted
      # and the last covered day closes at end-of-day instead.
      end_day_str = (er = e.end_raw) ? Time.parse_rfc3339(er).to_local.to_s("%Y-%m-%d") : ""

      out = [] of Segment
      cursor = first_day
      while cursor <= last_day
        day = cursor.to_s("%Y-%m-%d")
        if day >= from && day <= to # clamp to the sync window
          start_at = day == start_day_str ? e.start_raw : iso_local(cursor)
          end_at =
            if day == end_day_str && (er = e.end_raw)
              er
            else
              iso_local(cursor.at_end_of_day) # 23:59:59 local
            end
          out << Segment.new(
            external_id: "#{e.external_id}##{day}",
            scheduled_on: day,
            start_at: start_at,
            end_at: end_at,
          )
        end
        cursor = cursor.shift(days: 1) # DST-safe calendar step
      end
      out
    end

    # RFC-3339 in the time's LOCAL offset (e.g. "…-05:00"), to whole seconds —
    # `Time#to_rfc3339` normalizes to UTC ("…Z"), but we want the local offset to
    # match the provider's raw start/end strings.
    def self.iso_local(t : Time) : String
      t.to_s("%Y-%m-%dT%H:%M:%S%:z")
    end

    # Keep an event whose covered span intersects [from, to] (NOT start-day only,
    # so a multi-day event running into the window from before is re-emitted and
    # its in-window segments stay in `keep`), AND that isn't declined/pending:
    # you own it, you have no attendee entry (subscribed calendars), or you
    # accepted/tentatively-accepted.
    def self.filter(events : Array(NormalizedEvent), from : String, to : String) : Array(NormalizedEvent)
      events.select do |e|
        first_day, last_day = covered_days(e.start_raw, e.end_raw)
        next false unless first_day.to_s("%Y-%m-%d") <= to &&
                          last_day.to_s("%Y-%m-%d") >= from
        e.is_owner ||
          e.self_response.nil? ||
          e.self_response == "accepted" ||
          e.self_response == "tentative"
      end
    end

    # The markdown body, assembled deterministically from the normalized event.
    def self.compose_body(e : NormalizedEvent) : String
      String.build do |io|
        io << "📅 #{e.calendar_name}  ·  RSVP: #{rsvp_label(e)}"
        if loc = e.location
          # Meeting links (Tuple, Zoom, …) commonly arrive as the location, so
          # linkify it: a URL location becomes tappable, a plain place is left
          # as text.
          io << "\n📍 #{escape_and_linkify(loc)}" unless loc.empty?
        end
        if link = e.meet_link
          # A Markdown link, not a bare URL: the app renders the body through
          # SwiftUI's Markdown parser, which only makes `[text](url)` tappable.
          io << "\n🔗 [Join Meeting](#{link})" unless link.empty?
        end
        io << "\n\n👥 #{e.attendees.join(", ")}" unless e.attendees.empty?
        if desc = e.description
          cleaned = clean_description(desc)
          io << "\n\n#{cleaned}" unless cleaned.empty?
        end
      end
    end

    # The single openable URL for the event, most-specific first: the live join
    # link, else a location that is itself a URL (Tuple/Zoom often arrive there),
    # else the Google Calendar event page. nil when none apply.
    def self.external_url(e : NormalizedEvent) : String?
      if (link = e.meet_link) && !link.empty?
        link
      elsif (loc = e.location) && url?(loc)
        loc
      elsif (html = e.html_link) && !html.empty?
        html
      end
    end

    def self.url?(str : String) : Bool
      str.starts_with?("http://") || str.starts_with?("https://")
    end

    def self.rsvp_label(e : NormalizedEvent) : String
      return "owner" if e.is_owner
      case e.self_response
      when "accepted"  then "accepted"
      when "tentative" then "tentative"
      else                  "—"
      end
    end

    # Flatten provider HTML descriptions to readable text: block tags become
    # newlines, remaining tags are stripped, entities decoded, blank runs
    # collapsed. Deterministic — no LLM cleanup pass.
    def self.clean_description(raw : String) : String
      escape_and_linkify(flatten_html(raw))
    end

    # Flatten provider HTML to readable plain text: block tags become newlines,
    # remaining tags are stripped, entities decoded, blank runs collapsed.
    def self.flatten_html(raw : String) : String
      text = raw
        .gsub(/<br\s*\/?>/i, "\n")
        .gsub(/<\/(p|div|li|tr)>/i, "\n")
        .gsub(/<[^>]+>/, "")
      HTML.unescape(text).gsub(/\n{3,}/, "\n\n").strip
    end

    URL_RE = /https?:\/\/[^\s\]\)]+/

    # Prepare plain text for the app's Markdown parser: escape inline Markdown
    # metacharacters (so a stray "*" or "[" renders literally) while turning
    # bare URLs into tappable autolinks (`[url](url)`) — the parser only links
    # bracketed URLs, not bare ones. URLs are emitted whole in a single pass so
    # their own characters (including "_" and "~") are never backslash-escaped.
    def self.escape_and_linkify(text : String) : String
      String.build do |io|
        cursor = 0
        text.scan(URL_RE) do |m|
          io << escape_markdown(text[cursor...m.begin(0)])
          url = m[0]
          io << "[#{url}](#{url})"
          cursor = m.end(0)
        end
        io << escape_markdown(text[cursor..])
      end
    end

    # Backslash-escape the inline Markdown metacharacters so plain text renders
    # verbatim through the app's Markdown parser instead of being interpreted
    # (a stray "*" italicizing, "[" opening a link, a "`" starting code).
    def self.escape_markdown(text : String) : String
      text.gsub(/[\\`*_~\[\]]/) { |c| "\\#{c}" }
    end
  end
end
