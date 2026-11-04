# frozen_string_literal: true

require "test_helper"

class TenantDisconnectTest < ActiveSupport::TestCase
  context "#disconnect_hris!" do
    should "drop the credentials and stop the sync, keeping the config" do
      tenant = create(:tenant, :with_hibob_config)

      tenant.disconnect_hris!

      tenant.reload
      assert_nil tenant.hris_credentials
      assert_not tenant.hris_secrets.complete?
      assert_not tenant.hris_config.sync_enabled?
      assert_equal "hibob", tenant.hris_config.provider, "the config survives for a reconnect"
      assert_not_empty tenant.hris_config.role_mappings
      assert_not tenant.hris_config.configured?(tenant)
    end

    should "sever even when the stored config no longer validates" do
      tenant = create(:tenant, :with_hibob_config)
      tenant.update_columns(hris_config: HrisConfig.new(provider: "bamboohr", sync_enabled: true))

      tenant.disconnect_hris!

      tenant.reload
      assert_nil tenant.hris_credentials
      assert_not tenant.hris_config.sync_enabled?
    end

    should "keep sync state a job wrote since this tenant was loaded" do
      tenant = create(:tenant, :with_hibob_config)
      stale = Tenant.find(tenant.id)
      tenant.with_lock do
        tenant.hris_config.last_synced_at = Time.zone.parse("2026-11-01 10:00")
        tenant.save!
      end

      stale.disconnect_hris!

      assert_equal Time.zone.parse("2026-11-01 10:00"), stale.reload.hris_config.last_synced_at
    end
  end

  context "#remove_ai_api_key!" do
    should "drop the key and switch suggestions off, keeping the model settings" do
      tenant = create(:tenant, :with_ai_model)
      tenant.update_ai_model!(settings: { suggestions_enabled: true })

      tenant.remove_ai_api_key!

      tenant.reload
      assert_nil tenant.ai_credentials
      assert_not tenant.ai_secrets.api_key?
      assert_not tenant.ai_config.suggestions_enabled?
      assert_equal "anthropic", tenant.ai_config.provider, "the settings survive"
      assert_raises(ActiveRecord::RecordInvalid, "suggestions cannot come back without a key") do
        tenant.update_ai_model!(settings: { suggestions_enabled: true })
      end
    end

    should "clear the legacy settings switch too" do
      tenant = create(:tenant, :with_ai_model, settings: { "evidence_suggestions_enabled" => true })

      tenant.remove_ai_api_key!

      assert_not tenant.reload.evidence_suggestions_enabled?
    end

    should "work on an instance left dirty by a refused save" do
      tenant = create(:tenant, :with_ai_model)
      assert_raises(ActiveRecord::RecordInvalid) do
        tenant.update_ai_model!(settings: { provider: "openai_compatible", base_url: "https://other.example.com/v1", model: "a/b" })
      end

      tenant.remove_ai_api_key!

      assert_not tenant.reload.ai_secrets.api_key?
    end
  end

  context "#disconnect_feedback_exchange!" do
    should "drop both secrets and the key ids, disable the exchange, keep the peer" do
      tenant = create(:tenant)
      tenant.update_feedback_exchange!(
        settings: { provider: "exchange", peer_name: "chip", base_url: "https://chip.example.com/api/feedback-exchange", enabled: true },
        outbound_secret: "out-secret-0123456789abcdef0123456789abcd",
        inbound_secret: "in-secret-0123456789abcdef0123456789abcd"
      )
      assert tenant.reload.inbound_key_id.present?

      tenant.disconnect_feedback_exchange!

      tenant.reload
      assert_nil tenant.feedback_exchange_credentials
      assert_not tenant.feedback_exchange_secrets.complete?
      assert_nil tenant.inbound_key_id
      assert_nil tenant.previous_inbound_key_id
      assert_not tenant.feedback_exchange_config.enabled?
      assert_equal "chip", tenant.feedback_exchange_config.peer_name, "the peer survives for a reconnect"
    end
  end
end
