# frozen_string_literal: true

require "test_helper"

class Assessments::AlignmentCompletionsControllerTest < ActionDispatch::IntegrationTest
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

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  context "POST /assessments/:assessment_id/alignment_completion" do
    # The setup seeds no framework capabilities, so the assessed level has no
    # cells — this also pins the completion gate's zero-cell behaviour: a role
    # with nothing to align never blocks completion.
    should "let the manager mark alignment complete and flip status to aligned" do
      sign_in @manager_user
      post assessment_alignment_completion_path(@report_assignment)

      assert_redirected_to assessment_path(@report_assignment)

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_equal "aligned", progress.status
        assert_not_nil progress.aligned_at
        assert_equal @manager.id, progress.aligned_by_id
      end
    end

    should "deny the assessee from completing alignment" do
      sign_in @report_user
      post assessment_alignment_completion_path(@report_assignment)

      assert_response :forbidden

      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_not_equal "aligned", progress&.status
      end
    end

    should "deny a second completion once aligned" do
      sign_in @manager_user
      post assessment_alignment_completion_path(@report_assignment)
      assert_redirected_to assessment_path(@report_assignment)

      post assessment_alignment_completion_path(@report_assignment)
      assert_response :forbidden
    end
  end

  context "completion gate with current-level capabilities" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        category = create(:framework_capability_category,
          framework_id: @framework.framework_id, name: "Thinking", ordinal: 1)
        @cap = create(:framework_capability, category_id: category.category_id,
          name: "Critical Thinking")
        create(:framework_capability_role_binding,
          capability_id: @cap.capability_id, role_id: @role.role_id)
        create(:framework_behavioural_expectation, capability_id: @cap.capability_id,
          level_ordinal: 2, description: "Synthesises information")
      end
    end

    should "block completion while a current-level cell lacks an agreed rating" do
      sign_in @manager_user
      post assessment_alignment_completion_path(@report_assignment)

      assert_redirected_to assessment_path(@report_assignment)
      assert_match(/1 current-level capability still needs an agreed rating/, flash[:alert])
      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_equal "aligning", progress.status
        assert_nil progress.aligned_at
      end
    end

    should "complete once every current-level cell carries an agreed rating" do
      ActsAsTenant.with_tenant(@tenant) do
        # The capability was bound after alignment started, so the aligner
        # names the role that now reads it.
        PersonDevelopment::CommandHandler.new.align_assessment(
          @report.id, @framework.framework_id, @cap.stable_id,
          level_ordinal: 2, aligned_frequency: "consistent", cycle_id: @cycle_id,
          aligned_by_id: @manager.id, role_id: @role.role_id
        )
      end

      sign_in @manager_user
      post assessment_alignment_completion_path(@report_assignment)

      assert_redirected_to assessment_path(@report_assignment)
      ActsAsTenant.with_tenant(@tenant) do
        progress = AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @report.id)
        assert_equal "aligned", progress.status
      end
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
