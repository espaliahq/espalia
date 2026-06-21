# frozen_string_literal: true

require "test_helper"

class Slack::ClientTest < ActiveSupport::TestCase
  setup do
    @stubs = Faraday::Adapter::Test::Stubs.new
    @client = Slack::Client.new(bot_token: "xoxb-test")
    stubbed = Faraday.new(url: Slack::Client::BASE_URL) do |f|
      f.request :json
      f.response :json
      f.adapter :test, @stubs
    end
    @client.instance_variable_set(:@connection, stubbed)
  end

  context "#lookup_user_id_by_email" do
    should "return the Slack user id on success" do
      @stubs.get("/api/users.lookupByEmail") { [ 200, {}, { "ok" => true, "user" => { "id" => "U123" } } ] }
      assert_equal "U123", @client.lookup_user_id_by_email("alex@acme.com")
      @stubs.verify_stubbed_calls
    end

    should "return nil when the email isn't in the workspace" do
      @stubs.get("/api/users.lookupByEmail") { [ 200, {}, { "ok" => false, "error" => "users_not_found" } ] }
      assert_nil @client.lookup_user_id_by_email("ghost@acme.com")
    end
  end

  context "#post_dm" do
    should "open a DM then post the message" do
      @stubs.post("/api/conversations.open") { [ 200, {}, { "ok" => true, "channel" => { "id" => "D999" } } ] }
      @stubs.post("/api/chat.postMessage") { [ 200, {}, { "ok" => true } ] }

      assert @client.post_dm(slack_user_id: "U123", text: "Hi", blocks: [ { type: "section" } ])["ok"]
      @stubs.verify_stubbed_calls
    end
  end

  context "error mapping" do
    should "raise AuthenticationError on a token problem" do
      @stubs.post("/api/conversations.open") { [ 200, {}, { "ok" => false, "error" => "invalid_auth" } ] }
      assert_raises(Slack::Errors::AuthenticationError) { @client.open_dm("U123") }
    end

    should "raise ApiError on any other failure" do
      @stubs.post("/api/conversations.open") { [ 200, {}, { "ok" => false, "error" => "channel_not_found" } ] }
      error = assert_raises(Slack::Errors::ApiError) { @client.open_dm("U123") }
      assert_equal "channel_not_found", error.code
    end
  end
end
