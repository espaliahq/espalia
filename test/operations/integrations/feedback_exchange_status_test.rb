# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Operations::Integrations::FeedbackExchangeStatusTest < ActiveSupport::TestCase
  include HrisMappingFixtures

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @admin_tenant_user = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tenant_user = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def call(tenant_user: @admin_tenant_user)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Integrations::FeedbackExchangeStatus.call(context: hris_context(tenant_user), params: {})
    end
  end

  should "report an unconfigured exchange" do
    result = call

    assert_equal :not_configured, result[:state]
    assert_not result[:connected]
    assert_equal({ outbound: false, inbound: false }, result[:secrets])
    assert_equal({ feedback: false, deletions: false }, result[:cursors])
  end

  should "report a connected exchange without exposing a secret" do
    freeze_time do
      @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(
        peer_name: "chip", base_url: "https://chip.example.com/x", enabled: true,
        cursor: "c1", last_synced_at: Time.current
      ))
      @tenant.update_feedback_exchange!(outbound_secret: "out-secret-value", inbound_secret: "in-secret-value")

      result = call

      assert_equal :active, result[:state]
      assert result[:connected]
      assert_equal "chip", result[:peer]
      assert_equal "https://chip.example.com/x", result[:peer_address]
      assert_equal Time.current.iso8601, result[:last_synced_at]
      assert_equal({ feedback: true, deletions: false }, result[:cursors])
      assert_equal({ outbound: true, inbound: true }, result[:secrets])
      assert_not_includes result.to_json, "secret-value"
    end
  end

  should "report what the import has done, and whom it could not find" do
    ActsAsTenant.with_tenant(@tenant) do
      %w[imported imported updated].each_with_index do |status, i|
        FeedbackExchangeImport.create!(origin: "chip", external_id: "r#{i}", status: status, synced_at: Time.current)
      end
      FeedbackExchangeImport.create!(origin: "chip", external_id: "r9", status: "skipped", skip_reason: "recipient_unmatched",
                                     record: { recipient: { email: "new@example.com", display_name: "New" } },
                                     synced_at: Time.current)
    end

    result = call

    assert_equal({ imported: 2, updated: 1, withdrawn: 0, skipped: 1, skip_reasons: { "recipient_unmatched" => 1 } },
                 result[:imports])
    assert_equal [ { email: "new@example.com", display_name: "New", role: "recipient", records: 1 } ], result[:unmatched_people]
  end

  should "report missing secrets" do
    @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(peer_name: "chip", base_url: "https://chip.example.com", enabled: true))

    assert_equal :missing_secrets, call[:state]
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member_tenant_user) }
  end
end
