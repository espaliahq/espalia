# frozen_string_literal: true

require "test_helper"

# Checks the shape of the assessments_mine Operation: which rows belong
# in `own:` vs `direct_reports:`, the embedded payload fields, and that
# strangers (no Person link) get a Pundit denial. The MCP transport
# layer is covered separately by McpServerTest.
class Operations::Assessments::MineTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @person  = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      @report  = create(:person, tenant: @tenant, manager_id: @person.id, name: "Bob")
      @outside = create(:person, tenant: @tenant, name: "Carol") # not a report
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      pd_handler     = PersonDevelopment::CommandHandler.new
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler.assign_to_framework(@person.id,  framework_id, @role.role_id, @level.level_id)
      pd_handler.assign_to_framework(@report.id,  framework_id, @role.role_id, @level.level_id)
      pd_handler.assign_to_framework(@outside.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)
      cycles_handler.enroll(@cycle_id, @report.id, enrolled_by: @person.id)
    end

    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::Mine.call(context: @context)
    end
  end

  context "own" do
    should "include the caller's assignment with framework, role, level and current cycle" do
      result = call_op

      assert_equal 1, result[:own].size
      row = result[:own].first
      assert_equal "Engineering", row.dig(:framework, :name)
      assert_equal "E",  row.dig(:role, :code)
      assert_equal 2,    row.dig(:level, :ordinal)
      assert_equal "Q1", row.dig(:current_cycle, :name)
      assert_equal "open", row.dig(:current_cycle, :status)
      refute row.key?(:assessee), "own rows should not carry an :assessee key"
    end
  end

  context "direct_reports" do
    should "include only direct reports, each with their assessee identity" do
      result = call_op

      report_names = result[:direct_reports].map { |r| r.dig(:assessee, :name) }
      assert_equal [ "Bob" ], report_names
      refute_includes report_names, "Carol", "non-reports must not appear"
    end

    should "return an empty array when the caller has no direct reports" do
      lone_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        lone_person = create(:person, tenant: @tenant, email: lone_user.email)
        tu = create(:tenant_user, tenant: @tenant, user: lone_user, person: lone_person, role: :member)
        ctx = AuthorizationContext.new(user: lone_user, tenant_user: tu, person: lone_person)
        result = Operations::Assessments::Mine.call(context: ctx)
        assert_equal [], result[:direct_reports]
      end
    end
  end

  context "policy" do
    should "deny callers without a linked Person" do
      stranger_user = create(:user)
      ctx = AuthorizationContext.new(user: stranger_user, tenant_user: nil, person: nil)

      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Assessments::Mine.call(context: ctx)
        end
      end
    end
  end
end
