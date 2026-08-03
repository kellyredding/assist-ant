require "../spec_helper"

# Integration coverage for `scratch list`. A read: it sends a `scratch.list`
# request over the socket (`with_task_reply_server`, defined in task_spec) and
# prints the app's JSON reply for the agent to parse — so the assertions are the
# envelope's `state` field and the reply reaching stdout untouched. An unknown
# `--state` is caught locally, before any request. Shells out to the built
# binary, so it skips when the binary isn't built.
describe "assist-ant scratch list" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends a scratch.list request defaulting to state=open" do
    reply = %({"items":[{"body":"ask about the retro doc","created_at":"2026-08-03T12:00:00Z","id":"scr-1","title":"ask about the retro doc"}]})
    with_task_reply_server(reply) do |sock, channel|
      result = run_binary(
        [binary, "scratch", "list"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      # Byte-for-byte, not re-serialized: the CLI parses nothing, so the agent
      # reads exactly the JSON the app composed.
      result[:stdout].should eq "#{reply}\n"

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "scratch.list"
      # Sent even though it's the default, so the envelope is self-describing.
      parsed["detail_data"]["state"].should eq "open"
    end
  end

  it "passes --state completed through" do
    with_task_reply_server(%({"items":[]})) do |sock, channel|
      result = run_binary(
        [binary, "scratch", "list", "--state", "completed"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      JSON.parse(channel.receive)["detail_data"]["state"].should eq "completed"
    end
  end

  it "rejects an unknown --state value (before any request)" do
    result = run_binary([binary, "scratch", "list", "--state", "bogus"])
    result[:status].success?.should be_false
    result[:stderr].should contain "--state"
  end

  it "exits non-zero when the app is not running (no reply)" do
    missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
    result = run_binary(
      [binary, "scratch", "list"],
      env: {"ASSIST_ANT_SOCKET" => missing},
    )
    result[:status].success?.should be_false
    result[:stderr].should contain "is the app running?"
  end

  it "prints help and exits 0 for --help (no socket needed)" do
    result = run_binary([binary, "scratch", "list", "--help"])
    result[:status].success?.should be_true
    result[:stdout].should contain "USAGE:"
    result[:stdout].should contain "--state"
  end
end
