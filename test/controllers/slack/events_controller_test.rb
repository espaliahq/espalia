# frozen_string_literal: true

require "test_helper"

class Slack::EventsControllerTest < ActionDispatch::IntegrationTest
  SECRET = "test-signing-secret"

  # POST a raw JSON body signed exactly as Slack would, with the signing secret
  # stubbed onto Slack.oauth_config.
  def post_event(payload, signature: :valid, timestamp: Time.now.to_i.to_s)
    body = payload.to_json
    sig = signature == :valid ? Slack::RequestVerifier.sign(timestamp:, body:, secret: SECRET) : signature
    Slack.stub(:oauth_config, { signing_secret: SECRET }) do
      post slack_events_path, params: body, headers: {
        "CONTENT_TYPE" => "application/json",
        "X-Slack-Signature" => sig,
        "X-Slack-Request-Timestamp" => timestamp
      }
    end
  end

  context "url_verification" do
    should "echo the challenge when the signature is valid" do
      post_event({ type: "url_verification", challenge: "c-3po-r2d2" })
      assert_response :success
      assert_equal "c-3po-r2d2", response.body
    end
  end

  context "event_callback" do
    should "acknowledge a signed event" do
      post_event({ type: "event_callback", event: { type: "message", channel_type: "im", text: "hi" } })
      assert_response :success
    end
  end

  context "an unsigned or forged request" do
    should "reject a wrong signature" do
      post_event({ type: "url_verification", challenge: "x" }, signature: "v0=deadbeef")
      assert_response :unauthorized
    end

    should "reject a missing signature" do
      body = { type: "url_verification", challenge: "x" }.to_json
      Slack.stub(:oauth_config, { signing_secret: SECRET }) do
        post slack_events_path, params: body, headers: { "CONTENT_TYPE" => "application/json" }
      end
      assert_response :unauthorized
    end

    should "reject when no signing secret is configured (fail closed)" do
      body = { type: "url_verification", challenge: "x" }.to_json
      ts = Time.now.to_i.to_s
      sig = Slack::RequestVerifier.sign(timestamp: ts, body:, secret: SECRET)
      Slack.stub(:oauth_config, { signing_secret: nil }) do
        post slack_events_path, params: body, headers: {
          "CONTENT_TYPE" => "application/json", "X-Slack-Signature" => sig, "X-Slack-Request-Timestamp" => ts
        }
      end
      assert_response :unauthorized
    end
  end
end
