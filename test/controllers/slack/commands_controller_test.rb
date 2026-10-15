# frozen_string_literal: true

require "test_helper"
require_relative "../../support/slack_fixture"

class Slack::CommandsControllerTest < ActionDispatch::IntegrationTest
  include SlackFixture

  setup { build_slack_fixture }

  def post_command(text:, user_id: "U_JORDAN", team_id: TEAM_ID, signed: true)
    body = { command: "/growthos", text: text, user_id: user_id, team_id: team_id, trigger_id: "trig.1" }.to_query
    headers = signed ? signed_slack_headers(body) : {}
    Slack.stub(:oauth_config, { signing_secret: SECRET }) do
      post slack_commands_path, params: body, headers: headers.merge("CONTENT_TYPE" => "application/x-www-form-urlencoded")
    end
  end

  should "open the feedback modal for a member, seeding any text after the subcommand" do
    with_fake_slack do |fake|
      post_command(text: "feedback great incident call")
      assert_response :success
      call = fake.calls.find { |c| c.first == :open_view }
      assert_not_nil call
      assert_equal "trig.1", call[1]
      view = call[2]
      assert_equal Slack::FeedbackModal::CALLBACK_ID, view[:callback_id]
      content = view[:blocks].find { |b| b[:block_id] == Slack::FeedbackModal::BLOCKS[:content] }
      assert_equal "great incident call", content[:element][:initial_value]
      assert view[:blocks].any? { |b| b[:block_id] == Slack::FeedbackModal::BLOCKS[:capability] }, "offers the framework's capabilities"
    end
  end

  should "explain usage for anything but feedback" do
    with_fake_slack do
      post_command(text: "help")
      assert_response :success
      assert_match(/\/growthos feedback/, response.parsed_body["text"])
      assert_equal "ephemeral", response.parsed_body["response_type"]
    end
  end

  should "open the modal for an HRIS-known person who never signed in, and tell a stranger to ask an admin" do
    with_fake_slack do |fake|
      post_command(text: "feedback", user_id: "U_NIA")
      assert_response :success
      assert_equal 1, fake.calls.count { |c| c.first == :open_view }
      post_command(text: "feedback", user_id: "U_GHOST")
      assert_match(/No GrowthOS account/, response.parsed_body["text"])
      assert_equal 1, fake.calls.count { |c| c.first == :open_view }
    end
  end

  should "answer a replayed request with nothing, and record nothing twice" do
    with_fake_slack do |fake|
      body = { command: "/growthos", text: "feedback", user_id: "U_JORDAN", team_id: TEAM_ID, trigger_id: "trig.1" }.to_query
      headers = signed_slack_headers(body).merge("CONTENT_TYPE" => "application/x-www-form-urlencoded")
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
        Slack.stub(:oauth_config, { signing_secret: SECRET }) do
          2.times { post slack_commands_path, params: body, headers: headers }
        end
      end
      assert_response :success
      assert_equal 1, fake.calls.count { |c| c.first == :open_view }
    end
  end

  should "refuse a workspace that isn't connected" do
    with_fake_slack do
      post_command(text: "feedback", team_id: "T_OTHER")
      assert_match(/isn't connected/, response.parsed_body["text"])
    end
  end

  should "reject an unsigned request" do
    post_command(text: "feedback", signed: false)
    assert_response :unauthorized
  end
end
