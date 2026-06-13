require "../spec_helper"

describe AssistAnt::Commands::SessionEvent do
  describe ".detail_from" do
    it "extracts session_id and source" do
      d = AssistAnt::Commands::SessionEvent.detail_from(
        %({"session_id":"abc-123","source":"resume","cwd":"/x"}))
      d.should_not be_nil
      d.not_nil!["session_id"].as_s.should eq("abc-123")
      d.not_nil!["source"].as_s.should eq("resume")
    end

    it "omits source when absent" do
      d = AssistAnt::Commands::SessionEvent.detail_from(%({"session_id":"abc"}))
      d.not_nil!.has_key?("source").should be_false
    end

    it "returns nil without a session_id" do
      AssistAnt::Commands::SessionEvent.detail_from(%({"source":"clear"})).should be_nil
    end

    it "returns nil on empty or malformed input" do
      AssistAnt::Commands::SessionEvent.detail_from("").should be_nil
      AssistAnt::Commands::SessionEvent.detail_from("not json").should be_nil
    end
  end
end
