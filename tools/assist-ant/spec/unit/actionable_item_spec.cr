require "../spec_helper"

# Unit coverage for the Linear provider: parsing/normalization, bare-URL
# linkification (without escaping the surrounding markdown), and body
# composition. Batch shaping + the published envelope live in
# spec/integration/actionable_item_spec.cr.
describe AssistAnt::LinearSync do
  linear = AssistAnt::LinearSync::LinearParser.new

  describe "LinearParser#parse" do
    it "normalizes issues by state type and drops canceled/triage" do
      raw = %({"issues":[
        {"id":"FLEX-1","title":"Active","url":"https://l/1","statusType":"started","status":"In Progress","team":"Flex","priority":{"value":2,"name":"High"}},
        {"id":"FLEX-2","title":"Done","url":"https://l/2","statusType":"completed","status":"Done","completedAt":"2026-06-08T15:30:00.000Z","team":"Flex","priority":{"value":0,"name":"No priority"}},
        {"id":"FLEX-3","title":"Canceled","url":"https://l/3","statusType":"canceled","status":"Canceled","team":"Flex"}
      ]})
      issues = linear.parse(raw)
      issues.map(&.external_id).should eq ["FLEX-1", "FLEX-2"] # canceled dropped
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
