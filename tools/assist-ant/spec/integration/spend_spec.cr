require "../spec_helper"

# `assist-ant spend set` is request/reply: it reads each --variant file, sends a
# `spend.set` envelope (primary/secondary + a variants array of {label, body}),
# and relays the app's ack. Uses the replying server from task_spec. Shells out
# to the built binary — skips if unbuilt (run `make dev` first).
describe "assist-ant spend set" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends a spend.set envelope with pill strings and variant cards" do
    with_task_reply_server(%({"ok":true})) do |sock, channel|
      mtd = File.tempfile("aa-mtd", ".txt")
      mtd.print("📊 Month to Date\nTotal $2678.82\n")
      mtd.close
      ytd = File.tempfile("aa-ytd", ".txt")
      ytd.print("📊 Year to Date\nTotal $13797.77\n")
      ytd.close
      begin
        result = run_binary(
          [binary, "spend", "set",
           "--primary", "$392 today", "--secondary", "$2.7k mo",
           "--variant", "Month to Date=#{mtd.path}",
           "--variant", "Year to Date=#{ytd.path}"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        result[:stdout].should contain "2 variant"

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "spend.set"
        detail = parsed["detail_data"]
        detail["primary"].should eq "$392 today"
        detail["secondary"].should eq "$2.7k mo"
        detail["variants"].as_a.size.should eq 2
        detail["variants"][0]["label"].should eq "Month to Date"
        detail["variants"][0]["body"].as_s.should contain "2678.82"
      ensure
        File.delete(mtd.path) if File.exists?(mtd.path)
        File.delete(ytd.path) if File.exists?(ytd.path)
      end
    end
  end

  it "rejects an empty payload before sending" do
    result = run_binary([binary, "spend", "set"])
    result[:status].success?.should be_false
    result[:stderr].should contain "nothing to set"
  end

  it "errors on a missing --variant file" do
    result = run_binary(
      [binary, "spend", "set", "--variant", "X=/no/such/file.txt"])
    result[:status].success?.should be_false
    result[:stderr].should contain "not found"
  end

  it "rejects a malformed --variant (no LABEL=PATH)" do
    result = run_binary(
      [binary, "spend", "set", "--variant", "justlabel"])
    result[:status].success?.should be_false
    result[:stderr].should contain "LABEL=PATH"
  end

  it "exits non-zero when the app refused the write" do
    with_task_reply_server(%({"ok":false,"error":"empty spend payload"})) do |sock, _|
      result = run_binary(
        [binary, "spend", "set", "--primary", "x"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "empty spend payload"
    end
  end

  it "exits non-zero when the app is not running (no reply)" do
    missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
    result = run_binary(
      [binary, "spend", "set", "--primary", "x"],
      env: {"ASSIST_ANT_SOCKET" => missing},
    )
    result[:status].success?.should be_false
    result[:stderr].should contain "is the app running?"
  end
end
