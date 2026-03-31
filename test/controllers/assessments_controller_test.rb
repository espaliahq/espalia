# frozen_string_literal: true

require "test_helper"

class AssessmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      # Build framework via factories
      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      create(:framework_level, role_id: @role.role_id, ordinal: 1, title: "Junior", code: "E1")

      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 1, description: "Asks good questions")
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises information")

      # Create assignment with open cycle via event projection
      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)
      handler.open_assessment_cycle(
        @person.id, framework_id,
        SecureRandom.uuid_v7, "Q1 2026", "regular", 1
      )

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  context "GET /assessments" do
    should "render index with framework assignments" do
      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Engineering Growth"
      assert_includes response.body, "My Assessments"
    end

    should "redirect unauthenticated users to sign in" do
      get assessments_path
      assert_redirected_to new_user_session_path
    end
  end

  context "GET /assessments/:id" do
    should "render assessment matrix for assigned framework" do
      sign_in @user
      get assessment_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "Engineering Growth"
      assert_includes response.body, "Critical Thinking"
      assert_includes response.body, "assessment-matrix"
      assert_includes response.body, "scoring-panel"
    end

    should "show frequency selectors" do
      sign_in @user
      get assessment_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "Some"
      assert_includes response.body, "Occasional"
      assert_includes response.body, "Consistent"
    end

    should "redirect if person not assigned to framework" do
      sign_in @user
      get assessment_path("nonexistent-id")

      assert_redirected_to assessments_path
    end

    should "redirect unauthenticated users to sign in" do
      get assessment_path(@framework.framework_id)
      assert_redirected_to new_user_session_path
    end
  end

  context "as manager" do
    setup do
      @manager_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
        create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
        @person.update!(manager: @manager)
      end
    end

    should "render manager assessment view for direct report" do
      sign_in @manager_user
      get assessment_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "Manager Review"
      assert_includes response.body, @person.name
      assert_includes response.body, "assessment-matrix"
    end

    should "show team assessments section on index" do
      sign_in @manager_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Team Assessments"
      assert_includes response.body, @person.name
    end

    should "redirect if not manager and not assignee" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Other")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end

      sign_in other_user
      get assessment_path(@framework.framework_id)

      assert_redirected_to assessments_path
    end
  end

  context "GET /assessments/:id/matrix" do
    should "render Turbo Frame without layout" do
      sign_in @user
      get matrix_assessment_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "assessment-matrix"
      assert_not_includes response.body, "<html"
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
