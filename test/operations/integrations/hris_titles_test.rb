# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Operations::Integrations::HrisTitlesTest < ActiveSupport::TestCase
  include HrisMappingFixtures

  setup { build_hris_mapping_tenant }

  def call(tenant_user: @admin_tenant_user, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Integrations::HrisTitles.call(context: hris_context(tenant_user), params: params)
    end
  end

  should "describe every title with its mapping and who needs attention" do
    result = call

    assert result[:level_column_configured]
    settled = result[:titles].find { |t| t[:title] == "Software Engineer" }
    assert_equal({ framework_role_code: "E", level_ordinal: nil, level_source: "hris_level_column" }, settled[:mapping])
    renamed = result[:titles].find { |t| t[:title] == "Engineering Manager (EM3)" }
    assert_nil renamed[:mapping]
    assert_equal [ "Vera Renamed" ], renamed[:needs_attention].map { |p| p[:name] }
  end

  should "narrow to unmapped titles on request" do
    assert_equal [ "Analytics Lead", "Engineering Manager (EM3)" ],
      call(unmapped_only: true)[:titles].map { |t| t[:title] }
  end

  should "list the roles a title can map to, with their levels" do
    ae = call[:framework_roles].find { |r| r[:code] == "AE" }

    assert_equal({ code: "AE", name: "Analytics Engineer", level_ordinals: [ 2, 3 ] }, ae)
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(tenant_user: @member_tenant_user) }
  end
end
