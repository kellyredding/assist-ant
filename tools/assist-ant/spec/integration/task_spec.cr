require "../spec_helper"

# Integration coverage for `assist-ant task`: every subcommand is request/reply,
# so each test stands up a one-shot replying Unix socket, asserts the envelope
# the CLI sent (event + detail_data), and checks the CLI's handling of the
# app's ack. Local validation errors and the app-not-running path exit non-zero
# without needing a server. Shells out to the built binary — skips when it
# isn't built (run `make dev` first).

# A one-shot replying server: accept one connection, hand the request line to
# `channel`, write `reply` back, close. Generalizes the manual server in
# actionable_item_list_names_spec to send a chosen reply line.
def with_task_reply_server(reply : String, &)
  sock_path = File.join(Dir.tempdir, "aa-task-#{Random.rand(1_000_000)}.sock")
  File.delete(sock_path) if File.exists?(sock_path)
  server = UNIXServer.new(sock_path)
  channel = Channel(String).new(1)
  spawn do
    conn = server.accept
    line = conn.gets || ""
    channel.send(line)
    conn.puts(reply)
    conn.close
  rescue ex
    channel.send("ERROR: #{ex.message}")
  end
  begin
    yield sock_path, channel
  ensure
    server.close
    File.delete(sock_path) if File.exists?(sock_path)
  end
end

describe "assist-ant task" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  describe "add" do
    it "sends a task.create envelope for a recurring interval task" do
      with_task_reply_server(%({"ok":true,"id":"t1","name":"Linear sync"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "add",
           "--name", "Linear sync", "--trigger", "recurring",
           "--cadence", "interval", "--interval-seconds", "900",
           "--prompt", "Sync my Linear issues"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        result[:stdout].should contain "Created task"
        result[:stdout].should contain "t1"

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "task.create"
        detail = parsed["detail_data"]
        detail["name"].should eq "Linear sync"
        detail["trigger_type"].should eq "recurring"
        detail["cadence_kind"].should eq "interval"
        detail["interval_seconds"].as_i.should eq 900
        detail["prompt"].should eq "Sync my Linear issues"
        detail["enabled"].should eq true
      end
    end

    it "sends a daily-time cadence for a recurring daily task" do
      with_task_reply_server(%({"ok":true,"id":"t2","name":"Brief"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "add",
           "--name", "Brief", "--trigger", "recurring",
           "--cadence", "daily", "--daily-time", "07:00",
           "--prompt", "Summarize today"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        detail = JSON.parse(channel.receive)["detail_data"]
        detail["cadence_kind"].should eq "daily"
        detail["daily_time"].should eq "07:00"
      end
    end

    it "sends weekdays + window for a windowed-interval task" do
      with_task_reply_server(%({"ok":true,"id":"t4","name":"Progress check"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "add",
           "--name", "Progress check", "--trigger", "recurring",
           "--cadence", "interval", "--interval-seconds", "3600",
           "--window-start", "08:55", "--window-end", "16:55",
           "--weekdays", "1,2,3,4,5", "--prompt", "Check my progress"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        detail = JSON.parse(channel.receive)["detail_data"]
        detail["cadence_kind"].should eq "interval"
        detail["interval_seconds"].as_i.should eq 3600
        detail["window_start"].should eq "08:55"
        detail["window_end"].should eq "16:55"
        detail["weekdays"].should eq "1,2,3,4,5"
      end
    end

    it "rejects a window on a daily cadence (interval only)" do
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "recurring",
         "--cadence", "daily", "--daily-time", "08:55",
         "--window-start", "08:55", "--window-end", "16:55", "--prompt", "p"])
      result[:status].success?.should be_false
      result[:stderr].should contain "interval"
    end

    it "rejects half a window (start without end)" do
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "recurring",
         "--cadence", "interval", "--interval-seconds", "3600",
         "--window-start", "08:55", "--prompt", "p"])
      result[:status].success?.should be_false
      result[:stderr].should contain "both"
    end

    it "rejects a window whose start is not before its end" do
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "recurring",
         "--cadence", "interval", "--interval-seconds", "3600",
         "--window-start", "16:55", "--window-end", "08:55", "--prompt", "p"])
      result[:status].success?.should be_false
      result[:stderr].should contain "earlier"
    end

    it "rejects an out-of-range weekday mask" do
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "recurring",
         "--cadence", "daily", "--daily-time", "08:55",
         "--weekdays", "1,8", "--prompt", "p"])
      result[:status].success?.should be_false
      result[:stderr].should contain "weekdays"
    end

    it "rejects --weekdays on a one_shot task" do
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "one_shot",
         "--weekdays", "1,2,3", "--prompt", "p"])
      result[:status].success?.should be_false
      result[:stderr].should contain "recurring"
    end

    it "carries --disabled through as enabled=false" do
      with_task_reply_server(%({"ok":true,"id":"t3","name":"Off"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "add",
           "--name", "Off", "--trigger", "manual", "--disabled",
           "--prompt", "do it"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        JSON.parse(channel.receive)["detail_data"]["enabled"].should eq false
      end
    end

    it "rejects a recurring task with no cadence (before sending)" do
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "recurring", "--prompt", "p"])
      result[:status].success?.should be_false
      result[:stderr].should contain "cadence"
    end

    it "requires a prompt" do
      result = run_binary(
        [binary, "task", "add", "--name", "x", "--trigger", "manual"])
      result[:status].success?.should be_false
      result[:stderr].should contain "prompt"
    end

    it "exits non-zero when the app refused the write" do
      with_task_reply_server(%({"ok":false,"error":"store write failed"})) do |sock, _|
        result = run_binary(
          [binary, "task", "add",
           "--name", "x", "--trigger", "manual", "--prompt", "p"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_false
        result[:stderr].should contain "store write failed"
      end
    end

    it "exits non-zero when the app is not running (no reply)" do
      missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
      result = run_binary(
        [binary, "task", "add",
         "--name", "x", "--trigger", "manual", "--prompt", "p"],
        env: {"ASSIST_ANT_SOCKET" => missing},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "is the app running?"
    end
  end

  describe "list" do
    it "sends a task.list request and prints the reply JSON" do
      with_task_reply_server(%({"tasks":[{"id":"t1","name":"Linear sync"}]})) do |sock, channel|
        result = run_binary(
          [binary, "task", "list"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        result[:stdout].should contain "Linear sync"

        JSON.parse(channel.receive)["event"].should eq "task.list"
      end
    end
  end

  describe "update" do
    it "sends a task.update envelope with the id and only the changed fields" do
      with_task_reply_server(%({"ok":true,"id":"t1","name":"Renamed"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "update", "t1",
           "--name", "Renamed", "--interval-seconds", "1800"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        detail = JSON.parse(channel.receive)["detail_data"]
        detail["id"].should eq "t1"
        detail["name"].should eq "Renamed"
        detail["interval_seconds"].as_i.should eq 1800
        detail["trigger_type"]?.should be_nil # untouched fields aren't sent
      end
    end

    it "requires an id" do
      result = run_binary([binary, "task", "update"])
      result[:status].success?.should be_false
    end

    it "requires at least one field to change" do
      result = run_binary([binary, "task", "update", "t1"])
      result[:status].success?.should be_false
    end
  end

  describe "remove" do
    it "sends a task.delete envelope with the id" do
      with_task_reply_server(%({"ok":true,"id":"t1"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "remove", "t1"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "task.delete"
        parsed["detail_data"]["id"].should eq "t1"
      end
    end
  end

  describe "enable / disable" do
    it "enable sends task.update with enabled=true" do
      with_task_reply_server(%({"ok":true,"id":"t1","name":"X"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "enable", "t1"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "task.update"
        parsed["detail_data"]["enabled"].should eq true
      end
    end

    it "disable sends task.update with enabled=false" do
      with_task_reply_server(%({"ok":true,"id":"t1","name":"X"})) do |sock, channel|
        result = run_binary(
          [binary, "task", "disable", "t1"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        JSON.parse(channel.receive)["detail_data"]["enabled"].should eq false
      end
    end
  end

  it "rejects an unknown subcommand with a non-zero exit" do
    result = run_binary([binary, "task", "bogus"])
    result[:status].success?.should be_false
    result[:stderr].should contain "unknown task subcommand"
  end

  it "prints help and exits 0 for add --help (no socket needed)" do
    result = run_binary([binary, "task", "add", "--help"])
    result[:status].success?.should be_true
    result[:stdout].should contain "USAGE:"
  end
end
