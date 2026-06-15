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

  describe "#run with task" do
    # Routing smoke: a `task` command reaches Commands::Task and prints its help
    # without raising. A misroute would fall to the CLI's `else` branch and
    # `exit 1`, terminating the spec — so a clean return confirms the wiring.
    # Subcommand behavior + exit codes live in spec/integration/task_spec.cr.
    it "routes `task` with no args to the task command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["task"])
      end
    end

    it "routes `task --help` to the task command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["task", "--help"])
      end
    end
  end
end
