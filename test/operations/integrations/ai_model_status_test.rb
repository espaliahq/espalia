# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Operations::Integrations::AiModelStatusTest < ActiveSupport::TestCase
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
      Operations::Integrations::AiModelStatus.call(context: hris_context(tenant_user), params: {})
    end
  end

  should "report an unconfigured workspace" do
    result = call

    assert_equal :not_configured, result[:state]
    assert_not result[:configured]
    assert_not result[:api_key_present]
    assert_not result[:suggestions_enabled]
    assert_not result.key?(:pseudonymise_names), "names are always replaced; there is no switch to report"
    assert_equal "claude-opus-5-5", result[:model]
  end

  should "report a gateway workspace by host and model, without the address path or the key" do
    @tenant.update_ai_model!(
      settings: { provider: "openai_compatible", base_url: "https://ai-gateway.vercel.sh/v1", model: "anthropic/claude-opus-5-5",
                  suggestions_enabled: true },
      api_key: "sk-secret-key"
    )

    result = call

    assert_equal :active, result[:state]
    assert result[:configured]
    assert_equal "openai_compatible", result[:provider]
    assert_equal "ai-gateway.vercel.sh", result[:base_host]
    assert_equal "anthropic/claude-opus-5-5", result[:model]
    assert_nil result[:effort]
    assert result[:api_key_present]
    assert_not_includes result.to_json, "sk-secret-key"
    assert_not_includes result.to_json, "/v1"
  end

  should "say a configured but switched-off model is disabled" do
    @tenant.update_ai_model!(settings: { suggestions_enabled: false }, api_key: "sk-a")

    assert_equal :disabled, call[:state]
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member_tenant_user) }
  end
end
