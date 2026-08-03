require "../spec_helper"

# End-to-end coverage for `actionable-item sync`: shell out to the built binary,
# feed it a Linear issue list, capture the envelope it sends off a real
# UNIXServer, and assert on both the batch file it hands the app and the summary
# it composes from the app's reply.
#
# `sync` is REQUEST/REPLY now, so each happy-path test stands up a one-shot
# replying socket (`with_task_reply_server`, defined in task_spec) rather than
# the non-replying `with_socket_server`: the CLI waits for the outcome, because
# the app is the only thing that knows whether reconcile actually ran.
#
# Skips automatically if the binary hasn't been built — run `make dev` first.

# One started issue (with a bare URL in its body), one backlog issue, one triage
# issue, one recently-completed issue.
SYNC_FIXTURE = <<-JSON
  {"issues":[
    {"id":"FLEX-1","title":"Active","url":"https://linear.app/kajabi/issue/FLEX-1","statusType":"started","status":"In Progress","team":"Flex","priority":{"value":2,"name":"High"},"description":"Repro https://repro.test/x"},
    {"id":"DEV-9","title":"Old backlog","url":"https://linear.app/kajabi/issue/DEV-9","statusType":"backlog","status":"Backlog","team":"Dev","priority":{"value":0,"name":"No priority"}},
    {"id":"FLEX-6","title":"Needs triage","url":"https://linear.app/kajabi/issue/FLEX-6","statusType":"triage","status":"Triage","team":"Flex"},
    {"id":"FLEX-5","title":"Finished","url":"https://linear.app/kajabi/issue/FLEX-5","statusType":"completed","status":"Done","completedAt":"2026-06-08T15:30:00.000Z","team":"Flex","priority":{"value":3,"name":"Medium"}}
  ],"hasNextPage":false}
  JSON

# Write SYNC_FIXTURE to a temp file, run `sync --input` against a one-shot server
# answering `reply`, then hand the block the CLI result plus the parsed envelope.
def with_sync_run(reply : String, extra_args : Array(String) = [] of String, &)
  with_task_reply_server(reply) do |sock, channel|
    input = File.tempfile("linear-fixture", ".json")
    input.print(SYNC_FIXTURE)
    input.close
    begin
      result = run_binary(
        [SPEC_BIN, "actionable-item", "sync",
         "--provider", "linear", "--source", "linear",
         "--input", input.path] + extra_args,
        env: {"ASSIST_ANT_SOCKET" => sock},
      )
      yield result, JSON.parse(channel.receive)
    ensure
      File.delete(input.path) if File.exists?(input.path)
    end
  end
end

# A stubbed `linear` that answers only the backlog bucket, and answers it in two
# pages: page 1 hands back an `endCursor`, page 2 is recognised by the `after:`
# argument the fetch loop must thread into it. Everything the CLI has to get
# right about pagination is then visible in the resulting keep set. Every
# invocation appends its `--workspace` value so that can be asserted too.
PAGED_LINEAR_STUB = <<-SH
  #!/bin/sh
  echo "$2" >> "$(dirname "$0")/workspace.log"
  q="$4"
  case "$q" in
    *'eq: "backlog"'*) ;;
    *) echo '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
       exit 0 ;;
  esac
  case "$q" in
    *'after: "CUR-1"'*)
      echo '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"identifier":"PAGE-2","title":"second page","url":"https://l/2","state":{"type":"backlog","name":"Backlog"},"priorityLabel":"Low"}]}}}'
      ;;
    *)
      echo '{"data":{"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR-1"},"nodes":[{"identifier":"PAGE-1","title":"first page","url":"https://l/1","state":{"type":"backlog","name":"Backlog"},"priorityLabel":"Low"}]}}}'
      ;;
  esac
  SH

# Shadow `linear` on PATH with a stub shell script, so the `--fetch` paths can be
# exercised without a network or a credential.
def with_linear_stub(script : String, &)
  dir = File.join(Dir.tempdir, "aa-linear-stub-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(dir)
  begin
    stub = File.join(dir, "linear")
    File.write(stub, script)
    File.chmod(stub, 0o755)
    yield dir
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

describe "assist-ant actionable-item sync" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  it "sends an actionable_item.sync envelope and writes the batch" do
    reply = %({"ok":true,"applied":4,"retired":0,) +
            %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":12})
    with_sync_run(reply) do |result, parsed|
      result[:status].success?.should be_true

      parsed["event"].should eq "actionable_item.sync"
      detail = parsed["detail_data"]
      detail["source"].should eq "linear"
      detail["count"].should eq 4

      batch_file = detail["batch_file"].as_s
      File.exists?(batch_file).should be_true
      batch = JSON.parse(File.read(batch_file))
      File.delete(batch_file)

      batch["source"].should eq "linear"
      batch["reconcile"].as_bool.should be_true
      batch["keep"].as_a.map(&.as_s).sort
        .should eq ["DEV-9", "FLEX-1", "FLEX-5", "FLEX-6"]

      items = batch["items"].as_a
      items.size.should eq 4
      by_id = items.to_h { |it| {it["external_id"].as_s, it} }
      by_id["FLEX-1"]["status_type"].should eq "started"
      by_id["FLEX-1"]["body"].as_s.should contain "[https://repro.test/x](https://repro.test/x)"
      by_id["DEV-9"]["status_type"].should eq "backlog"
      by_id["FLEX-6"]["status_type"].should eq "triage"
      by_id["FLEX-5"]["status_type"].should eq "completed"
      by_id["FLEX-5"]["completed_at"].should eq "2026-06-08T15:30:00.000Z"
    end
  end

  describe "the reply-driven summary" do
    # The observability bug this replaces: the old line printed `reconcile=true`
    # from the CLI's own intent, so a retirement the app declined to perform read
    # as a success.
    it "reports the app's retired count rather than the CLI's intent" do
      reply = %({"ok":true,"applied":4,"retired":3,) +
              %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":51})
      with_sync_run(reply) do |result, parsed|
        result[:status].success?.should be_true
        result[:stdout].should contain "Synced 4 actionable items"
        result[:stdout].should contain "3 open, 1 completed"
        result[:stdout].should contain "retired=3"
        result[:stdout].should contain "reconcile=applied"
        result[:stdout].should_not contain "reconcile=true"
        result[:stderr].should_not contain "WITHHELD"

        File.delete(parsed["detail_data"]["batch_file"].as_s)
      end
    end

    # `retired=0` reads identically whether reconcile ran and found nothing or
    # was withheld before it looked. Without the state named on stdout, telling
    # them apart means noticing the ABSENCE of a stderr line — which a reader
    # holding only the summary cannot do. These three pin that it is stated.
    it "names reconcile=applied when it ran and retired nothing" do
      reply = %({"ok":true,"applied":4,"retired":0,) +
              %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":4})
      with_sync_run(reply) do |result, parsed|
        result[:stdout].should contain "reconcile=applied, retired=0"
        result[:stderr].should_not contain "WITHHELD"
        File.delete(parsed["detail_data"]["batch_file"].as_s)
      end
    end

    it "names the withheld state and its reason on stdout, not only stderr" do
      reply = %({"ok":true,"applied":4,"retired":0,"reconcile_withheld":true,) +
              %("withheld_reason":"fullTurnover","prior_candidates":30})
      with_sync_run(reply) do |result, parsed|
        result[:stdout].should contain "reconcile=WITHHELD:fullTurnover"
        File.delete(parsed["detail_data"]["batch_file"].as_s)
      end
    end

    it "names reconcile=off when --no-reconcile asked for none" do
      reply = %({"ok":true,"applied":4,"retired":0,) +
              %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":4})
      with_sync_run(reply, extra_args: ["--no-reconcile"]) do |result, parsed|
        result[:stdout].should contain "reconcile=off"
        result[:stdout].should_not contain "applied"
        File.delete(parsed["detail_data"]["batch_file"].as_s)
      end
    end

    it "warns on stderr, naming the reason and the prior candidate count" do
      reply = %({"ok":true,"applied":4,"retired":0,"reconcile_withheld":true,) +
              %("withheld_reason":"fullTurnover","prior_candidates":30})
      with_sync_run(reply) do |result, parsed|
        result[:status].success?.should be_true
        result[:stderr].should contain "reconcile WITHHELD (fullTurnover)"
        result[:stderr].should contain "30 existing"
        result[:stderr].should contain "--allow-full-turnover"
        # Withheld means nothing was retired, and the summary must say so.
        result[:stdout].should contain "retired=0"

        File.delete(parsed["detail_data"]["batch_file"].as_s)
      end
    end

    it "names the empty-fetch reason too" do
      reply = %({"ok":true,"applied":4,"retired":0,"reconcile_withheld":true,) +
              %("withheld_reason":"emptyFetch","prior_candidates":30})
      with_sync_run(reply) do |result, parsed|
        result[:stderr].should contain "reconcile WITHHELD (emptyFetch)"
        File.delete(parsed["detail_data"]["batch_file"].as_s)
      end
    end

    it "exits non-zero when the app is not running (no reply)" do
      missing = File.join(Dir.tempdir, "aa-absent-#{Random.rand(1_000_000)}.sock")
      input = File.tempfile("linear-fixture", ".json")
      input.print(SYNC_FIXTURE)
      input.close
      begin
        result = run_binary(
          [binary, "actionable-item", "sync",
           "--provider", "linear", "--source", "linear",
           "--input", input.path],
          env: {"ASSIST_ANT_SOCKET" => missing},
        )
        result[:status].success?.should be_false
        result[:stderr].should contain "is the app running?"
        # A sync nothing applied must not read as a success.
        result[:stdout].should_not contain "Synced"
      ensure
        File.delete(input.path) if File.exists?(input.path)
      end
    end
  end

  describe "--allow-full-turnover" do
    reply = %({"ok":true,"applied":4,"retired":2,) +
            %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":30})

    it "carries the override in the batch when passed" do
      with_sync_run(reply, ["--allow-full-turnover"]) do |result, parsed|
        result[:status].success?.should be_true
        batch_file = parsed["detail_data"]["batch_file"].as_s
        batch = JSON.parse(File.read(batch_file))
        File.delete(batch_file)
        batch["allow_full_turnover"].as_bool.should be_true
      end
    end

    it "omits the field entirely when not passed" do
      with_sync_run(reply) do |_, parsed|
        batch_file = parsed["detail_data"]["batch_file"].as_s
        batch = JSON.parse(File.read(batch_file))
        File.delete(batch_file)
        # Absent, not `false` — the app decodes the omission as false, and
        # omitting it keeps the payload honest about what was actually asked for.
        batch.as_h.has_key?("allow_full_turnover").should be_false
      end
    end
  end

  describe "--fetch" do
    it "paginates each bucket and keys the batch on identifier" do
      reply = %({"ok":true,"applied":2,"retired":0,) +
              %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":2})
      with_linear_stub(PAGED_LINEAR_STUB) do |dir|
        with_task_reply_server(reply) do |sock, channel|
          result = run_binary(
            [binary, "actionable-item", "sync",
             "--provider", "linear", "--source", "linear", "--fetch"],
            env: {"ASSIST_ANT_SOCKET" => sock, "PATH" => "#{dir}:#{ENV["PATH"]}"},
          )
          result[:status].success?.should be_true
          result[:stdout].should contain "Synced 2 actionable items"

          parsed = JSON.parse(channel.receive)
          batch_file = parsed["detail_data"]["batch_file"].as_s
          batch = JSON.parse(File.read(batch_file))
          File.delete(batch_file)

          # Page 2 is only reachable by threading the cursor.
          batch["keep"].as_a.map(&.as_s).sort.should eq ["PAGE-1", "PAGE-2"]
          batch["items"].as_a.first["status_type"].should eq "backlog"

          # One call per bucket, plus the extra page for backlog.
          workspaces = File.read_lines(File.join(dir, "workspace.log")).map(&.strip)
          workspaces.size.should eq 6
          workspaces.uniq.should eq ["kajabi"] # the default
        end
      end
    end

    it "passes --linear-workspace through to the `linear` CLI" do
      reply = %({"ok":true,"applied":2,"retired":0,) +
              %("reconcile_withheld":false,"withheld_reason":"","prior_candidates":2})
      with_linear_stub(PAGED_LINEAR_STUB) do |dir|
        with_task_reply_server(reply) do |sock, channel|
          result = run_binary(
            [binary, "actionable-item", "sync",
             "--provider", "linear", "--source", "linear", "--fetch",
             "--linear-workspace", "someother"],
            env: {"ASSIST_ANT_SOCKET" => sock, "PATH" => "#{dir}:#{ENV["PATH"]}"},
          )
          result[:status].success?.should be_true

          File.delete(JSON.parse(channel.receive)["detail_data"]["batch_file"].as_s)
          File.read_lines(File.join(dir, "workspace.log")).map(&.strip)
            .uniq.should eq ["someother"]
        end
      end
    end
  end

  describe "validation" do
    it "exits non-zero on an unknown subcommand" do
      result = run_binary([binary, "actionable-item", "bogus"])
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown actionable-item subcommand"
    end

    it "exits non-zero on an unknown provider" do
      result = run_binary(
        [binary, "actionable-item", "sync",
         "--provider", "bogus", "--source", "linear"],
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "unknown --provider"
    end

    it "refuses --fetch together with --input" do
      result = run_binary(
        [binary, "actionable-item", "sync",
         "--provider", "linear", "--source", "linear",
         "--fetch", "--input", "/tmp/does-not-matter.json"],
      )
      result[:status].success?.should be_false
      result[:stderr].should contain "mutually exclusive"
    end

    it "reports a failed `linear` CLI rather than an empty fetch" do
      with_linear_stub("#!/bin/sh\necho 'not authenticated' >&2\nexit 1\n") do |dir|
        result = run_binary(
          [binary, "actionable-item", "sync",
           "--provider", "linear", "--source", "linear", "--fetch"],
          env: {"PATH" => "#{dir}:#{ENV["PATH"]}"},
        )
        result[:status].success?.should be_false
        result[:stderr].should contain "`linear` CLI failed"
        result[:stderr].should contain "authenticated"
      end
    end

    it "aborts when the GraphQL response carries an errors array" do
      # Linear answers HTTP 200 with `errors`, so a zero exit is not a
      # successful query — the stub exits 0 on purpose.
      body = %({"errors":[{"message":"Authentication required"}]})
      with_linear_stub("#!/bin/sh\necho '#{body}'\nexit 0\n") do |dir|
        result = run_binary(
          [binary, "actionable-item", "sync",
           "--provider", "linear", "--source", "linear", "--fetch"],
          env: {"PATH" => "#{dir}:#{ENV["PATH"]}"},
        )
        result[:status].success?.should be_false
        result[:stderr].should contain "Linear API returned errors"
        result[:stderr].should contain "Authentication required"
      end
    end
  end
end
