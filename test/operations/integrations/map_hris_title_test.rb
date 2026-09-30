# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

# Mapping one HRIS title to a framework role (#436).
class Operations::Integrations::MapHrisTitleTest < ActiveSupport::TestCase
  include HrisMappingFixtures

  setup { build_hris_mapping_tenant }

  def call(tenant_user: @admin_tenant_user, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Integrations::MapHrisTitle.call(context: hris_context(tenant_user), params: params)
    end
  end

  context "mapping a renamed title" do
    should "store it and preview the move the next sync will make" do
      result = call(title: "Engineering Manager (EM3)", framework_role_code: "EM")

      assert_equal "EM", @tenant.reload.hris_config.mapping_for("engineering manager (em3)").framework_role_code
      assert_equal({ framework_role_code: "EM", level_ordinal: nil, level_source: "hris_level_column" }, result[:mapping])
      person = result[:people].sole
      assert_equal [ "Vera Renamed", "E L3", "EM L3", "drift" ],
        person.values_at(:name, :current_assignment, :next_sync_assignment, :status)
    end

    should "join the existing EM mapping rather than start a second one" do
      call(title: "Engineering Manager (EM3)", framework_role_code: "EM")

      em = @tenant.reload.hris_config.role_mappings.select { |m| m.framework_role_code == "EM" }
      assert_equal 1, em.size
      assert_includes em.first.hris_titles, "Engineering Manager (EM3)"
    end

    should "not reassign anyone itself" do
      call(title: "Engineering Manager (EM3)", framework_role_code: "EM")

      assert_equal @e_role.role_id, PersonFrameworkAssignment.find_by(person_id: @renamed.id).role_id
    end
  end

  context "a fixed level" do
    should "apply to everyone with the title" do
      result = call(title: "Analytics Lead", framework_role_code: "AE", level_ordinal: 3)

      assert_equal "fixed", result.dig(:mapping, :level_source)
      assert_equal "AE L3", result[:people].sole[:next_sync_assignment]
    end

    should "be refused when the role has no such level" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(title: "Analytics Lead", framework_role_code: "AE", level_ordinal: 7)
      end

      assert_match(/AE has no level 7/, error.message)
      assert_nil @tenant.reload.hris_config.mapping_for("Analytics Lead")
    end
  end

  context "invalid input" do
    should "refuse a role code the framework doesn't have" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(title: "Analytics Lead", framework_role_code: "ZZ")
      end

      assert_match(/no framework role has the code 'ZZ'/, error.message)
    end

    should "require a fixed level when the workspace has no HRIS level column" do
      @tenant.hris_config.level_field_id = nil
      @tenant.save!

      error = assert_raises(Operations::Base::ParameterError) do
        call(title: "Analytics Lead", framework_role_code: "AE")
      end

      assert_match(/no HRIS level column/, error.message)
    end

    should "refuse a blank title" do
      assert_raises(Operations::Base::ParameterError) do
        call(title: "   ", framework_role_code: "AE", level_ordinal: 3)
      end
    end
  end

  should "refuse a member who is not an admin" do
    assert_raises(Pundit::NotAuthorizedError) do
      call(title: "Analytics Lead", framework_role_code: "AE", level_ordinal: 3, tenant_user: @member_tenant_user)
    end
    assert_nil @tenant.reload.hris_config.mapping_for("Analytics Lead")
  end
end
