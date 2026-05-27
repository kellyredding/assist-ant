require "../spec_helper"

# Unit-level CLI behavior. Drives `AssistAnt::CLI.run` in-process
# for things that don't depend on stdout/stderr — output-driven
# behavior (--version banner, usage text, exit codes) lives in
# spec/integration/cli_spec.cr where we shell out to the binary.
describe AssistAnt::CLI do
  describe "VERSION" do
    it "is a non-empty string" do
      AssistAnt::CLI::VERSION.empty?.should be_false
    end
  end

  describe "#run with ping" do
    it "does not raise when the socket is missing" do
      with_sandbox do
        # No app running, no socket file. EventPublisher must
        # silently rescue.
        AssistAnt::CLI.new.run(["ping"])
      end
    end

    it "accepts an optional message argument" do
      with_sandbox do
        AssistAnt::CLI.new.run(["ping", "hello"])
      end
    end
  end
end
