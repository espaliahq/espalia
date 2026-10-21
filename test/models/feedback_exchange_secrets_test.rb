# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeSecretsTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  should "start empty" do
    assert_not @tenant.feedback_exchange_secrets.complete?
    assert_nil @tenant.feedback_exchange_secrets.outbound_secret
  end

  should "store the secrets encrypted" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret", inbound_secret: "in-secret")

    stored = ActiveRecord::Base.connection.select_value("SELECT feedback_exchange_credentials FROM tenants WHERE id = '#{@tenant.id}'")
    assert_not_includes stored, "out-secret"
    assert_equal "out-secret", @tenant.reload.feedback_exchange_secrets.outbound_secret
    assert @tenant.feedback_exchange_secrets.complete?
  end

  should "keep a secret when its field is left blank" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret", inbound_secret: "in-secret")
    @tenant.update_feedback_exchange!(outbound_secret: "", inbound_secret: "")

    assert_equal "out-secret", @tenant.reload.feedback_exchange_secrets.outbound_secret
    assert_equal "in-secret", @tenant.feedback_exchange_secrets.inbound_secret
    assert_nil @tenant.feedback_exchange_secrets.previous_inbound_secret
  end

  should "keep the old inbound secret as the previous one when it changes" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret", inbound_secret: "in-1")
    freeze_time do
      @tenant.update_feedback_exchange!(inbound_secret: "in-2")

      secrets = @tenant.reload.feedback_exchange_secrets
      assert_equal "in-2", secrets.inbound_secret
      assert_equal "in-1", secrets.previous_inbound_secret
      assert_equal Time.current.to_i, secrets.previous_rotated_at.to_i
    end
  end

  should "not rotate when the same inbound secret is saved again" do
    @tenant.update_feedback_exchange!(inbound_secret: "in-1")
    @tenant.update_feedback_exchange!(inbound_secret: "in-1")

    assert_nil @tenant.reload.feedback_exchange_secrets.previous_inbound_secret
  end

  should "keep sync state written since the tenant was loaded" do
    @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(peer_name: "chip", base_url: "https://chip.example.com"))
    stale = Tenant.find(@tenant.id)

    fresh = Tenant.find(@tenant.id)
    fresh.update!(feedback_exchange_config: FeedbackExchangeConfig.new(
      fresh.feedback_exchange_config.attributes.merge("cursor" => "c-42", "last_synced_at" => Time.current)
    ))

    stale.update_feedback_exchange!(settings: { peer_name: "chip2" })

    config = @tenant.reload.feedback_exchange_config
    assert_equal "chip2", config.peer_name
    assert_equal "c-42", config.cursor
    assert_not_nil config.last_synced_at
  end

  context "inbound key ids" do
    should "follow the stored inbound and previous secrets" do
      @tenant.update_feedback_exchange!(inbound_secret: "inbound-one-inbound-one-inbound-one-1")
      @tenant.update_feedback_exchange!(inbound_secret: "inbound-two-inbound-two-inbound-two-2")

      @tenant.reload
      assert_equal FeedbackExchange::Signature.key_id("inbound-two-inbound-two-inbound-two-2"), @tenant.inbound_key_id
      assert_equal FeedbackExchange::Signature.key_id("inbound-one-inbound-one-inbound-one-1"), @tenant.previous_inbound_key_id
    end

    should "be empty without an inbound secret" do
      @tenant.update_feedback_exchange!(outbound_secret: "outbound-only-outbound-only-0123456789")

      assert_nil @tenant.reload.inbound_key_id
    end

    should "refuse an inbound secret another workspace already uses" do
      other = create(:tenant)
      other.update_feedback_exchange!(inbound_secret: "shared-by-mistake-shared-by-mistake-1")

      error = assert_raises(ActiveRecord::RecordInvalid) do
        @tenant.update_feedback_exchange!(inbound_secret: "shared-by-mistake-shared-by-mistake-1")
      end
      assert_match(/already in use by another workspace/, error.message)
      assert_nil @tenant.reload.inbound_key_id
    end

    should "refuse an inbound secret another workspace still accepts as its previous one" do
      other = create(:tenant)
      other.update_feedback_exchange!(inbound_secret: "old-one-old-one-old-one-old-one-old-1")
      other.update_feedback_exchange!(inbound_secret: "new-one-new-one-new-one-new-one-new-1")

      assert_raises(ActiveRecord::RecordInvalid) do
        @tenant.update_feedback_exchange!(inbound_secret: "old-one-old-one-old-one-old-one-old-1")
      end
    end

    should "let a tenant save its own secret again" do
      @tenant.update_feedback_exchange!(inbound_secret: "mine-mine-mine-mine-mine-mine-mine-1")
      assert @tenant.update_feedback_exchange!(settings: { peer_name: "chip" })
    end
  end

  should "never print a value" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret", inbound_secret: "in-secret")
    secrets = @tenant.feedback_exchange_secrets

    assert_not_includes secrets.inspect, "secret"
    assert_not_includes secrets.to_s, "secret"
    assert_not_includes "#{secrets}", "secret"
  end
end
