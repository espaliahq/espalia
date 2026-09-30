# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Operations::Integrations::UnmapHrisTitleTest < ActiveSupport::TestCase
  include HrisMappingFixtures

  setup { build_hris_mapping_tenant }

  def call(tenant_user: @admin_tenant_user, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Integrations::UnmapHrisTitle.call(context: hris_context(tenant_user), params: params)
    end
  end

  should "remove the title and list who now keeps a stale assignment" do
    result = call(title: "software engineer")

    assert_nil @tenant.reload.hris_config.mapping_for("Software Engineer")
    person = result[:people].sole
    assert_equal [ "Sam Settled", "E L3", nil, "unmapped" ],
      person.values_at(:name, :current_assignment, :next_sync_assignment, :status)
  end

  should "refuse a title nobody mapped" do
    error = assert_raises(Operations::Base::ParameterError) { call(title: "Analytics Lead") }

    assert_match(/not mapped/, error.message)
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(title: "Software Engineer", tenant_user: @member_tenant_user) }
    assert @tenant.reload.hris_config.mapping_for("Software Engineer")
  end
end
