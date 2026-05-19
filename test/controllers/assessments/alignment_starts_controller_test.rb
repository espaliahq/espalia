# frozen_string_literal: true

require "test_helper"

class Assessments::AlignmentStartsControllerTest < ActionDispatch::IntegrationTest
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

      # Seed at least one rating so participant status is `started` —
      # AssessmentPolicy#start_alignment? requires this.
      handler.rate_self(@report.id, framework_id, SecureRandom.uuid_v7,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id)

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  context "POST /assessments/:assessment_id/alignment_start" do
    should "let the manager start alignment and flip participant status to aligning" do
      sign_in @manager_user
      post assessment_alignment_start_path(@report_assignment)

      assert_redirected_to assessment_path(@report_assignment)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_equal "aligning", progress.status
        assert_not_nil progress.alignment_started_at
        assert_equal @manager.id, progress.alignment_started_by_id
      end
    end

    should "deny the assessee from starting alignment" do
      sign_in @report_user
      post assessment_alignment_start_path(@report_assignment)

      assert_response :forbidden

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_not_equal "aligning", progress&.status
      end
    end

    should "deny a second start_alignment once alignment is in progress" do
      sign_in @manager_user
      post assessment_alignment_start_path(@report_assignment)
      assert_redirected_to assessment_path(@report_assignment)

      post assessment_alignment_start_path(@report_assignment)
      assert_response :forbidden
    end

    should "deny an unrelated tenant member" do
      stranger_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        stranger = create(:person, tenant: @tenant, email: stranger_user.email, name: "Stranger")
        create(:tenant_user, tenant: @tenant, user: stranger_user, person: stranger)
      end

      sign_in stranger_user
      post assessment_alignment_start_path(@report_assignment)

      assert_response :forbidden
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
