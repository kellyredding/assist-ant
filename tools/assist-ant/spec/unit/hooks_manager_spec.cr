require "../spec_helper"

# Run a block with ASSIST_ANT_WORKSPACE_DIR pointed at a fresh temp dir.
# Crystal spec has no around_each, so each example calls this directly.
def with_workspace(create = true, &)
  dir = Path.new(Dir.tempdir) / "assist-ant-ws-#{Random.rand(1_000_000)}"
  Dir.mkdir_p(dir.to_s) if create
  begin
    with_env("ASSIST_ANT_WORKSPACE_DIR", dir.to_s) do
      yield dir
    end
  ensure
    FileUtils.rm_rf(dir.to_s) if Dir.exists?(dir.to_s)
  end
end

describe AssistAnt::HooksManager do
  it "creates the SessionStart hook in an absent settings.json" do
    with_workspace do
      AssistAnt::HooksManager.install.should be_true
      settings = JSON.parse(File.read(AssistAnt::HooksManager.settings_file))
      cmd = settings["hooks"]["SessionStart"][0]["hooks"][0]["command"].as_s
      cmd.should contain("assist-ant session-event")
    end
  end

  it "preserves other hooks and top-level keys" do
    with_workspace do
      existing = {
        "model" => "opus",
        "hooks" => {
          "Stop" => [{"hooks" => [{"type" => "command", "command" => "my-hook"}]}],
        },
      }
      FileUtils.mkdir_p(AssistAnt::HooksManager.settings_file.parent.to_s)
      File.write(AssistAnt::HooksManager.settings_file, existing.to_json)

      AssistAnt::HooksManager.install.should be_true
      settings = JSON.parse(File.read(AssistAnt::HooksManager.settings_file))
      settings["model"].as_s.should eq("opus")
      settings["hooks"]["Stop"][0]["hooks"][0]["command"].as_s.should eq("my-hook")
      settings["hooks"]["SessionStart"].as_a.size.should eq(1)
    end
  end

  it "is idempotent (no duplicate on re-install)" do
    with_workspace do
      AssistAnt::HooksManager.install
      AssistAnt::HooksManager.install
      settings = JSON.parse(File.read(AssistAnt::HooksManager.settings_file))
      settings["hooks"]["SessionStart"].as_a.size.should eq(1)
    end
  end

  it "reports installed? accurately" do
    with_workspace do
      AssistAnt::HooksManager.installed?.should be_false
      AssistAnt::HooksManager.install
      AssistAnt::HooksManager.installed?.should be_true
    end
  end

  it "uninstall removes only our hook" do
    with_workspace do
      existing = {
        "hooks" => {
          "SessionStart" => [{"hooks" => [{"type" => "command", "command" => "other"}]}],
        },
      }
      FileUtils.mkdir_p(AssistAnt::HooksManager.settings_file.parent.to_s)
      File.write(AssistAnt::HooksManager.settings_file, existing.to_json)
      AssistAnt::HooksManager.install
      AssistAnt::HooksManager.uninstall.should be_true

      settings = JSON.parse(File.read(AssistAnt::HooksManager.settings_file))
      starts = settings["hooks"]["SessionStart"].as_a
      starts.size.should eq(1)
      starts[0]["hooks"][0]["command"].as_s.should eq("other")
    end
  end

  it "no-ops when the workspace is missing" do
    with_workspace(create: false) do
      AssistAnt::HooksManager.install.should be_false
    end
  end
end
