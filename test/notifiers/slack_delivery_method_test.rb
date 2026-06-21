# frozen_string_literal: true

require "test_helper"
require_relative "../support/inbox_test_notifier"

# Fake Slack client capturing the DM payload, swapped in for Slack::Client.
class FakeSlackClient
  attr_reader :posted

  def initialize
    @posted = []
  end

  def lookup_user_id_by_email(_email) = "U123"

  def post_dm(**kwargs)
    @posted << kwargs
    { "ok" => true }
  end
end

class SlackDeliveryMethodTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    @tenant.connect_slack!(bot_token: "xoxb-1", team_id: "T1", team_name: "Acme")
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: "alex@acme.com")
      @membership = create(:tenant_user, tenant: @tenant, user: @user, person: person, role: :member)
    end
    # Disable in-app so the Slack job has no wait and the escalation gate passes
    # immediately — exercises the actual send path deterministically.
    @user.update_notification_preference(:evidence_requested, in_app: false, slack: true)
  end

  def deliver_with_fake_slack
    fake = FakeSlackClient.new
    Slack::Client.stub(:new, fake) do
      perform_enqueued_jobs do
        InboxTestNotifier.with(title: "Add evidence", body: "Please help", tenant_id: @tenant.id).deliver(@user)
      end
    end
    fake
  end

  should "DM the recipient and cache their resolved Slack user id" do
    fake = deliver_with_fake_slack

    assert_equal 1, fake.posted.size
    dm = fake.posted.first
    assert_equal "U123", dm[:slack_user_id]
    assert_match "Add evidence", dm[:text]
    assert_equal "U123", @membership.reload.slack_user_id
  end

  should "skip delivery when the tenant has no Slack connection" do
    @tenant.disconnect_slack!
    fake = deliver_with_fake_slack
    assert_empty fake.posted
  end

  should "not raise when the recipient isn't in the Slack workspace" do
    @membership.update_column(:slack_user_id, nil)
    fake = FakeSlackClient.new
    def fake.lookup_user_id_by_email(_email) = nil

    Slack::Client.stub(:new, fake) do
      perform_enqueued_jobs do
        InboxTestNotifier.with(title: "Hi", tenant_id: @tenant.id).deliver(@user)
      end
    end

    assert_empty fake.posted
  end
end
