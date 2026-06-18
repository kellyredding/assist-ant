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

  describe "#run with actionable-item" do
    # Routing smoke (in-process): each subcommand's `--help` reaches
    # Commands::ActionableItem and returns without raising or exiting — a misroute
    # would `exit 1` and kill the spec. The `--help` paths print and return
    # without touching the socket; envelope behavior + exit codes for the write
    # subcommands live in spec/integration/actionable_item_*_spec.cr.
    it "routes `actionable-item` with no args to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["actionable-item"])
      end
    end

    it "routes `actionable-item list --help` to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["actionable-item", "list", "--help"])
      end
    end

    it "routes `actionable-item update --help` to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["actionable-item", "update", "--help"])
      end
    end

    it "routes `actionable-item remove --help` to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["actionable-item", "remove", "--help"])
      end
    end
  end

  describe "#run with spend" do
    # Routing smoke (in-process): `spend` and `spend set --help` reach
    # Commands::Spend and return without raising or exiting. Envelope behavior +
    # exit codes live in spec/integration/spend_spec.cr.
    it "routes `spend` with no args to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["spend"])
      end
    end

    it "routes `spend set --help` to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["spend", "set", "--help"])
      end
    end
  end

  describe "#run with priority" do
    # Routing smoke (in-process): `priority` and `priority set --help` reach
    # Commands::Priority and return without raising or exiting. Envelope behavior
    # + exit codes live in spec/integration/priority_spec.cr.
    it "routes `priority` with no args to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["priority"])
      end
    end

    it "routes `priority set --help` to the command" do
      with_sandbox do
        AssistAnt::CLI.new.run(["priority", "set", "--help"])
      end
    end
  end
end
