require "../spec_helper"

# Integration coverage for `scratch add`. Request/reply, so each happy path
# stands up a one-shot replying socket (`with_task_reply_server`, defined in
# task_spec), asserts the `scratch.add` envelope the CLI sent, and checks the
# CLI relays the app's ack. Local validation exits non-zero before any request.
# Shells out to the built binary, so it skips when the binary isn't built.
describe "assist-ant scratch add" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends a scratch.add envelope for --text and prints the acked id" do
    with_task_reply_server(%({"ok":true,"id":"scr-1"})) do |sock, channel|
      result = run_binary(
        [binary, "scratch", "add", "--text", "ask about the retro doc"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      result[:stdout].should contain "scr-1"

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "scratch.add"
      parsed["detail_data"]["text"].should eq "ask about the retro doc"
      # The app derives the title from the text; the CLI must not invent one.
      parsed["detail_data"]["title"]?.should be_nil
    end
  end

  it "sends the file's CONTENTS (never its path) for --text-file" do
    with_task_reply_server(%({"ok":true,"id":"scr-2"})) do |sock, channel|
      note = File.tempfile("aa-scratch-note", ".md")
      note.print("## Retro\n\n- run `make check` first\n")
      note.close
      begin
        result = run_binary(
          [binary, "scratch", "add", "--text-file", note.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        detail = JSON.parse(channel.receive)["detail_data"]
        text = detail["text"].as_s
        text.should contain "## Retro"
        text.should contain "run `make check` first" # backticks survive intact
        text.should contain "\n"                     # multi-line survives
        text.should_not contain note.path
      ensure
        File.delete(note.path) if File.exists?(note.path)
      end
    end
  end

  it "includes list in the envelope when --list is given" do
    with_task_reply_server(%({"ok":true,"id":"scr-3","list":"Reading","name":"read the RFC"})) do |sock, channel|
      result = run_binary(
        [binary, "scratch", "add", "--text", "read the RFC", "--list", "Reading"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true
      # Printed from the ack's list, not from the flag, so the summary reports
      # the grouping the app kept rather than the one this command asked for.
      result[:stdout].should contain "list Reading"

      detail = JSON.parse(channel.receive)["detail_data"]
      # `list`, not `list_name`: the scratch envelope names each field after the
      # flag that sets it, the same way convert's link is `url`.
      detail["list"].should eq "Reading"
      detail["text"].should eq "read the RFC"
    end
  end

  it "omits list from the envelope when --list is not given" do
    with_task_reply_server(%({"ok":true,"id":"scr-4","name":"ungrouped note"})) do |sock, channel|
      result = run_binary(
        [binary, "scratch", "add", "--text", "ungrouped note"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      # Absent, not empty: an absent key parks the note ungrouped, while an
      # empty string would name a list called "" — a different instruction, and
      # one the store would faithfully carry into the item on conversion.
      JSON.parse(channel.receive)["detail_data"]["list"]?.should be_nil
    end
  end

  it "treats an empty --list as no list at all" do
    with_task_reply_server(%({"ok":true,"id":"scr-5","name":"still ungrouped"})) do |sock, channel|
      result = run_binary(
        [binary, "scratch", "add", "--text", "still ungrouped", "--list", ""],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_true

      # The `unless l.empty?` guard is the only thing standing between an
      # operator passing nothing and a list named "" reaching the store.
      JSON.parse(channel.receive)["detail_data"]["list"]?.should be_nil
    end
  end

  it "rejects --text and --text-file together (before any request)" do
    note = File.tempfile("aa-scratch-note", ".md")
    note.print("from the file\n")
    note.close
    begin
      result = run_binary(
        [binary, "scratch", "add", "--text", "inline", "--text-file", note.path])
      result[:status].success?.should be_false
      result[:stderr].should contain "mutually exclusive"
    ensure
      File.delete(note.path) if File.exists?(note.path)
    end
  end

  it "requires one of --text / --text-file" do
    result = run_binary([binary, "scratch", "add"])
    result[:status].success?.should be_false
    result[:stderr].should contain "--text"
  end

  it "rejects a --text-file that does not exist" do
    missing = File.join(Dir.tempdir, "aa-missing-#{Random.rand(1_000_000)}.md")
    result = run_binary([binary, "scratch", "add", "--text-file", missing])
    result[:status].success?.should be_false
    result[:stderr].should contain "not found"
  end

  it "rejects an empty --text-file" do
    note = File.tempfile("aa-scratch-empty", ".md")
    note.close
    begin
      result = run_binary([binary, "scratch", "add", "--text-file", note.path])
      result[:status].success?.should be_false
      result[:stderr].should contain "empty"
    ensure
      File.delete(note.path) if File.exists?(note.path)
    end
  end

  it "exits non-zero when the app refused the write" do
    with_task_reply_server(%({"ok":false,"error":"no workspace"})) do |sock, _|
      result = run_binary(
        [binary, "scratch", "add", "--text", "x"],
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "no workspace"
    end
  end

  it "exits non-zero when the app is not running (no reply)" do
    missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
    result = run_binary(
      [binary, "scratch", "add", "--text", "x"],
      env: {"ASSIST_ANT_SOCKET" => missing},
    )
    result[:status].success?.should be_false
    result[:stderr].should contain "is the app running?"
  end

  it "prints help and exits 0 for --help (no socket needed)" do
    result = run_binary([binary, "scratch", "add", "--help"])
    result[:status].success?.should be_true
    result[:stdout].should contain "--text-file"
  end
end
