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

  describe ".compose_body" do
    it "builds the header with a Linear link and linkifies the description" do
      raw = %({"issues":[
        {"id":"FLEX-7","title":"X","url":"https://linear.app/kajabi/issue/FLEX-7","statusType":"started","status":"In Progress","team":"Flex","priority":{"value":2,"name":"High"},"project":"c3: MCP","projectMilestone":{"name":"Panel"},"description":"Repro at https://repro.test/x and see [docs](https://docs.test)."}
      ]})
      body = AssistAnt::LinearSync.compose_body(linear.parse(raw).first)
      body.should contain "📐 Flex  ·  In Progress  ·  High"
      body.should contain "🔗 [FLEX-7 in Linear](https://linear.app/kajabi/issue/FLEX-7)"
      body.should contain "📁 c3: MCP › Panel"
      body.should contain "[https://repro.test/x](https://repro.test/x)" # bare → linkified
      body.should contain "[docs](https://docs.test)"                    # existing link untouched
    end
  end
end
