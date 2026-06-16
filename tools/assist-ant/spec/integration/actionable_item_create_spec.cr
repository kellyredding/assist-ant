require "../spec_helper"

# Integration coverage for `actionable-item create`. It is now REQUEST/REPLY (so
# it can print the new item's id), so each happy-path test stands up a one-shot
# replying socket (`with_task_reply_server`, defined in task_spec), asserts the
# `actionable_item.create` envelope the CLI sent, and checks the CLI relays the
# app's ack. Local validation errors exit non-zero before any request, and an
# absent app (no reply) / refused write also exit non-zero. Shells out to the
# built binary, so it skips when the binary isn't built (run `make dev` first).
describe "assist-ant actionable-item create" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends an actionable_item.create envelope and prints the acked id" do
    with_task_reply_server(%({"ok":true,"id":"itm-1","name":"Read the RFC"})) do |sock, channel|
      body = File.tempfile("aa-cap-body", ".md")
      body.print("## Summary\n\n- point one\n")
      body.close

      begin
        result = run_binary(
          [binary, "actionable-item", "create",
           "--kind", "explore", "--title", "Read the RFC",
           "--scheduled-on", "2026-06-20", "--url", "https://example.com/rfc",
           "--body-file", body.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        result[:stdout].should contain "itm-1"

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "actionable_item.create"
        detail = parsed["detail_data"]
        detail["kind"].should eq "explore"
        detail["title"].should eq "Read the RFC"
        detail["scheduled_on"].should eq "2026-06-20"
        detail["external_url"].should eq "https://example.com/rfc"
        detail["body"].as_s.should contain "point one"
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  it "passes --icebox through as a boolean detail flag" do
    with_task_reply_server(%({"ok":true,"id":"itm-2","name":"Later task"})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "create",
         "--kind", "todo", "--title", "Later task", "--icebox"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      parsed = JSON.parse(channel.receive)
      parsed["detail_data"]["icebox"].should eq true
    end
  end

  it "passes --list through as the list_name detail field" do
    with_task_reply_server(%({"ok":true,"id":"itm-3","name":"Buy milk"})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "create",
         "--kind", "todo", "--title", "Buy milk", "--list", "Errands"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "actionable_item.create"
      parsed["detail_data"]["list_name"].should eq "Errands"
    end
  end

  it "rejects an invalid --kind with a non-zero exit (before any request)" do
    result = run_binary(
      [binary, "actionable-item", "create", "--kind", "calendar", "--title", "x"])
    result[:status].success?.should be_false
    result[:stderr].should contain "--kind"
  end

  it "requires --title" do
    result = run_binary(
      [binary, "actionable-item", "create", "--kind", "todo"])
    result[:status].success?.should be_false
  end

  it "exits non-zero when the app refused the write" do
    with_task_reply_server(%({"ok":false,"error":"invalid kind/title"})) do |sock, _|
      result = run_binary(
        [binary, "actionable-item", "create", "--kind", "todo", "--title", "x"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "invalid kind/title"
    end
  end

  it "exits non-zero when the app is not running (no reply)" do
    missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
    result = run_binary(
      [binary, "actionable-item", "create", "--kind", "todo", "--title", "x"],
      env: {"ASSIST_ANT_SOCKET" => missing},
    )
    result[:status].success?.should be_false
    result[:stderr].should contain "is the app running?"
  end
end
