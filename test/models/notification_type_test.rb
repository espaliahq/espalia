# frozen_string_literal: true

require "test_helper"

class NotificationTypeTest < ActiveSupport::TestCase
  context ".all / .find / .exists?" do
    should "expose registered definitions" do
      assert_includes NotificationType.all.map(&:key), :evidence_requested
      assert_equal "Feedback requested from you", NotificationType.find(:evidence_requested).label
      assert NotificationType.exists?("evidence_requested")
      assert_not NotificationType.exists?(:nonexistent_type)
    end

    should "register the comment notification types" do
      keys = NotificationType.all.map(&:key)
      assert_includes keys, :comment_reply
      assert_includes keys, :assessment_commented
      assert_includes keys, :team_assessment_commented

      # All three escalate to Slack by default — conversational notifications
      # should reach absent recipients; a drowning manager can opt out per type.
      assert NotificationType.enabled?({}, :comment_reply, :slack)
      assert NotificationType.enabled?({}, :assessment_commented, :slack)
      assert NotificationType.enabled?({}, :team_assessment_commented, :slack)
    end
  end

  context ".enabled?" do
    should "fall back to the registry default when no override is present" do
      assert NotificationType.enabled?({}, :evidence_requested, :slack)
      assert_not NotificationType.enabled?({}, :evidence_request_responded, :slack)
    end

    should "honour an explicit override over the default" do
      overrides = { "evidence_requested" => { "slack" => false } }
      assert_not NotificationType.enabled?(overrides, :evidence_requested, :slack)

      overrides = { "evidence_request_responded" => { "slack" => true } }
      assert NotificationType.enabled?(overrides, :evidence_request_responded, :slack)
    end

    should "accept symbol and string type/channel keys" do
      assert NotificationType.enabled?({}, "evidence_requested", "in_app")
      assert NotificationType.enabled?({}, :evidence_requested, :in_app)
    end

    should "fail closed for unknown types or channels" do
      assert_not NotificationType.enabled?({}, :nonexistent_type, :slack)
      assert_not NotificationType.enabled?({}, :evidence_requested, :sms)
    end
  end
end
