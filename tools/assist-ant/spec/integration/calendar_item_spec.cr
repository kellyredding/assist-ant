require "../spec_helper"

# End-to-end coverage for `calendar-item sync`: shell out to the built binary,
# feed it a provider response, capture the envelope it publishes off a real
# UNIXServer (reusing `with_socket_server` / `run_binary` from the sibling
# integration specs), and assert on the batch file it hands the app.
# Skips automatically if the binary hasn't been built — run `make dev` first.
describe "assist-ant calendar-item sync" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  # One timed accepted event (kept), one all-day event (skipped), one declined
  # event (skipped).
  fixture = <<-JSON
    {"events":[
      {"id":"evt-1","summary":"Standup","start":{"dateTime":"2026-06-10T15:00:00Z","timeZone":"America/Chicago"},"end":{"dateTime":"2026-06-10T15:30:00Z"},"organizer":{"email":"kelly.redding@kajabi.com","self":true},"attendees":[{"email":"kelly.redding@kajabi.com","self":true,"responseStatus":"accepted"}],"location":"Room 1","hangoutLink":"https://meet.google.com/evt-1","description":"<p>Daily standup</p>","calendarId":"kelly.redding@kajabi.com"},
      {"id":"evt-allday","summary":"Holiday","start":{"date":"2026-07-04"},"calendarId":"en.usa#holiday@group.v.calendar.google.com"},
      {"id":"evt-declined","summary":"Optional","start":{"dateTime":"2026-06-11T16:00:00Z"},"attendees":[{"email":"kelly.redding@kajabi.com","self":true,"responseStatus":"declined"}],"calendarId":"kelly.redding@kajabi.com"}
    ],"totalCount":3,"calendars":["kelly.redding@kajabi.com"]}
    JSON

  it "publishes a calendar_item.sync envelope and writes a batch of qualifying items" do
    with_socket_server do |sock_path, channel|
      input = File.tempfile("gcal-fixture", ".json")
      input.print(fixture)
      input.close
      begin
        result = run_binary(
          [binary, "calendar-item", "sync",
           "--provider", "google-calendar", "--source", "gcal",
           "--from", "2026-06-08", "--to", "2026-07-08",
           "--input", input.path],
          env: {"ASSIST_ANT_SOCKET" => sock_path},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "calendar_item.sync"
        detail = parsed["detail_data"]
        detail["source"].should eq "gcal"
        detail["count"].should eq 1

        batch_file = detail["batch_file"].as_s
        File.exists?(batch_file).should be_true
        batch = JSON.parse(File.read(batch_file))
        File.delete(batch_file)

        batch["source"].should eq "gcal"
        batch["from"].should eq "2026-06-08"
        batch["to"].should eq "2026-07-08"
        batch["prune"].as_bool.should be_true
        batch["keep"].as_a.map(&.as_s).should eq ["evt-1"]

        items = batch["items"].as_a
        items.size.should eq 1
        item = items.first
        item["external_id"].should eq "evt-1"
        item["title"].should eq "Standup"
        # start_at passes through verbatim; scheduled_on is the local day.
        item["start_at"].should eq "2026-06-10T15:00:00Z"
        item["scheduled_on"].should eq(
          AssistAnt::Commands::CalendarItem.scheduled_on("2026-06-10T15:00:00Z")
        )
        item["body"].as_s.should contain "Daily standup"
        item["external_url"].should eq "https://meet.google.com/evt-1"
      ensure
        File.delete(input.path) if File.exists?(input.path)
      end
    end
  end

  describe "validation" do
    it "exits non-zero on an unknown subcommand" do
      result = run_binary([binary, "calendar-item", "bogus"])
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown calendar-item subcommand"
    end

    it "exits non-zero when a required flag is missing" do
      result = run_binary(
        [binary, "calendar-item", "sync",
         "--provider", "google-calendar",
         "--from", "2026-06-08", "--to", "2026-07-08"], # no --source
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "--source"
    end

    it "exits non-zero on an unknown provider" do
      result = run_binary(
        [binary, "calendar-item", "sync",
         "--provider", "bogus", "--source", "gcal",
         "--from", "2026-06-08", "--to", "2026-07-08"],
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown --provider"
    end
  end
end
