require "../spec_helper"

# Unit coverage for the Linear provider: MCP-payload parsing/normalization
# (`--input`), the direct GraphQL fetch's query + projection (`--fetch`),
# bare-URL linkification (without escaping the surrounding markdown), and body
# composition. Batch shaping + the sync envelope live in
# spec/integration/actionable_item_spec.cr.
describe AssistAnt::LinearSync do
  linear = AssistAnt::LinearSync::LinearParser.new
  fetcher = AssistAnt::LinearSync::APIFetcher.new("kajabi")

  describe "LinearParser#parse" do
    # `triage` is mirrored: a triage ticket is assigned, unresolved work, so
    # leaving it out did not hide those issues — it retired them on every run.
    # `canceled` stays out deliberately: it is not work, and falling out of both
    # `items` and `keep` is how the mirror retires a stale copy.
    it "normalizes issues by state type, keeps triage, and drops canceled" do
      raw = %({"issues":[
        {"id":"FLEX-1","title":"Active","url":"https://l/1","statusType":"started","status":"In Progress","team":"Flex","priority":{"value":2,"name":"High"}},
        {"id":"FLEX-2","title":"Done","url":"https://l/2","statusType":"completed","status":"Done","completedAt":"2026-06-08T15:30:00.000Z","team":"Flex","priority":{"value":0,"name":"No priority"}},
        {"id":"FLEX-3","title":"Canceled","url":"https://l/3","statusType":"canceled","status":"Canceled","team":"Flex"},
        {"id":"FLEX-4","title":"Needs triage","url":"https://l/4","statusType":"triage","status":"Triage","team":"Flex"}
      ]})
      issues = linear.parse(raw)
      # triage kept, canceled dropped
      issues.map(&.external_id).should eq ["FLEX-1", "FLEX-2", "FLEX-4"]
      issues.map(&.status_type).should_not contain "canceled"
      issues[2].status_type.should eq "triage"
      issues[1].completed?.should be_true
      issues[1].completed_at.should eq "2026-06-08T15:30:00.000Z"
      issues[0].completed?.should be_false
    end

    it "reads project, milestone, and priority context" do
      raw = %({"issues":[
        {"id":"FLEX-9","title":"X","url":"https://l/9","statusType":"backlog","status":"Backlog","team":"Flex","priority":{"value":3,"name":"Medium"},"project":"c3: MCP","projectMilestone":{"id":"m1","name":"Action Panel"}}
      ]})
      i = linear.parse(raw).first
      i.status_type.should eq "backlog"
      i.project.should eq "c3: MCP"
      i.milestone.should eq "Action Panel"
      i.priority_name.should eq "Medium"
    end
  end

  # The `--fetch` projection is the thing that drifted twice in one day, so it is
  # pinned field by field. `query_for` and `normalize` are separated from the
  # shell-out precisely so this can happen with no network.
  describe "APIFetcher#normalize" do
    # A realistic GraphQL node: nested `{ name }` objects, `priorityLabel`
    # alongside the numeric `priority`, and a UUID `id` the projection must
    # ignore even when something upstream selects it.
    node = JSON.parse(%({
      "id": "8b215160-ab01-4e98-819f-a57debfdf1d8",
      "identifier": "FLEX-4426",
      "title": "  Coaching controllers bypass turbo_frame_layout  ",
      "description": "See the POC PR.",
      "url": "https://linear.app/kajabi/issue/FLEX-4426/coaching",
      "state": {"type": "started", "name": "In Progress"},
      "completedAt": null,
      "team": {"name": "Flex"},
      "priority": 2,
      "priorityLabel": "High",
      "project": {"name": "Admin Turbo Frames"},
      "projectMilestone": {"name": "DevQA"},
      "labels": {"nodes": [{"name": "bug"}, {"name": "turbo"}]}
    }))

    it "keys on identifier, never on the UUID id" do
      issue = fetcher.normalize(node).not_nil!
      issue.external_id.should eq "FLEX-4426"
      issue.external_id.should_not contain "8b215160"
    end

    it "flattens the nested GraphQL shapes the rest of the pipeline wants flat" do
      issue = fetcher.normalize(node).not_nil!
      issue.status_type.should eq "started" # state { type }
      issue.status.should eq "In Progress"  # state { name }
      issue.team.should eq "Flex"           # team { name }
      issue.project.should eq "Admin Turbo Frames"
      issue.milestone.should eq "DevQA"       # projectMilestone { name }
      issue.labels.should eq ["bug", "turbo"] # labels { nodes { name } }
      # Flat all along, and stripped.
      issue.title.should eq "Coaching controllers bypass turbo_frame_layout"
      issue.description.should eq "See the POC PR."
      issue.url.should eq "https://linear.app/kajabi/issue/FLEX-4426/coaching"
    end

    it "reads priorityLabel rather than the numeric priority" do
      fetcher.normalize(node).not_nil!.priority_name.should eq "High"
    end

    it "leaves priority_name empty when only the numeric priority is present" do
      numeric = JSON.parse(%({"identifier":"FLEX-1","title":"t","url":"u",
        "priority":2,"state":{"type":"started","name":"In Progress"}}))
      fetcher.normalize(numeric).not_nil!.priority_name.should eq ""
    end

    it "includes triage and excludes canceled" do
      triage = JSON.parse(%({"identifier":"FLEX-9","title":"t","url":"u",
        "state":{"type":"triage","name":"Triage"}}))
      canceled = JSON.parse(%({"identifier":"FLEX-8","title":"t","url":"u",
        "state":{"type":"canceled","name":"Canceled"}}))
      fetcher.normalize(triage).not_nil!.status_type.should eq "triage"
      fetcher.normalize(canceled).should be_nil
    end

    it "carries completedAt through, which drives both resolve and unresolve" do
      done = JSON.parse(%({"identifier":"FLEX-5","title":"t","url":"u",
        "completedAt":"2026-07-28T21:37:51.690Z",
        "state":{"type":"completed","name":"Done"}}))
      issue = fetcher.normalize(done).not_nil!
      issue.completed?.should be_true
      issue.completed_at.should eq "2026-07-28T21:37:51.690Z"
      fetcher.normalize(node).not_nil!.completed_at.should be_nil
    end

    it "treats an absent project/milestone as nil rather than empty" do
      bare = JSON.parse(%({"identifier":"FLEX-1","title":"t","url":"u",
        "project":null,"projectMilestone":null,"labels":{"nodes":[]},
        "state":{"type":"backlog","name":"Backlog"}}))
      issue = fetcher.normalize(bare).not_nil!
      issue.project.should be_nil
      issue.milestone.should be_nil
      issue.labels.should be_empty
      issue.team.should eq ""
    end

    it "renders the ticket link from the identifier, not a UUID" do
      body = AssistAnt::LinearSync.compose_body(fetcher.normalize(node).not_nil!)
      body.should contain "[FLEX-4426](https://linear.app/kajabi/issue/FLEX-4426/coaching)"
      body.should_not contain "8b215160"
    end
  end

  describe "APIFetcher#query_for" do
    it "selects identifier and never selects the UUID id" do
      q = fetcher.query_for("started")
      q.should contain "identifier"
      # Not in the selection set at all — not even as an unused field, because
      # selecting it is what invites the re-keying mistake.
      q.lines.map(&.strip).should_not contain "id"
    end

    it "selects every field the projection maps" do
      q = fetcher.query_for("started")
      %w[identifier title description url completedAt priorityLabel].each do |field|
        q.should contain field
      end
      q.should contain "state { type name }"
      q.should contain "team { name }"
      q.should contain "project { name }"
      q.should contain "projectMilestone { name }"
      q.should contain "labels { nodes { name } }"
    end

    it "projects priorityLabel rather than the numeric priority" do
      q = fetcher.query_for("started")
      q.should contain "priorityLabel"
      q.lines.map(&.strip).should_not contain "priority"
    end

    it "scopes each bucket to the assignee and its own state type" do
      q = fetcher.query_for("triage")
      q.should contain "assignee: { isMe: { eq: true } }"
      q.should contain %(state: { type: { eq: "triage" } })
    end

    it "requests the completed bucket within the 7-day window" do
      fetcher.query_for("completed").should contain %(updatedAt: { gt: "-P7D" })
      # Every other bucket is live work and is taken whole.
      fetcher.query_for("started").should_not contain "updatedAt"
    end

    it "threads the cursor into the next page's query" do
      first = fetcher.query_for("backlog")
      first.should_not contain "after:"
      first.should contain "pageInfo { hasNextPage endCursor }"

      second = fetcher.query_for("backlog", after: "cur-123")
      second.should contain %(after: "cur-123")
      second.should contain %(state: { type: { eq: "backlog" } })
    end

    it "fetches exactly the buckets the parser mirrors" do
      AssistAnt::LinearSync::APIFetcher::BUCKETS.to_a.sort
        .should eq AssistAnt::LinearSync::SYNCED_TYPES.to_a.sort
    end
  end

  describe ".linkify_bare_urls" do
    it "wraps a bare URL as a markdown link" do
      AssistAnt::LinearSync.linkify_bare_urls("see https://x.com here")
        .should eq "see [https://x.com](https://x.com) here"
    end

    it "leaves an existing markdown link untouched" do
      AssistAnt::LinearSync.linkify_bare_urls("[doc](https://x.com)")
        .should eq "[doc](https://x.com)"
    end

    it "leaves an autolink untouched" do
      AssistAnt::LinearSync.linkify_bare_urls("<https://x.com>")
        .should eq "<https://x.com>"
    end

    it "preserves surrounding markdown without escaping it" do
      input = "**bold** and _em_ and a list:\n- one"
      AssistAnt::LinearSync.linkify_bare_urls(input).should eq input
    end
  end

  describe ".lift_truncation_marker" do
    it "moves a trailing (truncated …) marker onto its own block" do
      input = "### OAuth Impl... (truncated, use get_issue for full description)"
      AssistAnt::LinearSync.lift_truncation_marker(input)
        .should eq "### OAuth Impl...\n\n(truncated, use get_issue for full description)"
    end

    it "leaves a description without the marker untouched" do
      input = "## Overview\n\nSome description text."
      AssistAnt::LinearSync.lift_truncation_marker(input).should eq input
    end
  end

  describe ".compose_body" do
    it "lifts Linear's trailing truncation marker onto its own block" do
      raw = %({"issues":[
        {"id":"FLEX-8","title":"X","url":"https://l/8","statusType":"started","status":"In Progress","description":"## Technical Requirements\\n\\n### OAuth Impl... (truncated, use get_issue for full description)"}
      ]})
      body = AssistAnt::LinearSync.compose_body(linear.parse(raw).first)
      body.should contain "### OAuth Impl...\n\n(truncated, use get_issue for full description)"
      body.should_not contain "Impl... (truncated"
    end

    it "leads with the ticket link, then project · milestone · status, then the linkified description" do
      raw = %({"issues":[
        {"id":"FLEX-7","title":"X","url":"https://linear.app/kajabi/issue/FLEX-7","statusType":"started","status":"In Progress","team":"Flex","priority":{"value":2,"name":"High"},"project":"c3: MCP","projectMilestone":{"name":"Panel"},"labels":["bug"],"description":"Repro at https://repro.test/x and see [docs](https://docs.test)."}
      ]})
      body = AssistAnt::LinearSync.compose_body(linear.parse(raw).first)
      body.should contain "[FLEX-7](https://linear.app/kajabi/issue/FLEX-7)" # ticket link, no suffix
      # ticket and metadata are separate blocks (blank line between them)
      body.should contain ")\n\nc3: MCP  ·  Panel  ·  In Progress"
      body.should contain "[https://repro.test/x](https://repro.test/x)" # bare → linkified
      body.should contain "[docs](https://docs.test)"                    # existing link untouched
      # Dropped: team, priority, labels, the "in Linear" suffix, and all emoji.
      body.should_not contain "Flex"
      body.should_not contain "High"
      body.should_not contain "bug"
      body.should_not contain "in Linear"
      body.should_not contain "📐"
    end
  end
end
