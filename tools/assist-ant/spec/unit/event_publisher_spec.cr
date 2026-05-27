require "../spec_helper"

describe AssistAnt::EventPublisher do
  describe ".build_envelope" do
    it "builds minimal envelope with v=1, event, and ts" do
      env = AssistAnt::EventPublisher.build_envelope(event: "ping")
      parsed = JSON.parse(env)
      parsed["v"].should eq 1
      parsed["event"].should eq "ping"
      parsed["ts"].as_i64.should be > 0
      parsed["ref"]?.should be_nil
      parsed["detail_data"]?.should be_nil
    end

    it "emits a single line (no embedded newlines)" do
      env = AssistAnt::EventPublisher.build_envelope(
        event: "thing.happened",
        detail_data: {"msg" => JSON::Any.new("hello world")},
      )
      env.includes?('\n').should be_false
    end

    it "includes ref when provided" do
      env = AssistAnt::EventPublisher.build_envelope(
        event: "ping",
        ref: "abc-123",
      )
      JSON.parse(env)["ref"].should eq "abc-123"
    end

    it "includes detail_data as an object" do
      detail = {
        "message" => JSON::Any.new("hi"),
        "count"   => JSON::Any.new(42_i64),
      }
      env = AssistAnt::EventPublisher.build_envelope(
        event: "ping",
        detail_data: detail,
      )
      parsed = JSON.parse(env)
      parsed["detail_data"]["message"].should eq "hi"
      parsed["detail_data"]["count"].should eq 42
    end

    it "omits ref and detail_data when nil" do
      env = AssistAnt::EventPublisher.build_envelope(event: "ping")
      env.includes?("ref").should be_false
      env.includes?("detail_data").should be_false
    end
  end
end
