module AssistAnt
  # Centralized path resolution. All other code reads paths from
  # here — never builds them ad-hoc. Every value is overridable via
  # an env var so specs can isolate to tempdirs.
  module Paths
    extend self

    def root : Path
      Path.new(ENV.fetch("ASSIST_ANT_ROOT", (Path.home / ".assist-ant").to_s))
    end

    def data_dir : Path
      Path.new(ENV.fetch("ASSIST_ANT_DATA_DIR", (root / "data").to_s))
    end

    # The agent's workspace — the cwd of the embedded Claude session.
    # A Sync-backed symlink set up manually as a prerequisite; never
    # created here (absent from ensure_dirs!).
    def workspace_dir : Path
      Path.new(ENV.fetch("ASSIST_ANT_WORKSPACE_DIR", (root / "workspace").to_s))
    end

    def runtime_dir : Path
      Path.new(ENV.fetch("ASSIST_ANT_RUNTIME_DIR", (root / "runtime").to_s))
    end

    def socket_path : Path
      Path.new(ENV.fetch("ASSIST_ANT_SOCKET", (runtime_dir / "assist-ant.sock").to_s))
    end

    def log_dir : Path
      runtime_dir / "logs"
    end

    # Create all directories the app/CLI expects to exist.
    # Idempotent. The CLI does not call this — the app does at
    # startup. The CLI is a pure sender and must not assume the
    # data dir exists.
    def ensure_dirs!
      [data_dir, runtime_dir, log_dir].each do |dir|
        FileUtils.mkdir_p(dir.to_s)
      end
    end
  end
end
