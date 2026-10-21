# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeSecretsTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  should "start empty" do
    assert_not @tenant.feedback_exchange_secrets.complete?
    assert_nil @tenant.feedback_exchange_secrets.outbound_secret
  end

  should "store the secrets encrypted" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret-0123456789abcdef0123456789abcd", inbound_secret: "in-secret-0123456789abcdef0123456789abcd")

    stored = ActiveRecord::Base.connection.select_value("SELECT feedback_exchange_credentials FROM tenants WHERE id = '#{@tenant.id}'")
    assert_not_includes stored, "out-secret-0123456789abcdef0123456789abcd"
    assert_equal "out-secret-0123456789abcdef0123456789abcd", @tenant.reload.feedback_exchange_secrets.outbound_secret
    assert @tenant.feedback_exchange_secrets.complete?
  end

  should "keep a secret when its field is left blank" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret-0123456789abcdef0123456789abcd", inbound_secret: "in-secret-0123456789abcdef0123456789abcd")
    @tenant.update_feedback_exchange!(outbound_secret: "", inbound_secret: "")

    assert_equal "out-secret-0123456789abcdef0123456789abcd", @tenant.reload.feedback_exchange_secrets.outbound_secret
    assert_equal "in-secret-0123456789abcdef0123456789abcd", @tenant.feedback_exchange_secrets.inbound_secret
    assert_nil @tenant.feedback_exchange_secrets.previous_inbound_secret
  end

  should "keep the old inbound secret as the previous one when it changes" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret-0123456789abcdef0123456789abcd", inbound_secret: "in-1-0123456789abcdef0123456789abcd")
    freeze_time do
      @tenant.update_feedback_exchange!(inbound_secret: "in-2-0123456789abcdef0123456789abcd")

      secrets = @tenant.reload.feedback_exchange_secrets
      assert_equal "in-2-0123456789abcdef0123456789abcd", secrets.inbound_secret
      assert_equal "in-1-0123456789abcdef0123456789abcd", secrets.previous_inbound_secret
      assert_equal Time.current.to_i, secrets.previous_rotated_at.to_i
    end
  end

  should "not rotate when the same inbound secret is saved again" do
    @tenant.update_feedback_exchange!(inbound_secret: "in-1-0123456789abcdef0123456789abcd")
    @tenant.update_feedback_exchange!(inbound_secret: "in-1-0123456789abcdef0123456789abcd")

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

  context "secret quality" do
    should "refuse a secret shorter than 32 characters" do
      error = assert_raises(ActiveRecord::RecordInvalid) { @tenant.update_feedback_exchange!(outbound_secret: "a" * 31) }
      assert_match(/Outbound secret must be at least 32 characters/, error.message)

      error = assert_raises(ActiveRecord::RecordInvalid) { @tenant.update_feedback_exchange!(inbound_secret: "b" * 31) }
      assert_match(/Inbound secret must be at least 32 characters/, error.message)
    end

    should "accept exactly 32 characters" do
      assert @tenant.update_feedback_exchange!(outbound_secret: "a" * 32, inbound_secret: "b" * 32)
    end

    should "refuse the same secret in both directions" do
      error = assert_raises(ActiveRecord::RecordInvalid) do
        @tenant.update_feedback_exchange!(outbound_secret: "s" * 40, inbound_secret: "s" * 40)
      end
      assert_match(/must differ/, error.message)
    end

    should "refuse an inbound secret equal to the stored outbound secret" do
      @tenant.update_feedback_exchange!(outbound_secret: "s" * 40)

      assert_raises(ActiveRecord::RecordInvalid) { @tenant.update_feedback_exchange!(inbound_secret: "s" * 40) }
    end

    should "not judge secrets on a save that leaves them alone" do
      @tenant.update_columns(feedback_exchange_credentials: { "outbound_secret" => "short", "inbound_secret" => "short2" })

      assert @tenant.reload.update!(name: "Renamed")
    end
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

  should "say which secrets are stored without shadowing Object#presence" do
    assert_equal({ "outbound_secret" => false, "inbound_secret" => false }, @tenant.feedback_exchange_secrets.stored)

    @tenant.update_feedback_exchange!(outbound_secret: "o" * 40)

    assert_equal({ "outbound_secret" => true, "inbound_secret" => false }, @tenant.feedback_exchange_secrets.stored)
  end

  should "never print a value" do
    @tenant.update_feedback_exchange!(outbound_secret: "out-secret-0123456789abcdef0123456789abcd", inbound_secret: "in-secret-0123456789abcdef0123456789abcd")
    secrets = @tenant.feedback_exchange_secrets

    assert_not_includes secrets.inspect, "secret"
    assert_not_includes secrets.to_s, "secret"
    assert_not_includes "#{secrets}", "secret"
  end
end
