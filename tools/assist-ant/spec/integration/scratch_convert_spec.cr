require "../spec_helper"

# Integration coverage for `scratch convert`. Request/reply, so each happy path
# stands up a one-shot replying socket (`with_task_reply_server`, defined in
# task_spec), asserts the `scratch.convert` envelope the CLI sent, and checks the
# CLI relays the app's ack. Local validation exits non-zero before any request.
#
# Two contracts get their own tests because they are the ones that would regress
# silently: the body arrives as file CONTENTS (backticks intact, path absent),
# and `--body TEXT` does not exist — a Markdown body must never cross a shell
# argument, where a backtick is command substitution.
#
# The store's refusals are relayed verbatim rather than flattened into one
# message: the agent chose the id, so it has to learn which of the three
# refusals it hit to pick a next move. Shells out to the built binary, so it
# skips when the binary isn't built.
describe "assist-ant scratch convert" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends a scratch.convert envelope and prints the acked title" do
    with_task_reply_server(%({"ok":true,"id":"scr-1","name":"Fix the retro doc"})) do |sock, channel|
      body = File.tempfile("aa-convert-body", ".md")
      body.print("## Notes\n\n- point one\n")
      body.close
      begin
        result = run_binary(
          [binary, "scratch", "convert",
           "--id", "scr-1", "--kind", "todo",
           "--title", "Fix the retro doc", "--body-file", body.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true
        result[:stdout].should contain "scr-1"
        result[:stdout].should contain "Fix the retro doc"

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "scratch.convert"
        detail = parsed["detail_data"]
        detail["id"].should eq "scr-1"
        detail["kind"].should eq "todo"
        detail["title"].should eq "Fix the retro doc"
        detail["body"].as_s.should contain "point one"
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  it "sends the body file's CONTENTS (never its path), backticks intact" do
    with_task_reply_server(%({"ok":true,"id":"scr-2","name":"Wire up the retry"})) do |sock, channel|
      body = File.tempfile("aa-convert-body", ".md")
      body.print("## Plan\n\n- run `make check` first\n- then `$PATH` survives\n")
      body.close
      begin
        result = run_binary(
          [binary, "scratch", "convert",
           "--id", "scr-2", "--kind", "explore",
           "--title", "Wire up the retry", "--body-file", body.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        text = JSON.parse(channel.receive)["detail_data"]["body"].as_s
        text.should contain "## Plan"
        text.should contain "run `make check` first" # backticks survive intact
        text.should contain "`$PATH`"                # no shell expansion
        text.should contain "\n"                     # multi-line survives
        text.should_not contain body.path
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  it "includes --url in the envelope when it is given" do
    with_task_reply_server(%({"ok":true,"id":"scr-3","name":"Read the RFC"})) do |sock, channel|
      body = File.tempfile("aa-convert-body", ".md")
      body.print("the note\n")
      body.close
      begin
        result = run_binary(
          [binary, "scratch", "convert",
           "--id", "scr-3", "--kind", "explore", "--title", "Read the RFC",
           "--body-file", body.path, "--url", "https://example.com/rfc"],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        JSON.parse(channel.receive)["detail_data"]["url"].should eq "https://example.com/rfc"
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  it "omits url from the envelope when --url is not given" do
    with_task_reply_server(%({"ok":true,"id":"scr-4","name":"No link"})) do |sock, channel|
      body = File.tempfile("aa-convert-body", ".md")
      body.print("the note\n")
      body.close
      begin
        result = run_binary(
          [binary, "scratch", "convert",
           "--id", "scr-4", "--kind", "todo", "--title", "No link",
           "--body-file", body.path],
          env: {"ASSIST_ANT_SOCKET" => sock},
        )
        result[:status].success?.should be_true

        # Absent, not empty: the store only sets a url when one is present, so
        # an empty string would be a different (and wrong) instruction.
        JSON.parse(channel.receive)["detail_data"]["url"]?.should be_nil
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  describe "validation (before any request)" do
    it "rejects an invalid --kind" do
      body = File.tempfile("aa-convert-body", ".md")
      body.print("the note\n")
      body.close
      begin
        result = run_binary(
          [binary, "scratch", "convert",
           "--id", "scr-1", "--kind", "scratch", "--title", "x",
           "--body-file", body.path])
        result[:status].success?.should be_false
        result[:stderr].should contain "--kind"
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end

    it "requires --id" do
      result = run_binary(
        [binary, "scratch", "convert",
         "--kind", "todo", "--title", "x", "--body-file", "/tmp/aa-nope.md"])
      result[:status].success?.should be_false
      result[:stderr].should contain "--id is required"
    end

    it "requires --kind" do
      result = run_binary(
        [binary, "scratch", "convert",
         "--id", "scr-1", "--title", "x", "--body-file", "/tmp/aa-nope.md"])
      result[:status].success?.should be_false
      result[:stderr].should contain "--kind is required"
    end

    it "requires --title" do
      result = run_binary(
        [binary, "scratch", "convert",
         "--id", "scr-1", "--kind", "todo", "--body-file", "/tmp/aa-nope.md"])
      result[:status].success?.should be_false
      result[:stderr].should contain "--title is required"
    end

    it "requires --body-file" do
      result = run_binary(
        [binary, "scratch", "convert",
         "--id", "scr-1", "--kind", "todo", "--title", "x"])
      result[:status].success?.should be_false
      result[:stderr].should contain "--body-file is required"
    end

    # The guard against Markdown-through-shell regressing: a `--body TEXT` flag
    # would put backticks in a shell argument, where they are command
    # substitution. It must stay unknown.
    it "rejects --body as an unknown flag" do
      result = run_binary(
        [binary, "scratch", "convert",
         "--id", "scr-1", "--kind", "todo", "--title", "x",
         "--body", "## Notes"])
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown flag"
    end

    it "rejects a --body-file that does not exist" do
      missing = File.join(Dir.tempdir, "aa-missing-#{Random.rand(1_000_000)}.md")
      result = run_binary(
        [binary, "scratch", "convert",
         "--id", "scr-1", "--kind", "todo", "--title", "x",
         "--body-file", missing])
      result[:status].success?.should be_false
      result[:stderr].should contain "not found"
    end

    it "rejects an empty --body-file" do
      body = File.tempfile("aa-convert-empty", ".md")
      body.close
      begin
        result = run_binary(
          [binary, "scratch", "convert",
           "--id", "scr-1", "--kind", "todo", "--title", "x",
           "--body-file", body.path])
        result[:status].success?.should be_false
        result[:stderr].should contain "empty"
      ensure
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  # Each store guard comes back as its own string, so the agent learns whether
  # it picked something already actionable, something trashed, or nothing at all.
  describe "relaying the app's refusals" do
    {
      "only a scratch note can be converted",
      "note is in the Trash — put it back first",
      "no item with id scr-9",
    }.each do |refusal|
      it "exits non-zero and relays #{refusal.inspect}" do
        with_task_reply_server(%({"ok":false,"error":#{refusal.to_json}})) do |sock, _|
          body = File.tempfile("aa-convert-body", ".md")
          body.print("the note\n")
          body.close
          begin
            result = run_binary(
              [binary, "scratch", "convert",
               "--id", "scr-9", "--kind", "todo", "--title", "x",
               "--body-file", body.path],
              env: {"ASSIST_ANT_SOCKET" => sock},
            )
            result[:status].success?.should be_false
            result[:stderr].should contain refusal
          ensure
            File.delete(body.path) if File.exists?(body.path)
          end
        end
      end
    end
  end

  it "exits non-zero when the app is not running (no reply)" do
    missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
    body = File.tempfile("aa-convert-body", ".md")
    body.print("the note\n")
    body.close
    begin
      result = run_binary(
        [binary, "scratch", "convert",
         "--id", "scr-1", "--kind", "todo", "--title", "x",
         "--body-file", body.path],
        env: {"ASSIST_ANT_SOCKET" => missing},
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "is the app running?"
    ensure
      File.delete(body.path) if File.exists?(body.path)
    end
  end

  it "prints help and exits 0 for --help (no socket needed)" do
    result = run_binary([binary, "scratch", "convert", "--help"])
    result[:status].success?.should be_true
    result[:stdout].should contain "USAGE:"
    result[:stdout].should contain "--body-file"
  end

  it "rejects an unknown subcommand with a non-zero exit" do
    result = run_binary([binary, "scratch", "bogus"])
    result[:status].success?.should be_false
    result[:stderr].should contain "unknown scratch subcommand"
    result[:stderr].should contain "scratch --help"
  end
end
