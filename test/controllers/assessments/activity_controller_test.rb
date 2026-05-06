# frozen_string_literal: true

require "test_helper"

class Assessments::ActivityControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Test FW")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "SE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 1, title: "E1", code: "E1")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking")
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 1, description: "x")

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      handler.rate_self(@person.id, framework_id, @cap.stable_id,
        level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  context "GET /assessments/:assessment_id/activity" do
    should "render the activity Turbo Frame for the assessee" do
      sign_in @user
      get assessment_activity_path(@assignment)
      assert_response :success
      assert_match "assessment-activity", response.body
      assert_match "Self-rated", response.body
    end

    should "render an empty state when there's no activity" do
      ActsAsTenant.with_tenant(@tenant) do
        other_person = create(:person, tenant: @tenant, name: "Other")
        # Set up an assignment with no events.
        framework_id = SecureRandom.uuid_v7
        framework = create(:framework_state, framework_id: framework_id, name: "Empty")
        rf = create(:framework_role_family, framework_id: framework_id, name: "X")
        role = create(:framework_role,
          role_family_id: rf.role_family_id, name: "R", code: "R", track: "ic")
        level = create(:framework_level, role_id: role.role_id, ordinal: 1, title: "L", code: "L1")
        empty_assignment = create(:person_framework_assignment,
          tenant: @tenant, person_id: other_person.id, framework_id: framework_id,
          role_id: role.role_id, level_id: level.level_id)
        other_person.update!(manager: @person)
        @empty_assignment = empty_assignment
      end

      sign_in @user
      get assessment_activity_path(@empty_assignment)
      assert_response :success
      assert_match "No activity yet", response.body
    end

    should "deny an unrelated viewer" do
      ActsAsTenant.with_tenant(@tenant) do
        target = create(:person, tenant: @tenant, name: "Stranger")
        @other_assignment = create(:person_framework_assignment,
          tenant: @tenant, person_id: target.id, framework_id: SecureRandom.uuid_v7,
          role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7)
      end

      sign_in @user
      get assessment_activity_path(@other_assignment)
      assert_response :redirect
    end

    should "redirect unauthenticated requests" do
      get assessment_activity_path(@assignment)
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
