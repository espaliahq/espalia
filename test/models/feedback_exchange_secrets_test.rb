# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeSecretsTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  should "start empty" do
    assert_not @tenant.feedback_exchange_secrets.complete?
    assert_nil @tenant.feedback_exchange_secrets.outbound_secret
  end

  should "store the secrets encrypted" do
    @tenant.update_feedback_exchange_secrets!(outbound_secret: "out-secret", inbound_secret: "in-secret")

    stored = ActiveRecord::Base.connection.select_value("SELECT feedback_exchange_credentials FROM tenants WHERE id = '#{@tenant.id}'")
    assert_not_includes stored, "out-secret"
    assert_equal "out-secret", @tenant.reload.feedback_exchange_secrets.outbound_secret
    assert @tenant.feedback_exchange_secrets.complete?
  end

  should "keep a secret when its field is left blank" do
    @tenant.update_feedback_exchange_secrets!(outbound_secret: "out-secret", inbound_secret: "in-secret")
    @tenant.update_feedback_exchange_secrets!(outbound_secret: "", inbound_secret: "")

    assert_equal "out-secret", @tenant.reload.feedback_exchange_secrets.outbound_secret
    assert_equal "in-secret", @tenant.feedback_exchange_secrets.inbound_secret
    assert_nil @tenant.feedback_exchange_secrets.previous_inbound_secret
  end

  should "keep the old inbound secret as the previous one when it changes" do
    @tenant.update_feedback_exchange_secrets!(outbound_secret: "out-secret", inbound_secret: "in-1")
    freeze_time do
      @tenant.update_feedback_exchange_secrets!(inbound_secret: "in-2")

      secrets = @tenant.reload.feedback_exchange_secrets
      assert_equal "in-2", secrets.inbound_secret
      assert_equal "in-1", secrets.previous_inbound_secret
      assert_equal Time.current.to_i, secrets.previous_rotated_at.to_i
    end
  end

  should "not rotate when the same inbound secret is saved again" do
    @tenant.update_feedback_exchange_secrets!(inbound_secret: "in-1")
    @tenant.update_feedback_exchange_secrets!(inbound_secret: "in-1")

    assert_nil @tenant.reload.feedback_exchange_secrets.previous_inbound_secret
  end

  should "never print a value" do
    @tenant.update_feedback_exchange_secrets!(outbound_secret: "out-secret", inbound_secret: "in-secret")
    secrets = @tenant.feedback_exchange_secrets

    assert_not_includes secrets.inspect, "secret"
    assert_not_includes secrets.to_s, "secret"
    assert_not_includes "#{secrets}", "secret"
  end
end
