require "../spec_helper"

# Integration tests for the socket-write path. Spins up a real
# UNIXServer, points the publisher at it, verifies bytes-on-wire
# match the envelope shape.
describe AssistAnt::EventPublisher do
  describe ".send_to_socket" do
    it "writes the envelope line and receives the FIN-wait byte" do
      with_socket_server do |sock_path, received_channel|
        result = AssistAnt::EventPublisher
          .send_to_socket("hello-line", sock_path)
        result.should be_true
        received_channel.receive.should eq "hello-line"
      end
    end

    it "returns false when the socket does not exist" do
      missing = File.join(Dir.tempdir, "aa-missing-#{Random.rand(99999)}.sock")
      AssistAnt::EventPublisher
        .send_to_socket("ignored", missing)
        .should be_false
    end
  end

  describe ".publish" do
    it "writes a valid envelope JSON line to the socket" do
      with_socket_server do |sock_path, received_channel|
        with_env("ASSIST_ANT_SOCKET", sock_path) do
          AssistAnt::EventPublisher.publish(
            event: "ping",
            detail_data: {"message" => JSON::Any.new("hi")},
          ).should be_true
        end

        line = received_channel.receive
        parsed = JSON.parse(line)
        parsed["v"].should eq 1
        parsed["event"].should eq "ping"
        parsed["ts"].as_i64.should be > 0
        parsed["detail_data"]["message"].should eq "hi"
      end
    end

    it "returns false silently when no app is listening" do
      with_env("ASSIST_ANT_SOCKET", "/tmp/aa-nope-#{Random.rand(99999)}.sock") do
        AssistAnt::EventPublisher.publish(event: "ping").should be_false
      end
    end
  end
end

# Spawn a one-shot UNIXServer that accepts a single connection,
# reads one line, then closes. The first line received is sent to
# the channel the block yields. Cleans up the socket file on exit.
def with_socket_server(&)
  sock_path = File.join(
    Dir.tempdir,
    "aa-integration-#{Random.rand(1_000_000)}.sock",
  )
  File.delete(sock_path) if File.exists?(sock_path)
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
    yield sock_path, channel
  ensure
    server.close
    File.delete(sock_path) if File.exists?(sock_path)
  end
end
