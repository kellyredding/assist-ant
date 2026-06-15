require "../spec_helper"

# Unit-level coverage for `calendar-item`: the local-date derivation (pure,
# zone-pinned), the provider parser / filter / body composition, and in-process
# routing that must not raise when no app is listening. Output-driven behavior
# (exit codes, the published envelope, the batch file) lives in
# spec/integration/calendar_item_spec.cr.
describe AssistAnt::Commands::CalendarItem do
  describe ".scheduled_on" do
    it "derives the local civil date of the start instant, not the UTC date" do
      saved = Time::Location.local
      begin
        Time::Location.local = Time::Location.fixed(-7 * 3600) # UTC-7
        # 03:00Z is 20:00 the previous day at UTC-7.
        AssistAnt::Commands::CalendarItem
          .scheduled_on("2026-06-06T03:00:00Z").should eq "2026-06-05"
        # 18:00Z is 11:00 the same day at UTC-7.
        AssistAnt::Commands::CalendarItem
          .scheduled_on("2026-06-06T18:00:00Z").should eq "2026-06-06"
      ensure
        Time::Location.local = saved
      end
    end

    it "honors the offset carried in the start string" do
      saved = Time::Location.local
      begin
        Time::Location.local = Time::Location.fixed(0) # UTC
        # 23:30-07:00 is 06:30Z the next day.
        AssistAnt::Commands::CalendarItem
          .scheduled_on("2026-06-06T23:30:00-07:00").should eq "2026-06-07"
      ensure
        Time::Location.local = saved
      end
    end
  end

  describe "#run sync (in-process, no app listening)" do
    it "does not raise with valid flags when the socket is missing" do
      with_sandbox do
        input = File.tempfile("gcal", ".json")
        input.print(%({"events":[]}))
        input.close
        begin
          AssistAnt::CLI.new.run([
            "calendar-item", "sync",
            "--provider", "google-calendar", "--source", "gcal",
            "--from", "2026-06-08", "--to", "2026-07-08",
            "--input", input.path,
          ])
        ensure
          File.delete(input.path) if File.exists?(input.path)
        end
      end
    end
  end
end

describe AssistAnt::CalendarSync do
  google = AssistAnt::CalendarSync::GoogleCalendarParser.new

  describe "GoogleCalendarParser#parse" do
    it "keeps timed events and skips all-day events" do
      raw = %({"events":[
        {"id":"a","summary":"Timed","start":{"dateTime":"2026-06-10T15:00:00Z"},"calendarId":"kelly.redding@kajabi.com"},
        {"id":"b","summary":"AllDay","start":{"date":"2026-06-10"},"calendarId":"x"}
      ]})
      google.parse(raw).map(&.external_id).should eq ["a"]
    end

    it "maps calendarId to a roster name and reads the self RSVP" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"attendees":[{"email":"kelly.redding@kajabi.com","self":true,"responseStatus":"tentative"}],"calendarId":"76g7qc6v4csb7c31lagle78cs2e5or7l@import.calendar.google.com"}
      ]})
      e = google.parse(raw).first
      e.calendar_name.should eq "Travis Troop 226"
      e.self_response.should eq "tentative"
      e.start_raw.should eq "2026-06-10T15:00:00Z" # verbatim, never converted
    end
  end

  describe ".filter" do
    it "drops declined and out-of-window, keeps accepted/owner/no-attendee" do
      raw = %({"events":[
        {"id":"acc","summary":"A","start":{"dateTime":"2026-06-10T15:00:00Z"},"attendees":[{"email":"k","self":true,"responseStatus":"accepted"}],"calendarId":"kelly.redding@kajabi.com"},
        {"id":"dec","summary":"D","start":{"dateTime":"2026-06-10T15:00:00Z"},"attendees":[{"email":"k","self":true,"responseStatus":"declined"}],"calendarId":"kelly.redding@kajabi.com"},
        {"id":"sub","summary":"S","start":{"dateTime":"2026-06-10T15:00:00Z"},"calendarId":"en.usa#holiday@group.v.calendar.google.com"},
        {"id":"out","summary":"O","start":{"dateTime":"2026-08-01T15:00:00Z"},"attendees":[{"email":"k","self":true,"responseStatus":"accepted"}],"calendarId":"kelly.redding@kajabi.com"}
      ]})
      kept = AssistAnt::CalendarSync.filter(
        google.parse(raw), from: "2026-06-08", to: "2026-07-08"
      )
      kept.map(&.external_id).sort.should eq ["acc", "sub"]
    end
  end

  describe ".compose_body" do
    it "builds the markdown header and flattens HTML descriptions" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"location":"Room 1","description":"<p>Hi<br>there</p>","attendees":[{"email":"a@x.com"}],"organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      body = AssistAnt::CalendarSync.compose_body(google.parse(raw).first)
      body.should contain "📅 Work"
      body.should contain "RSVP: owner"
      body.should contain "📍 Room 1"
      body.should contain "Hi\nthere"
      body.should_not contain "<p>"
    end

    it "renders the meet link as a tappable markdown link, not a bare URL" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"hangoutLink":"https://meet.google.com/abc-defg-hij","organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      body = AssistAnt::CalendarSync.compose_body(google.parse(raw).first)
      body.should contain "🔗 [Join Meeting](https://meet.google.com/abc-defg-hij)"
    end

    it "linkifies a URL location (e.g. a Tuple/Zoom link) so it is tappable" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"location":"https://tuple.app/c/evXrbg","organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      body = AssistAnt::CalendarSync.compose_body(google.parse(raw).first)
      body.should contain "📍 [https://tuple.app/c/evXrbg](https://tuple.app/c/evXrbg)"
    end
  end

  describe ".external_url" do
    it "prefers the join link over location and the html link" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"hangoutLink":"https://meet.google.com/abc","location":"https://zoom.us/j/1","htmlLink":"https://www.google.com/calendar/event?eid=z","organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      AssistAnt::CalendarSync.external_url(google.parse(raw).first)
        .should eq "https://meet.google.com/abc"
    end

    it "falls back to a URL location when there is no join link" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"location":"https://zoom.us/j/1","htmlLink":"https://www.google.com/calendar/event?eid=z","organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      AssistAnt::CalendarSync.external_url(google.parse(raw).first)
        .should eq "https://zoom.us/j/1"
    end

    it "ignores a non-URL location and falls back to the html link" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"location":"Room 4","htmlLink":"https://www.google.com/calendar/event?eid=z","organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      AssistAnt::CalendarSync.external_url(google.parse(raw).first)
        .should eq "https://www.google.com/calendar/event?eid=z"
    end

    it "is nil when the event carries no openable URL" do
      raw = %({"events":[
        {"id":"a","summary":"X","start":{"dateTime":"2026-06-10T15:00:00Z"},"location":"Room 4","organizer":{"self":true},"calendarId":"kelly.redding@kajabi.com"}
      ]})
      AssistAnt::CalendarSync.external_url(google.parse(raw).first).should be_nil
    end
  end

  describe ".clean_description" do
    it "strips tags, converts breaks, and decodes entities" do
      AssistAnt::CalendarSync
        .clean_description("<p>A &amp; B<br>C</p>").should eq "A & B\nC"
    end

    it "escapes inline markdown metacharacters in the flattened text" do
      AssistAnt::CalendarSync
        .clean_description("Pay *now* for _50%_ [off]")
        .should eq "Pay \\*now\\* for \\_50%\\_ \\[off\\]"
    end

    it "turns bare URLs into autolinks without escaping URL characters" do
      AssistAnt::CalendarSync
        .clean_description("Join at https://x.com/a_b now")
        .should eq "Join at [https://x.com/a_b](https://x.com/a_b) now"
    end
  end
end
