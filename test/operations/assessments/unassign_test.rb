# frozen_string_literal: true

require "test_helper"

# Operations::Assessments::Unassign:
# - tenant admin removes a person's framework assignment (row deleted)
# - blocked while the person is enrolled in an open cycle (unenroll first)
# - denies non-admins (assessee, manager)
class Operations::Assessments::UnassignTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @report_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin  = create(:person, tenant: @tenant, email: @admin_user.email, name: "Admin")
      @report = create(:person, tenant: @tenant, email: @report_user.email, name: "Rep")
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin, role: :admin)
      @report_tu = create(:tenant_user, tenant: @tenant, user: @report_user, person: @report, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      PersonDevelopment::CommandHandler.new.assign_to_framework(
        @report.id, @framework_id, @role.role_id, @level.level_id
      )
      @assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end

    @admin_context = AuthorizationContext.new(
      user: @admin_user, tenant_user: @admin_tu, person: @admin
    )
  end

  def call_as(context, reason: nil)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::Unassign.call(
        context: context,
        params: { assignment_id: @assignment.id, reason: reason }
      )
    end
  end

  context "as tenant admin, no open cycle" do
    should "delete the assignment row and return the previous role/level" do
      result = call_as(@admin_context, reason: "data_correction")

      ActsAsTenant.with_tenant(@tenant) do
        assert_nil PersonFrameworkAssignment.find_by(id: @assignment.id)
      end
      assert_equal @report.id, result[:person_id]
      assert_equal @framework_id, result[:framework_id]
      assert_equal @role.role_id, result[:previous_role_id]
      assert_equal @level.level_id, result[:previous_level_id]
    end
  end

  context "while enrolled in an open cycle" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        cycles = AssessmentCycles::CommandHandler.new
        cycle_id = SecureRandom.uuid_v7
        cycles.define_cycle(cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @admin.id)
        cycles.enroll(cycle_id, @report.id, enrolled_by: @admin.id)
      end
    end

    should "refuse with a ParameterError and leave the assignment intact" do
      assert_raises(Operations::Base::ParameterError) { call_as(@admin_context) }
      ActsAsTenant.with_tenant(@tenant) do
        assert PersonFrameworkAssignment.exists?(id: @assignment.id)
      end
    end
  end

  context "as a non-admin" do
    should "deny the assessee" do
      ctx = AuthorizationContext.new(
        user: @report_user, tenant_user: @report_tu, person: @report
      )
      assert_raises(Pundit::NotAuthorizedError) { call_as(ctx) }
    end
  end
end
