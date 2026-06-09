require "../spec_helper"

# End-to-end coverage for `actionable-item sync`: shell out to the built
# binary, feed it a Linear issue list, capture the envelope it publishes off a
# real UNIXServer (reusing `with_socket_server` / `run_binary` from the sibling
# integration specs), and assert on the batch file it hands the app.
# Skips automatically if the binary hasn't been built — run `make dev` first.
describe "assist-ant actionable-item sync" do
  binary = SPEC_BIN

  before_each do
    pending! "binary not built — run `make dev` first" unless File.exists?(binary)
  end

  # One started issue (with a bare URL in its body), one backlog issue, one
  # recently-completed issue.
  fixture = <<-JSON
    {"issues":[
      {"id":"FLEX-1","title":"Active","url":"https://linear.app/kajabi/issue/FLEX-1","statusType":"started","status":"In Progress","team":"Flex","priority":{"value":2,"name":"High"},"description":"Repro https://repro.test/x"},
      {"id":"DEV-9","title":"Old backlog","url":"https://linear.app/kajabi/issue/DEV-9","statusType":"backlog","status":"Backlog","team":"Dev","priority":{"value":0,"name":"No priority"}},
      {"id":"FLEX-5","title":"Finished","url":"https://linear.app/kajabi/issue/FLEX-5","statusType":"completed","status":"Done","completedAt":"2026-06-08T15:30:00.000Z","team":"Flex","priority":{"value":3,"name":"Medium"}}
    ],"hasNextPage":false}
    JSON

  it "publishes an actionable_item.sync envelope and writes the batch" do
    with_socket_server do |sock_path, channel|
      input = File.tempfile("linear-fixture", ".json")
      input.print(fixture)
      input.close
      begin
        result = run_binary(
          [binary, "actionable-item", "sync",
           "--provider", "linear", "--source", "linear",
           "--input", input.path],
          env: {"ASSIST_ANT_SOCKET" => sock_path},
        )
        result[:status].success?.should be_true

        parsed = JSON.parse(channel.receive)
        parsed["event"].should eq "actionable_item.sync"
        detail = parsed["detail_data"]
        detail["source"].should eq "linear"
        detail["count"].should eq 3

        batch_file = detail["batch_file"].as_s
        File.exists?(batch_file).should be_true
        batch = JSON.parse(File.read(batch_file))
        File.delete(batch_file)

        batch["source"].should eq "linear"
        batch["reconcile"].as_bool.should be_true
        batch["keep"].as_a.map(&.as_s).sort.should eq ["DEV-9", "FLEX-1", "FLEX-5"]

        items = batch["items"].as_a
        items.size.should eq 3
        by_id = items.to_h { |it| {it["external_id"].as_s, it} }
        by_id["FLEX-1"]["status_type"].should eq "started"
        by_id["FLEX-1"]["body"].as_s.should contain "[https://repro.test/x](https://repro.test/x)"
        by_id["DEV-9"]["status_type"].should eq "backlog"
        by_id["FLEX-5"]["status_type"].should eq "completed"
        by_id["FLEX-5"]["completed_at"].should eq "2026-06-08T15:30:00.000Z"
      ensure
        File.delete(input.path) if File.exists?(input.path)
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
  end
end
