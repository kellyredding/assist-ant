ENV["ASSIST_ANT_SKIP_CLI"] = "1"

# Use a temporary directory for AssistAnt data during tests.
# This prevents specs from reading or writing the real
# ~/.assist-ant/. Set BEFORE requiring the source so any
# constant evaluation at load time picks it up.
SPEC_ASSIST_ANT_ROOT = Path.new(Dir.tempdir) /
                       "assist-ant-test-#{Random.rand(100000)}"
ENV["ASSIST_ANT_ROOT"] = SPEC_ASSIST_ANT_ROOT.to_s

require "spec"
require "file_utils"
require "../src/assist_ant"

Dir.mkdir_p(SPEC_ASSIST_ANT_ROOT.to_s)

# Clean up the spec root after the full suite runs.
Spec.after_suite do
  if Dir.exists?(SPEC_ASSIST_ANT_ROOT.to_s)
    FileUtils.rm_rf(SPEC_ASSIST_ANT_ROOT.to_s)
  end
end

# Temporarily set an environment variable for the duration of the
# block, restoring the prior value (or unsetting it) afterward.
def with_env(key : String, value : String, &)
  previous = ENV[key]?
  ENV[key] = value
  begin
    yield
  ensure
    if previous
      ENV[key] = previous
    else
      ENV.delete(key)
    end
  end
end

# Allocate a fresh per-test sandbox directory, run the block with
# ASSIST_ANT_ROOT pointing at it, then clean up. Use this for any
# spec that touches the filesystem.
def with_sandbox(&)
  sandbox = Path.new(Dir.tempdir) /
            "assist-ant-spec-#{Random.rand(1_000_000)}"
  Dir.mkdir_p(sandbox.to_s)
  begin
    with_env("ASSIST_ANT_ROOT", sandbox.to_s) do
      yield sandbox
    end
  ensure
    FileUtils.rm_rf(sandbox.to_s) if Dir.exists?(sandbox.to_s)
  end
end

# Path to a freshly-built `assist-ant` binary, for shell-out
# integration specs. Defaults to the local dev build; override via
# `ASSIST_ANT_BIN` if running against an installed copy.
SPEC_BIN = ENV["ASSIST_ANT_BIN"]? ||
           File.expand_path("../build/assist-ant", __DIR__)
