# frozen_string_literal: true

require "test_helper"
require_relative "../support/inbox_test_notifier"

# Exercises the smart-escalation gate on the notifier base via a concrete
# test notifier (bound to :evidence_requested — default in_app + slack on).
class ApplicationNotifierTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member) }
  end

  def notification_for(user)
    InboxTestNotifier.with(title: "Hi").deliver(user)
    user.notifications.reload.first
  end

  context "smart escalation" do
    should "wait the escalation delay and gate on unread when in-app is enabled" do
      n = notification_for(@user)

      assert_equal ApplicationNotifier::ESCALATION_DELAY, n.external_wait
      assert n.escalate_external?(:slack), "unread in-app should escalate to slack"

      n.mark_as_read!
      assert_not n.escalate_external?(:slack), "read in-app should suppress the slack ping"
    end

    should "deliver externally immediately when in-app is disabled" do
      @user.update_notification_preference(:evidence_requested, in_app: false, slack: true)
      n = notification_for(@user)

      assert_equal 0, n.external_wait
      assert n.escalate_external?(:slack), "no in-app copy means no duplication — send now"
    end

    should "not escalate when the channel itself is disabled" do
      @user.update_notification_preference(:evidence_requested, slack: false)
      n = notification_for(@user)

      assert_not n.escalate_external?(:slack)
    end
  end
end
