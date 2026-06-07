require "../spec_helper"

# Unit-level coverage for the `calendar-item` command: the local-date
# derivation (pure logic, with the time zone pinned) and in-process routing
# that must not raise when no app is listening. Output-driven behavior
# (missing-flag exit codes, the published envelope) lives in
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

  describe "#run (in-process, no app listening)" do
    it "upsert does not raise with valid flags when the socket is missing" do
      with_sandbox do
        AssistAnt::CLI.new.run([
          "calendar-item", "upsert",
          "--external-id", "e1", "--title", "Standup",
          "--start", "2026-06-06T10:00:00Z", "--source", "gcal",
        ])
      end
    end

    it "prune does not raise with valid flags when the socket is missing" do
      with_sandbox do
        AssistAnt::CLI.new.run([
          "calendar-item", "prune",
          "--source", "gcal", "--from", "2026-06-06", "--to", "2026-06-13",
          "--keep", "e1",
        ])
      end
    end
  end
end
