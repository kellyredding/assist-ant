require "../spec_helper"

# `assist-ant priority set` is request/reply: it reads the --body file, sends a
# `priority.set` envelope ({ body }), and relays the app's ack. Uses the replying
# server from task_spec. Shells out to the built binary — skips if unbuilt (run
# `make dev` first).
describe "assist-ant priority set" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends a priority.set envelope with the body block" do
    with_task_reply_server(%({"ok":true})) do |sock, channel|
      block = File.tempfile("aa-priority", ".md")
      block.print("🎯 Priorities\n1. Finish the refactor\n2. Review ABC-123\n")
      block.close
      begin
        result = run_binary(
          [binary, "priority", "set", "--body", block.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        result[:stdout].should contain "Captured priority"

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "priority.set"
        detail = parsed["detail_data"]
        detail["body"].as_s.should contain "Finish the refactor"
        detail["body"].as_s.should contain "ABC-123"
      ensure
        File.delete(block.path) if File.exists?(block.path)
      end
    end
  end

  it "rejects an empty payload before sending" do
    result = run_binary([binary, "priority", "set"])
    result[:status].success?.should be_false
    result[:stderr].should contain "nothing to set"
  end

  it "errors on a missing --body file" do
    result = run_binary(
      [binary, "priority", "set", "--body", "/no/such/file.txt"])
    result[:status].success?.should be_false
    result[:stderr].should contain "not found"
  end

  it "errors on an empty --body file" do
    empty = File.tempfile("aa-empty", ".md")
    empty.close
    begin
      result = run_binary([binary, "priority", "set", "--body", empty.path])
      result[:status].success?.should be_false
      result[:stderr].should contain "empty"
    ensure
      File.delete(empty.path) if File.exists?(empty.path)
    end
  end

  it "exits non-zero when the app refused the write" do
    with_task_reply_server(%({"ok":false,"error":"empty priority payload"})) do |sock, _|
      block = File.tempfile("aa-priority", ".md")
      block.print("x")
      block.close
      begin
        result = run_binary(
          [binary, "priority", "set", "--body", block.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_false
        result[:stderr].should contain "empty priority payload"
      ensure
        File.delete(block.path) if File.exists?(block.path)
      end
    end
  end

  it "exits non-zero when the app is not running (no reply)" do
    missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
    block = File.tempfile("aa-priority", ".md")
    block.print("x")
    block.close
    begin
      result = run_binary(
        [binary, "priority", "set", "--body", block.path],
        env: {"ASSIST_ANT_SOCKET" => missing},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "is the app running?"
    ensure
      File.delete(block.path) if File.exists?(block.path)
    end
  end
end
