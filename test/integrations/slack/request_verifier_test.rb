# frozen_string_literal: true

require "test_helper"

class Slack::RequestVerifierTest < ActiveSupport::TestCase
  SECRET = "8f742231b10e8888abcd99yyyzzz85a5"

  setup do
    @now = 1_700_000_000
    @timestamp = @now.to_s
    @body = "token=abc&type=event_callback"
    @signature = Slack::RequestVerifier.sign(timestamp: @timestamp, body: @body, secret: SECRET)
  end

  def valid?(**overrides)
    Slack::RequestVerifier.valid?(
      signature: @signature, timestamp: @timestamp, body: @body, secret: SECRET, now: @now, **overrides
    )
  end

  context ".valid?" do
    should "accept a correctly signed, fresh request" do
      assert valid?
    end

    should "reject a tampered body" do
      assert_not valid?(body: "token=abc&type=tampered")
    end

    should "reject a wrong signing secret" do
      assert_not valid?(secret: "different-secret")
    end

    should "reject a stale timestamp beyond the skew window" do
      stale = (@now - Slack::RequestVerifier::MAX_SKEW_SECONDS - 1).to_s
      sig = Slack::RequestVerifier.sign(timestamp: stale, body: @body, secret: SECRET)
      assert_not valid?(timestamp: stale, signature: sig)
    end

    should "reject a non-numeric timestamp" do
      sig = Slack::RequestVerifier.sign(timestamp: "not-a-number", body: @body, secret: SECRET)
      assert_not valid?(timestamp: "not-a-number", signature: sig)
    end

    should "reject blank signature, timestamp, or secret" do
      assert_not valid?(signature: nil)
      assert_not valid?(timestamp: nil)
      assert_not valid?(secret: nil)
    end
  end

  context ".sign" do
    should "produce a v0= prefixed hex HMAC-SHA256" do
      sig = Slack::RequestVerifier.sign(timestamp: @timestamp, body: @body, secret: SECRET)
      assert_match(/\Av0=[0-9a-f]{64}\z/, sig)
    end
  end
end
