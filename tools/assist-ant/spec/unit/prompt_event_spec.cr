require "../spec_helper"

describe AssistAnt::Commands::PromptEvent do
  describe ".detail_from" do
    it "extracts the session_id" do
      d = AssistAnt::Commands::PromptEvent.detail_from(
        %({"session_id":"abc-123","prompt":"do the thing","cwd":"/x"}))
      d.should_not be_nil
      d.not_nil!["session_id"].as_s.should eq("abc-123")
    end

    # The app matches the event against its own send; it never needs the text,
    # and forwarding it would put whatever the user typed onto the socket.
    it "does not carry the prompt text" do
      d = AssistAnt::Commands::PromptEvent.detail_from(
        %({"session_id":"abc","prompt":"something private"}))
      d.not_nil!.has_key?("prompt").should be_false
    end

    it "returns nil without a session_id" do
      AssistAnt::Commands::PromptEvent.detail_from(%({"prompt":"hi"})).should be_nil
    end

    it "returns nil on empty or malformed input" do
      AssistAnt::Commands::PromptEvent.detail_from("").should be_nil
      AssistAnt::Commands::PromptEvent.detail_from("not json").should be_nil
    end
  end
end
