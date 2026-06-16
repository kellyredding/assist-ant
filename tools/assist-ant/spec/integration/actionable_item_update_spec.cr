require "../spec_helper"

# Integration coverage for `actionable-item update|remove|list`: each is
# request/reply, so a one-shot replying socket (`with_task_reply_server`, defined
# in task_spec) asserts the envelope the CLI sent (event + detail_data) and the
# CLI's handling of the ack. Local validation errors exit non-zero without a
# server. Shells out to the built binary — skips when it isn't built.

describe "assist-ant actionable-item update" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends an actionable_item.update envelope with the id and present fields" do
    with_task_reply_server(%({"ok":true,"id":"itm-1","name":"Renamed"})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "update", "itm-1",
         "--title", "Renamed", "--list", "Errands",
         "--scheduled-on", "2026-06-20", "--url", "https://example.com/x"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      result[:stdout].should contain "itm-1"

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "actionable_item.update"
      detail = parsed["detail_data"]
      detail["id"].should eq "itm-1"
      detail["title"].should eq "Renamed"
      detail["list_name"].should eq "Errands"
      detail["scheduled_on"].should eq "2026-06-20"
      detail["external_url"].should eq "https://example.com/x"
      # Untouched clears/toggles are not sent.
      detail["unschedule"]?.should be_nil
      detail["trash"]?.should be_nil
    end
  end

  it "sends the clear flags as booleans" do
    with_task_reply_server(%({"ok":true,"id":"itm-1","name":"x"})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "update", "itm-1",
         "--unschedule", "--clear-list", "--clear-url"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      detail = JSON.parse(channel.receive)["detail_data"]
      detail["unschedule"].should eq true
      detail["clear_list"].should eq true
      detail["clear_url"].should eq true
    end
  end

  it "sends the icebox and trash toggles as booleans" do
    with_task_reply_server(%({"ok":true,"id":"itm-1","name":"x"})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "update", "itm-1", "--no-icebox", "--trash"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      detail = JSON.parse(channel.receive)["detail_data"]
      detail["icebox"].should eq false
      detail["trash"].should eq true
    end
  end

  it "reads the body from --body-file" do
    with_task_reply_server(%({"ok":true,"id":"itm-1","name":"x"})) do |sock, channel|
      body = File.tempfile("aa-upd-body", ".md")
      body.print("updated body\n")
      body.close
      begin
        result = run_binary(
          [binary, "actionable-item", "update", "itm-1", "--body-file", body.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        JSON.parse(channel.receive)["detail_data"]["body"].as_s.should contain "updated body"
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  it "requires an id" do
    result = run_binary([binary, "actionable-item", "update"])
    result[:status].success?.should be_false
  end

  it "requires at least one field to change" do
    result = run_binary([binary, "actionable-item", "update", "itm-1"])
    result[:status].success?.should be_false
  end

  it "rejects a bad --scheduled-on before sending" do
    result = run_binary(
      [binary, "actionable-item", "update", "itm-1", "--scheduled-on", "june"])
    result[:status].success?.should be_false
    result[:stderr].should contain "scheduled-on"
  end

  it "rejects mutually-exclusive --scheduled-on and --unschedule" do
    result = run_binary(
      [binary, "actionable-item", "update", "itm-1",
       "--scheduled-on", "2026-06-20", "--unschedule"])
    result[:status].success?.should be_false
    result[:stderr].should contain "mutually exclusive"
  end

  it "exits non-zero when the app refused the write" do
    with_task_reply_server(%({"ok":false,"error":"only manual items can be edited"})) do |sock, _|
      result = run_binary(
        [binary, "actionable-item", "update", "itm-1", "--title", "x"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "only manual items"
    end
  end
end

describe "assist-ant actionable-item remove" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends an actionable_item.delete envelope with the id" do
    with_task_reply_server(%({"ok":true,"id":"itm-1","name":"gone"})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "remove", "itm-1"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "actionable_item.delete"
      parsed["detail_data"]["id"].should eq "itm-1"
    end
  end

  it "requires an id" do
    result = run_binary([binary, "actionable-item", "remove"])
    result[:status].success?.should be_false
  end
end

describe "assist-ant actionable-item list" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends an actionable_item.list request defaulting to state=active" do
    with_task_reply_server(%({"items":[{"id":"itm-1","title":"a"}]})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "list"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      result[:stdout].should contain "itm-1"

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "actionable_item.list"
      parsed["detail_data"]["state"].should eq "active"
    end
  end

  it "passes --state trashed through" do
    with_task_reply_server(%({"items":[]})) do |sock, channel|
      result = run_binary(
        [binary, "actionable-item", "list", "--state", "trashed"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      JSON.parse(channel.receive)["detail_data"]["state"].should eq "trashed"
    end
  end

  it "rejects an unknown --state value" do
    result = run_binary(
      [binary, "actionable-item", "list", "--state", "bogus"])
    result[:status].success?.should be_false
    result[:stderr].should contain "--state"
  end

  it "prints help and exits 0 for --help (no socket needed)" do
    result = run_binary([binary, "actionable-item", "list", "--help"])
    result[:status].success?.should be_true
    result[:stdout].should contain "USAGE:"
  end
end
