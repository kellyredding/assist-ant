require "../spec_helper"

# End-to-end coverage for the `calendar-item` command: shell out to the built
# binary and capture the envelope it publishes off a real UNIXServer (reusing
# `with_socket_server` and `run_binary` from the sibling integration specs).
# Skips automatically if the binary hasn't been built — run `make dev` first.
describe "assist-ant calendar-item" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "upsert publishes a calendar_item.upsert envelope with a locally-derived scheduled_on" do
    with_socket_server do |sock_path, channel|
      result = run_binary(
        [binary, "calendar-item", "upsert",
         "--external-id", "evt-1", "--title", "Standup",
         "--start", "2026-06-06T18:00:00Z", "--source", "gcal",
         "--time-zone", "America/Los_Angeles"],
        env: {"ASSIST_ANT_SOCKET" => sock_path},
      )
      result[:status].success?.should be_true

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "calendar_item.upsert"
      detail = parsed["detail_data"]
      detail["external_id"].should eq "evt-1"
      detail["title"].should eq "Standup"
      detail["source"].should eq "gcal"
      detail["start_at"].should eq "2026-06-06T18:00:00Z"
      detail["time_zone"].should eq "America/Los_Angeles"
      # scheduled_on is derived in local time from the start instant.
      expected = AssistAnt::Commands::CalendarItem.scheduled_on("2026-06-06T18:00:00Z")
      detail["scheduled_on"].should eq expected
    end
  end

  it "prune publishes a calendar_item.prune envelope with from/to and the keep set" do
    with_socket_server do |sock_path, channel|
      result = run_binary(
        [binary, "calendar-item", "prune",
         "--source", "gcal", "--from", "2026-06-06", "--to", "2026-06-13",
         "--keep", "evt-1", "--keep", "evt-2"],
        env: {"ASSIST_ANT_SOCKET" => sock_path},
      )
      result[:status].success?.should be_true

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "calendar_item.prune"
      detail = parsed["detail_data"]
      detail["source"].should eq "gcal"
      detail["from"].should eq "2026-06-06"
      detail["to"].should eq "2026-06-13"
      detail["keep"].as_a.map(&.as_s).should eq ["evt-1", "evt-2"]
      detail["allow_empty"].should be_false
    end
  end

  describe "validation" do
    it "exits non-zero when a required flag is missing" do
      result = run_binary(
        [binary, "calendar-item", "upsert",
         "--external-id", "e1", "--title", "T",
         "--start", "2026-06-06T18:00:00Z"], # no --source
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "--source"
    end

    it "exits non-zero on an unknown subcommand" do
      result = run_binary([binary, "calendar-item", "bogus"])
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown calendar-item subcommand"
    end

    it "prune refuses an empty keep set without --allow-empty" do
      result = run_binary(
        [binary, "calendar-item", "prune",
         "--source", "gcal", "--from", "2026-06-06", "--to", "2026-06-13"],
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "empty --keep"
    end

    it "prune permits an empty keep set with --allow-empty" do
      with_socket_server do |sock_path, channel|
        result = run_binary(
          [binary, "calendar-item", "prune",
           "--source", "gcal", "--from", "2026-06-06", "--to", "2026-06-13",
           "--allow-empty"],
          env: {"ASSIST_ANT_SOCKET" => sock_path},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "calendar_item.prune"
        detail = parsed["detail_data"]
        detail["allow_empty"].should be_true
        detail["keep"].as_a.empty?.should be_true
      end
    end
  end
end
