require "../spec_helper"

# Integration coverage for `actionable-item list-names`: a read command that
# sends an `actionable_item.list_names` request over the socket and prints the
# app's JSON reply for the agent to parse. Unlike the fire-and-forget senders,
# this needs a server that writes a reply line back, so it stands up its own
# replying socket rather than reusing `with_socket_server`.
# Skips automatically if the binary hasn't been built — run `make dev` first.
describe "assist-ant actionable-item list-names" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends a list_names request and prints the app's JSON reply" do
    sock_path = File.join(
      Dir.tempdir, "aa-listnames-#{Random.rand(1_000_000)}.sock")
    File.delete(sock_path) if File.exists?(sock_path)
    server = UNIXServer.new(sock_path)
    channel = Channel(String).new(1)

    spawn do
      conn = server.accept
      line = conn.gets || "" # the request envelope
      channel.send(line)
      conn.puts(%({"lists":["Errands","Reading"]})) # the reply line
      conn.close
    rescue ex
      channel.send("ERROR: #{ex.message}")
    end

    begin
      result = run_binary(
        [binary, "actionable-item", "list-names"],
        env: {"ASSIST_ANT_SOCKET" => sock_path},
      )
      result[:status].success?.should be_true
      result[:stdout].should contain "Errands"

      parsed = JSON.parse(channel.receive)
      parsed["event"].should eq "actionable_item.list_names"
    ensure
      server.close
      File.delete(sock_path) if File.exists?(sock_path)
    end
  end

  it "prints help and exits 0 for --help (no socket needed)" do
    result = run_binary([binary, "actionable-item", "list-names", "--help"])
    result[:status].success?.should be_true
    result[:stdout].should contain "USAGE:"
    result[:stdout].should contain "list-names"
  end
end
