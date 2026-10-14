# frozen_string_literal: true

require "test_helper"

# Bulk confirm of a category's carried ratings (#480).
class Assessments::CarriedRatingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      @category = cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises information")

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1 2026", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  def seed_carried
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @framework.framework_id, @cap.stable_id, level_ordinal: 2, frequency: "occasional",
        cycle_id: @cycle_id, comment: "Seeded from prior cycle", source: "seeded",
        seeded_from_cycle_id: SecureRandom.uuid_v7
      )
    end
  end

  def rating
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
                                     capability_stable_id: @cap.stable_id, level_ordinal: 2)
    end
  end

  context "as the assessee" do
    setup do
      seed_carried
      sign_in @user
    end

    should "list the category's carried ratings, ticked, with the expectation" do
      get assessment_carried_ratings_path(@assignment, category_id: @category.category_id)

      assert_response :success
      assert_select "input[type=checkbox][name='cells[]'][value='#{@cap.stable_id}|2'][checked]"
      assert_select "li", text: /Synthesises information/
      assert_select "li", text: /Most of the time/
    end

    should "confirm the ticked ratings and return to the category" do
      post assessment_carried_ratings_path(@assignment),
           params: { category_id: @category.category_id, cells: [ "#{@cap.stable_id}|2" ] }

      assert_redirected_to assessment_path(@assignment, category: @category.category_id)
      assert_equal "Confirmed 1 carried rating for this cycle.", flash[:notice]
      assert_equal "human", rating.self_rating_source
      assert_equal "occasional", rating.self_rated_frequency
    end

    should "ask for at least one tick" do
      post assessment_carried_ratings_path(@assignment), params: { category_id: @category.category_id }

      assert_redirected_to assessment_carried_ratings_path(@assignment, category_id: @category.category_id)
      assert_equal "seeded", rating.self_rating_source
    end

    should "say there is nothing to confirm once alignment has started" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.start_alignment(@person.id, @framework.framework_id, @cycle_id,
                                                              started_by_id: @person.id)
      end

      get assessment_carried_ratings_path(@assignment, category_id: @category.category_id)

      assert_redirected_to assessment_path(@assignment)
      assert_equal Assessments::CarriedRatingsController::NOTHING_TO_CONFIRM, flash[:alert]
    end

    should "send an unknown category back to the assessment" do
      get assessment_carried_ratings_path(@assignment, category_id: SecureRandom.uuid_v7)

      assert_redirected_to assessment_path(@assignment)
    end
  end

  context "as someone with no part in the assessment" do
    setup do
      seed_carried
      @stranger = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        stranger_person = create(:person, tenant: @tenant, email: @stranger.email, name: "Stranger")
        create(:tenant_user, tenant: @tenant, user: @stranger, person: stranger_person)
      end
      sign_in @stranger
    end

    should "deny the list and the confirm" do
      get assessment_carried_ratings_path(@assignment, category_id: @category.category_id)
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      post assessment_carried_ratings_path(@assignment),
           params: { category_id: @category.category_id, cells: [ "#{@cap.stable_id}|2" ] }
      assert_equal "seeded", rating.self_rating_source
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
