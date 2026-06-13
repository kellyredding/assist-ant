require "../spec_helper"

# Integration coverage for `actionable-item create`: one manual item is
# published as an `actionable_item.create` envelope carrying the fields inline;
# invalid input exits non-zero before publishing. Shells out to the built
# binary, so it skips when the binary isn't built (run `make dev` first).
describe "assist-ant actionable-item create" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "publishes an actionable_item.create envelope with the inline fields" do
    with_sandbox do |sandbox|
      runtime = sandbox / "runtime"
      Dir.mkdir_p(runtime.to_s)
      sock_path = (runtime / "assist-ant.sock").to_s
      server = UNIXServer.new(sock_path)
      channel = Channel(String).new(1)

      spawn do
        conn = server.accept
        line = conn.gets || ""
        channel.send(line)
        conn.close
      rescue ex
        channel.send("ERROR: #{ex.message}")
      end

      body = File.tempfile("aa-cap-body", ".md")
      body.print("## Summary\n\n- point one\n")
      body.close

      begin
        result = run_binary(
          [binary, "actionable-item", "create",
           "--kind", "explore", "--title", "Read the RFC",
           "--scheduled-on", "2026-06-20", "--url", "https://example.com/rfc",
           "--body-file", body.path],
          env: {"ASSIST_ANT_ROOT" => sandbox.to_s},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "actionable_item.create"
        detail = parsed["detail_data"]
        detail["kind"].should eq "explore"
        detail["title"].should eq "Read the RFC"
        detail["scheduled_on"].should eq "2026-06-20"
        detail["external_url"].should eq "https://example.com/rfc"
        detail["body"].as_s.should contain "point one"
      ensure
        server.close
        File.delete(sock_path) if File.exists?(sock_path)
        File.delete(body.path) if File.exists?(body.path)
      end
    end
  end

  it "passes --icebox through as a boolean detail flag" do
    with_sandbox do |sandbox|
      runtime = sandbox / "runtime"
      Dir.mkdir_p(runtime.to_s)
      sock_path = (runtime / "assist-ant.sock").to_s
      server = UNIXServer.new(sock_path)
      channel = Channel(String).new(1)

      spawn do
        conn = server.accept
        line = conn.gets || ""
        channel.send(line)
        conn.close
      rescue ex
        channel.send("ERROR: #{ex.message}")
      end

      begin
        result = run_binary(
          [binary, "actionable-item", "create",
           "--kind", "todo", "--title", "Later task", "--icebox"],
          env: {"ASSIST_ANT_ROOT" => sandbox.to_s},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["detail_data"]["icebox"].should eq true
      ensure
        server.close
        File.delete(sock_path) if File.exists?(sock_path)
      end
    end
  end

  it "rejects an invalid --kind with a non-zero exit" do
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

  it "passes --list through as the list_name detail field" do
    with_socket_server do |sock_path, channel|
      result = run_binary(
        [binary, "actionable-item", "create",
         "--kind", "todo", "--title", "Buy milk", "--list", "Errands"],
        env: {"ASSIST_ANT_SOCKET" => sock_path},
      )
      result[:status].success?.should be_true

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "actionable_item.create"
      parsed["detail_data"]["list_name"].should eq "Errands"
    end
  end
end
