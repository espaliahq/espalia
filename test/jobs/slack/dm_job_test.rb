# frozen_string_literal: true

require "test_helper"
require_relative "../../support/slack_fixture"

class Slack::DmJobTest < ActiveJob::TestCase
  include SlackFixture

  setup { build_slack_fixture }

  should "deliver the DM through the tenant's client, button included" do
    with_fake_slack do |fake|
      Slack::DmJob.perform_now(@tenant.id, "U_JORDAN", "Thanks.", url: "https://example.test/x", button: "Open")
      dm = fake.calls.find { |c| c.first == :post_dm }
      assert_equal "U_JORDAN", dm[1]
      assert_equal "https://example.test/x", dm[3].last.dig(:elements, 0, :url)
    end
  end

  should "resolve the recipient by email when no Slack id is known" do
    with_fake_slack do |fake|
      Slack::DmJob.perform_now(@tenant.id, nil, "A link.", email: "newcomer@example.com")
      assert_equal "U_NIA", fake.calls.find { |c| c.first == :post_dm }[1]
    end
  end

  should "do nothing for a tenant that is gone or disconnected" do
    with_fake_slack do |fake|
      Slack::DmJob.perform_now(SecureRandom.uuid, "U_JORDAN", "x")
      @tenant.update!(slack_credentials: {})
      Slack::DmJob.perform_now(@tenant.id, "U_JORDAN", "x")
      assert_empty fake.calls
    end
  end
end
