module AssistAnt
  # Publishes lightweight event envelopes over a Unix domain socket
  # to AssistAntApp. Fire-and-forget; all socket errors are
  # silently rescued. The CLI works identically whether the app is
  # running or not.
  #
  # Wire format is newline-delimited JSON:
  #   {"v":1,"event":"ping","ts":1716825600,"detail_data":{...}}
  #
  # Event names are free-form strings (not an enum) so new events
  # ship without recompiling the app side. Unknown events are
  # dropped silently by the app's EventCoordinator.
  module EventPublisher
    extend self

    ENVELOPE_VERSION = 1
    WRITE_TIMEOUT    = 100.milliseconds

    # Build a JSON envelope string for the given event. Returns the
    # JSON line without trailing newline.
    def build_envelope(
      event : String,
      detail_data : Hash(String, JSON::Any)? = nil,
      ref : String? = nil,
    ) : String
      io = IO::Memory.new
      builder = JSON::Builder.new(io)
      builder.document do
        builder.object do
          builder.field("v", ENVELOPE_VERSION)
          builder.field("event", event)
          builder.field("ts", Time.utc.to_unix)
          if r = ref
            builder.field("ref", r)
          end
          if d = detail_data
            builder.field("detail_data") do
              builder.object do
                d.each do |k, v|
                  builder.field(k) { v.to_json(builder) }
                end
              end
            end
          end
        end
      end
      io.to_s
    end

    # Publish an event to AssistAntApp. Returns true on success,
    # false on any failure. Callers MUST NOT branch on the return
    # value — it is informational only. Per protocol, the CLI is
    # silent regardless of whether the app is running.
    def publish(
      event : String,
      detail_data : Hash(String, JSON::Any)? = nil,
      ref : String? = nil,
    ) : Bool
      envelope = build_envelope(event, detail_data, ref)
      send_to_socket(envelope)
    rescue
      false
    end

    # Low-level socket write. Connects, writes the JSON line, reads
    # one byte to wait for the server's close (FIN/RST race
    # avoidance — see galaxy_ledger/event_publisher.cr lines 93–100
    # in ~/projects/kellyredding/galaxy/), then closes. Separated
    # from publish for testability.
    def send_to_socket(
      envelope : String,
      socket_path : String = Paths.socket_path.to_s,
    ) : Bool
      socket = UNIXSocket.new(socket_path)
      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.puts(envelope)
        socket.read_timeout = WRITE_TIMEOUT
        buf = Bytes.new(1)
        socket.read(buf) rescue nil
        true
      ensure
        socket.close
      end
    rescue
      false
    end
  end
end
