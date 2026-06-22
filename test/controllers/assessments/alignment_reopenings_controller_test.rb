# frozen_string_literal: true

require "test_helper"

class Assessments::AlignmentReopeningsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user, password: "password123")
    @report_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @report = create(:person, tenant: @tenant, email: @report_user.email, name: "Report",
        manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @report_user, person: @report)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@report.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1 2026", "regular", 1, defined_by: @manager.id)
      cycle_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      handler.rate_self(@report.id, framework_id, SecureRandom.uuid_v7,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id)
      handler.start_alignment(@report.id, framework_id, @cycle_id, started_by_id: @manager.id)
      handler.complete_alignment(@report.id, framework_id, @cycle_id, completed_by_id: @manager.id)

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  context "POST /assessments/:assessment_id/alignment_reopening" do
    should "let the manager re-open a completed alignment back to aligning" do
      sign_in @manager_user
      post assessment_alignment_reopening_path(@report_assignment)

      assert_redirected_to assessment_path(@report_assignment)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_equal "aligning", progress.status
        assert_nil progress.aligned_at
      end
    end

    should "deny the assessee from re-opening alignment" do
      sign_in @report_user
      post assessment_alignment_reopening_path(@report_assignment)

      assert_response :forbidden

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_equal "aligned", progress.status
      end
    end

    should "deny re-opening when the cycle is not aligned" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.reopen_alignment(
          @report.id, @framework.framework_id, @cycle_id, reopened_by_id: @manager.id
        )
      end
      sign_in @manager_user
      post assessment_alignment_reopening_path(@report_assignment)
      assert_response :forbidden
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
