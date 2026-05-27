require "../spec_helper"

describe AssistAnt::Paths do
  describe ".root" do
    it "honors ASSIST_ANT_ROOT when set" do
      with_env("ASSIST_ANT_ROOT", "/tmp/aa-test-root") do
        AssistAnt::Paths.root.to_s.should eq "/tmp/aa-test-root"
      end
    end
  end

  describe ".data_dir" do
    it "defaults to <root>/data" do
      with_env("ASSIST_ANT_ROOT", "/tmp/aa-test-root") do
        AssistAnt::Paths.data_dir.to_s.should eq "/tmp/aa-test-root/data"
      end
    end

    it "honors ASSIST_ANT_DATA_DIR override" do
      with_env("ASSIST_ANT_ROOT", "/tmp/ignored") do
        with_env("ASSIST_ANT_DATA_DIR", "/elsewhere/data") do
          AssistAnt::Paths.data_dir.to_s.should eq "/elsewhere/data"
        end
      end
    end
  end

  describe ".runtime_dir" do
    it "defaults to <root>/runtime" do
      with_env("ASSIST_ANT_ROOT", "/tmp/aa-test-root") do
        AssistAnt::Paths.runtime_dir.to_s.should eq "/tmp/aa-test-root/runtime"
      end
    end

    it "honors ASSIST_ANT_RUNTIME_DIR override" do
      with_env("ASSIST_ANT_RUNTIME_DIR", "/elsewhere/runtime") do
        AssistAnt::Paths.runtime_dir.to_s.should eq "/elsewhere/runtime"
      end
    end
  end

  describe ".socket_path" do
    it "defaults to <runtime_dir>/assist-ant.sock" do
      with_env("ASSIST_ANT_ROOT", "/tmp/aa-test-root") do
        AssistAnt::Paths.socket_path.to_s
          .should eq "/tmp/aa-test-root/runtime/assist-ant.sock"
      end
    end

    it "honors ASSIST_ANT_SOCKET override" do
      with_env("ASSIST_ANT_SOCKET", "/var/sock/aa.sock") do
        AssistAnt::Paths.socket_path.to_s.should eq "/var/sock/aa.sock"
      end
    end
  end

  describe ".log_dir" do
    it "lives under runtime_dir" do
      with_env("ASSIST_ANT_ROOT", "/tmp/aa-test-root") do
        AssistAnt::Paths.log_dir.to_s
          .should eq "/tmp/aa-test-root/runtime/logs"
      end
    end
  end

  describe ".ensure_dirs!" do
    it "creates data, runtime, and log directories" do
      with_sandbox do |sandbox|
        AssistAnt::Paths.ensure_dirs!
        Dir.exists?(AssistAnt::Paths.data_dir.to_s).should be_true
        Dir.exists?(AssistAnt::Paths.runtime_dir.to_s).should be_true
        Dir.exists?(AssistAnt::Paths.log_dir.to_s).should be_true
      end
    end

    it "is idempotent" do
      with_sandbox do
        AssistAnt::Paths.ensure_dirs!
        AssistAnt::Paths.ensure_dirs! # second call must not raise
      end
    end
  end
end
