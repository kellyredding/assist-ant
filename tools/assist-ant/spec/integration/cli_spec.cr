require "../spec_helper"

# End-to-end CLI tests: shell out to the built binary, capture
# stdout/stderr/exit status, verify the contract.
#
# Skips automatically if the binary hasn't been built yet (so
# `crystal spec` works in a fresh checkout). Run `make dev` first
# to build it.
describe "assist-ant binary" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  describe "--version" do
    it "prints the version and exits 0" do
      result = run_binary([binary, "--version"])
      result[:status].success?.should be_true
      result[:stdout].should contain AssistAnt::CLI::VERSION
    end
  end

  describe "--help" do
    it "prints usage and exits 0" do
      result = run_binary([binary, "--help"])
      result[:status].success?.should be_true
      result[:stdout].should contain "Usage:"
      result[:stdout].should contain "ping"
    end
  end

  describe "no args" do
    it "prints usage and exits 0" do
      result = run_binary([binary])
      result[:status].success?.should be_true
      result[:stdout].should contain "Usage:"
    end
  end

  describe "unknown command" do
    it "prints an error to stderr and exits non-zero" do
      result = run_binary([binary, "bogus-command"])
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown command"
    end
  end

  describe "unknown flag" do
    it "prints an error to stderr and exits non-zero" do
      result = run_binary([binary, "--no-such-flag"])
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown flag"
    end
  end

  describe "ping with no app running" do
    it "exits 0 silently when the socket does not exist" do
      with_sandbox do |sandbox|
        result = run_binary(
          [binary, "ping"],
          env: {"ASSIST_ANT_ROOT" => sandbox.to_s},
        )
        result[:status].success?.should be_true
        result[:stdout].strip.should eq ""
        result[:stderr].strip.should eq ""
      end
    end

    it "exits 0 silently when given a message argument" do
      with_sandbox do |sandbox|
        result = run_binary(
          [binary, "ping", "hello-from-spec"],
          env: {"ASSIST_ANT_ROOT" => sandbox.to_s},
        )
        result[:status].success?.should be_true
      end
    end

    it "does not create the data dir or runtime dir" do
      # The CLI is a pure sender. The app owns directory creation.
      with_sandbox do |sandbox|
        run_binary(
          [binary, "ping"],
          env: {"ASSIST_ANT_ROOT" => sandbox.to_s},
        )
        Dir.exists?((sandbox / "data").to_s).should be_false
        Dir.exists?((sandbox / "runtime").to_s).should be_false
      end
    end
  end

  describe "ping with a listening socket" do
    it "delivers the envelope to a server listening at the configured path" do
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
            [binary, "ping", "from-integration"],
            env: {"ASSIST_ANT_ROOT" => sandbox.to_s},
          )
          result[:status].success?.should be_true

          line = channel.receive
          parsed = JSON.parse(line)
          parsed["v"].should eq 1
          parsed["event"].should eq "ping"
          parsed["detail_data"]["message"].should eq "from-integration"
        ensure
          server.close
          File.delete(sock_path) if File.exists?(sock_path)
        end
      end
    end
  end
end

# Run a binary, capture stdout, stderr, and exit status.
#
# Uses temp files instead of `output: IO::Memory.new` because
# Process.run only redirects to file descriptors — passing an
# IO::Memory directly returns an empty buffer.
#
# Always unsets ASSIST_ANT_SKIP_CLI in the child env. The spec
# helper sets it in the parent process to prevent
# `require "assist_ant"` from invoking CLI.run on load — if the
# subprocess inherits it, the binary short-circuits before
# parsing args and looks like a silent no-op.
def run_binary(
  cmd : Array(String),
  env : Hash(String, String) = {} of String => String,
) : NamedTuple(stdout: String, stderr: String, status: Process::Status)
  child_env = Hash(String, String?).new
  env.each { |k, v| child_env[k] = v }
  child_env["ASSIST_ANT_SKIP_CLI"] = nil

  stdout_path = File.tempname("aa-spec-stdout-", ".log")
  stderr_path = File.tempname("aa-spec-stderr-", ".log")
  stdout_file = File.open(stdout_path, "w+")
  stderr_file = File.open(stderr_path, "w+")
  begin
    status = Process.run(
      cmd[0],
      cmd[1..],
      env: child_env,
      output: stdout_file,
      error: stderr_file,
    )
    stdout_file.flush
    stderr_file.flush
    stdout_file.rewind
    stderr_file.rewind
    {
      stdout: stdout_file.gets_to_end,
      stderr: stderr_file.gets_to_end,
      status: status,
    }
  ensure
    stdout_file.close
    stderr_file.close
    File.delete(stdout_path) if File.exists?(stdout_path)
    File.delete(stderr_path) if File.exists?(stderr_path)
  end
end
